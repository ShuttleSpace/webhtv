#!/usr/bin/env bash
#
# patch_chaquopy_minsdk.sh
#
# webhtv 为支持 Android 6.0 (API 23) 把 minSdk 降到 23，但 Chaquopy 17.0.0 的 Gradle
# 插件有两处会因此失败，本脚本对 ~/.gradle/caches 里的插件 jar（构建缓存）打两处补丁：
#
#   1) 配置期守卫 (PythonPlugin.onVariant)
#      Chaquopy 16.0.0+ 硬编码了 "minSdk >= 24" 策略守卫：
#      "This version of Chaquopy requires minSdk version 24 or higher"。
#      把 `bipush 24` 改成 `bipush 1`（apiLevel >= 1 永远成立）即可让它永不触发。
#
#   2) 构建期 wheel 平台标签下限 (chaquopy/pip_install.py -> platform_tag)
#      Chaquopy 把项目 minSdk 作为 --min-api-level 传给 pip，于是只匹配
#      `android_<minSdk>_*` 的 wheel。但 Chaquopy 的 pypi 镜像里所有 Python >= 3.10
#      的 wheel 都打在 `android_24_*`（API 24+），minSdk=23 时 pip 报
#      "from versions: none"（lxml/ujson/pycryptodome 等装不上）。
#      把平台标签下限抬到 24（max(min_api_level, 24)）即可让这些 wheel 被选中。
#      这是构建期选择逻辑，运行时这些纯 C 包在 API 23 上仍可正常加载。
#
# 注意：
#   - Chaquopy 17.0.0 支持 AGP 7.3–9.2，降级到支持 API 23 的 15.0.1 会与本项目
#     的 Gradle 9.5.1 / AGP 9.x 冲突，因此走"打补丁"而非"降级"。
#   - 本脚本修改的是 ~/.gradle/caches 里的插件 jar（构建缓存），不是仓库文件。
#     执行 `./gradlew --refresh-dependencies` 或清缓存后需重新运行本脚本。
#   - 运行时 Python 解释器是懒加载（仅在使用 Python Spider 时触发），
#      即使 Python 运行时在 API 23 上有个别兼容问题，App 仍能安装/启动/播视频。
#   - 备份只在“确实要打补丁前”从原始 jar 创建，文件名为 <jar>.chaquopy_patched.bak；
#     若曾用其他方式打过补丁（备份名为 <jar>.chaquopy_minsdk.bak），回退时同样识别。
#
set -euo pipefail

CACHE_ROOT="$HOME/.gradle/caches/modules-2/files-2.1/com.chaquo.python/gradle"

find "$CACHE_ROOT" -type f -name 'gradle-*.jar' 2>/dev/null | while IFS= read -r JAR; do
  [ -n "$JAR" ] || continue
  python3 - "$JAR" <<'PY'
import sys, zipfile, shutil, os, io

# --- 补丁常量（必须定义在 Python 段内；外层 heredoc 为引号包裹，bash 变量不会注入） ---
GUARD_NEEDLE = b'\x10\x18\xa2'   # bipush 24 ; if_icmpge
GUARD_REPL  = b'\x10\x01\xa2'    # bipush 1  ; if_icmpge  -> apiLevel >= 1 always true

PY_OLD = b'return "android_{}_{}".format(self.min_api_level, re.sub(r"[-.]", "_", abi))'
PY_NEW = b'return "android_{}_{}".format(max(self.min_api_level, 24), re.sub(r"[-.]", "_", abi))'

jar = sys.argv[1]
if not os.path.exists(jar):
    print(f"跳过（不存在）: {jar}")
    sys.exit(0)

with zipfile.ZipFile(jar) as z:
    names = z.namelist()
    if 'com/chaquo/python/PythonPlugin.class' not in names:
        print(f"跳过 {jar}：不含 PythonPlugin.class")
        sys.exit(0)
    if 'com/chaquo/python/gradle/build-packages.zip' not in names:
        print(f"跳过 {jar}：不含 build-packages.zip")
        sys.exit(0)
    data = {n: z.read(n) for n in names}

cls = data['com/chaquo/python/PythonPlugin.class']
with io.BytesIO(data['com/chaquo/python/gradle/build-packages.zip']) as bz:
    with zipfile.ZipFile(bz) as _z:
        bnames = _z.namelist()
        assert 'chaquopy/pip_install.py' in bnames, "pip_install.py 缺失"
        bdata = {n: _z.read(n) for n in bnames}
        py = bdata['chaquopy/pip_install.py']

# 只在“确实要打补丁”时创建备份，确保备份始终是未打补丁的原始 jar
will_patch = (GUARD_NEEDLE in cls) or (PY_OLD in py)
backup = jar + '.chaquopy_patched.bak'
if will_patch and not os.path.exists(backup):
    shutil.copy2(jar, backup)

# --- Patch 1: minSdk guard in PythonPlugin.class (bipush 24 -> bipush 1) ---
if GUARD_NEEDLE in cls:
    assert cls.count(GUARD_NEEDLE) == 1, "守卫特征不唯一，中止以防误改"
    data['com/chaquo/python/PythonPlugin.class'] = cls.replace(GUARD_NEEDLE, GUARD_REPL)
    print(f"守卫补丁：已应用 ({jar})")
else:
    print(f"守卫补丁：已打过/无需 ({jar})")

# --- Patch 2: wheel platform-tag floor in pip_install.py (min_api_level -> max(...,24)) ---
if PY_OLD in py:
    bdata['chaquopy/pip_install.py'] = py.replace(PY_OLD, PY_NEW)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as out:
        for n, c in bdata.items():
            out.writestr(n, c)
    data['com/chaquo/python/gradle/build-packages.zip'] = buf.getvalue()
    print(f"平台标签补丁：已应用 ({jar})")
else:
    print(f"平台标签补丁：已打过/无需 ({jar})")

if will_patch:
    tmp = jar + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as out:
        for n, c in data.items():
            out.writestr(n, c)
    shutil.move(tmp, jar)
    print(f"已重写 jar（备份：{backup}）")
else:
    print(f"jar 已是最新（无需改动）：{jar}")
PY
done

echo "Chaquopy 补丁完成。若曾改动 chaquo/build.gradle 的 python.version 或 minSdk，重新构建即可生效。"
