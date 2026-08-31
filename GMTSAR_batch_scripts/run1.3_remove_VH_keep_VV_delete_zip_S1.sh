#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 21, 2026

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

MARKER_NAME=".run1.2_unzip_complete"
LOG_FILE="run1.3_remove_VH_keep_VV_delete_zip_S1.log"

if [[ "${RUN3_LOG_WRAPPED:-0}" != "1" ]]; then
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        RUN3_LOG_WRAPPED=1 "$0" "$@"
        exit $?
    fi
    RUN3_LOG_WRAPPED=1 "$0" "$@" 2>&1 | tee "${LOG_FILE}"
    exit "${PIPESTATUS[0]}"
fi

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

usage() {
    cat <<'EOF'
用法：./run1.3_remove_VH_keep_VV_delete_zip_S1.sh [--delete]

默认不删除，只扫描 VH 并生成 ZIP 检查清单。
确认清单后显式传入 --delete，才会删除 VH 文件和检查通过的 ZIP。
正式删除要求 failed_zip.txt 存在且为空，并且全部 ZIP 通过 Run 1.3 检查。

选项：
  --delete      执行正式删除
  -h, --help    显示帮助
EOF
}

DELETE_MODE=0
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --delete)
            DELETE_MODE=1
            shift
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

for command_name in find sort stat grep awk wc tee; do
    command -v "${command_name}" >/dev/null 2>&1 || die "cannot find command: ${command_name}"
done

WORK_DIR="$(pwd -P)"
TRACK="$(basename -- "${WORK_DIR}")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "current directory must be named T plus digits (current: ${TRACK})"

ZIP_DIR="zip"
SAFE_DIR="${TRACK}_SAFE"
RUN1_2_FAILED_FILE="failed_zip.txt"
VH_LIST="run1.3_remove_VH_keep_VV_delete_zip_S1_vh_files.txt"
ALL_ZIP_LIST="${ZIP_DIR}/run1.3_all_zip_before_cleanup.txt"
READY_LIST="${ZIP_DIR}/run1.3_zip_ready_to_delete.txt"
DELETED_LIST="${ZIP_DIR}/run1.3_deleted_zip_list.txt"
KEPT_LIST="${ZIP_DIR}/run1.3_kept_zip_list.txt"

[[ -d "${SAFE_DIR}" ]] || die "cannot find SAFE directory: ${SAFE_DIR}/"
mkdir -p -- "${ZIP_DIR}"

LOCK_DIR=""
if command -v flock >/dev/null 2>&1; then
    exec 9> .run1.3_remove_VH_keep_VV_delete_zip_S1.lock
    flock -n 9 || die "another Run 1.3 process is already running in this directory"
else
    LOCK_DIR=".run1.3_remove_VH_keep_VV_delete_zip_S1.lock.d"
    mkdir "${LOCK_DIR}" 2>/dev/null ||
        die "another Run 1.3 process may be running (or remove stale ${LOCK_DIR})"
    trap 'rmdir -- "${LOCK_DIR}" 2>/dev/null || true' EXIT
fi

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

count_nonempty() {
    find "$1" -maxdepth 1 -type f -iname "$2" -size +0c -print | wc -l | awk '{print $1}'
}

count_list_entries() {
    awk 'NF && $1 !~ /^#/ {count++} END {print count + 0}' "$1"
}

CHECK_REASON=""
check_zip_safe_pair() {
    local zip_path="$1" safe_name safe_path marker vv_tiff_count vv_xml_count zip_size
    safe_name="$(safe_name_from_zip "${zip_path}")"
    safe_path="${SAFE_DIR}/${safe_name}"
    marker="${safe_path}/${MARKER_NAME}"

    if [[ ! -d "${safe_path}" ]]; then
        CHECK_REASON="SAFE directory missing: ${safe_name}"
        return 1
    fi
    if [[ ! -s "${safe_path}/manifest.safe" ]]; then
        CHECK_REASON="manifest.safe missing or empty: ${safe_name}"
        return 1
    fi
    if [[ ! -d "${safe_path}/measurement" || ! -d "${safe_path}/annotation" ]]; then
        CHECK_REASON="measurement/ or annotation/ missing: ${safe_name}"
        return 1
    fi
    if [[ ! -s "${marker}" ]]; then
        CHECK_REASON="Run 1.2 completion marker missing: ${safe_name}"
        return 1
    fi
    if ! grep -Fqx "source_zip=$(basename -- "${zip_path}")" "${marker}"; then
        CHECK_REASON="Run 1.2 marker ZIP name mismatch: ${safe_name}"
        return 1
    fi
    zip_size="$(file_size "${zip_path}")"
    if ! grep -Fqx "source_size=${zip_size}" "${marker}"; then
        CHECK_REASON="Run 1.2 marker ZIP size mismatch: ${safe_name}"
        return 1
    fi

    vv_tiff_count="$(count_nonempty "${safe_path}/measurement" '*-vv-*.tif*')"
    vv_xml_count="$(count_nonempty "${safe_path}/annotation" '*-vv-*.xml')"
    if (( vv_tiff_count == 0 )); then
        CHECK_REASON="non-empty VV TIFF missing: ${safe_name}"
        return 1
    fi
    if (( vv_xml_count == 0 )); then
        CHECK_REASON="non-empty VV annotation XML missing: ${safe_name}"
        return 1
    fi
    if (( vv_tiff_count != vv_xml_count )); then
        CHECK_REASON="VV TIFF/XML count mismatch (${vv_tiff_count}/${vv_xml_count}): ${safe_name}"
        return 1
    fi

    CHECK_REASON="OK"
    return 0
}

