#!/usr/bin/env bash
# Run 4.3: submit the prepared burst SBAS inversion through nohup.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

SBAS_DIR_NAME='sbas_burst'
INTERNAL_SCRIPT='run_sbas_parallel.sh'
LOG_NAME='run4.3_sbas_parallel.log'
PID_NAME='run4.3_sbas_parallel.pid'
SUBMISSION_NAME='run4.3_submission.info'

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 4.3: submit the prepared burst SBAS inversion

Usage:
  ./run4.3_sbas_parallel_burst.sh
  ./run4.3_sbas_parallel_burst.sh 1

No arguments:
  Check Run 4.2 products, table counts, command and current PID state.
  SBAS is not started.

Mode 1:
  Start sbas_burst/run_sbas_parallel.sh through nohup.
  Do not add nohup or a trailing & yourself.

Monitor:
  tail -f sbas_burst/run4.3_sbas_parallel.log

Check PID:
  ps -fp $(cat sbas_burst/run4.3_sbas_parallel.pid)

Run 4.3 does not modify burst/intf_all grids.
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

for command_name in awk basename date grep mkdir mv nohup ps sed sleep tr wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done
command -v sbas_parallel >/dev/null 2>&1 ||
    die "sbas_parallel not found in PATH"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT)"

SBAS_DIR="$ROOT/$SBAS_DIR_NAME"
RUN42_COMPLETE="$SBAS_DIR/run4.2_complete"
INTF_TAB="$SBAS_DIR/intf.tab"
SCENE_TAB="$SBAS_DIR/scene.tab"
COMMAND_SCRIPT="$SBAS_DIR/$INTERNAL_SCRIPT"

[[ -d "$SBAS_DIR" ]] || die "missing $SBAS_DIR; complete Run 4.2 first"
for file in "$RUN42_COMPLETE" "$INTF_TAB" "$SCENE_TAB" "$COMMAND_SCRIPT" \
            "$SBAS_DIR/supermaster.PRM" "$SBAS_DIR/supermaster.LED"; do
    [[ -s "$file" ]] || die "missing or empty: $file"
done
[[ -x "$COMMAND_SCRIPT" ]] || die "not executable: $COMMAND_SCRIPT"

RUN42_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$RUN42_COMPLETE")"
EXPECTED_PAIRS="$(awk -F= '$1=="pairs" {print $2; exit}' "$RUN42_COMPLETE")"
EXPECTED_SCENES="$(awk -F= '$1=="scenes" {print $2; exit}' "$RUN42_COMPLETE")"
ACTUAL_PAIRS="$(wc -l < "$INTF_TAB" | tr -d ' ')"
ACTUAL_SCENES="$(wc -l < "$SCENE_TAB" | tr -d ' ')"
[[ "$RUN42_STATUS" == COMPLETE ]] || die "Run 4.2 status is not COMPLETE"
[[ "$EXPECTED_PAIRS" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid pairs value in run4.2_complete"
[[ "$EXPECTED_SCENES" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid scenes value in run4.2_complete"
[[ "$ACTUAL_PAIRS" -eq "$EXPECTED_PAIRS" ]] ||
    die "intf.tab=$ACTUAL_PAIRS but Run 4.2 pairs=$EXPECTED_PAIRS"
[[ "$ACTUAL_SCENES" -eq "$EXPECTED_SCENES" ]] ||
    die "scene.tab=$ACTUAL_SCENES but Run 4.2 scenes=$EXPECTED_SCENES"

SBAS_COMMAND="$(awk '
    NF && $1 !~ /^#/ && $1 != "set" && $1 != "cd" {line=$0}
    END {print line}
' "$COMMAND_SCRIPT")"
[[ "$SBAS_COMMAND" == sbas_parallel[[:space:]]* ]] ||
    die "cannot find the sbas_parallel command in $COMMAND_SCRIPT"
RECORDED_COMMAND="$(awk -F= '$1=="command" {sub(/^command=/, ""); print; exit}' \
    "$RUN42_COMPLETE")"
[[ "$RECORDED_COMMAND" == "$SBAS_COMMAND" ]] ||
    die "run_sbas_parallel.sh command differs from run4.2_complete"

PID_FILE="$SBAS_DIR/$PID_NAME"
RUN_STATE='not running'
OLD_PID=''
if [[ -s "$PID_FILE" ]]; then
    OLD_PID="$(tr -d '[:space:]' < "$PID_FILE")"
    if [[ "$OLD_PID" =~ ^[1-9][0-9]*$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        OLD_COMMAND="$(ps -p "$OLD_PID" -o args= 2>/dev/null || true)"
        if [[ "$OLD_COMMAND" == *run_sbas_parallel* || "$OLD_COMMAND" == *sbas_parallel* ]]; then
            RUN_STATE="running (PID=$OLD_PID)"
        else
            RUN_STATE="PID reused by another process (PID=$OLD_PID)"
        fi
    else
        RUN_STATE="stale PID file (PID=${OLD_PID:-unknown})"
    fi
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 4.3 burst SBAS submission check'
printf 'Track root       : %s\n' "$ROOT"
printf 'SBAS directory   : %s\n' "$SBAS_DIR"
printf 'Interferograms   : %s\n' "$ACTUAL_PAIRS"
printf 'Scenes           : %s\n' "$ACTUAL_SCENES"
printf 'Internal command : %s\n' "$COMMAND_SCRIPT"
printf 'Prepared command : %s\n' "$SBAS_COMMAND"
printf 'Current state    : %s\n' "$RUN_STATE"
printf 'Log              : %s/%s\n' "$SBAS_DIR" "$LOG_NAME"
printf '%s\n' '========================================'

if (( $# == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] sbas_parallel was not started.'
    printf '%s\n' '[NEXT] ./run4.3_sbas_parallel_burst.sh 1'
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
        mv -- "$name" "$BACKUP_DIR/"
        backup_count=$((backup_count + 1))
    fi
done
(( backup_count == 0 )) ||
    printf '[BACKUP] Previous Run 4.3 control files: %s/%s\n' "$(pwd -P)" "$BACKUP_DIR"

nohup "./$INTERNAL_SCRIPT" > "$LOG_NAME" 2>&1 < /dev/null &
PID=$!
printf '%s\n' "$PID" > "$PID_NAME"

{
    printf 'status=SUBMITTED\n'
    printf 'submitted=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'pid=%s\n' "$PID"
    printf 'pairs=%s\n' "$ACTUAL_PAIRS"
    printf 'scenes=%s\n' "$ACTUAL_SCENES"
    printf 'log=%s/%s\n' "$(pwd -P)" "$LOG_NAME"
    printf 'command=%s\n' "$SBAS_COMMAND"
} > "$SUBMISSION_NAME"

sleep 1
if ! kill -0 "$PID" 2>/dev/null; then
    printf '%s\n' '[ERROR] sbas_parallel exited immediately. First log lines:' >&2
    sed -n '1,80p' "$LOG_NAME" >&2 || true
    exit 1
fi

printf '%s\n' '========================================'
printf '%s\n' '[STARTED] Run 4.3 burst SBAS inversion'
printf 'PID             : %s\n' "$PID"
printf 'Log             : %s/%s\n' "$(pwd -P)" "$LOG_NAME"
printf 'PID file        : %s/%s\n' "$(pwd -P)" "$PID_NAME"
printf '%s\n' 'The job is running under nohup; the terminal may be closed.'
printf 'Monitor: tail -f %s/%s\n' "$SBAS_DIR_NAME" "$LOG_NAME"
printf '%s\n' '========================================'
