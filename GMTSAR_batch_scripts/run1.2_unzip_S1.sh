#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 21, 2026

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

MARKER_NAME=".run1.2_unzip_complete"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

file_size() {
    local size
    if size="$(stat -c '%s' "$1" 2>/dev/null)"; then
        :
    else
        size="$(stat -f '%z' "$1" 2>/dev/null)" || return 1
    fi
    [[ "${size}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${size}"
}

safe_name_from_zip() {
    local name stem
    name="$(basename -- "$1")"
    stem="${name%.zip}"
    if [[ "${stem}" == *.SAFE ]]; then
        printf '%s\n' "${stem}"
    else
        printf '%s.SAFE\n' "${stem}"
    fi
}

safe_is_valid() {
    local safe_path="$1"
    [[ -d "${safe_path}" ]] || return 1
    [[ -s "${safe_path}/manifest.safe" ]] || return 1
    [[ -d "${safe_path}/annotation" ]] || return 1
    [[ -d "${safe_path}/measurement" ]] || return 1
    find "${safe_path}/measurement" -maxdepth 1 -type f \
        \( -iname '*.tif' -o -iname '*.tiff' \) -size +0c -print -quit |
        grep -q . || return 1
    find "${safe_path}/annotation" -maxdepth 1 -type f \
        -iname '*.xml' -size +0c -print -quit |
        grep -q . || return 1
}

zip_has_completed_safe() {
    local safe_dir="$1" zip_path="$2" safe_name safe_path marker
    safe_name="$(safe_name_from_zip "${zip_path}")"
    safe_path="${safe_dir}/${safe_name}"
    marker="${safe_path}/${MARKER_NAME}"
    safe_is_valid "${safe_path}" &&
        [[ -s "${marker}" ]] &&
        grep -Fqx "source_zip=$(basename -- "${zip_path}")" "${marker}" &&
        grep -Fqx "source_size=$(file_size "${zip_path}")" "${marker}"
}

write_marker() {
    local safe_path="$1" zip_path="$2" marker_tmp
    marker_tmp="${safe_path}/${MARKER_NAME}.tmp.$$"
    {
        printf 'source_zip=%s\n' "$(basename -- "${zip_path}")"
        printf 'source_size=%s\n' "$(file_size "${zip_path}")"
        printf 'completed_at=%s\n' "$(date '+%F %T %z')"
    } > "${marker_tmp}"
    mv -f -- "${marker_tmp}" "${safe_path}/${MARKER_NAME}"
}

run_worker() {
    local safe_dir="$1" temp_root="$2" zip_path="$3"
    local safe_name final_safe job_tmp extracted_safe backup

    safe_name="$(safe_name_from_zip "${zip_path}")"
    final_safe="${safe_dir}/${safe_name}"

    if zip_has_completed_safe "${safe_dir}" "${zip_path}"; then
        printf '[SKIP] %s already completed\n' "${safe_name}"
        return 0
    fi

    job_tmp="${temp_root}/${safe_name}.$$"
    rm -rf -- "${job_tmp}"
    mkdir -p -- "${job_tmp}"

    printf '[START] %s\n' "${zip_path}"
    if ! unzip -q -- "${zip_path}" -d "${job_tmp}"; then
        printf '[FAILED] unzip failed: %s\n' "${zip_path}" >&2
        rm -rf -- "${job_tmp}"
        return 1
    fi

    extracted_safe="${job_tmp}/${safe_name}"
    if ! safe_is_valid "${extracted_safe}"; then
        printf '[FAILED] invalid or unexpected SAFE in %s\n' "${zip_path}" >&2
        rm -rf -- "${job_tmp}"
        return 1
    fi

    if [[ -e "${final_safe}" ]]; then
        backup="${final_safe}.incomplete.$(date '+%Y%m%dT%H%M%S').$$"
        printf '[WARNING] move old/unmarked SAFE to %s\n' "${backup}"
        mv -- "${final_safe}" "${backup}"
    fi

    mv -- "${extracted_safe}" "${final_safe}"
    write_marker "${final_safe}" "${zip_path}"
    rmdir -- "${job_tmp}" 2>/dev/null || true
    printf '[DONE] %s\n' "${zip_path}"
}

if [[ "${1:-}" == "--worker" ]]; then
    [[ "$#" -eq 4 ]] || die "invalid internal worker arguments"
    run_worker "$2" "$3" "$4"
    exit $?
fi

usage() {
    cat <<'EOF'
用法：./run1.2_unzip_S1.sh [1] [选项]

运行模式：
  无参数           只读预览；检查 ZIP、SAFE 完成状态和待解压数量
  1                正式并行解压

选项：
  --jobs N          并行解压任务数（默认：10）
  --interval N      进度记录间隔秒数（默认：30）
  --min-size-mb N   ZIP 最小合理大小 MB（默认：100）
  -h, --help        显示帮助

脚本必须在 T34、T56、T158 这类轨道目录中运行。
EOF
}

MODE="PREVIEW"
if [[ "${1:-}" == "1" ]]; then
    MODE="FORMAL"
    shift
elif [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    die "mode must be 1 (or omit it for preview)"
fi

JOBS=10
INTERVAL=30
MIN_ZIP_SIZE_MB=100

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --jobs)
            [[ "$#" -ge 2 ]] || die "--jobs requires a value"
            JOBS="$2"
            shift 2
            ;;
        --interval)
            [[ "$#" -ge 2 ]] || die "--interval requires a value"
            INTERVAL="$2"
            shift 2
            ;;
        --min-size-mb)
            [[ "$#" -ge 2 ]] || die "--min-size-mb requires a value"
            MIN_ZIP_SIZE_MB="$2"
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

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
[[ "${INTERVAL}" =~ ^[1-9][0-9]*$ ]] || die "--interval must be a positive integer"
[[ "${MIN_ZIP_SIZE_MB}" =~ ^[0-9]+$ ]] || die "--min-size-mb must be a non-negative integer"

