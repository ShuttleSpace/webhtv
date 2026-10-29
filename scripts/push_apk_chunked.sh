#!/usr/bin/env bash
# 分块推送 APK 到 Android TV 并安装。
#
# 为什么需要它：
#   这台 TV 的 adbd 在传输大文件末尾会主动断开（"failed to read copy response: EOF"），
#   此时文件其实已经完整写到设备上，但 adb server 端的连接已失效，后续任何命令都报
#   "device not found"。所以策略是：
#     1) 每块推送前强制重连（disconnect + connect + 用真实命令验证连通）；
#     2) 推送命令的退出码不可信 —— 以**设备端实际字节数**为准；
#     3) 字节数不匹配才重试该块，其它块不重复传。
#
# 用法:
#   scripts/push_apk_chunked.sh <apk路径> [设备地址]
#
# 环境变量:
#   CHUNK_SIZE  分块大小，默认 6m

set -uo pipefail

APK="${1:-}"
DEVICE="${2:-192.168.8.5:5555}"
ADB="${ADB:-/Users/humphrey/Library/Android/sdk/platform-tools/adb}"
CHUNK_SIZE="${CHUNK_SIZE:-6m}"
WORKDIR="${WORKDIR:-/tmp}"
PREFIX="$WORKDIR/whtv.part."
REMOTE_DIR=/data/local/tmp

if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "用法: $0 <apk路径> [设备地址]" >&2
  exit 1
fi

rm -f "${PREFIX}"*
split -b "$CHUNK_SIZE" "$APK" "$PREFIX"
TOTAL_APK=$(wc -c < "$APK" | tr -d " ")
CHUNKS=$(ls "${PREFIX}"* | wc -l | tr -d ' ')
echo "== 分块推送 =="
echo "APK: $APK ($TOTAL_APK bytes)"
echo "设备: $DEVICE"
echo "分块: $CHUNKS 块 x $CHUNK_SIZE"

# 强制重连：adb server 可能还持有已死的 transport，必须 disconnect 再 connect，
# 并且用一条真实命令确认可用（get-state 可能返回缓存的 device 状态）。
reconnect() {
  local i
  for i in 1 2 3 4 5 6; do
    $ADB disconnect "$DEVICE" >/dev/null 2>&1
    sleep 1
    $ADB connect "$DEVICE" >/dev/null 2>&1
    sleep 2
    if $ADB -s "$DEVICE" shell echo ok 2>/dev/null | grep -q ok; then
      return 0
    fi
    sleep 2
  done
  return 1
}

remote_size() {
  $ADB -s "$DEVICE" shell "wc -c < $REMOTE_DIR/$1" 2>/dev/null | tr -d '\r\n '
}

reconnect || { echo "无法连接 $DEVICE" >&2; exit 1; }

FAILED=0
for f in "${PREFIX}"*; do
  b=$(basename "$f")
  want=$(wc -c < "$f" | tr -d " ")
  for try in 1 2 3 4 5; do
    # 传输末尾 adbd 会断，此时连接失效 -> 先确保连接是活的
    reconnect || { echo "重连失败 ($b, try=$try)"; sleep 5; continue; }

    # 推送。退出码不可信（EOF 但文件已完整），只记录不据此失败。
    $ADB -s "$DEVICE" push "$f" "$REMOTE_DIR/$b" >/dev/null 2>&1

    got=$(remote_size "$b")
    if [ "$got" = "$want" ]; then
      echo "OK   $b ($got bytes)  [$try]"
      break
    fi
    echo "重试 $b try=$try  期望 $want 实得 ${got:-0}"
    $ADB -s "$DEVICE" shell "rm -f $REMOTE_DIR/$b" >/dev/null 2>&1
    sleep 3
  done

  got=$(remote_size "$b")
  if [ "$got" != "$want" ]; then
    echo "失败: $b（期望 $want，实得 ${got:-0}）" >&2
    FAILED=1
  fi
done

if [ "$FAILED" != "0" ]; then
  echo "有分块未成功传输，终止安装。" >&2
  exit 1
fi

reconnect || { echo "合并前无法连接" >&2; exit 1; }

echo "== 合并 =="
$ADB -s "$DEVICE" shell "cat ${REMOTE_DIR}/whtv.part.* > ${REMOTE_DIR}/webhtv.apk && wc -c < ${REMOTE_DIR}/webhtv.apk" 2>&1 | tr -d '\r'

echo "== 安装 =="
$ADB -s "$DEVICE" shell "pm install -r ${REMOTE_DIR}/webhtv.apk" 2>&1 | tail -3

reconnect || true
$ADB -s "$DEVICE" shell "rm -f ${REMOTE_DIR}/whtv.part.* ${REMOTE_DIR}/webhtv.apk" >/dev/null 2>&1
rm -f "${PREFIX}"*
echo "== 完成 =="
