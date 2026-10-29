#!/usr/bin/env bash
#
# tv_crash_catch.sh —— 从 Android TV 上抓取崩溃现场并还原成可读堆栈
#
# 用法:
#   bash scripts/tv_crash_catch.sh [设备地址] [输出目录]
#   bash scripts/tv_crash_catch.sh 192.168.8.5:5555 /tmp/tv-crash
#
# 产出（默认 /tmp/tv-crash-<时间戳>/）:
#   screen.png    崩溃瞬间的屏幕截图（CrashActivity 的崩溃页往往直接写着堆栈）
#   logcat.txt    设备完整 logcat
#   errors.txt    异常关键行（FATAL / NoSuchMethodError / CustomActivityOnCrash ...）
#   retraced.txt  用 R8 mapping 反混淆后的堆栈（release 构建才有 mapping）
#
# 注意:
#   - 设备需已 adb connect（adb server 陈旧时先 adb kill-server 再 connect）。
#   - Android 6.0 production ROM 拿不到 /data/tombstones、logcat -b crash 常为空，
#     真正的堆栈通常在 CrashActivity 截图里，或 System.err / CustomActivityOnCrash 日志里。
set -uo pipefail

DEVICE="${1:-192.168.8.5:5555}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${2:-/tmp/tv-crash-$STAMP}"

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
RETRACE="$SDK/cmdline-tools/latest/bin/retrace"
MAPPING="${TV_MAPPING:-app/build/outputs/mapping/leanbackArm64_v8aRelease/mapping.txt}"

mkdir -p "$OUT"

echo "== 设备: $DEVICE  输出: $OUT"

if ! "$ADB" -s "$DEVICE" get-state >/dev/null 2>&1; then
    echo "!! 设备未连接，先执行: adb kill-server && adb connect $DEVICE" >&2
    exit 2
fi

# 1) 崩溃页截图（最有效：customactivityoncrash 会把完整堆栈显示在屏幕上）
if "$ADB" -s "$DEVICE" exec-out screencap -p > "$OUT/screen.png" 2>/dev/null; then
    echo "== 截图: $OUT/screen.png"
fi

# 2) logcat
"$ADB" -s "$DEVICE" logcat -d -v time > "$OUT/logcat.txt" 2>/dev/null
echo "== logcat: $OUT/logcat.txt ($(wc -l < "$OUT/logcat.txt") 行)"

# 3) 异常关键行
grep -nE "FATAL EXCEPTION|NoSuchMethodError|NoSuchFieldError|ClassNotFoundException|VerifyError|NoSuchMethodError|CustomActivityOnCrash|AndroidRuntime.*Exception|has died" \
    "$OUT/logcat.txt" > "$OUT/errors.txt" 2>/dev/null || true
echo "== 异常关键行: $OUT/errors.txt ($(wc -l < "$OUT/errors.txt" | tr -d ' ') 行)"
[ -s "$OUT/errors.txt" ] && sed -n '1,40p' "$OUT/errors.txt"

# 4) 反混淆（AGP 8+ 的栈帧是 r8-map-id-<hash> 形式，只有 retrace 能还原）
if [ -f "$MAPPING" ] && [ -x "$RETRACE" ]; then
    grep -E "^\s+at |^\s*Caused by:" "$OUT/logcat.txt" > "$OUT/frames.txt" 2>/dev/null || true
    if [ -s "$OUT/frames.txt" ]; then
        "$RETRACE" "$MAPPING" "$OUT/frames.txt" > "$OUT/retraced.txt" 2>/dev/null
        echo "== 反混淆堆栈: $OUT/retraced.txt"
    fi
else
    echo "!! 未找到 mapping ($MAPPING) 或 retrace，跳过反混淆"
fi

# 5) 顺手报告当前前台 Activity 与进程
{
    echo "--- 前台 Activity ---"
    "$ADB" -s "$DEVICE" shell "dumpsys activity activities | grep mResumedActivity" 2>/dev/null
    echo "--- app 进程 ---"
    "$ADB" -s "$DEVICE" shell "ps | grep com.fongmi.android.tv | grep -v grep" 2>/dev/null
} > "$OUT/state.txt" 2>/dev/null
cat "$OUT/state.txt"

echo
echo "提示: 若崩溃页仍在前台，直接看 $OUT/screen.png；"
echo "      若要还原混淆栈，看 $OUT/retraced.txt（需要 release 构建产物）。"
