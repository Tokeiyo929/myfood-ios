#!/bin/bash
set -euo pipefail
udid=$1
mode=$2
case "$mode" in
  smoke) argument=-autoSmoke; names="01-history 02-detail 03-record 04-map-china 05-map-europe 06-rank 07-tracks 08-settings" ;;
  autotest) argument=-autoTest; names= ;;
  *) echo "Unknown test mode: $mode" >&2; exit 1 ;;
esac
# 预授定位权限+模拟坐标（上海），让冒烟的快速建档走完整定位分支而不弹系统窗
xcrun simctl privacy "$udid" grant location com.tokeiyo929.myfood 2>/dev/null || true
xcrun simctl location "$udid" set "31.2304,121.4737" 2>/dev/null || true
container=$(xcrun simctl get_app_container "$udid" com.tokeiyo929.myfood data)
directory="$container/tmp/$mode"
mkdir -p "$directory" "$mode"
rm -f "$directory"/done.txt "$directory"/result.txt "$directory"/now-* "$directory"/ack-*
pid=
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  cp "$directory"/*.txt "$mode/" 2>/dev/null || true
}
trap cleanup EXIT
xcrun simctl terminate "$udid" com.tokeiyo929.myfood 2>/dev/null || true
xcrun simctl launch --console "$udid" com.tokeiyo929.myfood "$argument" > "$mode-console.txt" 2>&1 &
pid=$!
for ((second=0; second<180; second++)); do
  for name in $names; do
    if [ -f "$directory/now-$name" ] && [ ! -f "$directory/ack-$name" ]; then
      xcrun simctl io "$udid" screenshot "$mode/$name.png"
      : > "$directory/ack-$name"
    fi
  done
  if [ -f "$directory/done.txt" ]; then break; fi
  if ! kill -0 "$pid" 2>/dev/null; then echo "App exited before completion" >&2; exit 1; fi
  sleep 1
done
test -f "$directory/done.txt" || { echo "Test timed out" >&2; exit 1; }
test "$(cat "$directory/done.txt")" = PASS
grep -qx 'RESULT: ALL PASS' "$directory/result.txt"
if grep -q '^FAIL' "$directory/result.txt"; then cat "$directory/result.txt"; exit 1; fi
for name in $names; do test -s "$mode/$name.png"; done
# 即使已写 PASS，随后异常退出或挂起仍必须失败。
for ((second=0; second<10; second++)); do
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$pid" 2>/dev/null; then echo "App did not exit after completion" >&2; exit 1; fi
wait "$pid"
pid=
cat "$directory/result.txt"
