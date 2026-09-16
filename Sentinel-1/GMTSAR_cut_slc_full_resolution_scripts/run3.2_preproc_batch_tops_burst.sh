#!/usr/bin/env bash
# Run 3.2: parallel TOPS preprocessing for one Sentinel-1 burst stack.

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 3.2: preprocess one burst stack

Usage:
  ./run3.2_preproc_batch_tops_burst.sh
  ./run3.2_preproc_batch_tops_burst.sh NCORES MODE [ESD_MODE]

No arguments:
  Show this guide only. No preprocessing is started.

MODE used by preproc_batch_tops_parallel_new_wx.csh:
  1 = standard preprocessing with preproc_batch_tops.csh
  2 = ESD preprocessing with preproc_batch_tops_esd.csh

ESD_MODE is required only when MODE=2:
  0 = average residual azimuth shift
  1 = median residual azimuth shift (recommended/default ESD choice)
  2 = spatial interpolation of residual azimuth shifts

Recommended normal processing:
  ./run3.2_preproc_batch_tops_burst.sh 5 1

ESD alternatives:
  ./run3.2_preproc_batch_tops_burst.sh 5 2 0
  ./run3.2_preproc_batch_tops_burst.sh 5 2 1
  ./run3.2_preproc_batch_tops_burst.sh 5 2 2

Input from Run 3.1:
  burst/raw/data.in
  burst/raw/dem.grd

