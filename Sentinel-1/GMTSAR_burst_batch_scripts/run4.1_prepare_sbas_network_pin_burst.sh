#!/usr/bin/env bash
# Run 4.1: prepare the SBAS pair network directly from burst unwrap products.
# Use external DEM correction and stable-area reference correction.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 4.1: prepare the burst SBAS network (DEM-corrected and reference-pinned unwrap)

Usage:
  ./run4.1_prepare_sbas_network_pin_burst.sh
  ./run4.1_prepare_sbas_network_pin_burst.sh 1

No arguments:
  Check that all finalized Run 3.11 products exist and preview the SBAS network.
  Grid extents, increments and registration are not inspected in this step.
  No SBAS files are created or replaced.

Mode 1:
  ./run4.1_prepare_sbas_network_pin_burst.sh 1

Input interferograms:
  burst/intf_all/<pair>/unwrap_dem_correct_pin_up.grd
  burst/intf_all/<pair>/corr.grd

Run 3.9 must crop corr.grd to the exact unwrap_dem_correct_pin_up.grd geometry first.

Source network and baseline information:
  burst/run3.5_expected_pairs.tsv
  burst/run3.3_finalized.info
  burst/baseline_table.dat

This workflow uses:
  unwrap_dem_correct_pin_up.grd
  external DEM-error correction from Run 3.10
  stable-reference correction from Run 3.11

Outputs:
  sbas_burst_pin/intflist_new
  sbas_burst_pin/intf.in
  sbas_burst_pin/baseline_table.dat
  sbas_burst_pin/supermaster.PRM
  sbas_burst_pin/supermaster.LED
  sbas_burst_pin/run4.1_missing_pairs.tsv
  sbas_burst_pin/run4.1_complete

