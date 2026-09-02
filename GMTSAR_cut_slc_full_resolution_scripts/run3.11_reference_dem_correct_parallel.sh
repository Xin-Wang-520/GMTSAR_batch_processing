#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C LANG=C
# Modified by Xin Wang, USTC, Hefei, 2026-08-30.

usage() {
cat <<'USAGE'
Run 3.11: reference DEM-corrected interferograms

Check only:
  ./run3.11_reference_dem_correct_parallel.sh

Run:
  ./run3.11_reference_dem_correct_parallel.sh 10 1000/2000/200/300

10 = parallel interferograms
The second argument is xmin/xmax/ymin/ymax in radar coordinates.
The median in this window is subtracted from each interferogram.
Output: burst/intf_all/20*_*/unwrap_dem_correct_pin_up.grd
USAGE
}

ROOT="$(pwd -P)"
PAIR_ROOT="$ROOT/burst/intf_all"
[[ -d "$PAIR_ROOT" ]] || { echo "[ERR] Run in a track directory containing burst/intf_all/."; exit 1; }
cd "$PAIR_ROOT"
mapfile -t DIRS < <(find . -maxdepth 1 -mindepth 1 -type d -name '20*_*' -printf '%f\n' | sort)
((${#DIRS[@]} > 0)) || { echo "[ERR] No burst/intf_all/20*_* directories."; exit 1; }

MISSING=run3.11_missing_inputs.tsv
: > "$MISSING"
for d in "${DIRS[@]}"; do
  [[ -s "$d/unwrap_dem_correct.grd" ]] || printf '%s\tmissing_or_empty_unwrap_dem_correct.grd\n' "$d" >> "$MISSING"
done
N_MISSING=$(wc -l < "$MISSING" | tr -d ' ')
echo "========================================"
echo "Run 3.11 input check"
echo "Track root           : $ROOT"
echo "Interferogram pairs  : ${#DIRS[@]}"
echo "Valid corrected grids: $((${#DIRS[@]}-N_MISSING))/${#DIRS[@]}"
echo "========================================"
if [[ -s "$MISSING" ]]; then echo "[ERR] See $PAIR_ROOT/$MISSING"; cat "$MISSING"; exit 1; fi
rm -f "$MISSING"

if [[ $# -eq 0 ]]; then usage; echo "[INFO] No processing was started."; exit 0; fi
[[ $# -eq 2 ]] || { usage; exit 1; }
JOBS="$1"
REGION="$2"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "[ERR] JOBS must be a positive integer."; exit 1; }
awk -v r="$REGION" 'BEGIN {n=split(r,a,"/"); if(n!=4)exit 1; for(i=1;i<=4;i++)if(a[i]!~/^-?[0-9]+([.][0-9]+)?$/)exit 1; if(!(a[1]<a[2]&&a[3]<a[4]))exit 1}' ||
  { echo "[ERR] REGION must be xmin/xmax/ymin/ymax with min < max."; exit 1; }
command -v gmt >/dev/null || { echo "[ERR] GMT not found."; exit 1; }

RUN_LIST=run3.11_reference_pending.txt
FAILED=run3.11_reference_failed.tsv
RESULTS=run3.11_reference_values.tsv
: > "$RUN_LIST"
: > "$FAILED"
for d in "${DIRS[@]}"; do
  if [[ -s "$d/unwrap_dem_correct_pin_up.grd" && -s "$d/reference_dem_correct.info" ]] &&
     grep -Fqx "region=$REGION" "$d/reference_dem_correct.info"; then
    :
  else
    echo "$d" >> "$RUN_LIST"
  fi
done
N_PENDING=$(wc -l < "$RUN_LIST" | tr -d ' ')
echo "[RUN] jobs=$JOBS region=$REGION pending=$N_PENDING completed=$((${#DIRS[@]}-N_PENDING))"
if ((N_PENDING==0)); then rm -f "$RUN_LIST" "$FAILED"; echo "[DONE] All outputs already match this window."; exit 0; fi

run_one() {
  local d="$1" region="$2"
  (
    cd "$d"
    tmp=$(mktemp .run3.11.XXXXXX.grd)
    trap 'rm -f "$tmp"' EXIT INT TERM
    gmt grdcut unwrap_dem_correct.grd -R"$region" -G"$tmp"
    median=$(gmt grdinfo "$tmp" -L1 -C | awk '{print $12}')
    awk -v x="$median" 'BEGIN{exit !(x~/^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/)}' ||
      { echo "[FAIL] invalid median: $median" >&2; exit 1; }
    out="unwrap_dem_correct_pin_up.grd.tmp.$$"
    gmt grdmath unwrap_dem_correct.grd "$median" SUB = "$out"
    [[ -s "$out" ]] || exit 1
    mv "$out" unwrap_dem_correct_pin_up.grd
    printf 'region=%s\nmedian=%s\ncompleted=%s\n' "$region" "$median" "$(date -Is)" > reference_dem_correct.info
  )
}
export -f run_one
set +e
xargs -I{} -P "$JOBS" bash -lc 'run_one "$1" "$2"' _ {} "$REGION" < "$RUN_LIST"
status=$?
set -e

: > "$FAILED"
printf 'interferogram\treference_median\tregion\n' > "$RESULTS"
for d in "${DIRS[@]}"; do
  if [[ -s "$d/unwrap_dem_correct_pin_up.grd" && -s "$d/reference_dem_correct.info" ]] &&
     grep -Fqx "region=$REGION" "$d/reference_dem_correct.info"; then
    median=$(awk -F= '$1=="median"{print $2}' "$d/reference_dem_correct.info")
    printf '%s\t%s\t%s\n' "$d" "$median" "$REGION" >> "$RESULTS"
  else
    printf '%s\tmissing_or_invalid_output\n' "$d" >> "$FAILED"
  fi
done
if [[ -s "$FAILED" || $status -ne 0 ]]; then echo "[ERROR] See $PAIR_ROOT/$FAILED"; exit 1; fi
rm -f "$RUN_LIST" "$FAILED"
printf 'region=%s\npairs=%s\ncompleted=%s\n' "$REGION" "${#DIRS[@]}" "$(date -Is)" > run3.11_complete
echo "========================================"
echo "[DONE] Reference correction: ${#DIRS[@]}/${#DIRS[@]} passed validation."
echo "Output list: $PAIR_ROOT/$RESULTS"
echo "========================================"
