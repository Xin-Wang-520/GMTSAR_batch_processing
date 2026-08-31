#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 21, 2026

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
用法：
  ./run2.1_prepare_SAFE_orbits.sh [选项]       # 只检查和预览
  ./run2.1_prepare_SAFE_orbits.sh 1 [选项]     # 正式生成清单并下载轨道

在 InSAR_processing/Descending/T*/ 中运行：创建 organized/、生成
SAFE_filelist，并调用 download_sentinel_orbits_linux_new.csh 下载轨道文件。

选项：
  --mode 1|2           1=POEORB 精密轨道（默认），2=RESORB 快速轨道
  --source-safe DIR    清理后 SAFE 来源目录
  --organized-dir DIR  输出目录（默认：organized）
  --downloader FILE    轨道下载 csh 脚本或 PATH 中的命令
  -h, --help           显示帮助
EOF
}

RUN_FORMAL=0
ORBIT_MODE=1
SOURCE_SAFE=""
ORGANIZED_DIR="organized"
DOWNLOADER="download_sentinel_orbits_linux_new.csh"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        1)
            (( RUN_FORMAL == 0 )) || die "formal mode 1 was specified more than once"
            RUN_FORMAL=1
            shift
            ;;
        --mode)
            [[ "$#" -ge 2 ]] || die "--mode requires 1 or 2"
            ORBIT_MODE="$2"
            shift 2
            ;;
        --source-safe)
            [[ "$#" -ge 2 ]] || die "--source-safe requires a directory"
            SOURCE_SAFE="$2"
            shift 2
            ;;
        --organized-dir)
            [[ "$#" -ge 2 ]] || die "--organized-dir requires a directory"
            ORGANIZED_DIR="$2"
            shift 2
            ;;
        --downloader)
            [[ "$#" -ge 2 ]] || die "--downloader requires a file or command"
            DOWNLOADER="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ "${ORBIT_MODE}" == "1" || "${ORBIT_MODE}" == "2" ]] || die "--mode must be 1 or 2"

for command_name in find sort awk grep sed wget unzip date wc tee; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "cannot find command: ${command_name}"
done

WORK_DIR="$(pwd -P)"
TRACK="$(basename -- "${WORK_DIR}")"
DIRECTION="$(basename -- "$(dirname -- "${WORK_DIR}")")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number directory (current: ${WORK_DIR})"

if [[ -z "${SOURCE_SAFE}" ]]; then
    SOURCE_SAFE="/data2/xinw/HMF_Sentinel1_data/${DIRECTION}/${TRACK}/${TRACK}_SAFE"
fi

[[ -d "${SOURCE_SAFE}" ]] || die "SAFE source directory not found: ${SOURCE_SAFE}"

if [[ -x "${DOWNLOADER}" ]]; then
    DOWNLOADER_PATH="$(cd -- "$(dirname -- "${DOWNLOADER}")" && pwd -P)/$(basename -- "${DOWNLOADER}")"
elif DOWNLOADER_PATH="$(command -v "${DOWNLOADER}" 2>/dev/null)"; then
    :
else
    die "orbit downloader not found or not executable: ${DOWNLOADER}"
fi

