#!/usr/bin/env bash
# Run 3.7: generate a radar-coordinate land mask directly for one burst stack.
# No IW merge and no merge/ directory are used.

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

TRANS_MIN_BYTES="${BURST_TRANS_MIN_BYTES:-1048576}"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 3.7: radar-coordinate land mask for one burst stack (no merge)

Usage:
  ./run3.7_make_landmask_ra_burst.sh
  ./run3.7_make_landmask_ra_burst.sh 1

No arguments:
  Check all required inputs and grid geometry only.
  No land mask is generated or replaced.

Mode 1:
  Generate or replace the burst radar-coordinate land mask:
  ./run3.7_make_landmask_ra_burst.sh 1

Inputs:
  burst/topo/dem.grd
  burst/topo/trans.dat
  burst/mask_def.grd                         (from Run 3.6)
  burst/intf_all/<pair>/phasefilt.grd       (from Run 3.5)
  burst/run3.5_expected_pairs.tsv

Processing:
  1. Validate every finalized Run 3.5 phasefilt.grd.
  2. Confirm mask_def.grd and phasefilt.grd have identical geometry.
  3. Run landmask.csh in an isolated temporary directory containing links
     to burst/topo/dem.grd and burst/topo/trans.dat.
  4. Resample landmask_ra.grd exactly to the burst phase-grid geometry.
  5. Validate the output and plot the radar-coordinate land mask.

Outputs:
  burst/landmask_ra.grd
  burst/landmask_ra.pdf

No merge/ directory is read, created, moved or modified.
========================================
EOF
}

