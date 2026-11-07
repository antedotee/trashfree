#!/bin/zsh
# Times tfscan on one or more targets. Each run is a fresh process, so every run pays
# the same allocation costs; the first run per target is a discarded warm-up so the
# rest read from a warm cache.
#
# Usage: scripts/bench-scan.sh [-n runs] [-t threads] [-o out.tsv] [--no-warmup] target...
# A target of "/" scans the startup disk with the app's startup-disk rules.
# Prints: target, run, threads, seconds, items, bytes; then the median per target.
set -euo pipefail
root="${0:A:h:h}"
runs=5 threads="" out="" warmup=1
while (( $# )); do
  case "$1" in
    -n) runs=$2; shift 2 ;;
    -t) threads=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    --no-warmup) warmup=0; shift ;;
    *) break ;;
  esac
done
(( $# )) || { print -u2 "usage: $0 [-n runs] [-t threads] [-o out.tsv] [--no-warmup] target..."; exit 2; }
[[ -n $out ]] || { mkdir -p "$root/analysis/bench"; out="$root/analysis/bench/$(date +%Y%m%d-%H%M%S)-trashfree.tsv"; }

swift build -c release --product tfscan --package-path "$root" >&2
tfscan="$(swift build -c release --show-bin-path --package-path "$root")/tfscan"

print -r -- $'target\trun\tthreads\tseconds\titems\tbytes' > "$out"
for target in "$@"; do
  args=("$target")
  [[ $target == / ]] && args+=(--startup)
  [[ -n $threads ]] && args+=(--threads "$threads")
  (( warmup )) && "$tfscan" "${args[@]}" --tsv > /dev/null
  for run in {1..$runs}; do
    "$tfscan" "${args[@]}" --tsv | awk -v r="$run" 'BEGIN{FS=OFS="\t"} {$2=r; print}' | tee -a "$out"
  done
done

print -u2 "\nmedian seconds (min-max) per target -> $out"
awk 'BEGIN{FS="\t"} NR>1 {t[$1]=t[$1] " " $4; items[$1]=$5; bytes[$1]=$6}
  END {
    for (k in t) {
      n = split(substr(t[k], 2), v, " ")
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] + 0 < v[i] + 0) { x = v[i]; v[i] = v[j]; v[j] = x }
      median = (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
      printf "%s\tmedian %.3f\t(%.3f-%.3f)\titems %s\tbytes %s\n", k, median, v[1], v[n], items[k], bytes[k]
    }
  }' "$out" >&2
