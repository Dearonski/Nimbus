# Sourced by hitches.sh and cpu.sh: finds the running app, builds the gesture tool, owns the focus.
root=${0:A:h:h:h}
out=$root/build/perf
mkdir -p $out
flick=$out/flick
if [[ ! -x $flick || $root/tools/perf/flick.swift -nt $flick ]]; then
  xcrun swiftc -swift-version 6 -O $root/tools/perf/flick.swift -o $flick || exit 1
fi
pid=$(pgrep -x Nimbus | head -1)
[[ -z $pid ]] && { echo "Nimbus is not running"; exit 1; }
echo "pid $pid: $(ps -o args= -p $pid)"
events() { osascript -e "tell application \"System Events\" to $1"; }

front=$(events 'unix id of first process whose frontmost is true')
focus() { events "set frontmost of (first process whose unix id is $1) to true" > /dev/null; }
# An inactive window scrolls on another path: the run measures the app the way it is used.
focus $pid
trap 'focus $front' EXIT
sleep 1
echo "screen: $(events 'name of first window of process "Nimbus"' 2>/dev/null)"
