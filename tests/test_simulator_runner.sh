#!/bin/bash
set -euo pipefail
runner=$(cd "$(dirname "$0")" && pwd)/run_simulator_tests.sh
testdir=$(mktemp -d)
trap 'rm -rf "$testdir"' EXIT
mkdir -p "$testdir/bin" "$testdir/container/tmp"
export FIXTURE_CONTAINER="$testdir/container"
cat > "$testdir/bin/xcrun" <<'MOCK'
#!/bin/bash
case "$2" in
  get_app_container) echo "$FIXTURE_CONTAINER" ;;
  terminate) exit 0 ;;
  io) printf 'PNG' > "$5" ;;
  launch)
    mode=autotest
    if [ "$6" = -autoSmoke ]; then mode=smoke; fi
    directory="$FIXTURE_CONTAINER/tmp/$mode"
    case "$FIXTURE_CASE" in
      partial) printf 'PASS first\n' > "$directory/result.txt"; exit 0 ;;
      timeout) exec /bin/sleep 60 ;;
      smoke-pass)
        for name in 01-history 02-detail 03-record 04-map-china 05-map-europe 06-rank 07-tracks 08-settings; do
          : > "$directory/now-$name"
        done
        for ((i=0; i<1000; i++)); do
          test -f "$directory/ack-08-settings" && break
          /bin/sleep 0.01
        done ;;
    esac
    printf 'RESULT: ALL PASS\n' > "$directory/result.txt"
    printf PASS > "$directory/done.txt"
    if [ "$FIXTURE_CASE" = crash ]; then exit 7; fi
    if [ "$FIXTURE_CASE" = fail ]; then printf FAIL > "$directory/done.txt"; fi
    ;;
esac
MOCK
cat > "$testdir/bin/sleep" <<'MOCK'
#!/bin/bash
/bin/sleep 0.01
MOCK
chmod +x "$testdir/bin/"*
export PATH="$testdir/bin:$PATH"
cd "$testdir"
for scenario in pass partial crash fail timeout smoke-missing smoke-pass; do
  export FIXTURE_CASE=$scenario
  mode=autotest
  case "$scenario" in smoke-*) mode=smoke ;; esac
  result=0
  bash "$runner" fixture "$mode" > "$scenario.log" 2>&1 || result=$?
  case "$scenario" in
    pass|smoke-pass) test "$result" -eq 0 || { cat "$scenario.log"; exit 1; } ;;
    *) test "$result" -ne 0 || { echo "Incorrectly accepted $scenario"; exit 1; } ;;
  esac
  echo "PASS gate $scenario"
done
