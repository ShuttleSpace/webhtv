# =============================================================================
# webhtv — Android 6.0 (API 23) 一键构建 / 回退 工具链
# =============================================================================
#
# 背景
# ----
# 本项目原生 minSdk 为 24。为了能在 Android 6.0 上安装并播放视频，做了一系列
# 源码 / 脚本改造（minSdk→23、Chaquopy minSdk+wheel 标签补丁、mpv vulkan 关闭、
# manifest override 等）。这些改动通过 patches/android6-api23.patch 统一纳管，
# 可一键「应用 / 回退」，且回退后仓库恢复为原有（API 24+）状态，不影响其他平台。
#
# 关键安全点（已在源码层验证）
# ----------------------------
#  - minSdk=23 只决定“可安装到 Android 6.0”；原生库 exo_dovi_renderer 仍以
#    android-26 编译，且仅在 API>=26 时由 Java 守卫加载，API 23 上永不加载。
#  - 视频播放走标准 MediaCodec + Surface 路径，API 23 不崩。
#  - Chaquopy 补丁只改构建缓存 jar，运行时纯 C 包在 API 23 可正常加载。
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
    echo "== Chaquopy jar 是否已打补丁 =="
    CACHE_ROOT="$HOME/.gradle/caches/modules-2/files-2.1/com.chaquo.python/gradle"
    if find "$CACHE_ROOT" -type f \( -name 'gradle-*.jar.chaquopy_minsdk.bak' -o -name 'gradle-*.jar.chaquopy_patched.bak' \) 2>/dev/null | grep -q .; then
        echo "  已打补丁 (有备份，可回退)"
    else
        echo "  未打补丁"
    fi
    echo
    echo "== mise python 工具链 =="
    if mise where python >/dev/null 2>&1; then
        echo "  可用: $(mise where python)/bin/python3.10"
    else
        echo "  未就绪 (运行 android6-patch 会执行 mise install)"
    fi

# -----------------------------------------------------------------------------
# 应用 Android 6 全部改动（源码补丁 + Chaquopy 补丁 + 确保工具链）
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
    echo "打 Chaquopy minSdk / wheel 标签补丁 ..."
    bash scripts/patch_chaquopy_minsdk.sh

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
    echo "还原 Chaquopy jar（从备份）..."
    # 优先用真正的原始备份 (.chaquopy_minsdk.bak)；该脚本旧版会在已打补丁的 jar 上
    # 另存一份同名备份（实为打过补丁的副本），不能用于回退，故排在其次。
    # jar 位于 gradle/17.0.0/<hash>/ 子目录，需递归查找。
    CACHE_ROOT="$HOME/.gradle/caches/modules-2/files-2.1/com.chaquo.python/gradle"
    find "$CACHE_ROOT" -type f -name 'gradle-*.jar' 2>/dev/null | while IFS= read -r JAR; do
        case "$JAR" in *-sources.jar|*.bak|*.tmp) continue ;; esac
        if [ -f "$JAR.chaquopy_minsdk.bak" ]; then
            BAK="$JAR.chaquopy_minsdk.bak"
        elif [ -f "$JAR.chaquopy_patched.bak" ]; then
            BAK="$JAR.chaquopy_patched.bak"
        else
            continue
        fi
        cp -f "$BAK" "$JAR" && echo "  已还原 $(basename "$JAR") (from $(basename "$BAK"))"
    done
    echo "还原原生构建产物 (.so / lock) 到原始提交态 ..."
    git checkout -- \
        app/src/arm64_v8a/assets/mpv-libs \
        app/src/armeabi_v7a/assets/mpv-libs \
        third_party/exo-ass-native/prebuilt \
        third_party/exo-ass-native/MANIFEST.sha256 \
        third_party/exo-ass-native/build-provenance.json \
        third_party/dvd-native-lock.json \
        third_party/exo-ass-lock.json \
        third_party/mpv-native-lock.json \
        app/src/main/java/com/fongmi/android/tv/api/loader/PyLoader.java \
        app/src/main/java/com/fongmi/android/tv/api/loader/JsLoader.java
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
android6-build ABI="arm64_v8a":
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
    # 4) 锁定 buildPython（mise 管理的 python 3.10）
    BUILDPYTHON="$(mise where python)/bin/python3.10"
    echo "== 构建 assemble${FLAVOR}Debug (buildPython=$BUILDPYTHON) =="
    ./gradlew "assemble${FLAVOR}Debug" -PbuildPython="$BUILDPYTHON"

# -----------------------------------------------------------------------------
# 干净机首选：重建原生库 + 构建 APK
# -----------------------------------------------------------------------------
android6-build-all ABI="arm64_v8a":
    android6-native
    android6-build "{{ABI}}"

# -----------------------------------------------------------------------------
# 重新生成补丁文件（手工改了源码/脚本后调用，保持 patch 与工作树同步）
# -----------------------------------------------------------------------------
android6-diff:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ROOT}}"
    mkdir -p patches
    # 让新文件进入 diff 视野（intent-to-add），随后 reset 还原为未跟踪，不改变工作树
    git add -N scripts/patch_chaquopy_minsdk.sh mise.toml
    git diff -- \
        app/src/main/AndroidManifest.xml \
        app/src/main/java/com/fongmi/android/tv/api/loader/PyLoader.java \
        app/src/main/java/com/fongmi/android/tv/api/loader/JsLoader.java \
        chaquo/build.gradle \
        gradle/libs.versions.toml \
        scripts/build_dvd_deps.sh \
        scripts/build_mpv_native.sh \
        scripts/verify_exo_ass.py \
        scripts/verify_mpv_native_assets.sh \
        third_party/mpv-native-overrides/libplacebo.sh \
        third_party/mpv-native-overrides/mpv.sh \
        scripts/patch_chaquopy_minsdk.sh \
        mise.toml > "{{PATCH}}"
    git reset -q
    echo "已重新生成 {{PATCH}}（$(wc -l < "{{PATCH}}") 行）"
