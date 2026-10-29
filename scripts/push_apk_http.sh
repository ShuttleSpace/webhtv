#!/usr/bin/env bash
# 快速推送 APK 到 Android TV 并安装（HTTP 拉取法）。
#
# 为什么不用 `adb push`：
#   这台 TV 的 Wi-Fi 实际吞吐只有 ~0.1 MB/s（adb push 一个 134MB 的 APK 要 20+ 分钟），
#   且 adbd 在传输末尾会主动断开（"failed to read copy response: EOF"），导致连接失效、
#   后续命令全部报 "device not found"，非常脆弱。
#
# 做法：
#   本机起一个临时 HTTP 服务，TV 端用 busybox wget 主动拉取（方向反转，实测 ~4 MB/s，
#   134MB 约 30 秒），拉完后用字节数校验，再 pm install。
#   TV 端只有 busybox/toybox，没有 curl，所以统一用 busybox wget。
#
# 用法:
#   scripts/push_apk_http.sh <apk路径> [设备地址]
#
# 环境变量:
#   HTTP_PORT   本机 HTTP 服务端口，默认 8099
#   KEEP_SERVER 设为 1 时保留 HTTP 服务（便于多次推送）

set -uo pipefail

APK="${1:-}"
DEVICE="${2:-192.168.8.5:5555}"
ADB="${ADB:-/Users/humphrey/Library/Android/sdk/platform-tools/adb}"
HTTP_PORT="${HTTP_PORT:-8099}"
KEEP_SERVER="${KEEP_SERVER:-0}"
REMOTE_APK=/data/local/tmp/webhtv.apk

if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "用法: $0 <apk路径> [设备地址]" >&2
  exit 1
fi

# 本机在局域网中的地址（TV 需要能直接访问）
LOCAL_IP="${LOCAL_IP:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)}"
if [ -z "$LOCAL_IP" ]; then
  echo "无法确定本机局域网 IP，可用 LOCAL_IP=... 显式指定" >&2
  exit 1
fi

# 用 wc -c 而不是 stat：某些环境（沙箱 shim）下 stat 会输出额外内容污染变量
APK_SIZE=$(wc -c < "$APK" | tr -d ' ')
SERVE_DIR=$(mktemp -d /tmp/webhtv-http.XXXXXX)
cp "$APK" "$SERVE_DIR/webhtv.apk"

echo "== 准备 =="
echo "APK   : $APK ($APK_SIZE bytes)"
echo "设备  : $DEVICE"
echo "服务  : http://$LOCAL_IP:$HTTP_PORT/webhtv.apk"

# 启动 HTTP 服务（后台）
( cd "$SERVE_DIR" && python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 ) >/tmp/webhtv-http.log 2>&1 &
SERVER_PID=$!
cleanup() {
  if [ "$KEEP_SERVER" != "1" ]; then
    kill "$SERVER_PID" 2>/dev/null
    rm -rf "$SERVE_DIR"
  fi
}
trap cleanup EXIT

# 等待服务就绪
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sI --max-time 3 "http://127.0.0.1:$HTTP_PORT/webhtv.apk" 2>/dev/null | grep -q "200 OK"; then
    break
  fi
  sleep 1
done

# 确保设备在线
if ! $ADB -s "$DEVICE" shell echo ok 2>/dev/null | grep -q ok; then
  echo "== 重连设备 =="
  $ADB disconnect "$DEVICE" >/dev/null 2>&1
  sleep 1
  $ADB connect "$DEVICE" >/dev/null 2>&1
  sleep 3
fi

echo "== 下载（TV 主动拉取）=="
$ADB -s "$DEVICE" shell "busybox wget -O $REMOTE_APK http://$LOCAL_IP:$HTTP_PORT/webhtv.apk" 2>&1 \
  | tail -1 | tr '\r' '\n' | tail -2

echo "== 校验 =="
GOT=$($ADB -s "$DEVICE" shell "wc -c < $REMOTE_APK" 2>/dev/null | tr -d '\r\n ')
if [ "$GOT" != "$APK_SIZE" ]; then
  echo "大小不匹配：期望 $APK_SIZE，实得 ${GOT:-0}" >&2
  exit 1
fi
echo "大小一致: $GOT bytes"

echo "== 安装 =="
$ADB -s "$DEVICE" shell "pm install -r $REMOTE_APK" 2>&1 | tail -3

$ADB -s "$DEVICE" shell "rm -f $REMOTE_APK" >/dev/null 2>&1
echo "== 完成 =="
