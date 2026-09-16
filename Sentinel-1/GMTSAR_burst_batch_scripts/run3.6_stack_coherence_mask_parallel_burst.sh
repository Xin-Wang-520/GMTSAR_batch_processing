#!/usr/bin/env bash
# Run 3.6: calculate mean coherence and a coherence mask directly from one burst stack.
# No IW1/IW2/IW3 merge is performed.

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

DEFAULT_THRESHOLD="0.075"
DEFAULT_BATCH="50"
DEFAULT_JOBS="5"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 3.6: mean-coherence mask for one burst stack (no merge)

Usage:
  ./run3.6_stack_coherence_mask_parallel_burst.sh
  ./run3.6_stack_coherence_mask_parallel_burst.sh THRESHOLD [BATCH] [JOBS]

No arguments:
  Show this guide and check every Run 3.5 corr.grd.
  No burst result is changed and stack processing is not started.

Recommended formal run:
  ./run3.6_stack_coherence_mask_parallel_burst.sh 0.075 50 5

Arguments:
  THRESHOLD  Mean-coherence threshold for mask_def.grd (0 to 1).
             Recommended value: 0.075
  BATCH      Number of corr.grd files summed in one batch. Default: 50
  JOBS       Maximum batch jobs processed concurrently. Default: 5

Direct input (no merge/ directory):
  burst/intf_all/<pair>/corr.grd

Outputs:
  burst/grid_list
  burst/mean_corr.grd
  burst/mask_def.grd
  burst/mask_def.pdf

Mask values:
  1   = mean_corr >= THRESHOLD
  NaN = mean_corr <  THRESHOLD
========================================
EOF
}

validate_parameters() {
    [[ "$THRESHOLD" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
        die "THRESHOLD must be numeric: $THRESHOLD"
    awk -v value="$THRESHOLD" 'BEGIN {exit !(value >= 0 && value <= 1)}' ||
        die "THRESHOLD must be between 0 and 1: $THRESHOLD"
    [[ "$BATCH" =~ ^[1-9][0-9]*$ ]] ||
        die "BATCH must be a positive integer: $BATCH"
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] ||
        die "JOBS must be a positive integer: $JOBS"
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi

for command_name in awk basename cp find head mktemp mv sort split uniq wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "$ROOT_DIR")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT_DIR)"

BURST_DIR="$ROOT_DIR/burst"
INTF_ALL_DIR="$BURST_DIR/intf_all"
EXPECTED_FILE="$BURST_DIR/run3.5_expected_pairs.tsv"
FAILED_FILE="$BURST_DIR/run3.5_failed_pairs.tsv"
FINAL_INFO="$BURST_DIR/run3.3_finalized.info"

[[ -d "$BURST_DIR" ]] || die "missing $BURST_DIR"
[[ -d "$INTF_ALL_DIR" ]] || die "missing $INTF_ALL_DIR; complete Run 3.5 first"
[[ -s "$EXPECTED_FILE" ]] || die "missing $EXPECTED_FILE; complete Run 3.5 first"
[[ -s "$FINAL_INFO" ]] || die "missing $FINAL_INFO; complete Run 3.3 Mode 2 first"
if [[ -s "$FAILED_FILE" ]]; then
    die "Run 3.5 has failed pairs listed in $FAILED_FILE; resolve them first"
fi

