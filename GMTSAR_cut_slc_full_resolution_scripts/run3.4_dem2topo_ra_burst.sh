#!/usr/bin/env bash
# Run 3.4: convert the geographic DEM to radar coordinates for one burst stack.

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
Run 3.4: convert burst DEM to radar coordinates

Usage:
  ./run3.4_dem2topo_ra_burst.sh
  ./run3.4_dem2topo_ra_burst.sh 1

No arguments:
  Show this guide only. No processing is started.

Mode 1 - formal processing:
  1. Confirm that Run 3.3 Mode 2 finalized the pair network.
  2. Read master_image from burst/batch_tops.config.
  3. Validate the real IW1/IW2/IW3 product suffix and master PRM/LED.
  4. Link the master PRM/LED into burst/topo.
  5. Run: dem2topo_ra.csh MASTER.PRM dem.grd 0
  6. Validate trans.dat and topo_ra.grd automatically.

Inputs:
  burst/run3.3_finalized.info
  burst/intf.in
  burst/batch_tops.config
  burst/raw/<master>.PRM
  burst/raw/<master>.LED
  burst/topo/dem.grd

Outputs:
  burst/topo/trans.dat
  burst/topo/topo_ra.grd
  burst/topo/dem2topo_ra.log

Recommended:
  ./run3.4_dem2topo_ra_burst.sh 1

For a long server run:
  nohup ./run3.4_dem2topo_ra_burst.sh 1 \
    > run3.4_dem2topo_ra.nohup.log 2>&1 &

Optional override:
  DEM2TOPO_SCRIPT=/path/dem2topo_ra.csh ./run3.4_dem2topo_ra_burst.sh 1
  BURST_TRANS_MIN_BYTES=524288 ./run3.4_dem2topo_ra_burst.sh 1
