#!/usr/bin/env bash
# Run 3.5: generate TOPS interferograms in parallel for one burst stack.

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
Run 3.5: parallel TOPS interferograms for one burst stack

Usage:
  ./run3.5_intf_tops_parallel_burst.sh
  ./run3.5_intf_tops_parallel_burst.sh JOBS

No arguments:
  Show this guide only. No interferogram processing is started.

JOBS:
  Maximum number of interferogram pairs processed concurrently inside burst/.

Recommended:
  ./run3.5_intf_tops_parallel_burst.sh 5

Equivalent driver command inside burst/:
  intf_tops_parallel.csh intf.in batch_tops.config 5

Required state:
  Run 3.3 Mode 2 finalized burst/intf.in.
  Run 3.4 generated burst/topo/trans.dat and burst/topo/topo_ra.grd.
  batch_tops.config has proc_stage=2 and topo_phase=1.

Main outputs:
  burst/intf_all/<pair>/corr.grd
  burst/intf_all/<pair>/mask.grd
  burst/intf_all/<pair>/phasefilt.grd
  burst/itp.log
  burst/run3.5_expected_pairs.tsv
  burst/run3.5_failed_pairs.tsv    (only when failures occur)

For a long server run:
  nohup ./run3.5_intf_tops_parallel_burst.sh 5 \
    > run3.5_intf_tops_parallel.nohup.log 2>&1 &

Monitor:
  tail -f run3.5_intf_tops_parallel.nohup.log
  tail -f burst/itp.log

Override the driver if needed:
  INTF_PARALLEL_SCRIPT=/path/intf_tops_parallel.csh \
    ./run3.5_intf_tops_parallel_burst.sh 5