All finalized pairs must be complete. Incomplete pairs are reported, but they
are not silently excluded from the SBAS network.
========================================
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
(( $# <= 1 )) || die "use no arguments for checking, or use mode 1"
if (( $# == 1 )); then
    [[ "$1" == 1 ]] || die "MODE must be 1"
fi

for command_name in awk basename cp cut date mktemp mv sed sort tr uniq wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT)"

BURST_DIR="$ROOT/burst"
PAIR_ROOT="$BURST_DIR/intf_all"
EXPECTED_FILE="$BURST_DIR/run3.5_expected_pairs.tsv"
FINAL_INFO="$BURST_DIR/run3.3_finalized.info"
RUN35_FAILED="$BURST_DIR/run3.5_failed_pairs.tsv"
RUN38_FAILED="$BURST_DIR/run3.8_failed_pairs.tsv"
RUN38_PID="$BURST_DIR/run3.8_unwrap.pid"
BASELINE_SRC="$BURST_DIR/baseline_table.dat"
SWATH_FILE="$BURST_DIR/burst_swath.txt"
SBAS_DIR="$ROOT/sbas_burst_pin"

[[ -d "$BURST_DIR" ]] || die "missing $BURST_DIR"
[[ -d "$PAIR_ROOT" ]] || die "missing $PAIR_ROOT; complete Run 3.5 first"
[[ -s "$EXPECTED_FILE" ]] || die "missing $EXPECTED_FILE; complete Run 3.5 first"
[[ -s "$FINAL_INFO" ]] || die "missing $FINAL_INFO; complete Run 3.3 Mode 2 first"
[[ -s "$BASELINE_SRC" ]] || die "missing $BASELINE_SRC"
[[ -s "$SWATH_FILE" ]] || die "missing $SWATH_FILE"
[[ ! -s "$RUN35_FAILED" ]] || die "Run 3.5 failure report is not empty: $RUN35_FAILED"
if [[ -s "$RUN38_FAILED" ]]; then
    printf '[WARNING] Stale or unresolved Run 3.8 failure report exists: %s\n' \
        "$RUN38_FAILED" >&2
    printf '%s\n' '[WARNING] Run 4.1 will validate all current products directly.' >&2
fi

if [[ -s "$RUN38_PID" ]]; then
    RUN38_PROCESS="$(awk 'NR==1 {print $1; exit}' "$RUN38_PID")"
    if [[ "$RUN38_PROCESS" =~ ^[1-9][0-9]*$ ]] && kill -0 "$RUN38_PROCESS" 2>/dev/null; then
        die "Run 3.8 is still running (PID $RUN38_PROCESS); wait for it to finish"
    fi
fi

FINAL_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$FINAL_INFO")"
ACCEPTED_PAIRS="$(awk -F= '$1=="accepted_pair_count" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_STATUS" == FINALIZED ]] || die "Run 3.3 status is not FINALIZED"
[[ "$ACCEPTED_PAIRS" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid accepted_pair_count in $FINAL_INFO"

SWATH="$(tr -d '[:space:]' < "$SWATH_FILE" | tr '[:lower:]' '[:upper:]')"
[[ "$SWATH" =~ ^IW([123])$ ]] || die "invalid swath in $SWATH_FILE: $SWATH"
PRODUCT_SUFFIX="F${BASH_REMATCH[1]}"
MASTER_IMAGE="$(awk -F= '$1=="master_image" {print $2; exit}' "$FINAL_INFO")"
[[ "$MASTER_IMAGE" =~ ^S1_[0-9]{8}_ALL_${PRODUCT_SUFFIX}$ ]] ||
    die "invalid or missing master_image in $FINAL_INFO: ${MASTER_IMAGE:-empty}"
MASTER_PRM="$BURST_DIR/topo/${MASTER_IMAGE}.PRM"
MASTER_LED="$BURST_DIR/topo/${MASTER_IMAGE}.LED"
[[ -s "$MASTER_PRM" ]] || die "missing burst master PRM: $MASTER_PRM"
[[ -s "$MASTER_LED" ]] || die "missing burst master LED: $MASTER_LED"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run4.1-burst.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT INT TERM
PAIR_LIST="$TMP/pairs.txt"
PAIR_MAP="$TMP/pair_map.tsv"
MISSING_LIST="$TMP/missing_pairs.tsv"
STAGE="$TMP/stage"
mkdir -p "$STAGE"
: > "$PAIR_LIST"
: > "$PAIR_MAP"
printf 'pair\tmissing_or_empty_files\n' > "$MISSING_LIST"

while IFS=$'\t' read -r source_pair pair pair_log extra; do
    [[ -n "$source_pair" && -n "$pair" && -n "$pair_log" && -z "${extra:-}" ]] ||
        die "invalid record in $EXPECTED_FILE: ${source_pair:-empty}"
    [[ "$source_pair" =~ ^S1_[0-9]{8}_ALL_${PRODUCT_SUFFIX}:S1_[0-9]{8}_ALL_${PRODUCT_SUFFIX}$ ]] ||
        die "invalid source pair for $SWATH: $source_pair"
    [[ "$pair" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] ||
        die "invalid output pair directory: $pair"
    printf '%s\t%s\n' "$pair" "$source_pair" >> "$PAIR_MAP"

    pair_dir="$PAIR_ROOT/$pair"
    missing=()
    [[ -d "$pair_dir" ]] || missing+=("pair_directory")
    for name in corr.grd phasefilt.grd unwrap_dem_correct_pin_up.grd unwrap.pdf; do
        [[ -s "$pair_dir/$name" ]] || missing+=("$name")
    done
    if (( ${#missing[@]} > 0 )); then
        joined="$(IFS=,; printf '%s' "${missing[*]}")"
        printf '%s\t%s\n' "$pair" "$joined" >> "$MISSING_LIST"
    fi

done < "$EXPECTED_FILE"

sort -k1,1 -u "$PAIR_MAP" -o "$PAIR_MAP"
cut -f1 "$PAIR_MAP" > "$PAIR_LIST"
PAIR_COUNT="$(wc -l < "$PAIR_LIST" | tr -d ' ')"
DUPLICATE_SOURCE_COUNT="$(cut -f1 "$EXPECTED_FILE" | sort | uniq -d | wc -l | tr -d ' ')"
DUPLICATE_DIR_COUNT="$(cut -f2 "$EXPECTED_FILE" | sort | uniq -d | wc -l | tr -d ' ')"
[[ "$PAIR_COUNT" -eq "$ACCEPTED_PAIRS" ]] ||
    die "Run 3.5 pair directories=$PAIR_COUNT, Run 3.3 accepted pairs=$ACCEPTED_PAIRS"
(( DUPLICATE_SOURCE_COUNT == 0 )) || die "Run 3.5 manifest contains duplicate source pairs"
(( DUPLICATE_DIR_COUNT == 0 )) || die "Run 3.5 manifest contains duplicate output directories"

MISSING_COUNT="$(( $(wc -l < "$MISSING_LIST" | tr -d ' ') - 1 ))"
if (( MISSING_COUNT > 0 )); then
    printf '[ERROR] %s finalized pairs are incomplete:\n' "$MISSING_COUNT" >&2
    sed -n '1,21p' "$MISSING_LIST" >&2
    (( MISSING_COUNT > 20 )) && printf '%s\n' '[INFO] Only the first 20 are shown.' >&2
    die "complete the listed current products before starting SBAS"
fi

PARAMETER_MODE='not inspected by Run 4.1'
COMMON_THRESHOLD='not checked'
COMMON_DISCONTINUITY='not checked'
COMMON_REGION='not checked'

CORR_PRESENT="$PAIR_COUNT"

cut -f2 "$PAIR_MAP" > "$STAGE/intf.in"

awk -F: 'NF>=2 {print $1; print $2}' "$STAGE/intf.in" | sort -u > "$STAGE/used_scenes.txt"
awk 'NR==FNR {available[$1]=1; next} !($1 in available) {print $1}' \
    "$BASELINE_SRC" "$STAGE/used_scenes.txt" > "$STAGE/missing_scenes.txt"
if [[ -s "$STAGE/missing_scenes.txt" ]]; then
    printf '[ERROR] These scenes are absent from %s:\n' "$BASELINE_SRC" >&2
    sed 's/^/  /' "$STAGE/missing_scenes.txt" >&2
    exit 1
fi
awk 'NR==FNR {used[$1]=1; next} ($1 in used)' \
    "$STAGE/used_scenes.txt" "$BASELINE_SRC" > "$STAGE/baseline_table.dat"

cp "$PAIR_LIST" "$STAGE/intflist_new"
cp "$MISSING_LIST" "$STAGE/run4.1_missing_pairs.tsv"
cp "$MASTER_PRM" "$STAGE/supermaster.PRM"
cp "$MASTER_LED" "$STAGE/supermaster.LED"
PAIR_LINES="$(wc -l < "$STAGE/intf.in" | tr -d ' ')"
SCENE_LINES="$(wc -l < "$STAGE/used_scenes.txt" | tr -d ' ')"
BASELINE_LINES="$(wc -l < "$STAGE/baseline_table.dat" | tr -d ' ')"
[[ "$PAIR_LINES" -eq "$PAIR_COUNT" ]] || die "generated intf.in count mismatch"
[[ "$BASELINE_LINES" -eq "$SCENE_LINES" ]] || die "filtered baseline table count mismatch"

printf '%s\n' '========================================'
printf '%s\n' 'Run 4.1 burst SBAS input check'
printf 'Track root               : %s\n' "$ROOT"
printf 'Burst swath              : %s -> %s\n' "$SWATH" "$PRODUCT_SUFFIX"
printf 'Finalized pairs          : %s\n' "$PAIR_COUNT"
printf 'Complete pin-corrected grids : %s\n' "$PAIR_COUNT"
printf 'Non-empty corr.grd       : %s\n' "$CORR_PRESENT"
printf 'Unique acquisition scenes: %s\n' "$SCENE_LINES"
printf 'Unwrap source            : burst/intf_all/<pair>/unwrap_dem_correct_pin_up.grd\n'
printf 'External DEM correction  : enabled\n'
printf 'Reference-pin correction : enabled\n'
printf 'Run 3.8 parameters       : %s\n' "$PARAMETER_MODE"
printf 'Correlation threshold    : %s\n' "$COMMON_THRESHOLD"
printf 'Maximum discontinuity    : %s\n' "$COMMON_DISCONTINUITY"
printf 'Radar region             : %s\n' "$COMMON_REGION"
printf 'Grid geometry check      : skipped (existence/non-empty only)\n'
printf 'Baseline source          : %s\n' "$BASELINE_SRC"
printf 'Master PRM source        : %s\n' "$MASTER_PRM"
printf 'Master LED source        : %s\n' "$MASTER_LED"
printf 'SBAS master PRM          : %s/supermaster.PRM\n' "$SBAS_DIR"
printf 'SBAS master LED          : %s/supermaster.LED\n' "$SBAS_DIR"
printf 'SBAS directory           : %s\n' "$SBAS_DIR"
printf '%s\n' '========================================'

if (( $# == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] No SBAS file was created or modified.'
    printf '%s\n' '[NEXT] ./run4.1_prepare_sbas_network_pin_burst.sh 1'
    exit 0
fi

mkdir -p "$SBAS_DIR"
STAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_DIR="$SBAS_DIR/run4.1_backup_$STAMP"
backup_count=0
for name in intflist_new intf.in baseline_table.dat supermaster.PRM supermaster.LED run4.1_missing_pairs.tsv run4.1_complete; do
    if [[ -e "$SBAS_DIR/$name" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$SBAS_DIR/$name" "$BACKUP_DIR/"
        backup_count=$((backup_count + 1))
    fi
done
(( backup_count == 0 )) || printf '[BACKUP] Previous Run 4.1 files: %s\n' "$BACKUP_DIR"

for name in intflist_new intf.in baseline_table.dat supermaster.PRM supermaster.LED run4.1_missing_pairs.tsv; do
    mv -f -- "$STAGE/$name" "$SBAS_DIR/$name"
done

{
    printf 'status=COMPLETE\n'
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'product_suffix=%s\n' "$PRODUCT_SUFFIX"
    printf 'pairs=%s\n' "$PAIR_COUNT"
    printf 'unique_scenes=%s\n' "$SCENE_LINES"
    printf 'pair_root=%s\n' "$PAIR_ROOT"
    printf 'unwrap_name=unwrap_dem_correct_pin_up.grd\n'
    printf 'corr_name=corr.grd\n'
    printf 'external_dem_correction=enabled\n'
    printf 'reference_pin_correction=enabled\n'
    printf 'correlation_threshold=%s\n' "$COMMON_THRESHOLD"
    printf 'maximum_discontinuity=%s\n' "$COMMON_DISCONTINUITY"
    printf 'radar_region=%s\n' "$COMMON_REGION"
    printf 'grid_geometry_check=skipped\n'
    printf 'baseline_source=%s\n' "$BASELINE_SRC"
    printf 'master_image=%s\n' "$MASTER_IMAGE"
    printf 'master_prm_source=%s\n' "$MASTER_PRM"
    printf 'master_led_source=%s\n' "$MASTER_LED"
    printf 'supermaster_prm=%s/supermaster.PRM\n' "$SBAS_DIR"
    printf 'supermaster_led=%s/supermaster.LED\n' "$SBAS_DIR"
} > "$SBAS_DIR/run4.1_complete"

printf '%s\n' '========================================'
printf '%s\n' '[DONE] Run 4.1 completed successfully.'
printf 'Pair list      : %s/intflist_new (%s)\n' "$SBAS_DIR" "$PAIR_COUNT"
printf 'SBAS intf.in   : %s/intf.in (%s)\n' "$SBAS_DIR" "$PAIR_LINES"
printf 'Baseline table : %s/baseline_table.dat (%s)\n' "$SBAS_DIR" "$BASELINE_LINES"
printf 'Supermaster PRM: %s/supermaster.PRM\n' "$SBAS_DIR"
printf 'Supermaster LED: %s/supermaster.LED\n' "$SBAS_DIR"
printf 'SBAS corr grids: burst/intf_all/<pair>/corr.grd (%s)\n' "$CORR_PRESENT"
printf '%s\n' 'Run 4.1 did not move, rename or modify corr.grd or unwrap_dem_correct_pin_up.grd.'
printf '%s\n' '========================================'