FINAL_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$FINAL_INFO")"
ACCEPTED_PAIRS="$(awk -F= '$1=="accepted_pair_count" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_STATUS" == FINALIZED ]] || die "Run 3.3 status is not FINALIZED"
[[ "$ACCEPTED_PAIRS" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid accepted_pair_count in $FINAL_INFO"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run3.6-burst.XXXXXX")"
LOCK_DIR=""
cleanup() {
    rm -rf -- "$TEMP_DIR"
    [[ -z "$LOCK_DIR" ]] || rmdir -- "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

PAIR_DIR_LIST="$TEMP_DIR/pair_dirs.txt"
CORR_LIST="$TEMP_DIR/corr_list.txt"
MISSING_LIST="$TEMP_DIR/missing.tsv"
: > "$PAIR_DIR_LIST"
: > "$CORR_LIST"
: > "$MISSING_LIST"

while IFS=$'\t' read -r pair pair_dir pair_log extra; do
    [[ -n "$pair" && -n "$pair_dir" && -n "$pair_log" && -z "${extra:-}" ]] ||
        die "invalid record in $EXPECTED_FILE: ${pair:-empty}"
    [[ "$pair" =~ ^S1_[0-9]{8}_ALL_F[123]:S1_[0-9]{8}_ALL_F[123]$ ]] ||
        die "invalid pair name in $EXPECTED_FILE: $pair"
    [[ "$pair_dir" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] ||
        die "invalid output directory in $EXPECTED_FILE: $pair_dir"
    printf '%s\n' "$pair_dir" >> "$PAIR_DIR_LIST"
    if [[ -s "$INTF_ALL_DIR/$pair_dir/corr.grd" ]]; then
        printf 'intf_all/%s/corr.grd\n' "$pair_dir" >> "$CORR_LIST"
    else
        printf '%s\t%s\n' "$pair" "$pair_dir/corr.grd" >> "$MISSING_LIST"
    fi
done < "$EXPECTED_FILE"

PAIR_COUNT="$(wc -l < "$PAIR_DIR_LIST" | awk '{print $1}')"
CORR_COUNT="$(wc -l < "$CORR_LIST" | awk '{print $1}')"
DUPLICATE_DIRS="$(sort "$PAIR_DIR_LIST" | uniq -d | wc -l | awk '{print $1}')"
[[ "$PAIR_COUNT" -eq "$ACCEPTED_PAIRS" ]] ||
    die "Run 3.5 manifest count=$PAIR_COUNT, Run 3.3 accepted count=$ACCEPTED_PAIRS"
(( DUPLICATE_DIRS == 0 )) ||
    die "Run 3.5 manifest contains $DUPLICATE_DIRS duplicate output directories"

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.6 burst-coherence input check (no merge)'
printf 'Track root             : %s\n' "$ROOT_DIR"
printf 'Finalized pairs        : %s\n' "$ACCEPTED_PAIRS"
printf 'Run 3.5 pair records   : %s\n' "$PAIR_COUNT"
printf 'Non-empty corr.grd     : %s\n' "$CORR_COUNT"
printf 'Input directory        : %s\n' "$INTF_ALL_DIR"
printf '%s\n' '========================================'

if [[ -s "$MISSING_LIST" ]]; then
    printf '%s\n' '[CHECK ERROR] Missing or empty Run 3.5 coherence grids:' >&2
    awk -F '\t' '{printf "  %s  missing: burst/intf_all/%s\n", $1, $2}' \
        "$MISSING_LIST" >&2
    die "stack processing was not started"
fi
printf '[CHECK OK] All %s finalized pairs contain a non-empty corr.grd.\n' "$PAIR_COUNT"

if (( $# == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] Inputs are complete; processing was NOT started.'
    printf '%s\n' '[NEXT] ./run3.6_stack_coherence_mask_parallel_burst.sh 0.075 50 5'
    exit 0
fi

(( $# >= 1 && $# <= 3 )) ||
    die "usage: $0 THRESHOLD [BATCH] [JOBS]"
THRESHOLD="$1"
BATCH="${2:-$DEFAULT_BATCH}"
JOBS="${3:-$DEFAULT_JOBS}"
validate_parameters

for command_name in gmt xargs; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

if command -v flock >/dev/null 2>&1; then
    exec 9> "$ROOT_DIR/.run3.6_stack_burst.lock"
    flock -n 9 || die "another burst Run 3.6 process is already running"
else
    LOCK_DIR="$ROOT_DIR/.run3.6_stack_burst.lock.d"
    mkdir "$LOCK_DIR" 2>/dev/null ||
        die "another burst Run 3.6 process may be running"
fi

cd "$BURST_DIR"
cp "$CORR_LIST" grid_list
CT="$(wc -l < grid_list | awk '{print $1}')"
FIRST="$(head -n 1 grid_list)"
[[ "$CT" -eq "$PAIR_COUNT" ]] || die "generated grid_list count mismatch"
[[ -s "$FIRST" ]] || die "first coherence grid is missing: burst/$FIRST"

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.6: parallel mean-coherence mask for one burst stack'
printf 'Working directory      : %s\n' "$BURST_DIR"
printf 'Coherence grids        : %s\n' "$CT"
printf 'Threshold              : %s\n' "$THRESHOLD"
printf 'Grids per batch        : %s\n' "$BATCH"
printf 'Parallel batch jobs    : %s\n' "$JOBS"
printf '%s\n' 'No merge/ directory is read, created, moved or modified.'
printf '%s\n' '========================================'

printf '%s\n' '[STEP 1] Prepare Run 3.6 temporary batches'
rm -rf -- .run3.6_stack_batches
rm -f -- mean_corr.grd mask_def.grd .run3.6_mask_sum.grd \
    .run3.6_mask_sum_next.grd mask_def.cpt mask_def.ps mask_def.pdf
mkdir .run3.6_stack_batches

printf '%s\n' '[STEP 2] Split the coherence-grid list'
split -l "$BATCH" -d -a 5 grid_list .run3.6_stack_batches/batch_
NBATCH="$(find .run3.6_stack_batches -maxdepth 1 -type f -name 'batch_[0-9]*' | wc -l | awk '{print $1}')"
(( NBATCH > 0 )) || die "no batch lists were generated"

printf '%s\n' '[STEP 3] Create the isolated batch worker'
cat > .run3.6_stack_batches/run_one_batch.sh <<'EOF_WORKER'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C
BLIST="$1"
OUT="$2"
LOG="$3"
{
    printf 'Batch list : %s\n' "$BLIST"
    printf 'Output     : %s\n' "$OUT"
    files=()
    while IFS= read -r file; do
        [[ -n "$file" ]] && files+=("$file")
    done < "$BLIST"
    ((${#files[@]} > 0)) || { printf '[ERROR] Empty batch\n' >&2; exit 1; }
    for file in "${files[@]}"; do
        [[ -s "$file" ]] || { printf '[ERROR] Missing: %s\n' "$file" >&2; exit 1; }
    done
    if ((${#files[@]} == 1)); then
        cp "${files[0]}" "$OUT"
    else
        command=(gmt grdmath "${files[0]}")
        for ((i=1; i<${#files[@]}; i++)); do command+=("${files[i]}" ADD); done
        command+=(= "$OUT")
        "${command[@]}"
    fi
    [[ -s "$OUT" ]] || { printf '[ERROR] Output not generated: %s\n' "$OUT" >&2; exit 1; }
    printf '[OK] %s\n' "$OUT"
} > "$LOG" 2>&1
EOF_WORKER
chmod +x .run3.6_stack_batches/run_one_batch.sh

printf '%s\n' '[STEP 4] Sum coherence grids in parallel batches'
: > .run3.6_stack_batches/jobs.txt
INDEX=0
while IFS= read -r BLIST; do
    INDEX=$((INDEX + 1))
    OUT="$(printf '.run3.6_stack_batches/batch_sum_%05d.grd' "$INDEX")"
    LOG="$(printf '.run3.6_stack_batches/batch_sum_%05d.log' "$INDEX")"
    printf ".run3.6_stack_batches/run_one_batch.sh '%s' '%s' '%s'\n" \
        "$BLIST" "$OUT" "$LOG" >> .run3.6_stack_batches/jobs.txt
done < <(find .run3.6_stack_batches -maxdepth 1 -type f -name 'batch_[0-9]*' | sort)

if command -v parallel >/dev/null 2>&1; then
    parallel --jobs "$JOBS" --halt soon,fail=1 < .run3.6_stack_batches/jobs.txt
else
    printf '%s\n' '[WARN] GNU parallel not found; using xargs -P.'
    xargs -I{} -P "$JOBS" bash -c '{}' < .run3.6_stack_batches/jobs.txt
fi

BATCH_GRIDS=()
while IFS= read -r grid; do
    [[ -n "$grid" ]] && BATCH_GRIDS+=("$grid")
done < <(find .run3.6_stack_batches -maxdepth 1 -type f -name 'batch_sum_*.grd' | sort)
((${#BATCH_GRIDS[@]} == NBATCH)) ||
    die "generated ${#BATCH_GRIDS[@]} batch sums; expected $NBATCH"

printf '%s\n' '[STEP 5] Combine batch sums and calculate mean coherence'
gmt grdmath "$FIRST" 0 MUL = .run3.6_mask_sum.grd
for grid in "${BATCH_GRIDS[@]}"; do
    gmt grdmath .run3.6_mask_sum.grd "$grid" ADD = .run3.6_mask_sum_next.grd
    mv -f -- .run3.6_mask_sum_next.grd .run3.6_mask_sum.grd
done
gmt grdmath .run3.6_mask_sum.grd "$CT" DIV = mean_corr.grd
[[ -s mean_corr.grd ]] || die "mean_corr.grd was not generated"

printf '%s\n' '[STEP 6] Create threshold mask'
gmt grdmath mean_corr.grd "$THRESHOLD" GE 0 NAN = mask_def.grd
[[ -s mask_def.grd ]] || die "mask_def.grd was not generated"

printf '%s\n' '[STEP 7] Inspect output grids'
gmt grdinfo mean_corr.grd | head
gmt grdinfo mask_def.grd | head

printf '%s\n' '[STEP 8] Plot burst/mask_def.pdf'
rm -f -- mask_def.cpt mask_def.ps mask_def.pdf gmt.conf gmt.history .gmtcommands4
cat > mask_def.cpt <<'EOF_CPT'
0.0  245 245 245   0.2  255 210 210
0.2  255 210 210   0.4  255 160 160
0.4  255 160 160   0.6  255 100 100
0.6  255 100 100   0.8  255  50  50
0.8  255  50  50   1.0  255   0   0
B    160 160 160
F    255   0   0
N    160 160 160
EOF_CPT

gmt grdimage mask_def.grd -JX6.5i -Cmask_def.cpt \
    -Bxaf+lRange -Byaf+lAzimuth -BWSen+t"Burst coherence mask: mean corr >= ${THRESHOLD}" \
    -X1.2i -Y2.8i -P -K > mask_def.ps
gmt psscale -Rmask_def.grd -J -DJBC+w5.0i/0.25i+h+o0i/0.35i \
    -Cmask_def.cpt -Bxa0.2f0.1 -O >> mask_def.ps
gmt psconvert -Tf -P -A -Z mask_def.ps
[[ -s mask_def.pdf ]] || die "mask_def.pdf was not generated"

printf '%s\n' '[STEP 9] Remove successful-run temporary files'
rm -f -- .run3.6_mask_sum.grd .run3.6_mask_sum_next.grd \
    mask_def.cpt gmt.conf gmt.history .gmtcommands4
rm -rf -- .run3.6_stack_batches

printf '%s\n' '========================================'
printf '%s\n' '[DONE] Run 3.6 completed successfully; no merge was performed.'
printf 'Input corr grids : %s\n' "$CT"
printf 'Mean coherence   : %s/mean_corr.grd\n' "$BURST_DIR"
printf 'Mask grid        : %s/mask_def.grd\n' "$BURST_DIR"
printf 'Mask figure      : %s/mask_def.pdf\n' "$BURST_DIR"
printf '%s\n' '========================================'