scan_vh() {
    local safe_path vh_tmp
    vh_tmp="${VH_LIST}.tmp.$$"
    : > "${vh_tmp}"
    while IFS= read -r -d '' safe_path; do
        find "${safe_path}" -type f -iname '*-vh-*' -print >> "${vh_tmp}"
    done < <(
        find "${SAFE_DIR}" -mindepth 1 -maxdepth 1 -type d -name '*.SAFE' -print0 |
            sort -z
    )
    sort "${vh_tmp}" > "${VH_LIST}"
    rm -f -- "${vh_tmp}"
}

build_zip_lists() {
    local zip_path zip_name
    local all_tmp ready_tmp kept_tmp
    all_tmp="${ALL_ZIP_LIST}.tmp.$$"
    ready_tmp="${READY_LIST}.tmp.$$"
    kept_tmp="${KEPT_LIST}.tmp.$$"
    : > "${all_tmp}"
    : > "${ready_tmp}"
    : > "${kept_tmp}"

    while IFS= read -r -d '' zip_path; do
        zip_name="$(basename -- "${zip_path}")"
        printf '%s\n' "${zip_name}" >> "${all_tmp}"
        if check_zip_safe_pair "${zip_path}"; then
            printf '%s\n' "${zip_name}" >> "${ready_tmp}"
        else
            printf '%s\t%s\n' "${zip_name}" "${CHECK_REASON}" >> "${kept_tmp}"
        fi
    done < <(find "${ZIP_DIR}" -maxdepth 1 -type f -name '*.zip' -print0 | sort -z)

    mv -f -- "${all_tmp}" "${ALL_ZIP_LIST}"
    mv -f -- "${ready_tmp}" "${READY_LIST}"
    mv -f -- "${kept_tmp}" "${KEPT_LIST}"
}

ZIP_TOTAL="$(find "${ZIP_DIR}" -maxdepth 1 -type f -name '*.zip' -print | wc -l | awk '{print $1}')"
scan_vh
VH_TOTAL="$(wc -l < "${VH_LIST}" | awk '{print $1}')"

RUN1_2_FAILED_COUNT=-1
if [[ -f "${RUN1_2_FAILED_FILE}" ]]; then
    RUN1_2_FAILED_COUNT="$(count_list_entries "${RUN1_2_FAILED_FILE}")"
fi

printf '%s\n' '========================================'
printf 'Run 1.3: remove VH, keep VV, clean ZIP\n'
printf 'Mode           : %s\n' "$([[ "${DELETE_MODE}" -eq 1 ]] && printf 'DELETE' || printf 'DRY-RUN')"
printf 'Track          : %s\n' "${TRACK}"
printf 'SAFE directory : %s\n' "${SAFE_DIR}"
printf 'ZIP total      : %d\n' "${ZIP_TOTAL}"
printf 'VH files       : %d\n' "${VH_TOTAL}"
if (( RUN1_2_FAILED_COUNT >= 0 )); then
    printf 'Run 1.2 failures: %d\n' "${RUN1_2_FAILED_COUNT}"
else
    printf 'Run 1.2 failures: UNKNOWN (%s missing)\n' "${RUN1_2_FAILED_FILE}"
fi
printf 'Start time     : %s\n' "$(date '+%F %T')"
printf '%s\n' '========================================'

if (( ZIP_TOTAL > 0 )); then
    build_zip_lists
else
    printf '[INFO] no ZIP remains; preserving previous ZIP cleanup lists\n'
fi

READY_TOTAL=0
KEPT_TOTAL=0
[[ -f "${READY_LIST}" ]] && READY_TOTAL="$(wc -l < "${READY_LIST}" | awk '{print $1}')"
[[ -f "${KEPT_LIST}" ]] && KEPT_TOTAL="$(wc -l < "${KEPT_LIST}" | awk '{print $1}')"

