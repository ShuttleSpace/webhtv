# =============================================================================
# webhtv — Android 6.0 (API 23) 一键构建 / 回退 工具链
# =============================================================================
#
# 背景
# ----
# 本项目原生 minSdk 为 24。为了能在 Android 6.0 上安装并播放视频，做了一系列
# 源码 / 脚本改造（minSdk→23、Chaquopy vendor 源码适配、mpv vulkan 关闭、
# manifest override 等）。这些改动通过 patches/android6-api23.patch 统一纳管，
# 可一键「应用 / 回退」，且回退后仓库恢复为原有（API 24+）状态，不影响其他平台。
# Chaquopy 的 API 23 适配不在 patch 内，而是以 vendor/chaquopy 本地源码
# （composite build 依赖替换）常驻提供，详见 vendor/chaquopy/README.md。
#
# 关键安全点（已在源码层验证）
# ----------------------------
#  - minSdk=23 只决定“可安装到 Android 6.0”；原生库 exo_dovi_renderer 仍以
#    android-26 编译，且仅在 API>=26 时由 Java 守卫加载，API 23 上永不加载。
#  - 视频播放走标准 MediaCodec + Surface 路径，API 23 不崩。
#  - Chaquopy 以 vendor/chaquopy 本地源码提供 API 23 适配（composite build），
#    运行时纯 C 包在 API 23 可正常加载。
#
# git 基线锁定（可复现性）
# ------------------------
#  - 适配基点 commit 记录在 patches/android6-baseline.txt。android6-patch 在
#    应用补丁前会校验当前 HEAD 是否等于该基线；不一致则中止，避免在不匹配的
#    提交上打补丁导致冲突或不可复现。
#  - just android6-pin 可将当前 HEAD 重写为新的适配基点（仅在确认上游已前进、
#    且补丁已针对新提交重新生成后使用）。
#
# 常用任务
# --------
#   just                        列出全部任务
#   just android6-status        查看当前处于 Android 6 / 原始 状态
#   just android6-patch         应用 Android 6 全部改动（幂等）
#   just android6-build         构建 leanback arm64 debug APK（默认 ABI）
#   just android6-build-all     干净机首选：重建原生库 + 构建 APK
#   just android6-revert        回退所有 Android 6 改动（恢复 API 24+ 状态）
#   just android6-diff          若手工改了源码，重新生成补丁文件
#
# 注意
# ----
#  - 原生库（mpv/ffmpeg/exo_ass/dvd）以提交态 .so 资产被 Gradle 打包，因此
#    “应用补丁 + 直接 assemble” 即可出包；android6-native 仅在需要全量重建
#    原生栈时运行（很慢，数十分钟）。
#  - android6-revert 会把 .so / lock 等构建产物也还原到原始提交态，确保其他
#    平台构建得到与上游完全一致的字节。
# =============================================================================

set dotenv-load := false

ROOT := "."
PATCH := "patches/android6-api23.patch"
BASELINE_FILE := "patches/android6-baseline.txt"

# 默认任务：列出全部任务
default:
    @just --list

# -----------------------------------------------------------------------------
# 状态查看
# -----------------------------------------------------------------------------
android6-status:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    echo "== git 基线锁定 =="
    if [ -f "{{BASELINE_FILE}}" ]; then
        PINNED="$(grep -vE '^\s*#' "{{BASELINE_FILE}}" | tr -d '[:space:]' | head -n1)"
        CURRENT="$(git rev-parse HEAD)"
        if [ "$CURRENT" = "$PINNED" ]; then
            echo "  匹配 ($CURRENT)"
        else
            echo "  不匹配：当前 HEAD=$CURRENT，锁定基线=$PINNED"
        fi
    else
        echo "  未锁定（缺少 {{BASELINE_FILE}}，运行 just android6-pin）"
    fi
    echo
    echo "== minSdk (libs.versions.toml) =="
    grep -E '^minSdk' gradle/libs.versions.toml || true
    echo
    echo "== 源码补丁是否已应用 =="
    if git apply --reverse --check "{{PATCH}}" 2>/dev/null; then
        echo "  已应用  -> 当前为 Android 6 (API 23) 状态"
    else
        echo "  未应用  -> 当前为原始 (API 24+) 状态"
    fi
    echo
    echo "== Chaquopy vendor 源码 =="
    if [ -f vendor/chaquopy/VERSION.txt ] && grep -q "MIN_SDK_VERSION = 23" vendor/chaquopy/buildSrc/src/main/java/com/chaquo/python/internal/Common.java; then
        echo "  就绪 (vendor/chaquopy $(cat vendor/chaquopy/VERSION.txt), MIN_SDK_VERSION=23)"
    else
        echo "  缺失或补丁不完整（见 vendor/chaquopy/README.md）"
    fi
    echo
    echo "== mise python 工具链 =="
    if mise where python >/dev/null 2>&1; then
        echo "  可用: $(mise where python)/bin/python3.10"
    else
        echo "  未就绪 (运行 android6-patch 会执行 mise install)"
    fi