========================================
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
if (( $# == 0 )); then
    usage
    printf '[INFO] No interferogram processing was started.\n'
    exit 0
fi
[[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || die "provide one positive JOBS value"
JOBS="$1"

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "$ROOT_DIR")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT_DIR)"

UNIT_DIR="$ROOT_DIR/burst"
RAW_DIR="$UNIT_DIR/raw"
TOPO_DIR="$UNIT_DIR/topo"
INTF_FILE="$UNIT_DIR/intf.in"
CONFIG="$UNIT_DIR/batch_tops.config"
FINAL_INFO="$UNIT_DIR/run3.3_finalized.info"
SWATH_FILE="$UNIT_DIR/burst_swath.txt"
EXPECTED_FILE="$UNIT_DIR/run3.5_expected_pairs.tsv"
FAILED_FILE="$UNIT_DIR/run3.5_failed_pairs.tsv"
UNEXPECTED_FILE="$UNIT_DIR/run3.5_unexpected_outputs.txt"
FRAME_LOG="$UNIT_DIR/itp.log"

for command_name in awk basename comm cut find grep mktemp parallel sed sort tail tcsh tr uniq wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done
command -v intf_tops.csh >/dev/null 2>&1 || die "intf_tops.csh was not found in PATH"

if [[ -n "${INTF_PARALLEL_SCRIPT:-}" ]]; then
    [[ -f "$INTF_PARALLEL_SCRIPT" ]] ||
        die "INTF_PARALLEL_SCRIPT not found: $INTF_PARALLEL_SCRIPT"
    INTF_DRIVER="$(cd -- "$(dirname -- "$INTF_PARALLEL_SCRIPT")" && pwd -P)/$(basename -- "$INTF_PARALLEL_SCRIPT")"
else
    INTF_DRIVER="$(command -v intf_tops_parallel.csh 2>/dev/null || true)"
    [[ -n "$INTF_DRIVER" && -f "$INTF_DRIVER" ]] ||
        die "intf_tops_parallel.csh was not found; set INTF_PARALLEL_SCRIPT"
fi

[[ -d "$UNIT_DIR" ]] || die "missing $UNIT_DIR; complete Run 2.3 first"
[[ -d "$RAW_DIR" ]] || die "missing $RAW_DIR; complete Run 2.3 first"
[[ -d "$TOPO_DIR" ]] || die "missing $TOPO_DIR; complete Run 2.3 first"
[[ -s "$INTF_FILE" ]] || die "missing or empty $INTF_FILE; complete Run 3.3 first"
[[ -s "$CONFIG" ]] || die "missing or empty $CONFIG; complete Run 3.3 first"
[[ -s "$FINAL_INFO" ]] || die "missing $FINAL_INFO; complete Run 3.3 Mode 2 first"
[[ -s "$SWATH_FILE" ]] || die "missing $SWATH_FILE; complete Run 2.3 first"

config_value() {
    local key="$1"
    awk -F= -v key="$key" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            value=$2
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$CONFIG"
}

clock_id_from_prm() {
    awk '$1 == "SC_clock_start" {printf "%d", int($3); exit}' "$1"
}

FINAL_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_STATUS" == FINALIZED ]] || die "Run 3.3 status is not FINALIZED"
ACCEPTED_PAIRS="$(awk -F= '$1=="accepted_pair_count" {print $2; exit}' "$FINAL_INFO")"
[[ "$ACCEPTED_PAIRS" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid or missing accepted_pair_count in $FINAL_INFO"

SWATH="$(tr -d '[:space:]' < "$SWATH_FILE" | tr '[:lower:]' '[:upper:]')"
[[ "$SWATH" =~ ^IW([123])$ ]] || die "invalid subswath in $SWATH_FILE: $SWATH"
PRODUCT_SUFFIX="F${BASH_REMATCH[1]}"

PROC_STAGE="$(config_value proc_stage)"
TOPO_PHASE="$(config_value topo_phase)"
SHIFT_TOPO="$(config_value shift_topo)"
THRESHOLD_GEOCODE="$(config_value threshold_geocode)"
MASTER_IMAGE="$(config_value master_image)"

[[ "$PROC_STAGE" == 2 ]] ||
    die "$CONFIG: proc_stage must be 2 after Run 3.4 (current: ${PROC_STAGE:-missing})"
[[ "$TOPO_PHASE" == 1 ]] ||
    die "$CONFIG: topo_phase must be 1 (current: ${TOPO_PHASE:-missing})"
[[ "$SHIFT_TOPO" == 0 || "$SHIFT_TOPO" == 1 ]] ||
    die "$CONFIG: shift_topo must be 0 or 1 (current: ${SHIFT_TOPO:-missing})"
[[ "$THRESHOLD_GEOCODE" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    die "$CONFIG: invalid threshold_geocode: ${THRESHOLD_GEOCODE:-missing}"
[[ "$MASTER_IMAGE" =~ ^S1_[0-9]{8}_ALL_${PRODUCT_SUFFIX}$ ]] ||
    die "$CONFIG: invalid master_image for $SWATH: ${MASTER_IMAGE:-missing}"
FINAL_MASTER="$(awk -F= '$1=="master_image" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_MASTER" == "$MASTER_IMAGE" ]] ||
    die "master_image changed after Run 3.3 finalization: config=$MASTER_IMAGE final=$FINAL_MASTER"

[[ -s "$TOPO_DIR/topo_ra.grd" ]] ||
    die "missing $TOPO_DIR/topo_ra.grd; complete Run 3.4 first"
[[ -s "$TOPO_DIR/trans.dat" ]] ||
    die "missing $TOPO_DIR/trans.dat; complete Run 3.4 first"
if [[ "$SHIFT_TOPO" == 1 ]]; then
    [[ -s "$TOPO_DIR/topo_shift.grd" ]] ||
        die "shift_topo=1 but $TOPO_DIR/topo_shift.grd is missing"
fi

CLEAN_INTF="$(mktemp "${TMPDIR:-/tmp}/run3.5-burst-intf.XXXXXX")"
LOCK_DIR=""
EXPECTED_DIRS=""
ACTUAL_DIRS=""
cleanup() {
    rm -f -- "$CLEAN_INTF"
    [[ -z "$EXPECTED_DIRS" ]] || rm -f -- "$EXPECTED_DIRS"
    [[ -z "$ACTUAL_DIRS" ]] || rm -f -- "$ACTUAL_DIRS"
    [[ -z "$LOCK_DIR" ]] || rmdir -- "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

awk 'NF && $0 !~ /^[[:space:]]*#/ {print}' "$INTF_FILE" > "$CLEAN_INTF"
PAIR_COUNT="$(wc -l < "$CLEAN_INTF" | awk '{print $1}')"
[[ "$PAIR_COUNT" -eq "$ACCEPTED_PAIRS" ]] ||
    die "intf.in changed after Run 3.3 finalization: current=$PAIR_COUNT, accepted=$ACCEPTED_PAIRS"
DUPLICATE_COUNT="$(sort "$CLEAN_INTF" | uniq -d | wc -l | awk '{print $1}')"
(( DUPLICATE_COUNT == 0 )) || die "$INTF_FILE contains $DUPLICATE_COUNT duplicate pair(s)"

if command -v flock >/dev/null 2>&1; then
    exec 9> "$ROOT_DIR/.run3.5_intf_burst.lock"
    flock -n 9 || die "another burst Run 3.5 process is already running"
else
    LOCK_DIR="$ROOT_DIR/.run3.5_intf_burst.lock.d"
    mkdir "$LOCK_DIR" 2>/dev/null || die "another burst Run 3.5 process may be running"
fi

declare -A CHECKED_IMAGES=()
: > "$EXPECTED_FILE"
while IFS= read -r line; do
    [[ "$line" =~ ^S1_([0-9]{8})_ALL_${PRODUCT_SUFFIX}:S1_([0-9]{8})_ALL_${PRODUCT_SUFFIX}$ ]] ||
        die "$INTF_FILE: invalid pair format: $line"
    REF="${line%%:*}"
    REP="${line#*:}"
    [[ "$REF" != "$REP" ]] || die "$INTF_FILE contains a self pair: $line"

    for image in "$REF" "$REP"; do
        if [[ -z "${CHECKED_IMAGES[$image]+x}" ]]; then
            for extension in PRM LED SLC; do
                [[ -s "$RAW_DIR/${image}.${extension}" ]] ||
                    die "required input missing or empty: $RAW_DIR/${image}.${extension}"
            done
            CHECKED_IMAGES["$image"]=1
        fi
    done

    REF_ID="$(clock_id_from_prm "$RAW_DIR/${REF}.PRM")"
    REP_ID="$(clock_id_from_prm "$RAW_DIR/${REP}.PRM")"
    [[ -n "$REF_ID" && -n "$REP_ID" ]] || die "failed to read SC_clock_start: $line"
    [[ "$REF_ID" != "$REP_ID" ]] || die "pair has identical SC_clock_start values: $line"

    DATE1="${REF:3:8}"
    DATE2="${REP:3:8}"
    WORK_DIR="$UNIT_DIR/intf/${REF_ID}_${REP_ID}"
    [[ ! -e "$WORK_DIR" ]] ||
        die "stale/interrupted work directory found: $WORK_DIR; inspect it before rerunning"

    printf '%s\t%s_%s\tintf_%s_%s.log\n' \
        "$line" "$REF_ID" "$REP_ID" "$DATE1" "$DATE2" >> "$EXPECTED_FILE"
done < "$CLEAN_INTF"

EXPECTED_COUNT="$(wc -l < "$EXPECTED_FILE" | awk '{print $1}')"
[[ "$EXPECTED_COUNT" -eq "$PAIR_COUNT" ]] || die "internal expected-pair count mismatch"

CPU_TOTAL="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf unknown)"
printf '%s\n' '========================================'
printf 'Run 3.5: parallel TOPS interferograms for one burst stack\n'
printf 'Track root       : %s\n' "$ROOT_DIR"
printf 'Detected swath   : %s -> %s\n' "$SWATH" "$PRODUCT_SUFFIX"
printf 'Master image     : %s\n' "$MASTER_IMAGE"
printf 'Finalized pairs  : %s\n' "$PAIR_COUNT"
printf 'Parallel jobs    : %s\n' "$JOBS"
printf 'CPU threads      : %s\n' "$CPU_TOTAL"
printf 'proc_stage       : %s\n' "$PROC_STAGE"
printf 'topo_phase       : %s\n' "$TOPO_PHASE"
printf 'shift_topo       : %s\n' "$SHIFT_TOPO"
printf 'threshold_geocode: %s\n' "$THRESHOLD_GEOCODE"
printf 'Parallel driver  : %s\n' "$INTF_DRIVER"
printf '[COMMAND] tcsh %q intf.in batch_tops.config %s\n' "$INTF_DRIVER" "$JOBS"
printf '%s\n' '========================================'
if [[ "$CPU_TOTAL" =~ ^[0-9]+$ ]] && (( JOBS > CPU_TOTAL )); then
    printf '[WARN] requested jobs (%s) exceed CPU threads (%s).\n' "$JOBS" "$CPU_TOTAL"
fi

rm -f -- "$FRAME_LOG" "$FAILED_FILE" "$UNEXPECTED_FILE"
printf '[RUN] Interferogram driver started; log=%s\n' "$FRAME_LOG"
set +e
(
    cd -- "$UNIT_DIR"
    tcsh "$INTF_DRIVER" intf.in batch_tops.config "$JOBS"
) > "$FRAME_LOG" 2>&1
DRIVER_STATUS=$?
set -e

printf 'pair\treason\tlog\n' > "$FAILED_FILE"
while IFS=$'\t' read -r pair output_dir pair_log; do
    reason=""
    if [[ ! -s "$UNIT_DIR/$pair_log" ]]; then
        reason="pair_log_missing_or_empty"
    elif ! grep -q 'END STACK OF TOPS INTERFEROGRAMS' "$UNIT_DIR/$pair_log"; then
        reason="completion_marker_missing"
    elif [[ ! -d "$UNIT_DIR/intf_all/$output_dir" ]]; then
        reason="output_directory_missing"
    else
        for grid in corr.grd mask.grd phasefilt.grd; do
            if [[ ! -s "$UNIT_DIR/intf_all/$output_dir/$grid" ]]; then
                reason="missing_or_empty_${grid}"
                break
            fi
        done
    fi
    [[ -z "$reason" ]] || printf '%s\t%s\t%s\n' "$pair" "$reason" "$pair_log" >> "$FAILED_FILE"
done < "$EXPECTED_FILE"

FAILED_COUNT=$(( $(wc -l < "$FAILED_FILE" | awk '{print $1}') - 1 ))

EXPECTED_DIRS="$(mktemp "${TMPDIR:-/tmp}/run3.5-expected-dirs.XXXXXX")"
ACTUAL_DIRS="$(mktemp "${TMPDIR:-/tmp}/run3.5-actual-dirs.XXXXXX")"
cut -f2 "$EXPECTED_FILE" | sort -u > "$EXPECTED_DIRS"
if [[ -d "$UNIT_DIR/intf_all" ]]; then
    find "$UNIT_DIR/intf_all" -mindepth 1 -maxdepth 1 -type d -print |
        while IFS= read -r directory; do basename -- "$directory"; done |
        sort -u > "$ACTUAL_DIRS"
else
    : > "$ACTUAL_DIRS"
fi
comm -13 "$EXPECTED_DIRS" "$ACTUAL_DIRS" > "$UNEXPECTED_FILE"
UNEXPECTED_COUNT="$(wc -l < "$UNEXPECTED_FILE" | awk '{print $1}')"
rm -f -- "$EXPECTED_DIRS" "$ACTUAL_DIRS"
EXPECTED_DIRS=""
ACTUAL_DIRS=""

if (( DRIVER_STATUS != 0 || FAILED_COUNT > 0 || UNEXPECTED_COUNT > 0 )); then
    printf '[FAILED] driver_status=%s, failed_pairs=%s/%s, unexpected_outputs=%s\n' \
        "$DRIVER_STATUS" "$FAILED_COUNT" "$EXPECTED_COUNT" "$UNEXPECTED_COUNT" >&2
    printf '[FRAME LOG] %s\n' "$FRAME_LOG" >&2
    printf '[FAILED LIST] %s\n' "$FAILED_FILE" >&2
    if (( UNEXPECTED_COUNT > 0 )); then
        printf '[UNEXPECTED OUTPUTS] %s\n' "$UNEXPECTED_FILE" >&2
    fi
    if [[ -s "$FRAME_LOG" ]]; then
        printf '[LAST 30 FRAME-LOG LINES]\n' >&2
        tail -n 30 "$FRAME_LOG" | sed 's/^/  /' >&2
    fi
    exit 1
fi

rm -f -- "$FAILED_FILE" "$UNEXPECTED_FILE"
printf '%s\n' '========================================'
printf '[DONE] Run 3.5 completed successfully.\n'
printf 'Validated pairs : %s/%s\n' "$EXPECTED_COUNT" "$EXPECTED_COUNT"
printf 'Output directory: %s/intf_all\n' "$UNIT_DIR"
printf 'Frame log       : %s\n' "$FRAME_LOG"
printf 'Expected map    : %s\n' "$EXPECTED_FILE"
printf '%s\n' '========================================'
