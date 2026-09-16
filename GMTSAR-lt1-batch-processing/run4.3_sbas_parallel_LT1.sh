#!/usr/bin/env bash
# Run 4.3: submit the prepared LT-1 sbas_parallel inversion with nohup.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

SBAS_DIR="sbas_detrend"
UNWRAP_NAME="unwrap_detrend_ref_pin.grd"
COMMAND_NAME="run_sbas_parallel.sh"
LOG_NAME="run4.3_sbas_parallel.log"
PID_NAME="run4.3_sbas_parallel.pid"
SUBMISSION_NAME="run4.3_submission.info"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Run 4.3: start the LT-1 SBAS inversion

Usage:
  ./run4.3_sbas_parallel_LT1.sh
  ./run4.3_sbas_parallel_LT1.sh 1

No arguments:
  Validate the Run 4.2 tables and command without starting SBAS.

Mode 1:
  Start sbas_detrend/run_sbas_parallel.sh with nohup in the background.
  Do not add another nohup or trailing &.

Monitor:
  tail -f sbas_detrend/run4.3_sbas_parallel.log

Check PID:
  ps -p $(cat sbas_detrend/run4.3_sbas_parallel.pid)

Expected main output after completion:
  sbas_detrend/vel.grd
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
(( $# <= 1 )) || die "use no arguments for checking, or mode 1"
[[ $# -eq 0 || "$1" == "1" ]] || die "MODE must be 1"
FORMAL=0
(( $# == 0 )) || FORMAL=1

for command_name in awk nohup sed wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done
command -v sbas_parallel >/dev/null 2>&1 ||
    die "sbas_parallel was not found in PATH"

ROOT="$(pwd -P)"
TRACK="$(basename -- "${ROOT}")"
[[ "${TRACK}" == "Ascending" || "${TRACK}" == "Descending" ]] ||
    die "run this script in an LT-1 Ascending or Descending directory"
[[ -d "${SBAS_DIR}" ]] || die "cannot find ${SBAS_DIR}/; complete Run 4.2 first"

for file in intf.tab scene.tab run4.2_complete "${COMMAND_NAME}"; do
    [[ -s "${SBAS_DIR}/${file}" ]] || die "missing or empty: ${SBAS_DIR}/${file}"
done
[[ -x "${SBAS_DIR}/${COMMAND_NAME}" ]] ||
    die "not executable: ${SBAS_DIR}/${COMMAND_NAME}"

EXPECTED_PAIRS="$(awk -F= '$1=="pairs"{print $2; exit}' "${SBAS_DIR}/run4.2_complete")"
EXPECTED_SCENES="$(awk -F= '$1=="scenes"{print $2; exit}' "${SBAS_DIR}/run4.2_complete")"
EXPECTED_UNWRAP="$(awk -F= '$1=="unwrap_name"{print $2; exit}' "${SBAS_DIR}/run4.2_complete")"
ACTUAL_PAIRS="$(wc -l < "${SBAS_DIR}/intf.tab" | awk '{print $1}')"
ACTUAL_SCENES="$(wc -l < "${SBAS_DIR}/scene.tab" | awk '{print $1}')"
[[ "${EXPECTED_PAIRS}" =~ ^[1-9][0-9]*$ ]] || die "invalid Run 4.2 pair count"
[[ "${EXPECTED_SCENES}" =~ ^[1-9][0-9]*$ ]] || die "invalid Run 4.2 scene count"
[[ "${EXPECTED_UNWRAP}" == "${UNWRAP_NAME}" ]] ||
    die "Run 4.2 used ${EXPECTED_UNWRAP:-an unknown unwrap input}; rerun Run 4.1 and Run 4.2 with ${UNWRAP_NAME}"
[[ "${ACTUAL_PAIRS}" == "${EXPECTED_PAIRS}" ]] ||
    die "intf.tab count differs from run4.2_complete"
[[ "${ACTUAL_SCENES}" == "${EXPECTED_SCENES}" ]] ||
    die "scene.tab count differs from run4.2_complete"

SBAS_COMMAND="$(awk '
    NF && $1!~/^#/ && $1!="set" && $1!="cd" {line=$0}
    END {print line}
' "${SBAS_DIR}/${COMMAND_NAME}")"
[[ "${SBAS_COMMAND}" == sbas_parallel[[:space:]]* ]] ||
    die "cannot find sbas_parallel command in ${SBAS_DIR}/${COMMAND_NAME}"

PID_FILE="${SBAS_DIR}/${PID_NAME}"
RUN_STATE="not running"
OLD_PID=""
if [[ -s "${PID_FILE}" ]]; then
    OLD_PID="$(tr -d '[:space:]' < "${PID_FILE}")"
    if [[ "${OLD_PID}" =~ ^[0-9]+$ ]] && kill -0 "${OLD_PID}" 2>/dev/null; then
        RUN_STATE="running (PID=${OLD_PID})"
    else
        RUN_STATE="stale PID file (PID=${OLD_PID:-unknown})"
    fi
fi

printf '%s\n' '========================================================================'
printf '%s\n' 'LT-1 Run 4.3 SBAS parallel inversion'
printf 'Mode:             %s\n' "$([[ "${FORMAL}" -eq 1 ]] && printf FORMAL || printf CHECK)"
printf 'Track:            %s\n' "${TRACK}"
printf 'SBAS directory:   %s/\n' "${SBAS_DIR}"
printf 'Interferograms:   %s\n' "${ACTUAL_PAIRS}"
printf 'Scenes:           %s\n' "${ACTUAL_SCENES}"
printf 'Phase input:      %s\n' "${UNWRAP_NAME}"
printf 'Command:          %s\n' "${SBAS_COMMAND}"
printf 'Current state:    %s\n' "${RUN_STATE}"
printf 'Log:              %s/%s\n' "${SBAS_DIR}" "${LOG_NAME}"
printf '%s\n' '========================================================================'

if (( FORMAL == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] sbas_parallel was not started.'
    exit 0
fi
[[ "${RUN_STATE}" != running* ]] || die "Run 4.3 is already active: ${RUN_STATE}"

cd "${SBAS_DIR}"
rm -f -- "${LOG_NAME}" "${PID_NAME}" "${SUBMISSION_NAME}"
nohup "./${COMMAND_NAME}" > "${LOG_NAME}" 2>&1 &
PID=$!
printf '%s\n' "${PID}" > "${PID_NAME}"

{
    printf 'submitted=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\npid=%s\n' "${TRACK}" "${PID}"
    printf 'pairs=%s\nscenes=%s\n' "${ACTUAL_PAIRS}" "${ACTUAL_SCENES}"
    printf 'unwrap_name=%s\n' "${UNWRAP_NAME}"
    printf 'log=%s/%s/%s\n' "${ROOT}" "${SBAS_DIR}" "${LOG_NAME}"
    printf 'command=%s\n' "${SBAS_COMMAND}"
} > "${SUBMISSION_NAME}"

sleep 1
if ! kill -0 "${PID}" 2>/dev/null; then
    printf '%s\n' '[ERROR] sbas_parallel exited immediately. Initial log:' >&2
    sed -n '1,100p' "${LOG_NAME}" >&2 || true
    exit 1
fi

printf '%s\n' '========================================================================'
printf '[STARTED] PID: %s\n' "${PID}"
printf '[LOG] %s/%s/%s\n' "${ROOT}" "${SBAS_DIR}" "${LOG_NAME}"
printf '[MONITOR] tail -f %s/%s\n' "${SBAS_DIR}" "${LOG_NAME}"
printf '[INFO] The process is already running under nohup.\n'
printf '%s\n' '========================================================================'
