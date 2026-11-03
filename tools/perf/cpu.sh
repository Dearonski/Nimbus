#!/bin/zsh
# usage: tools/perf/cpu.sh <label> [runs] — CPU the app spends on the same three flicks, nothing attached.
label=${1:?label}; runs=${2:-5}
source ${0:A:h}/common.sh
cpu() {
  ps -o time= -p $pid | awk -F'[:.]' '{ print (NF == 3 ? $1*60+$2 : ($1*60+$2)*60+$3) * 1000 + $NF*10 }'
}
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
for r in $(seq 1 $runs); do
  $flick $pid top; sleep 2
  a=$(cpu); t0=$(now)
  $flick $pid down; sleep 1
  b=$(cpu); t1=$(now)
  awk -v l=$label -v r=$r -v a=$a -v b=$b -v t0=$t0 -v t1=$t1 \
    'BEGIN { printf "%s #%d  cpu: %d ms over %.1f s = %.1f%%\n", l, r, b-a, t1-t0, (b-a)/((t1-t0)*10) }'
done