Main outputs:
  burst/raw/*ALL*.PRM
  burst/raw/*ALL*.LED
  burst/raw/*ALL*.SLC
  burst/raw/baseline_table.dat
  burst/raw/baseline.ps       (standard mode)
  burst/raw/preproc_all.log

NCORES is the maximum number of pair jobs for this one burst stack.
For a smaller machine, replace 5 with 3 or 2.

Override the custom preprocessor path if needed:
  PREPROC_SCRIPT=/path/to/script.csh ./run3.2_preproc_batch_tops_burst.sh 5 1
========================================
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if (( $# == 0 )); then
    usage
    printf '[INFO] No preprocessing was started.\n'
    exit 0
fi

(( $# >= 2 )) || die "NCORES and MODE are required; run without arguments for examples"
(( $# <= 3 )) || die "too many arguments; use --help"

NCORES="$1"
MODE="$2"
ESD_MODE="${3:-1}"
PREPROC_SCRIPT="${PREPROC_SCRIPT:-/home/xinw/bin/own/preproc_batch_tops_parallel_new_wx.csh}"

[[ "$NCORES" =~ ^[1-9][0-9]*$ ]] || die "NCORES must be a positive integer"
[[ "$MODE" == 1 || "$MODE" == 2 ]] || die "MODE must be 1 (standard) or 2 (ESD)"
if [[ "$MODE" == 2 && $# -ne 3 ]]; then
    die "MODE=2 requires ESD_MODE: 0 (average), 1 (median), or 2 (interpolation)"
fi
if [[ "$MODE" == 1 && $# -eq 3 ]]; then
    die "ESD_MODE is used only when MODE=2"
fi
[[ "$ESD_MODE" == 0 || "$ESD_MODE" == 1 || "$ESD_MODE" == 2 ]] ||
    die "ESD_MODE must be 0 (average), 1 (median), or 2 (interpolation)"

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "$ROOT_DIR")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT_DIR)"

UNIT_DIR="$ROOT_DIR/burst"
RAW_DIR="$UNIT_DIR/raw"
SWATH_FILE="$UNIT_DIR/burst_swath.txt"

[[ -f "$PREPROC_SCRIPT" ]] || die "custom preprocessor not found: $PREPROC_SCRIPT"
for command_name in tcsh parallel awk find wc tee tail sed gmt baseline_table.csh; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
if [[ "$MODE" == 1 ]]; then
    command -v preproc_batch_tops.csh >/dev/null 2>&1 ||
        die "preproc_batch_tops.csh was not found in PATH"
else
    command -v preproc_batch_tops_esd.csh >/dev/null 2>&1 ||
        die "preproc_batch_tops_esd.csh was not found in PATH"
fi

[[ -d "$RAW_DIR" ]] || die "missing $RAW_DIR; complete Run 2.3 first"
[[ -s "$RAW_DIR/data.in" ]] || die "missing or empty $RAW_DIR/data.in; complete Run 3.1 first"
[[ -e "$RAW_DIR/dem.grd" ]] || die "missing or broken $RAW_DIR/dem.grd"
[[ -s "$SWATH_FILE" ]] || die "missing $SWATH_FILE; complete Run 2.3 first"

SWATH="$(tr -d '[:space:]' < "$SWATH_FILE" | tr '[:lower:]' '[:upper:]')"
[[ "$SWATH" =~ ^IW[123]$ ]] || die "invalid subswath in $SWATH_FILE: $SWATH"
SWATH_LOWER="$(printf '%s' "$SWATH" | tr '[:upper:]' '[:lower:]')"

LOCK_DIR=""
if command -v flock >/dev/null 2>&1; then
    exec 9> .run3.2_preproc_burst.lock
    flock -n 9 || die "another burst Run 3.2 process is already running"
else
    LOCK_DIR=".run3.2_preproc_burst.lock.d"
    mkdir "$LOCK_DIR" 2>/dev/null || die "another burst Run 3.2 process may be running"
    trap 'rmdir -- "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

count_links() {
    find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type l "$@" -print |
        wc -l | awk '{print $1}'
}

count_outputs() {
    local pattern="$1"
    find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type f -name "$pattern" -print |
        wc -l | awk '{print $1}'
}

BROKEN_COUNT=0
while IFS= read -r -d '' link; do
    if [[ ! -e "$link" ]]; then
        printf '[BROKEN] %s -> %s\n' "$link" "$(readlink -- "$link")" >&2
        BROKEN_COUNT=$((BROKEN_COUNT + 1))
    fi
done < <(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type l -print0)
(( BROKEN_COUNT == 0 )) || die "$RAW_DIR contains $BROKEN_COUNT broken links"

DATA_COUNT="$(wc -l < "$RAW_DIR/data.in" | awk '{print $1}')"
XML_COUNT="$(count_links -iname "*-${SWATH_LOWER}-slc-*.xml")"
TIFF_COUNT="$(count_links \( -iname "*-${SWATH_LOWER}-slc-*.tif" -o -iname "*-${SWATH_LOWER}-slc-*.tiff" \))"
EOF_COUNT="$(count_links -iname '*.EOF')"
DEM_COUNT="$(count_links -name 'dem.grd')"

(( DATA_COUNT >= 2 )) || die "$RAW_DIR/data.in requires at least two records"
[[ "$XML_COUNT" -eq "$DATA_COUNT" ]] ||
    die "XML/data.in count mismatch: $XML_COUNT/$DATA_COUNT"
[[ "$TIFF_COUNT" -eq "$DATA_COUNT" ]] ||
    die "TIFF/data.in count mismatch: $TIFF_COUNT/$DATA_COUNT"
(( EOF_COUNT > 0 )) || die "no orbit EOF links found in $RAW_DIR"
[[ "$DEM_COUNT" -eq 1 ]] || die "$RAW_DIR requires exactly one dem.grd link"

DATA_ORBIT_MISSING=0
while IFS=: read -r slc orbit extra; do
    [[ -n "$slc" && -n "$orbit" && -z "${extra:-}" ]] ||
        die "malformed data.in record: ${slc}:${orbit}${extra:+:$extra}"
    if [[ "$orbit" = /* ]]; then
        orbit_path="$orbit"
    else
        orbit_path="$RAW_DIR/$orbit"
    fi
    if [[ ! -e "$orbit_path" ]]; then
        printf '[MISSING DATA.IN ORBIT] %s -> %s\n' "$slc" "$orbit" >&2
        DATA_ORBIT_MISSING=$((DATA_ORBIT_MISSING + 1))
    fi
done < "$RAW_DIR/data.in"
(( DATA_ORBIT_MISSING == 0 )) ||
    die "data.in references $DATA_ORBIT_MISSING unavailable orbit file(s); rerun updated Run 3.1"

CPU_TOTAL="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf unknown)"

printf '%s\n' '========================================'
printf 'Run 3.2: preprocess one burst stack\n'
printf 'Track root      : %s\n' "$ROOT_DIR"
printf 'Burst raw       : %s\n' "$RAW_DIR"
printf 'Detected swath  : %s\n' "$SWATH"
printf 'Acquisitions    : %s\n' "$DATA_COUNT"
printf 'XML/TIFF/EOF/DEM: %s/%s/%s/%s\n' "$XML_COUNT" "$TIFF_COUNT" "$EOF_COUNT" "$DEM_COUNT"
printf 'data.in orbits  : all %s records resolved\n' "$DATA_COUNT"
printf 'NCORES          : %s\n' "$NCORES"
printf 'CPU threads     : %s\n' "$CPU_TOTAL"
printf 'MODE            : %s (%s)\n' \
    "$MODE" "$([[ "$MODE" == 1 ]] && printf standard || printf ESD)"
if [[ "$MODE" == 2 ]]; then
    case "$ESD_MODE" in
        0) ESD_NAME=average ;;
        1) ESD_NAME=median ;;
        2) ESD_NAME=interpolation ;;
    esac
    printf 'ESD_MODE        : %s (%s)\n' "$ESD_MODE" "$ESD_NAME"
fi
printf 'Custom script   : %s\n' "$PREPROC_SCRIPT"
if [[ "$MODE" == 2 ]]; then
    printf '[COMMAND] tcsh %q data.in dem.grd %s %s %s\n' \
        "$PREPROC_SCRIPT" "$NCORES" "$MODE" "$ESD_MODE"
else
    printf '[COMMAND] tcsh %q data.in dem.grd %s %s\n' \
        "$PREPROC_SCRIPT" "$NCORES" "$MODE"
fi
printf '%s\n' '========================================'

if [[ "$CPU_TOTAL" =~ ^[0-9]+$ ]] && (( NCORES > CPU_TOTAL )); then
    printf '[WARN] requested jobs (%s) exceed detected CPU threads (%s).\n' \
        "$NCORES" "$CPU_TOTAL"
fi

clean_old_outputs() {
    local old_dir
    rm -f -- \
        "$RAW_DIR/preproc.cmd" \
        "$RAW_DIR/tmp_dirlist" \
        "$RAW_DIR/baseline.ps" \
        "$RAW_DIR/baseline.pdf" \
        "$RAW_DIR/baseline_table.dat" \
        "$RAW_DIR/table.gmt" \
        "$RAW_DIR/prmlist" \
        "$RAW_DIR/preproc_all.log"

    find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type f \
        \( -name 'log_*' -o -name '*.PRM' -o -name '*.LED' -o -name '*.SLC' \) \
        -delete

    shopt -s nullglob
    for old_dir in "$RAW_DIR"/20??????_20??????; do
        [[ -d "$old_dir" ]] || continue
        rm -rf -- "$old_dir"
    done
    shopt -u nullglob
}

clean_old_outputs

COMMAND_STATUS=0
(
    cd -- "$RAW_DIR"
    {
        printf '%s\n' '========================================'
        printf 'Run 3.2 unit : burst\n'
        printf 'Start time   : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'Raw directory: %s\n' "$RAW_DIR"
        printf 'Subswath     : %s\n' "$SWATH"
        printf 'Records      : %s\n' "$DATA_COUNT"
        printf 'NCORES       : %s\n' "$NCORES"
        printf 'MODE         : %s\n' "$MODE"
        printf 'ESD_MODE     : %s\n' "$ESD_MODE"
        printf 'Script       : %s\n' "$PREPROC_SCRIPT"
        printf '%s\n' '========================================'
    } > preproc_all.log

    set +e
    if [[ "$MODE" == 2 ]]; then
        tcsh "$PREPROC_SCRIPT" data.in dem.grd "$NCORES" "$MODE" "$ESD_MODE" \
            >> preproc_all.log 2>&1
    else
        tcsh "$PREPROC_SCRIPT" data.in dem.grd "$NCORES" "$MODE" \
            >> preproc_all.log 2>&1
    fi
    COMMAND_STATUS=$?
    set -e

    if (( COMMAND_STATUS != 0 )); then
        printf '[FAIL] custom preprocessor exited with status %s\n' "$COMMAND_STATUS" \
            | tee -a preproc_all.log >&2
        tail -n 50 preproc_all.log >&2 || true
        exit "$COMMAND_STATUS"
    fi
    printf 'Finish time  : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> preproc_all.log
)

PRM_COUNT="$(count_outputs '*ALL*.PRM')"
LED_COUNT="$(count_outputs '*ALL*.LED')"
SLC_COUNT="$(count_outputs '*ALL*.SLC')"

[[ "$PRM_COUNT" -eq "$DATA_COUNT" ]] ||
    die "PRM count=$PRM_COUNT, expected=$DATA_COUNT; inspect $RAW_DIR/preproc_all.log"
[[ "$LED_COUNT" -eq "$DATA_COUNT" ]] ||
    die "LED count=$LED_COUNT, expected=$DATA_COUNT; inspect $RAW_DIR/preproc_all.log"
[[ "$SLC_COUNT" -eq "$DATA_COUNT" ]] ||
    die "SLC count=$SLC_COUNT, expected=$DATA_COUNT; inspect $RAW_DIR/preproc_all.log"
[[ -s "$RAW_DIR/baseline_table.dat" ]] ||
    die "baseline_table.dat was not generated; inspect $RAW_DIR/preproc_all.log"

BASELINE_COUNT="$(wc -l < "$RAW_DIR/baseline_table.dat" | awk '{print $1}')"
[[ "$BASELINE_COUNT" -eq "$DATA_COUNT" ]] ||
    die "baseline lines=$BASELINE_COUNT, expected=$DATA_COUNT"
if [[ "$MODE" == 1 ]]; then
    [[ -s "$RAW_DIR/baseline.ps" ]] ||
        die "baseline.ps was not generated in standard mode"
fi

{
    printf '[OUTPUT OK] PRM=%s LED=%s SLC=%s baseline=%s\n' \
        "$PRM_COUNT" "$LED_COUNT" "$SLC_COUNT" "$BASELINE_COUNT"
    printf '[DONE] Run 3.2 burst preprocessing completed successfully.\n'
} | tee -a "$RAW_DIR/preproc_all.log"