for command_name in unzip parallel od stat find sort grep; do
    command -v "${command_name}" >/dev/null 2>&1 || die "cannot find command: ${command_name}"
done

WORK_DIR="$(pwd -P)"
TRACK="$(basename -- "${WORK_DIR}")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "current directory must be named T plus digits (current: ${TRACK})"

ZIP_DIR="zip"
SAFE_DIR="${TRACK}_SAFE"
TEMP_ROOT=".run1.2_unzip_tmp"
UNZIP_LOG="run1.2_unzip_S1.log"
PROGRESS_LOG="run1.2_unzip_S1_progress.log"
PARALLEL_LOG="run1.2_unzip_S1_parallel_joblog.txt"
FAILED_ZIP_FILE="failed_zip.txt"
MIN_ZIP_SIZE_BYTES=$((MIN_ZIP_SIZE_MB * 1024 * 1024))
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

[[ -d "${ZIP_DIR}" ]] || die "cannot find ZIP directory: ${ZIP_DIR}/"

mapfile -d '' ZIP_FILES < <(
    find "${ZIP_DIR}" -maxdepth 1 -type f -name '*.zip' -print0 | sort -z
)
ZIP_TOTAL=${#ZIP_FILES[@]}
(( ZIP_TOTAL > 0 )) || die "no *.zip files found in ${ZIP_DIR}/"

declare -A SAFE_NAMES=()
for zip_path in "${ZIP_FILES[@]}"; do
    safe_name="$(safe_name_from_zip "${zip_path}")"
    [[ -z "${SAFE_NAMES[${safe_name}]+x}" ]] ||
        die "multiple ZIP files map to the same SAFE: ${safe_name}"
    SAFE_NAMES["${safe_name}"]=1
done

if [[ "${MODE}" == "PREVIEW" ]]; then
    PREVIEW_BAD=0
    PREVIEW_COMPLETE=0
    PREVIEW_PENDING=0
    declare -a PREVIEW_BAD_FILES=()

    for zip_path in "${ZIP_FILES[@]}"; do
        size_bytes="$(file_size "${zip_path}" 2>/dev/null || printf '0')"
        signature="$(od -An -tx1 -N4 "${zip_path}" 2>/dev/null | tr -d ' \n')"
        if (( size_bytes < MIN_ZIP_SIZE_BYTES )) || [[ "${signature}" != "504b0304" ]]; then
            PREVIEW_BAD=$((PREVIEW_BAD + 1))
            PREVIEW_BAD_FILES+=("$(basename -- "${zip_path}")")
        elif zip_has_completed_safe "${SAFE_DIR}" "${zip_path}"; then
            PREVIEW_COMPLETE=$((PREVIEW_COMPLETE + 1))
        else
            PREVIEW_PENDING=$((PREVIEW_PENDING + 1))
        fi
    done

    printf '%s\n' '========================================'
    printf 'Run 1.2: Sentinel-1 unzip preview\n'
    printf 'Mode            : PREVIEW (no files are created or modified)\n'
    printf 'Work directory  : %s\n' "${WORK_DIR}"
    printf 'Track           : %s\n' "${TRACK}"
    printf 'ZIP total       : %d\n' "${ZIP_TOTAL}"
    printf 'Fast-check bad  : %d\n' "${PREVIEW_BAD}"
    printf 'Completed SAFE  : %d\n' "${PREVIEW_COMPLETE}"
    printf 'Pending unzip   : %d\n' "${PREVIEW_PENDING}"
    printf 'Formal jobs     : %d\n' "${JOBS}"
    printf 'SAFE directory  : %s/\n' "${SAFE_DIR}"
    printf '%s\n' '========================================'

    if (( PREVIEW_BAD > 0 )); then
        printf '[WARNING] ZIP files failing the fast check:\n'
        printf '  %s\n' "${PREVIEW_BAD_FILES[@]}"
        printf '[NEXT] Repair them with Run 1.1 before formal extraction.\n'
    fi
    printf '[NEXT] Start formal parallel extraction:\n'
    printf '  ./run1.2_unzip_S1.sh 1\n'
    printf '[OPTION] Change parallel jobs, for example:\n'
    printf '  ./run1.2_unzip_S1.sh 1 --jobs 5\n'
    printf '[PREVIEW ONLY] No directory, log, marker or failed_zip.txt was created.\n'
    exit 0
fi

mkdir -p -- "${SAFE_DIR}" "${TEMP_ROOT}"

LOCK_DIR=""
if command -v flock >/dev/null 2>&1; then
    exec 9> .run1.2_unzip_S1.lock
    flock -n 9 || die "another Run 1.2 process is already running in this directory"
else
    LOCK_DIR=".run1.2_unzip_S1.lock.d"
    mkdir "${LOCK_DIR}" 2>/dev/null ||
        die "another Run 1.2 process may be running (or remove stale ${LOCK_DIR})"
    trap 'rmdir -- "${LOCK_DIR}" 2>/dev/null || true' EXIT
fi

: > "${UNZIP_LOG}"
: > "${PROGRESS_LOG}"
: > "${PARALLEL_LOG}"

{
    printf '%s\n' '========================================'
    printf 'Run 1.2: Sentinel-1 atomic unzip (FORMAL)\n'
    printf 'Work directory : %s\n' "${WORK_DIR}"
    printf 'Track          : %s\n' "${TRACK}"
    printf 'ZIP total      : %d\n' "${ZIP_TOTAL}"
    printf 'SAFE directory : %s\n' "${SAFE_DIR}"
    printf 'Jobs           : %d\n' "${JOBS}"
    printf 'Start time     : %s\n' "$(date '+%F %T')"
    printf '%s\n' '========================================'
} | tee -a "${UNZIP_LOG}"

BAD_ZIP_COUNT=0
CHECKED=0
FAILED_ZIP_TMP="${FAILED_ZIP_FILE}.tmp.$$"
: > "${FAILED_ZIP_TMP}"
for zip_path in "${ZIP_FILES[@]}"; do
    CHECKED=$((CHECKED + 1))
    size_bytes="$(file_size "${zip_path}" 2>/dev/null || printf '0')"
    signature="$(od -An -tx1 -N4 "${zip_path}" 2>/dev/null | tr -d ' \n')"
    if (( size_bytes < MIN_ZIP_SIZE_BYTES )); then
        printf '[BAD] too small: %s (%s bytes)\n' "${zip_path}" "${size_bytes}" |
            tee -a "${UNZIP_LOG}"
        basename -- "${zip_path}" >> "${FAILED_ZIP_TMP}"
        BAD_ZIP_COUNT=$((BAD_ZIP_COUNT + 1))
    elif [[ "${signature}" != "504b0304" ]]; then
        printf '[BAD] invalid ZIP signature: %s (%s)\n' "${zip_path}" "${signature}" |
            tee -a "${UNZIP_LOG}"
        basename -- "${zip_path}" >> "${FAILED_ZIP_TMP}"
        BAD_ZIP_COUNT=$((BAD_ZIP_COUNT + 1))
    elif (( CHECKED % 100 == 0 || CHECKED == ZIP_TOTAL )); then
        printf '[INFO] ZIP check: %d/%d\n' "${CHECKED}" "${ZIP_TOTAL}" |
            tee -a "${UNZIP_LOG}"
    fi
done
if (( BAD_ZIP_COUNT > 0 )); then
    sort -u "${FAILED_ZIP_TMP}" -o "${FAILED_ZIP_TMP}"
    mv -f -- "${FAILED_ZIP_TMP}" "${FAILED_ZIP_FILE}"
    printf '[FAILED] %d ZIP files failed the fast check; list: %s\n' \
        "${BAD_ZIP_COUNT}" "${FAILED_ZIP_FILE}" | tee -a "${UNZIP_LOG}"
    die "run: ./run1.1_download_S1.py --failed ${FAILED_ZIP_FILE}"
fi
rm -f -- "${FAILED_ZIP_TMP}"
: > "${FAILED_ZIP_FILE}"

count_completed() {
    find "${SAFE_DIR}" -mindepth 1 -maxdepth 1 -type d -name '*.SAFE' \
        -exec test -s "{}/${MARKER_NAME}" \; -print | wc -l | awk '{print $1}'
}

printf '[INFO] starting GNU Parallel\n' | tee -a "${UNZIP_LOG}"
printf '%s\0' "${ZIP_FILES[@]}" |
    parallel -0 --jobs "${JOBS}" --line-buffer \
        --joblog "${PARALLEL_LOG}" \
        "${SCRIPT_PATH}" --worker "${SAFE_DIR}" "${TEMP_ROOT}" {} \
        >> "${UNZIP_LOG}" 2>&1 &
UNZIP_PID=$!

INTERRUPTED=0
handle_signal() {
    INTERRUPTED=1
    kill -TERM "${UNZIP_PID}" 2>/dev/null || true
}
trap handle_signal INT TERM HUP

while kill -0 "${UNZIP_PID}" 2>/dev/null; do
    completed="$(count_completed)"
    printf '[%s] total_zip=%d completed_markers=%d left=%d\n' \
        "$(date '+%F %T')" "${ZIP_TOTAL}" "${completed}" "$((ZIP_TOTAL - completed))" |
        tee -a "${PROGRESS_LOG}"
    sleep "${INTERVAL}" &
    wait $! || true
done

if wait "${UNZIP_PID}"; then
    UNZIP_STATUS=0
else
    UNZIP_STATUS=$?
fi

BAD_SAFE_COUNT=0
FAILED_ZIP_TMP="${FAILED_ZIP_FILE}.tmp.$$"
: > "${FAILED_ZIP_TMP}"
for zip_path in "${ZIP_FILES[@]}"; do
    safe_name="$(safe_name_from_zip "${zip_path}")"
    safe_path="${SAFE_DIR}/${safe_name}"
    if ! zip_has_completed_safe "${SAFE_DIR}" "${zip_path}"; then
        printf '[BAD] incomplete or unmarked SAFE: %s\n' "${safe_path}" | tee -a "${PROGRESS_LOG}"
        basename -- "${zip_path}" >> "${FAILED_ZIP_TMP}"
        BAD_SAFE_COUNT=$((BAD_SAFE_COUNT + 1))
    fi
done
sort -u "${FAILED_ZIP_TMP}" -o "${FAILED_ZIP_TMP}"
mv -f -- "${FAILED_ZIP_TMP}" "${FAILED_ZIP_FILE}"

find "${TEMP_ROOT}" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
rmdir -- "${TEMP_ROOT}" 2>/dev/null || true

{
    printf '%s\n' '========================================'
    printf 'Run 1.2 final validation\n'
    printf 'ZIP total      : %d\n' "${ZIP_TOTAL}"
    printf 'Parallel status: %d\n' "${UNZIP_STATUS}"
    printf 'Bad SAFE count : %d\n' "${BAD_SAFE_COUNT}"
    printf 'Failed ZIP list: %s\n' "${FAILED_ZIP_FILE}"
    printf 'Finish time    : %s\n' "$(date '+%F %T')"
    printf '%s\n' '========================================'
} | tee -a "${PROGRESS_LOG}" "${UNZIP_LOG}"

if (( INTERRUPTED != 0 )); then
    die "Run 1.2 interrupted; incomplete products are recorded in ${FAILED_ZIP_FILE}"
fi
if (( UNZIP_STATUS != 0 || BAD_SAFE_COUNT != 0 )); then
    die "Run 1.2 failed; run: ./run1.1_download_S1.py --failed ${FAILED_ZIP_FILE}"
fi
printf '[OK] Run 1.2 completed successfully: %s/\n' "${SAFE_DIR}" | tee -a "${PROGRESS_LOG}" "${UNZIP_LOG}"
