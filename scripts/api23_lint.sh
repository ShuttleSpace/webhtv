#!/usr/bin/env bash
# API 23 兼容性静态审计（lint NewApi）。
#
# 为什么用 lint 而不是自己写脚本比对 android.jar：
#   lint 自带**完整的 API 版本数据库**（哪个方法/字段在哪个 API level 引入），
#   并且能正确处理继承、字段、重载、以及 @RequiresApi / SDK_INT 守卫的判定。
#   自己用 javap 差集 android-23 会有大量误报（继承方法看不到）。
#
# 用法:
#   scripts/api23_lint.sh              # 审计 leanbackArm64_v8aRelease
#   scripts/api23_lint.sh <variant>    # 自定义变体
#
# 环境变量:
#   ANDROID_HOME  SDK 路径，默认 ~/Library/Android/sdk
#
# 产物:
#   app/build/intermediates/lint_intermediate_text_report/<variant>/
#     lintReport<variant>/lint-results-<variant>.txt
#
# 注意：任务名是 lint<Variant>，不是 lintDebug/lint 之类。
#      lint 依赖编译 → 依赖 chaquopy 的 pip 安装任务；本仓库里那个任务会触发
#      批量删除钩子（沙箱环境），因此用 -x 跳过它（pip 产物已存在时才安全）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
VARIANT="${1:-LeanbackArm64_v8aRelease}"
TASK="lint${VARIANT}"

echo "== API 23 兼容性审计 =="
echo "变体: $TASK"
echo "SDK  : $SDK"

REPORT_DIR="app/build/intermediates/lint_intermediate_text_report/$(echo "$VARIANT" | tr 'A-Z' 'a-z')"
REPORT_GLOB=$(find app/build/intermediates/lint_intermediate_text_report -name "lint-results-*.txt" 2>/dev/null | head -1)

export PATH="/Users/humphrey/.local/share/mise/installs/python/3.10.22/bin:$PATH"
PH=$(python3 -c "import os,urllib.parse as u;p=u.urlparse(os.environ.get('HTTPS_PROXY') or os.environ.get('https_proxy') or '');print(p.hostname or '127.0.0.1')")
PP=$(python3 -c "import os,urllib.parse as u;p=u.urlparse(os.environ.get('HTTPS_PROXY') or os.environ.get('https_proxy') or '');print(p.port or 8080)")

./gradlew ":app:$TASK" \
  -x :chaquo:installArm64_v8aReleasePythonRequirements \
  --console=plain \
  -Dhttp.proxyHost="$PH" -Dhttp.proxyPort="$PP" \
  -Dhttps.proxyHost="$PH" -Dhttps.proxyPort="$PP" 2>&1 | tail -5

REPORT=$(find app/build/intermediates/lint_intermediate_text_report -name "lint-results-*.txt" 2>/dev/null | head -1)
if [ -z "$REPORT" ]; then
  echo "未找到 lint 报告" >&2
  exit 1
fi

echo
echo "== NewApi 清单（API 23 上不存在的调用）=="
COUNT=$(grep -cE "\[NewApi\]$" "$REPORT")
grep -E "\[NewApi\]$" "$REPORT" | sed "s|$ROOT/||" | sed 's/ Error: Call requires/  →/; s/ Error: Class requires/  →/; s/ Error: Field requires/  →/'
echo
echo "共 $COUNT 条。判定规则："
echo "  · 有 SDK_INT 版本守卫 / try-catch / @RequiresApi 的 → 安全"
echo "  · 无守卫的 → API 23 上必崩 NoSuchMethodError / NoSuchFieldError"
echo "  · 报告全文: $REPORT"
