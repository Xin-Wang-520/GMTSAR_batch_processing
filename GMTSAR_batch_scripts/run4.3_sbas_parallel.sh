#!/usr/bin/env bash
# Run 4.3: submit the generated sbas_parallel command with nohup.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 12, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

SBAS_DIR="sbas_demcorr_pin"
INTERNAL_SCRIPT="run_sbas_parallel.sh"
LOG_NAME="run4.3_sbas_parallel.log"
PID_NAME="run4.3_sbas_parallel.pid"
SUBMISSION_NAME="run4.3_submission.info"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 4.3: submit the prepared sbas_parallel inversion

Check only (SBAS is NOT started):
  ./run4.3_sbas_parallel.sh

Formal background submission:
  ./run4.3_sbas_parallel.sh 1

Run 4.3 internally executes:
  cd sbas_demcorr_pin
  nohup ./run_sbas_parallel.sh > run4.3_sbas_parallel.log 2>&1 &

Do not add another nohup or trailing & when invoking Run 4.3.

Monitor:
  tail -f sbas_demcorr_pin/run4.3_sbas_parallel.log

Check PID:
  ps -p $(cat sbas_demcorr_pin/run4.3_sbas_parallel.pid)
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
(( $# <= 1 )) || die "expected no arguments, or mode 1"
[[ $# -eq 0 || "$1" == "1" ]] || die "MODE must be 1"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] || die "run this script in a T-number track directory (current: $ROOT)"
[[ -d "$SBAS_DIR" ]] || die "cannot find $SBAS_DIR/; complete Run 4.2 first"

for file in intf.tab scene.tab run4.2_complete "$INTERNAL_SCRIPT"; do
    [[ -s "$SBAS_DIR/$file" ]] || die "missing or empty: $SBAS_DIR/$file"
done
[[ -x "$SBAS_DIR/$INTERNAL_SCRIPT" ]] ||
    die "not executable: $SBAS_DIR/$INTERNAL_SCRIPT"
command -v nohup >/dev/null 2>&1 || die "nohup not found"

EXPECTED_PAIRS="$(awk -F= '$1=="pairs"{print $2; exit}' "$SBAS_DIR/run4.2_complete")"
EXPECTED_SCENES="$(awk -F= '$1=="scenes"{print $2; exit}' "$SBAS_DIR/run4.2_complete")"
ACTUAL_PAIRS="$(wc -l < "$SBAS_DIR/intf.tab" | tr -d ' ')"
ACTUAL_SCENES="$(wc -l < "$SBAS_DIR/scene.tab" | tr -d ' ')"
[[ "$EXPECTED_PAIRS" =~ ^[1-9][0-9]*$ ]] || die "invalid pairs value in run4.2_complete"
[[ "$EXPECTED_SCENES" =~ ^[1-9][0-9]*$ ]] || die "invalid scenes value in run4.2_complete"
[[ "$ACTUAL_PAIRS" == "$EXPECTED_PAIRS" ]] ||
    die "intf.tab lines ($ACTUAL_PAIRS) differ from Run 4.2 pairs ($EXPECTED_PAIRS)"
[[ "$ACTUAL_SCENES" == "$EXPECTED_SCENES" ]] ||
    die "scene.tab lines ($ACTUAL_SCENES) differ from Run 4.2 scenes ($EXPECTED_SCENES)"

SBAS_COMMAND="$(awk 'NF && $1 !~ /^#/ && $1 != "set" && $1 != "cd" {line=$0} END{print line}' "$SBAS_DIR/$INTERNAL_SCRIPT")"
[[ "$SBAS_COMMAND" == sbas_parallel[[:space:]]* ]] ||
    die "cannot find sbas_parallel command in $SBAS_DIR/$INTERNAL_SCRIPT"

PID_FILE="$SBAS_DIR/$PID_NAME"
RUN_STATE="not running"
OLD_PID=""
if [[ -s "$PID_FILE" ]]; then
    OLD_PID="$(tr -d '[:space:]' < "$PID_FILE")"
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        RUN_STATE="running (PID=$OLD_PID)"
    else
        RUN_STATE="stale PID file (PID=${OLD_PID:-unknown})"
    fi
fi

echo "========================================"
echo "Run 4.3 input check"
echo "Track root       : $ROOT"
echo "SBAS directory   : $SBAS_DIR"
echo "Interferograms   : $ACTUAL_PAIRS"
echo "Scenes           : $ACTUAL_SCENES"
echo "Internal command : $SBAS_DIR/$INTERNAL_SCRIPT"
echo "Prepared command : $SBAS_COMMAND"
echo "Current state    : $RUN_STATE"
echo "Log              : $SBAS_DIR/$LOG_NAME"
echo "========================================"

if (( $# == 0 )); then
    usage
    echo "[CHECK ONLY] sbas_parallel was not started."
    exit 0
fi

if [[ "$RUN_STATE" == running* ]]; then
    die "Run 4.3 is already active: $RUN_STATE"
fi

cd "$SBAS_DIR"
STAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_DIR="run4.3_backup_$STAMP"
backup_count=0
for name in "$LOG_NAME" "$PID_NAME" "$SUBMISSION_NAME"; do
    if [[ -e "$name" ]]; then
        mkdir -p "$BACKUP_DIR"
        mv "$name" "$BACKUP_DIR/"
        ((backup_count+=1))
    fi
done
(( backup_count > 0 )) && echo "[BACKUP] Previous Run 4.3 control files: $(pwd -P)/$BACKUP_DIR"

nohup "./$INTERNAL_SCRIPT" > "$LOG_NAME" 2>&1 &
PID=$!
printf '%s\n' "$PID" > "$PID_NAME"

{
    printf 'submitted=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'pid=%s\n' "$PID"
    printf 'pairs=%s\n' "$ACTUAL_PAIRS"
    printf 'scenes=%s\n' "$ACTUAL_SCENES"
    printf 'log=%s/%s/%s\n' "$ROOT" "$SBAS_DIR" "$LOG_NAME"
    printf 'command=%s\n' "$SBAS_COMMAND"
} > "$SUBMISSION_NAME"

sleep 1
if ! kill -0 "$PID" 2>/dev/null; then
    echo "[ERROR] sbas_parallel exited immediately. Log:" >&2
    sed -n '1,80p' "$LOG_NAME" >&2 || true
    exit 1
fi

echo "========================================"
echo "[STARTED] Run 4.3 SBAS inversion"
echo "PID : $PID"
echo "Log : $(pwd -P)/$LOG_NAME"
echo "PID file: $(pwd -P)/$PID_NAME"
echo "Monitor from the track root:"
echo "  tail -f $SBAS_DIR/$LOG_NAME"
echo "[INFO] The job is running under nohup; no additional & is required."
echo "========================================"