========================================
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
if (( $# == 0 )); then
    usage
    printf '[INFO] No processing was started.\n'
    exit 0
fi
[[ $# -eq 1 && "$1" == 1 ]] || die "use no arguments for help, or MODE=1 to run"

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "$ROOT_DIR")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT_DIR)"

UNIT_DIR="$ROOT_DIR/burst"
RAW_DIR="$UNIT_DIR/raw"
TOPO_DIR="$UNIT_DIR/topo"
CONFIG="$UNIT_DIR/batch_tops.config"
INTF_FILE="$UNIT_DIR/intf.in"
FINAL_INFO="$UNIT_DIR/run3.3_finalized.info"
SWATH_FILE="$UNIT_DIR/burst_swath.txt"
DEM="$TOPO_DIR/dem.grd"
LOG="$TOPO_DIR/dem2topo_ra.log"
TRANS_MIN_BYTES="${BURST_TRANS_MIN_BYTES:-1048576}"

[[ "$TRANS_MIN_BYTES" =~ ^[1-9][0-9]*$ ]] ||
    die "BURST_TRANS_MIN_BYTES must be a positive integer"

for command_name in awk grep gmt head sed tail tcsh wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

if [[ -n "${DEM2TOPO_SCRIPT:-}" ]]; then
    [[ -f "$DEM2TOPO_SCRIPT" ]] || die "DEM2TOPO_SCRIPT not found: $DEM2TOPO_SCRIPT"
    DEM2TOPO_PATH="$(cd -- "$(dirname -- "$DEM2TOPO_SCRIPT")" && pwd -P)/$(basename -- "$DEM2TOPO_SCRIPT")"
else
    DEM2TOPO_PATH="$(command -v dem2topo_ra.csh 2>/dev/null || true)"
    [[ -n "$DEM2TOPO_PATH" ]] || die "dem2topo_ra.csh was not found in PATH"
fi

[[ -d "$RAW_DIR" ]] || die "missing $RAW_DIR; complete Run 2.3 first"
[[ -d "$TOPO_DIR" ]] || die "missing $TOPO_DIR; complete Run 2.3 first"
[[ -s "$CONFIG" ]] || die "missing $CONFIG; complete Run 3.3 first"
[[ -s "$INTF_FILE" ]] || die "missing $INTF_FILE; complete Run 3.3 first"
[[ -s "$FINAL_INFO" ]] || die "missing $FINAL_INFO; complete Run 3.3 Mode 2 first"
[[ -s "$SWATH_FILE" ]] || die "missing $SWATH_FILE; complete Run 2.3 first"
[[ -e "$DEM" && -s "$DEM" ]] || die "DEM missing, broken or empty: $DEM"

FINAL_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_STATUS" == FINALIZED ]] || die "Run 3.3 status is not FINALIZED"
ACCEPTED_PAIRS="$(awk -F= '$1=="accepted_pair_count" {print $2; exit}' "$FINAL_INFO")"
[[ "$ACCEPTED_PAIRS" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid or missing accepted_pair_count in $FINAL_INFO"
CURRENT_PAIRS="$(awk 'NF && $0 !~ /^[[:space:]]*#/ {n++} END{print n+0}' "$INTF_FILE")"
[[ "$CURRENT_PAIRS" -eq "$ACCEPTED_PAIRS" ]] ||
    die "intf.in changed after Run 3.3 finalization: current=$CURRENT_PAIRS, accepted=$ACCEPTED_PAIRS"

SWATH="$(tr -d '[:space:]' < "$SWATH_FILE" | tr '[:lower:]' '[:upper:]')"
[[ "$SWATH" =~ ^IW([123])$ ]] || die "invalid subswath in $SWATH_FILE: $SWATH"
PRODUCT_SUFFIX="F${BASH_REMATCH[1]}"

MASTER_IMAGE="$(
    grep -E '^[[:space:]]*master_image[[:space:]]*=' "$CONFIG" |
        head -n 1 |
        awk -F= '{gsub(/[[:space:]]/, "", $2); print $2}'
)"
[[ "$MASTER_IMAGE" =~ ^S1_[0-9]{8}_ALL_${PRODUCT_SUFFIX}$ ]] ||
    die "invalid master_image for $SWATH: $MASTER_IMAGE"
FINAL_MASTER="$(awk -F= '$1=="master_image" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_MASTER" == "$MASTER_IMAGE" ]] ||
    die "master_image changed after Run 3.3 finalization: config=$MASTER_IMAGE final=$FINAL_MASTER"

MASTER_PRM="$RAW_DIR/${MASTER_IMAGE}.PRM"
MASTER_LED="$RAW_DIR/${MASTER_IMAGE}.LED"
[[ -s "$MASTER_PRM" ]] || die "master PRM missing or empty: $MASTER_PRM"
[[ -s "$MASTER_LED" ]] || die "master LED missing or empty: $MASTER_LED"

gmt grdinfo "$DEM" >/dev/null 2>&1 || die "GMT cannot read DEM grid: $DEM"

LOCK_DIR=""
if command -v flock >/dev/null 2>&1; then
    exec 9> "$ROOT_DIR/.run3.4_dem2topo_burst.lock"
    flock -n 9 || die "another burst Run 3.4 process is already running"
else
    LOCK_DIR="$ROOT_DIR/.run3.4_dem2topo_burst.lock.d"
    mkdir "$LOCK_DIR" 2>/dev/null || die "another burst Run 3.4 process may be running"
    trap 'rmdir -- "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

printf '%s\n' '========================================'
printf 'Run 3.4: burst DEM to radar coordinates\n'
printf 'Track root       : %s\n' "$ROOT_DIR"
printf 'Detected swath   : %s -> %s\n' "$SWATH" "$PRODUCT_SUFFIX"
printf 'Master image     : %s\n' "$MASTER_IMAGE"
printf 'Finalized pairs  : %s\n' "$ACCEPTED_PAIRS"
printf 'DEM input        : %s\n' "$DEM"
printf 'DEM2TOPO script  : %s\n' "$DEM2TOPO_PATH"
printf 'trans.dat minimum: %s bytes\n' "$TRANS_MIN_BYTES"
printf 'Output directory : %s\n' "$TOPO_DIR"
printf '[COMMAND] tcsh %q %q dem.grd 0\n' "$DEM2TOPO_PATH" "${MASTER_IMAGE}.PRM"
printf '%s\n' '========================================'

PRM_LINK="$TOPO_DIR/${MASTER_IMAGE}.PRM"
LED_LINK="$TOPO_DIR/${MASTER_IMAGE}.LED"
for destination in "$PRM_LINK" "$LED_LINK"; do
    if [[ -e "$destination" && ! -L "$destination" ]]; then
        die "refusing to replace regular file: $destination"
    fi
done
ln -sfn -- "../raw/${MASTER_IMAGE}.PRM" "$PRM_LINK"
ln -sfn -- "../raw/${MASTER_IMAGE}.LED" "$LED_LINK"
[[ -e "$PRM_LINK" && -e "$LED_LINK" ]] || die "failed to create master PRM/LED links"

rm -f -- \
    "$LOG" \
    "$TOPO_DIR/trans.dat" \
    "$TOPO_DIR/tmp_dem_ra.grd" \
    "$TOPO_DIR/topo_ra.grd"

printf '[RUN] dem2topo_ra.csh started; log=%s\n' "$LOG"
set +e
(
    cd -- "$TOPO_DIR"
    tcsh "$DEM2TOPO_PATH" "${MASTER_IMAGE}.PRM" dem.grd 0
) > "$LOG" 2>&1
COMMAND_STATUS=$?
set -e

if (( COMMAND_STATUS != 0 )); then
    printf '[FAIL] dem2topo_ra.csh exited with status %s\n' "$COMMAND_STATUS" >&2
    if [[ -s "$LOG" ]]; then
        printf '[FAIL] Last 40 log lines:\n' >&2
        tail -n 40 "$LOG" | sed 's/^/  /' >&2
    fi
    exit "$COMMAND_STATUS"
fi

TRANS="$TOPO_DIR/trans.dat"
TOPO_RA="$TOPO_DIR/topo_ra.grd"
[[ -s "$TRANS" ]] || die "trans.dat was not generated or is empty; inspect $LOG"
[[ -s "$TOPO_RA" ]] || die "topo_ra.grd was not generated or is empty; inspect $LOG"
TRANS_BYTES="$(wc -c < "$TRANS" | awk '{print $1}')"
TOPO_BYTES="$(wc -c < "$TOPO_RA" | awk '{print $1}')"
(( TRANS_BYTES >= TRANS_MIN_BYTES )) ||
    die "trans.dat is unexpectedly small: $TRANS_BYTES bytes (< $TRANS_MIN_BYTES); inspect $LOG"
gmt grdinfo "$TOPO_RA" >/dev/null 2>&1 || die "GMT cannot read generated grid: $TOPO_RA"

printf '%s\n' '========================================'
printf '[DONE] Run 3.4 completed successfully.\n'
printf 'trans.dat  : %s (%s bytes)\n' "$TRANS" "$TRANS_BYTES"
printf 'topo_ra.grd: %s (%s bytes)\n' "$TOPO_RA" "$TOPO_BYTES"
printf 'log        : %s\n' "$LOG"
printf '%s\n' '========================================'