# -----------------------------------------------------------------------------
# 应用 Android 6 全部改动（源码补丁 + 确保工具链；Chaquopy 已 vendor 化，无需打补丁）
# -----------------------------------------------------------------------------
android6-patch:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    if ! command -v mise >/dev/null 2>&1; then
        echo "错误：未找到 mise，请先安装 https://mise.jdx.dev" >&2
        exit 2
    fi
    # 0) 若源码补丁已应用（含已提交到 HEAD 的情况），跳过 git apply；
    #    否则要求当前 HEAD 与记录的适配基点一致，避免在不匹配的提交上打补丁。
    if git apply --reverse --check "{{PATCH}}" 2>/dev/null; then
        echo "源码补丁已应用（或已提交），跳过 git apply"
    else
        if [ ! -f "{{BASELINE_FILE}}" ]; then
            echo "错误：缺少基线文件 {{BASELINE_FILE}}，请先运行 just android6-pin" >&2
            exit 3
        fi
        PINNED="$(grep -vE '^\s*#' "{{BASELINE_FILE}}" | tr -d '[:space:]' | head -n1)"
        if [ -z "$PINNED" ]; then
            echo "错误：基线文件 {{BASELINE_FILE}} 未包含任何 commit 哈希" >&2
            exit 3
        fi
        CURRENT="$(git rev-parse HEAD)"
        if [ "$CURRENT" != "$PINNED" ]; then
            echo "错误：当前 HEAD ($CURRENT) 与锁定的 Android 6 基线 ($PINNED) 不一致。" >&2
            echo "  - 若要回到基点：git checkout $PINNED" >&2
            echo "  - 若确认当前提交为新的适配基点：just android6-pin（将重写基线文件）" >&2
            exit 3
        fi
        echo "git 基线校验通过：HEAD=$CURRENT (= 锁定基线)"
        echo "应用源码补丁 ({{PATCH}}) ..."
        git apply "{{PATCH}}"
    fi
    echo "确保 mise python 3.10 就绪 ..."
    mise install >/dev/null 2>&1 || true
    # Chaquopy 的 API 23 适配已固化在 vendor/chaquopy 本地源码（composite build），
    # 无需再对 ~/.gradle/caches 里的插件 jar 打补丁。
    echo "源码补丁与工具链就绪（Chaquopy 适配见 vendor/chaquopy/README.md）。"

# -----------------------------------------------------------------------------
# 回退 Android 6 全部改动（恢复为原始 API 24+ 状态，不影响其他平台）
# -----------------------------------------------------------------------------
android6-revert:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    if git apply --check "{{PATCH}}" 2>/dev/null; then
        echo "回退源码补丁 ..."
        git apply -R "{{PATCH}}"
    else
        echo "源码补丁未应用，跳过"
    fi
    # Chaquopy 的 API 23 适配已 vendor 化（vendor/chaquopy + settings.gradle 的
    # composite build 接线），不再有缓存 jar 补丁需要还原；该接线保留不回退，
    # API 23 构建路径始终可用（详见 vendor/chaquopy/README.md）。
    echo "还原原生构建产物 (.so / lock) 到原始提交态 ..."
    git checkout -- \
        app/src/arm64_v8a/assets/mpv-libs \
        app/src/armeabi_v7a/assets/mpv-libs \
        third_party/exo-ass-native/prebuilt \
        third_party/exo-ass-native/MANIFEST.sha256 \
        third_party/exo-ass-native/build-provenance.json \
        third_party/dvd-native-lock.json \
        third_party/exo-ass-lock.json \
        third_party/mpv-native-lock.json
    echo
    echo "回退完成：仓库已恢复为原始 (API 24+) 构建状态，其他平台可正常构建。"

# -----------------------------------------------------------------------------
# 锁定 / 重锁 git 基线（适配基点 commit）
# 仅在你确认“当前 HEAD 是 android6-api23.patch 的正确应用基点”时使用，
# 例如上游已前进、且补丁已针对新提交重新生成（先 just android6-diff）。
# -----------------------------------------------------------------------------
android6-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    CURRENT="$(git rev-parse HEAD)"
    mkdir -p patches
    {
        echo "# webhtv Android 6.0 (API 23) 适配 — git 基线锁定"
        echo "# 此 commit 是 patches/android6-api23.patch 的应用基点。"
        echo "# 运行 just android6-pin 可把当前 HEAD 设为新的适配基点。"
        echo "$CURRENT"
    } > "{{BASELINE_FILE}}"
    echo "已锁定 Android 6 基线 -> $CURRENT（写入 {{BASELINE_FILE}}）"