grid_signature() {
    gmt grdinfo "$1" -C | awk 'NR == 1 {
        # west east south north x_inc y_inc n_columns n_rows registration
        print $2, $3, $4, $5, $8, $9, $10, $11, $12
    }'
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
(( $# <= 1 )) || die "use no arguments for checking, or use mode 1"
if (( $# == 1 )); then
    [[ "$1" == 1 ]] || die "MODE must be 1"
fi
[[ "$TRANS_MIN_BYTES" =~ ^[1-9][0-9]*$ ]] ||
    die "BURST_TRANS_MIN_BYTES must be a positive integer"

for command_name in awk basename find gmt head ln mktemp mv sort wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "$ROOT_DIR")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT_DIR)"

BURST_DIR="$ROOT_DIR/burst"
TOPO_DIR="$BURST_DIR/topo"
INTF_ALL_DIR="$BURST_DIR/intf_all"
EXPECTED_FILE="$BURST_DIR/run3.5_expected_pairs.tsv"
FAILED_FILE="$BURST_DIR/run3.5_failed_pairs.tsv"
FINAL_INFO="$BURST_DIR/run3.3_finalized.info"
DEM="$TOPO_DIR/dem.grd"
TRANS="$TOPO_DIR/trans.dat"
COHERENCE_MASK="$BURST_DIR/mask_def.grd"

[[ -d "$BURST_DIR" ]] || die "missing $BURST_DIR"
[[ -d "$TOPO_DIR" ]] || die "missing $TOPO_DIR"
[[ -d "$INTF_ALL_DIR" ]] || die "missing $INTF_ALL_DIR; complete Run 3.5 first"
[[ -s "$EXPECTED_FILE" ]] || die "missing $EXPECTED_FILE; complete Run 3.5 first"
[[ -s "$FINAL_INFO" ]] || die "missing $FINAL_INFO; complete Run 3.3 Mode 2 first"
[[ -s "$DEM" ]] || die "missing, broken or empty: $DEM"
[[ -s "$TRANS" ]] || die "missing, broken or empty: $TRANS"
[[ -s "$COHERENCE_MASK" ]] || die "missing $COHERENCE_MASK; complete Run 3.6 first"
if [[ -s "$FAILED_FILE" ]]; then
    die "Run 3.5 has failed pairs listed in $FAILED_FILE; resolve them first"
fi

FINAL_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$FINAL_INFO")"
ACCEPTED_PAIRS="$(awk -F= '$1=="accepted_pair_count" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_STATUS" == FINALIZED ]] || die "Run 3.3 status is not FINALIZED"
[[ "$ACCEPTED_PAIRS" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid accepted_pair_count in $FINAL_INFO"

TRANS_BYTES="$(wc -c < "$TRANS" | awk '{print $1}')"
[[ "$TRANS_BYTES" =~ ^[0-9]+$ ]] || die "failed to determine trans.dat size"
(( TRANS_BYTES > TRANS_MIN_BYTES )) ||
    die "$TRANS is too small: $TRANS_BYTES bytes (must exceed $TRANS_MIN_BYTES)"
TRANS_MIB="$(awk -v bytes="$TRANS_BYTES" 'BEGIN {printf "%.2f", bytes/1024/1024}')"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run3.7-burst.XXXXXX")"
LOCK_DIR=""
WORK_DIR="$BURST_DIR/.run3.7_landmask_work"
cleanup() {
    rm -rf -- "$TEMP_DIR"
    [[ -z "$LOCK_DIR" ]] || rmdir -- "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

PAIR_DIR_LIST="$TEMP_DIR/pair_dirs.txt"
MISSING_LIST="$TEMP_DIR/missing.tsv"
: > "$PAIR_DIR_LIST"
: > "$MISSING_LIST"
TEMPLATE=""

while IFS=$'\t' read -r pair pair_dir pair_log extra; do
    [[ -n "$pair" && -n "$pair_dir" && -n "$pair_log" && -z "${extra:-}" ]] ||
        die "invalid record in $EXPECTED_FILE: ${pair:-empty}"
    [[ "$pair" =~ ^S1_[0-9]{8}_ALL_F[123]:S1_[0-9]{8}_ALL_F[123]$ ]] ||
        die "invalid pair name in $EXPECTED_FILE: $pair"
    [[ "$pair_dir" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] ||
        die "invalid output directory in $EXPECTED_FILE: $pair_dir"
    printf '%s\n' "$pair_dir" >> "$PAIR_DIR_LIST"
    phase_grid="$INTF_ALL_DIR/$pair_dir/phasefilt.grd"
    if [[ -s "$phase_grid" ]]; then
        [[ -n "$TEMPLATE" ]] || TEMPLATE="$phase_grid"
    else
        printf '%s\t%s\n' "$pair" "$pair_dir/phasefilt.grd" >> "$MISSING_LIST"
    fi
done < "$EXPECTED_FILE"

PAIR_COUNT="$(wc -l < "$PAIR_DIR_LIST" | awk '{print $1}')"
DUPLICATE_DIRS="$(sort "$PAIR_DIR_LIST" | uniq -d | wc -l | awk '{print $1}')"
[[ "$PAIR_COUNT" -eq "$ACCEPTED_PAIRS" ]] ||
    die "Run 3.5 manifest count=$PAIR_COUNT, Run 3.3 accepted count=$ACCEPTED_PAIRS"
(( DUPLICATE_DIRS == 0 )) ||
    die "Run 3.5 manifest contains $DUPLICATE_DIRS duplicate output directories"
if [[ -s "$MISSING_LIST" ]]; then
    printf '%s\n' '[CHECK ERROR] Missing or empty Run 3.5 phase grids:' >&2
    awk -F '\t' '{printf "  %s  missing: burst/intf_all/%s\n", $1, $2}' \
        "$MISSING_LIST" >&2
    die "land-mask processing was not started"
fi
[[ -n "$TEMPLATE" && -s "$TEMPLATE" ]] || die "no phasefilt.grd template found"

TEMPLATE_SIGNATURE="$(grid_signature "$TEMPLATE")"
MASK_SIGNATURE="$(grid_signature "$COHERENCE_MASK")"
[[ -n "$TEMPLATE_SIGNATURE" ]] || die "failed to read template grid geometry"
[[ -n "$MASK_SIGNATURE" ]] || die "failed to read mask_def.grd geometry"
[[ "$MASK_SIGNATURE" == "$TEMPLATE_SIGNATURE" ]] ||
    die "burst/mask_def.grd geometry does not match the Run 3.5 phase grid"

TEMPLATE_REL="${TEMPLATE#${ROOT_DIR}/}"
REGION="$(gmt grdinfo "$TEMPLATE" -C | awk 'NR == 1 {print $2 "/" $3 "/" $4 "/" $5}')"
[[ "$REGION" == */*/*/* ]] || die "failed to read radar region from $TEMPLATE"

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.7 burst land-mask input check (no merge)'
printf 'Track root             : %s\n' "$ROOT_DIR"
printf 'Finalized phase grids  : %s\n' "$PAIR_COUNT"
printf 'DEM                    : %s\n' "$DEM"
printf 'trans.dat              : %s MiB (> %s bytes)\n' "$TRANS_MIB" "$TRANS_MIN_BYTES"
printf 'Phase template         : %s\n' "$TEMPLATE_REL"
printf 'Radar region           : %s\n' "$REGION"
printf 'Grid signature         : %s\n' "$TEMPLATE_SIGNATURE"
printf 'Run 3.6 mask geometry  : matched\n'
printf '%s\n' '========================================'

if (( $# == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] Inputs are ready; land-mask processing was NOT started.'
    if [[ -s "$BURST_DIR/landmask_ra.grd" ]]; then
        printf 'Existing grid          : %s/landmask_ra.grd\n' "$BURST_DIR"
    else
        printf '%s\n' 'Existing grid          : not found'
    fi
    if [[ -s "$BURST_DIR/landmask_ra.pdf" ]]; then
        printf 'Existing figure        : %s/landmask_ra.pdf\n' "$BURST_DIR"
    else
        printf '%s\n' 'Existing figure        : not found'
    fi
    printf '%s\n' '[NEXT] ./run3.7_make_landmask_ra_burst.sh 1'
    exit 0
fi

command -v landmask.csh >/dev/null 2>&1 || die "landmask.csh was not found in PATH"

if command -v flock >/dev/null 2>&1; then
    exec 9> "$ROOT_DIR/.run3.7_landmask_burst.lock"
    flock -n 9 || die "another burst Run 3.7 process is already running"
else
    LOCK_DIR="$ROOT_DIR/.run3.7_landmask_burst.lock.d"
    mkdir "$LOCK_DIR" 2>/dev/null ||
        die "another burst Run 3.7 process may be running"
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.7: make burst radar-coordinate land mask'
printf 'Temporary workspace    : %s\n' "$WORK_DIR"
printf 'landmask.csh           : %s\n' "$(command -v landmask.csh)"
printf 'Command                : landmask.csh %s\n' "$REGION"
printf '%s\n' 'No merge/ directory will be used.'
printf '%s\n' '========================================'

printf '%s\n' '[STEP 1] Prepare isolated land-mask workspace'
rm -rf -- "$WORK_DIR"
mkdir "$WORK_DIR"
ln -s "$DEM" "$WORK_DIR/dem.grd"
ln -s "$TRANS" "$WORK_DIR/trans.dat"

printf '%s\n' '[STEP 2] Run landmask.csh'
(
    cd "$WORK_DIR"
    landmask.csh "$REGION"
)
[[ -s "$WORK_DIR/landmask_ra.grd" ]] ||
    die "landmask.csh did not generate $WORK_DIR/landmask_ra.grd"

printf '%s\n' '[STEP 3] Match the burst phase-grid geometry exactly'
gmt grdsample "$WORK_DIR/landmask_ra.grd" -R"$TEMPLATE" \
    -G"$WORK_DIR/landmask_ra_resampled.grd"
[[ -s "$WORK_DIR/landmask_ra_resampled.grd" ]] ||
    die "GMT did not generate the resampled land mask"

OUTPUT_SIGNATURE="$(grid_signature "$WORK_DIR/landmask_ra_resampled.grd")"
printf 'Template signature : %s\n' "$TEMPLATE_SIGNATURE"
printf 'Output signature   : %s\n' "$OUTPUT_SIGNATURE"
[[ "$OUTPUT_SIGNATURE" == "$TEMPLATE_SIGNATURE" ]] ||
    die "resampled land-mask geometry does not match the burst phase grid"

printf '%s\n' '[STEP 4] Install burst/landmask_ra.grd'
rm -f -- "$BURST_DIR/landmask_ra.grd" "$BURST_DIR/landmask_ra.pdf" \
    "$BURST_DIR/landmask_ra.ps" "$BURST_DIR/landmask_ra.cpt"
mv -f -- "$WORK_DIR/landmask_ra_resampled.grd" "$BURST_DIR/landmask_ra.grd"
[[ -s "$BURST_DIR/landmask_ra.grd" ]] || die "failed to install landmask_ra.grd"
gmt grdinfo "$BURST_DIR/landmask_ra.grd"

printf '%s\n' '[STEP 5] Plot burst/landmask_ra.pdf'
cd "$BURST_DIR"
rm -f -- landmask_ra.cpt landmask_ra.ps landmask_ra.pdf \
    gmt.conf gmt.history .gmtcommands4
cat > landmask_ra.cpt <<'EOF_CPT'
0.0  160 160 160   0.5  160 160 160
0.5  255   0   0   1.0  255   0   0
B    160 160 160
F    255   0   0
N    160 160 160
EOF_CPT

gmt grdimage landmask_ra.grd -JX6.5i -Clandmask_ra.cpt \
    -Bxaf+lRange -Byaf+lAzimuth -BWSen+t"Burst radar-coordinate land mask" \
    -X1.2i -Y2.8i -P -K > landmask_ra.ps
gmt psscale -Rlandmask_ra.grd -J -DJBC+w5.0i/0.25i+h+o0i/0.35i \
    -Clandmask_ra.cpt -Bxa0.5f0.5+l"Land mask" -O >> landmask_ra.ps
gmt psconvert -Tf -P -A -Z landmask_ra.ps
[[ -s landmask_ra.pdf ]] || die "landmask_ra.pdf was not generated"

printf '%s\n' '[STEP 6] Remove temporary files'
rm -f -- landmask_ra.cpt landmask_ra.ps gmt.conf gmt.history .gmtcommands4
rm -rf -- "$WORK_DIR"

printf '%s\n' '========================================'
printf '%s\n' '[DONE] Run 3.7 completed successfully; no merge was performed.'
printf 'Grid     : %s/landmask_ra.grd\n' "$BURST_DIR"
printf 'Figure   : %s/landmask_ra.pdf\n' "$BURST_DIR"
printf 'Template : %s\n' "$TEMPLATE_REL"
printf 'Region   : %s\n' "$REGION"
printf '%s\n' '========================================'