if [[ "${ORGANIZED_DIR}" = /* ]]; then
    ORGANIZED_ABS="${ORGANIZED_DIR}"
else
    ORGANIZED_ABS="${WORK_DIR}/${ORGANIZED_DIR}"
fi
SAFE_LIST="${ORGANIZED_ABS}/SAFE_filelist"
ORBIT_LOG="${ORGANIZED_ABS}/run2.1_orbit_download.log"
SUMMARY_LOG="${WORK_DIR}/run2.1_prepare_SAFE_orbits.log"

SAFE_TOTAL="$(find "${SOURCE_SAFE}" -mindepth 1 -maxdepth 1 -type d \
    -name '*.SAFE' -print | wc -l | awk '{print $1}')"
(( SAFE_TOTAL > 0 )) || die "no *.SAFE directories found in ${SOURCE_SAFE}"

EXISTING_EOF=0
EXISTING_LIST="no"
if [[ -d "${ORGANIZED_ABS}" ]]; then
    EXISTING_EOF="$(find "${ORGANIZED_ABS}" -maxdepth 1 -type f \
        -name '*.EOF' -print | wc -l | awk '{print $1}')"
    [[ -s "${SAFE_LIST}" ]] && EXISTING_LIST="yes ($(wc -l < "${SAFE_LIST}" | awk '{print $1}') lines)"
fi

printf '%s\n' '========================================'
printf 'Run 2.1: prepare SAFE list and Sentinel-1 orbits\n'
printf 'Run mode       : %s\n' "$([[ ${RUN_FORMAL} -eq 1 ]] && printf FORMAL || printf 'PREVIEW ONLY')"
printf 'Work directory : %s\n' "${WORK_DIR}"
printf 'Track          : %s\n' "${TRACK}"
printf 'Direction      : %s\n' "${DIRECTION}"
printf 'SAFE source    : %s\n' "${SOURCE_SAFE}"
printf 'SAFE total     : %d\n' "${SAFE_TOTAL}"
printf 'Organized dir  : %s\n' "${ORGANIZED_ABS}"
printf 'SAFE list      : %s\n' "${SAFE_LIST}"
printf 'Existing list  : %s\n' "${EXISTING_LIST}"
printf 'Existing EOF   : %d\n' "${EXISTING_EOF}"
printf 'Orbit mode     : %s (%s)\n' "${ORBIT_MODE}" \
    "$([[ ${ORBIT_MODE} == 1 ]] && printf POEORB || printf RESORB)"
printf 'Downloader     : %s\n' "${DOWNLOADER_PATH}"
printf '%s\n' '========================================'

if (( RUN_FORMAL == 0 )); then
    usage
    printf '[CHECK ONLY] No directory, SAFE list, log, lock or orbit file was created or modified.\n'
    printf '[NEXT] Formal run with the default POEORB mode:\n'
    printf '  ./run2.1_prepare_SAFE_orbits.sh 1\n'
    printf '[OPTION] Formal RESORB run:\n'
    printf '  ./run2.1_prepare_SAFE_orbits.sh 1 --mode 2\n'
    exit 0
fi

mkdir -p -- "${ORGANIZED_ABS}"
ORGANIZED_ABS="$(cd -- "${ORGANIZED_ABS}" && pwd -P)"
SAFE_LIST="${ORGANIZED_ABS}/SAFE_filelist"
ORBIT_LOG="${ORGANIZED_ABS}/run2.1_orbit_download.log"

LOCK_DIR=""
if command -v flock >/dev/null 2>&1; then
    exec 9> .run2.1_prepare_SAFE_orbits.lock
    flock -n 9 || die "another Run 2.1 process is already running"
else
    LOCK_DIR=".run2.1_prepare_SAFE_orbits.lock.d"
    mkdir "${LOCK_DIR}" 2>/dev/null ||
        die "another Run 2.1 process may be running (or remove stale ${LOCK_DIR})"
    trap 'rmdir -- "${LOCK_DIR}" 2>/dev/null || true' EXIT
fi

SAFE_LIST_TMP="${SAFE_LIST}.tmp.$$"
find "${SOURCE_SAFE}" -mindepth 1 -maxdepth 1 -type d -name '*.SAFE' -print |
    sort > "${SAFE_LIST_TMP}"
FORMAL_SAFE_TOTAL="$(wc -l < "${SAFE_LIST_TMP}" | awk '{print $1}')"
if (( FORMAL_SAFE_TOTAL == 0 )); then
    rm -f -- "${SAFE_LIST_TMP}"
    die "no *.SAFE directories found in ${SOURCE_SAFE}"
fi
(( FORMAL_SAFE_TOTAL == SAFE_TOTAL )) || {
    rm -f -- "${SAFE_LIST_TMP}"
    die "SAFE source changed during validation (${SAFE_TOTAL} -> ${FORMAL_SAFE_TOTAL}); rerun Run 2.1"
}
mv -f -- "${SAFE_LIST_TMP}" "${SAFE_LIST}"

{
    printf '%s\n' '========================================'
    printf 'Run 2.1: prepare SAFE list and Sentinel-1 orbits\n'
    printf 'Work directory : %s\n' "${WORK_DIR}"
    printf 'Track          : %s\n' "${TRACK}"
    printf 'Direction      : %s\n' "${DIRECTION}"
    printf 'SAFE source    : %s\n' "${SOURCE_SAFE}"
    printf 'SAFE list      : %s\n' "${SAFE_LIST}"
    printf 'SAFE total     : %d\n' "${SAFE_TOTAL}"
    printf 'Orbit mode     : %s\n' "${ORBIT_MODE}"
    printf 'Downloader     : %s\n' "${DOWNLOADER_PATH}"
    printf 'Start time     : %s\n' "$(date '+%F %T')"
    printf '%s\n' '========================================'
} | tee "${SUMMARY_LOG}"

set +e
(
    cd -- "${ORGANIZED_ABS}"
    "${DOWNLOADER_PATH}" "$(basename -- "${SAFE_LIST}")" "${ORBIT_MODE}"
) > "${ORBIT_LOG}" 2>&1
DOWNLOAD_STATUS=$?
set -e

cat "${ORBIT_LOG}"
ERROR_COUNT="$(grep -c '\[ERROR\]' "${ORBIT_LOG}" || true)"
EOF_TOTAL="$(find "${ORGANIZED_ABS}" -maxdepth 1 -type f -name '*.EOF' -print | wc -l | awk '{print $1}')"

{
    printf '%s\n' '========================================'
    printf 'Run 2.1 final validation\n'
    printf 'Downloader status : %d\n' "${DOWNLOAD_STATUS}"
    printf 'Logged errors     : %d\n' "${ERROR_COUNT}"
    printf 'EOF files         : %d\n' "${EOF_TOTAL}"
    printf 'Orbit log         : %s\n' "${ORBIT_LOG}"
    printf 'Finish time       : %s\n' "$(date '+%F %T')"
    printf '%s\n' '========================================'
} | tee -a "${SUMMARY_LOG}"

(( DOWNLOAD_STATUS == 0 )) || die "orbit downloader exited with ${DOWNLOAD_STATUS}"
(( ERROR_COUNT == 0 )) || die "${ERROR_COUNT} orbit errors found; see ${ORBIT_LOG}"
(( EOF_TOTAL > 0 )) || die "no .EOF orbit files found in ${ORGANIZED_ABS}"

printf '[OK] Run 2.1 completed successfully\n' | tee -a "${SUMMARY_LOG}"