# -----------------------------------------------------------------------------
# 重建原生库（vulkan 关闭后的 mpv，以及 exo_ass / dvd），写回 assets。
# 很重（mpv/ffmpeg 全量编译），仅在干净机或更换 mpv 源码时运行一次。
# -----------------------------------------------------------------------------
android6-native:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    : "${ANDROID_HOME:?请先设置 ANDROID_HOME}"
    # 若 mise 未把 ANDROID_NDK_HOME 注入环境，则从 ANDROID_HOME 推导
    if [ -z "${ANDROID_NDK_HOME:-}" ]; then
        NDK_CANDIDATE="${ANDROID_HOME}/ndk/29.0.14206865"
        if [ -d "$NDK_CANDIDATE" ]; then
            export ANDROID_NDK_HOME="$NDK_CANDIDATE"
        else
            echo "错误：未设置 ANDROID_NDK_HOME，且 ${NDK_CANDIDATE} 不存在" >&2
            exit 2
        fi
    fi
    echo "ANDROID_HOME=$ANDROID_HOME"
    echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
    echo "== 重建 dvd 依赖 =="
    bash scripts/build_dvd_deps.sh
    echo "== 重建 mpv/ffmpeg 原生栈并写回 assets =="
    bash scripts/build_mpv_native.sh --abi all --install
    echo "== 重建 exo_ass 并写回 assets =="
    python3 scripts/build_exo_ass_native.py --abi all --install

# -----------------------------------------------------------------------------
# 抓取 TV 上的崩溃现场（截图 + logcat + R8 反混淆）
# 用法: just android6-crash [设备地址]
#   bash scripts/tv_crash_catch.sh 192.168.8.5:5555
# 说明: Android 6.0 production ROM 拿不到 tombstones，崩溃页截图与 logcat 是主要线索。
# -----------------------------------------------------------------------------
android6-crash DEVICE="192.168.8.5:5555":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    bash scripts/tv_crash_catch.sh "{{DEVICE}}"

# -----------------------------------------------------------------------------
# 分块推送 APK 到 TV 并安装（这台 TV 的 adbd 传大文件末尾会主动断开）
# 用法: just android6-push [设备地址]
#   bash scripts/push_apk_chunked.sh <apk> 192.168.8.5:5555
# 说明: 这台 TV 的 adb push 实际只有 ~0.1MB/s 且末尾会断流（134MB 要 20+ 分钟）；
#       此脚本改为本机起 HTTP 服务、TV 用 busybox wget 主动拉取（~4MB/s，约 30 秒）。
# -----------------------------------------------------------------------------
android6-push DEVICE="192.168.8.5:5555":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    APK="{{ROOT}}/app/build/outputs/apk/leanbackArm64_v8a/release/leanback-arm64_v8a.apk"
    if [ ! -f "$APK" ]; then
        echo "未找到 APK: $APK" >&2
        echo "请先执行 just android6-build" >&2
        exit 1
    fi
    bash scripts/push_apk_http.sh "$APK" "{{DEVICE}}"

# -----------------------------------------------------------------------------
# API 23 (Android 6.0) 兼容性静态审计 —— 列出所有在 API 23 上不存在的 API 调用
# 用法: just android6-audit
# 说明: 用 lint 的 NewApi 检查（自带完整 API 版本数据库，比自己比对 android.jar
#       准确得多）。输出是"候选"，每项需回源码确认是否已有 SDK_INT 版本守卫。
# -----------------------------------------------------------------------------
android6-audit:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    bash scripts/api23_lint.sh

# -----------------------------------------------------------------------------
# 清理 CMake 缓存（原生平台 / NDK 切换后必须）
# -----------------------------------------------------------------------------
android6-clean:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    rm -rf app/.cxx
    echo "已清理 app/.cxx（下次构建会重新配置 CMake）"