printf '[SUMMARY] ready ZIP=%d, kept ZIP=%d, VH files=%d\n' \
    "${READY_TOTAL}" "${KEPT_TOTAL}" "${VH_TOTAL}"

if (( DELETE_MODE == 0 )); then
    if (( RUN1_2_FAILED_COUNT < 0 )); then
        printf '[BLOCK] %s is missing; formal deletion is not allowed\n' "${RUN1_2_FAILED_FILE}"
    elif (( RUN1_2_FAILED_COUNT > 0 )); then
        printf '[BLOCK] %s contains %d failed products\n' \
            "${RUN1_2_FAILED_FILE}" "${RUN1_2_FAILED_COUNT}"
    fi
    if (( ZIP_TOTAL > 0 && (KEPT_TOTAL > 0 || READY_TOTAL != ZIP_TOTAL) )); then
        printf '[BLOCK] not every ZIP passed Run 1.3 validation\n'
    fi
    printf '[DRY-RUN] no files were deleted\n'
    printf '[NEXT] inspect these files before formal deletion:\n'
    printf '  %s\n' "${VH_LIST}" "${READY_LIST}" "${KEPT_LIST}"
    printf '[NEXT] After confirming the lists, run:\n'
    printf '  ./run1.3_remove_VH_keep_VV_delete_zip_S1.sh --delete\n'
    exit 0
fi

[[ -f "${RUN1_2_FAILED_FILE}" ]] ||
    die "${RUN1_2_FAILED_FILE} is missing; complete Run 1.2 before --delete"
(( RUN1_2_FAILED_COUNT == 0 )) ||
    die "${RUN1_2_FAILED_FILE} contains ${RUN1_2_FAILED_COUNT} failed products; repair Run 1.1/1.2 first"
if (( ZIP_TOTAL > 0 )); then
    (( KEPT_TOTAL == 0 )) ||
        die "${KEPT_TOTAL} ZIP files are in the kept list; no files were deleted"
    (( READY_TOTAL == ZIP_TOTAL )) ||
        die "ready ZIP count (${READY_TOTAL}) does not equal ZIP total (${ZIP_TOTAL})"
fi

printf '[INFO] deleting listed VH files\n'
while IFS= read -r vh_path; do
    [[ -n "${vh_path}" ]] || continue
    if [[ -f "${vh_path}" ]]; then
        rm -- "${vh_path}"
        printf '[DELETE VH] %s\n' "${vh_path}"
    fi
done < "${VH_LIST}"

scan_vh
VH_LEFT="$(wc -l < "${VH_LIST}" | awk '{print $1}')"
(( VH_LEFT == 0 )) || die "${VH_LEFT} VH files remain; ZIP deletion stopped"

if (( ZIP_TOTAL > 0 )); then
    build_zip_lists
    READY_TOTAL="$(wc -l < "${READY_LIST}" | awk '{print $1}')"
    KEPT_TOTAL="$(wc -l < "${KEPT_LIST}" | awk '{print $1}')"
    (( KEPT_TOTAL == 0 && READY_TOTAL == ZIP_TOTAL )) ||
        die "Run 1.3 validation changed after VH cleanup; ZIP deletion stopped"
fi

touch -- "${DELETED_LIST}"
while IFS= read -r zip_name; do
    [[ -n "${zip_name}" ]] || continue
    zip_path="${ZIP_DIR}/${zip_name}"
    if [[ -f "${zip_path}" ]]; then
        rm -- "${zip_path}"
        printf '%s\t%s\n' "$(date '+%F %T %z')" "${zip_name}" >> "${DELETED_LIST}"
        printf '[DELETE ZIP] %s\n' "${zip_path}"
    fi
done < "${READY_LIST}"

ZIP_LEFT="$(find "${ZIP_DIR}" -maxdepth 1 -type f -name '*.zip' -print | wc -l | awk '{print $1}')"
printf '%s\n' '========================================'
printf 'Run 1.3 finished\n'
printf 'Deleted/absent ready ZIP : %d\n' "${READY_TOTAL}"
printf 'Kept ZIP                 : %d\n' "${KEPT_TOTAL}"
printf 'ZIP remaining            : %d\n' "${ZIP_LEFT}"
printf 'VH remaining             : %d\n' "${VH_LEFT}"
printf 'Finish time              : %s\n' "$(date '+%F %T')"
printf '%s\n' '========================================'

(( ZIP_LEFT == KEPT_TOTAL )) || die "remaining ZIP count does not match kept list"
printf '[OK] Run 1.3 completed successfully\n'
