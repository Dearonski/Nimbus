#!/bin/zsh
# usage: tools/perf/hitches.sh <label> [runs] — the same three flicks per run, Animation Hitches over 6 s.
# Needs Accessibility for the terminal. Open the list to measure first; results land in build/perf/.
setopt nullglob
label=${1:?label}; runs=${2:-3}
source ${0:A:h}/common.sh
df -h / | tail -1 | awk '{print "free:", $4}'
trace=$out/h.trace
for r in $(seq 1 $runs); do
  $flick $pid top; sleep 1.5
  rm -rf $out/rec.log $trace
  xcrun xctrace record --template 'Animation Hitches' --attach $pid --time-limit 6s --output $trace --no-prompt \
    > $out/rec.log 2>&1 &
  rec=$!
  for _ in $(seq 1 100); do grep -q 'Ctrl-C to stop\|Starting recording' $out/rec.log && break; sleep 0.1; done
  sleep 0.3
  $flick $pid down
  wait $rec
  for table in hitches hitches-frame-lifetimes; do
    xcrun xctrace export --input $trace --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$table\"]" \
      > $out/$label-$r-$table.xml 2>/dev/null
  done
  # The trace runs to gigabytes and DTServiceHub keeps deleted files open: once the disk went to zero.
  rm -rf $trace $(getconf DARWIN_USER_TEMP_DIR)/instruments*.ktrace; pkill -9 -x DTServiceHub
  printf "%s #%d  " $label $r
  python3 ${0:A:h}/parse_hitches.py $out/$label-$r-hitches.xml $out/$label-$r-hitches-frame-lifetimes.xml 6
  sleep 2
done