# -----------------------------------------------------------------------------
# 构建 APK（默认 leanback arm64 debug）。ABI 可选：arm64_v8a（默认）/ armeabi_v7a
# -----------------------------------------------------------------------------
android6-build ABI="arm64_v8a" MODE="Release":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    case "{{ABI}}" in
        arm64_v8a)   FLAVOR=LeanbackArm64_v8a   ;;
        armeabi_v7a) FLAVOR=LeanbackArmeabi_v7a ;;
        *) echo "未知 ABI: {{ABI}}（请用 arm64_v8a 或 armeabi_v7a）" >&2; exit 2 ;;
    esac
    # 1) 应用补丁（幂等）
    just android6-patch
    # 2) 清理 CMake 缓存
    just android6-clean
    # 3) 清理可能残留的失效本地代理（如 127.0.0.1:12334），避免 chaquo 下载被拦截
    case "${HTTP_PROXY:-}${HTTPS_PROXY:-}" in
        *127.0.0.1*12334*) unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ;;
    esac
    # 4) Chaquopy 插件构建期需要 python3.10（创建 venv / 运行 pip_install），
    #    把 mise 管理的 python 放到 PATH 最前（不再需要 -PbuildPython）。
    export PATH="$(mise where python)/bin:$PATH"
    echo "== 构建 assemble${FLAVOR}${MODE} (python3.10 via mise, chaquopy via vendor/chaquopy) =="
    ./gradlew "assemble${FLAVOR}${MODE}" # 如果报错 state lock ，则是因为org.gradle.parallel=true+-no-daemon 在Gralde8.x下的已知bug.可以添加 --no-daemon --no-parallel 参数禁用

# -----------------------------------------------------------------------------
# 干净机首选：重建原生库 + 构建 APK
# -----------------------------------------------------------------------------
android6-build-all ABI="arm64_v8a":
    android6-native
    android6-build "{{ABI}}"

# -----------------------------------------------------------------------------
# 重新生成补丁文件（保持 patch 与已提交状态同步）
#
# 补丁 = 「适配基点 → 当前 HEAD」在指定文件上的 diff。
# 基点取 patches/android6-baseline.txt 里锁定的 commit（见 just android6-pin）。
# 用基点 diff 而非工作树 diff，是为了让补丁描述"已提交的适配内容"，
# android6-revert 才能在干净 checkout 上把它整体还原。
# -----------------------------------------------------------------------------
android6-diff:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    mkdir -p patches
    if [ ! -f "{{BASELINE_FILE}}" ]; then
        echo "错误：缺少基线文件 {{BASELINE_FILE}}，请先运行 just android6-pin" >&2
        exit 3
    fi
    PINNED="$(grep -vE '^\s*#' "{{BASELINE_FILE}}" | tr -d '[:space:]' | head -n1)"
    if [ -z "$PINNED" ]; then
        echo "错误：基线文件 {{BASELINE_FILE}} 未包含任何 commit 哈希" >&2
        exit 3
    fi
    git diff "$PINNED"..HEAD -- \
        app/src/main/AndroidManifest.xml \
        app/src/main/java/com/fongmi/android/tv/api/loader/PyLoader.java \
        app/src/main/java/com/fongmi/android/tv/api/loader/JsLoader.java \
        app/src/main/java/com/fongmi/android/tv/bean/Vod.java \
        app/src/main/java/com/fongmi/android/tv/player/karaoke/KaraokeTrackRepository.java \
        app/src/main/java/com/fongmi/android/tv/player/exo/ExoTunnelingRuntimeState.java \
        app/src/main/java/com/fongmi/android/tv/player/PlaybackDiagnosticCollector.java \
        app/src/main/java/com/fongmi/android/tv/player/PlaybackProfileAbStore.java \
        app/src/main/java/com/fongmi/android/tv/player/PlaybackCompatibilityRetentionPolicy.java \
        app/src/main/java/com/fongmi/android/tv/service/PlaybackService.java \
        app/src/main/java/com/fongmi/android/tv/setting/Setting.java \
        app/src/main/java/com/fongmi/android/tv/ui/activity/PlaybackActivity.java \
        app/src/main/java/com/fongmi/android/tv/ui/dialog/GitCloudDialog.java \
        app/src/main/java/com/fongmi/android/tv/ui/dialog/RemoteTrustDialog.java \
        app/src/main/java/com/fongmi/android/tv/utils/ScanTask.java \
        app/src/main/java/com/fongmi/android/tv/utils/Util.java \
        app/src/leanback/java/com/fongmi/android/tv/receiver/BootReceiver.java \
        app/src/leanback/java/com/fongmi/android/tv/ui/custom/CustomSelector.java \
        app/src/mobile/java/com/fongmi/android/tv/ui/activity/LiveActivity.java \
        catvod/src/main/java/com/github/catvod/crawler/diagnostics/DiagnosticReport.java \
        catvod/src/main/java/com/github/catvod/net/CookieStore.java \
        chaquo/build.gradle \
        gradle/libs.versions.toml \
        settings.gradle \
        scripts/build_dvd_deps.sh \
        scripts/build_mpv_native.sh \
        scripts/verify_exo_ass.py \
        scripts/verify_mpv_native_assets.sh \
        third_party/mpv-native-overrides/libplacebo.sh \
        third_party/mpv-native-overrides/mpv.sh \
        mise.toml > "{{PATCH}}"
    echo "已重新生成 {{PATCH}}（$(wc -l < "{{PATCH}}") 行，基点 ${PINNED}）"

