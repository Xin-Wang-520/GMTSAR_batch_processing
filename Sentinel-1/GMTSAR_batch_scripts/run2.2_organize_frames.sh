#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 28, 2026

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

validate_pins_file() {
    awk '
        NF == 0 { next }
        {
            if (NF != 2 || $1 !~ /^[-+]?[0-9]+([.][0-9]+)?$/ ||
                $2 !~ /^[-+]?[0-9]+([.][0-9]+)?$/) {
                print "FORMAT_ERROR"
                exit
            }
            count++
            lon[count] = $1 + 0
            lat[count] = $2 + 0
            if (lon[count] < -180 || lon[count] > 180 ||
                lat[count] < -90 || lat[count] > 90) {
                print "RANGE_ERROR"
                exit
            }
        }
        END {
            if (count != 2) print "COUNT_ERROR " count
            else if (lon[1] == lon[2] || lat[1] == lat[2]) print "ORDER_ERROR"
            else print lon[1], lat[1], lon[2], lat[2]
        }
    ' "$1"
}

pins_order_is_valid() {
    if [[ "$1" == "Descending" ]]; then
        awk -v x1="$2" -v y1="$3" -v x2="$4" -v y2="$5" \
            'BEGIN {exit !(x1 < x2 && y1 > y2)}'
    else
        awk -v x1="$2" -v y1="$3" -v x2="$4" -v y2="$5" \
            'BEGIN {exit !(x1 > x2 && y1 < y2)}'
    fi
}

file_signature() {
    cksum "$1" | awk '{print $1 ":" $2}'
}

state_value() {
    awk -F= -v wanted="$2" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$1"
}

extract_safe_date() {
    local safe_name
    safe_name="$(basename -- "$1")"
    if [[ "${safe_name}" =~ _([0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])T ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

date_output_exists() {
    local date_value="$1"
    local candidate
    for candidate in "${ORGANIZED_ABS}"/F????_F????/*"${date_value}"T*.SAFE; do
        [[ -d "${candidate}" ]] && return 0
    done
    return 1
}

date_output_is_valid() {
    local date_value="$1"
    local candidate iw xml_count tiff_count found=0
    for candidate in "${ORGANIZED_ABS}"/F????_F????/*"${date_value}"T*.SAFE; do
        [[ -d "${candidate}" ]] || continue
        found=1
        for iw in 1 2 3; do
            xml_count="$(find "${candidate}/annotation" -maxdepth 1 -type f -iname "*iw${iw}*${POLARIZATION}*.xml" -print 2>/dev/null | wc -l | awk '{print $1}')"
            tiff_count="$(find "${candidate}/measurement" -maxdepth 1 -type f -iname "*iw${iw}*${POLARIZATION}*.tiff" -print 2>/dev/null | wc -l | awk '{print $1}')"
            [[ "${xml_count}" -eq 1 && "${tiff_count}" -eq 1 ]] || return 1
        done
    done
    (( found == 1 ))
}

mode2_log_has_critical_errors() {
    grep -Eiq 'Couldn.t open xml|couldn.t open master[.]PRM|Error: Incorrect input|cannot stat .*(new[.]xml|new[.]tiff)|gmtinfo \[ERROR\]|awk:.*syntax error|No space left|Killed|Segmentation fault|Connection timed out|Connection refused|Temporary failure in name resolution|Unable to establish SSL connection|failed: Connection' "$1"
}

prepare_mode2_safe_list() {
    local refresh_mode="$1"
    local source_good=""
    local safe_path safe_date iw xml_count tiff_count
    local good_tmp skip_tmp list_tmp selected_dates_tmp missing_dates_tmp errors_tmp
    local recovered_good_tmp=""

    if [[ "${refresh_mode}" == "refresh" ]]; then
        [[ -s "${ORIGINAL_GOOD_DATES}" ]] ||
            die "mode=1 did not create organize_mode1_good_dates.txt"
        source_good="${ORIGINAL_GOOD_DATES}"
    elif [[ -s "${GOOD_DATES}" ]]; then
        source_good="${GOOD_DATES}"
    elif [[ -s "${ORIGINAL_GOOD_DATES}" ]]; then
        source_good="${ORIGINAL_GOOD_DATES}"
    elif [[ -s "${PREVIEW_LOG}" ]]; then
        recovered_good_tmp="$(mktemp "${GOOD_DATES}.recover.XXXXXX")" ||
            die "cannot create recovered good-date file"
        awk '
            /^ Good dates:/ {inside=1; next}
            inside && /^-+/ {exit}
            inside && $1 ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/ {print $1}
        ' "${PREVIEW_LOG}" > "${recovered_good_tmp}"
        [[ -s "${recovered_good_tmp}" ]] || {
            rm -f -- "${recovered_good_tmp}"
            die "cannot recover good dates from the old mode=1 log; run mode 1 again"
        }
        source_good="${recovered_good_tmp}"
    else
        die "good-date result not found; run ./run2.2_organize_frames.sh 1 first"
    fi

    good_tmp="$(mktemp "${GOOD_DATES}.tmp.XXXXXX")" || die "cannot create good-date file"
    sort -u -- "${source_good}" | awk '$1 ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/ {print $1}' > "${good_tmp}"
    [[ -s "${good_tmp}" ]] || {
        rm -f -- "${good_tmp}"
        die "no valid good dates were produced by mode=1"
    }
    mv -f -- "${good_tmp}" "${GOOD_DATES}"
    [[ -z "${recovered_good_tmp}" ]] || rm -f -- "${recovered_good_tmp}"

    skip_tmp="$(mktemp "${SKIP_DATES}.tmp.XXXXXX")" || die "cannot create skip-date file"
    if [[ -f "${ORIGINAL_SKIP_DATES}" ]]; then
        sort -u -- "${ORIGINAL_SKIP_DATES}" > "${skip_tmp}"
    else
        : > "${skip_tmp}"
    fi
    mv -f -- "${skip_tmp}" "${SKIP_DATES}"

    list_tmp="$(mktemp "${MODE2_SAFE_LIST}.tmp.XXXXXX")" || die "cannot create filtered SAFE list"
    selected_dates_tmp="$(mktemp "${MODE2_SAFE_LIST}.dates.XXXXXX")" || die "cannot create selected-date file"
    errors_tmp="$(mktemp "${MODE2_INPUT_ERRORS}.tmp.XXXXXX")" || die "cannot create input-error file"
    : > "${errors_tmp}"

    while IFS= read -r safe_path; do
        [[ -n "${safe_path}" ]] || continue
        safe_date="$(extract_safe_date "${safe_path}")" || {
            printf '%s\t%s\n' "UNKNOWN_DATE" "${safe_path}" >> "${errors_tmp}"
            continue
        }
        grep -Fxq -- "${safe_date}" "${GOOD_DATES}" || continue
        printf '%s\n' "${safe_path}" >> "${list_tmp}"
        printf '%s\n' "${safe_date}" >> "${selected_dates_tmp}"

        for iw in 1 2 3; do
            xml_count="$(find "${safe_path}/annotation" -maxdepth 1 -type f -iname "*iw${iw}*${POLARIZATION}*.xml" -print 2>/dev/null | wc -l | awk '{print $1}')"
            tiff_count="$(find "${safe_path}/measurement" -maxdepth 1 -type f -iname "*iw${iw}*${POLARIZATION}*.tiff" -print 2>/dev/null | wc -l | awk '{print $1}')"
            if [[ "${xml_count}" -ne 1 || "${tiff_count}" -ne 1 ]]; then
                printf '%s\tIW%s\tXML=%s\tTIFF=%s\t%s\n' "${safe_date}" "${iw}" "${xml_count}" "${tiff_count}" "${safe_path}" >> "${errors_tmp}"
            fi
        done
    done < "${SAFE_LIST}"

    sort -u -o "${list_tmp}" -- "${list_tmp}"
    sort -u -o "${selected_dates_tmp}" -- "${selected_dates_tmp}"
    [[ -s "${list_tmp}" ]] || die "filtered mode=2 SAFE list is empty"

    missing_dates_tmp="$(mktemp "${MODE2_SAFE_LIST}.missing.XXXXXX")" || die "cannot create missing-date file"
    while IFS= read -r safe_date; do
        grep -Fxq -- "${safe_date}" "${selected_dates_tmp}" || printf '%s\n' "${safe_date}" >> "${missing_dates_tmp}"
    done < "${GOOD_DATES}"

    if [[ -s "${missing_dates_tmp}" ]]; then
        mv -f -- "${missing_dates_tmp}" "${MODE2_MISSING_DATES}"
        rm -f -- "${list_tmp}" "${selected_dates_tmp}" "${errors_tmp}"
        die "some good dates have no SAFE entries; inspect ${MODE2_MISSING_DATES}"
    fi
    rm -f -- "${missing_dates_tmp}" "${MODE2_MISSING_DATES}"

    if [[ -s "${errors_tmp}" ]]; then
        mv -f -- "${errors_tmp}" "${MODE2_INPUT_ERRORS}"
        rm -f -- "${list_tmp}" "${selected_dates_tmp}"
        die "filtered SAFE integrity check failed; inspect ${MODE2_INPUT_ERRORS}"
    fi
    rm -f -- "${errors_tmp}" "${MODE2_INPUT_ERRORS}" "${selected_dates_tmp}"
    mv -f -- "${list_tmp}" "${MODE2_SAFE_LIST}"
    MODE2_SAFE_TOTAL="$(wc -l < "${MODE2_SAFE_LIST}" | awk '{print $1}')"
}

run_mode1_parallel() {
    local mode1_work_root="${ORGANIZED_ABS}/.run2.2_mode1_work"
    local mode1_log_dir="${ORGANIZED_ABS}/run2.2_mode1_date_logs"
    local mode1_failed="${ORGANIZED_ABS}/run2.2_mode1_failed_dates.txt"
    local date_list date_value index total failed_count good_count skip_count
    local stopped_count cover_count stale_path
    local worker_index worker_pid worker_date
    local -a preview_pids preview_dates

    mkdir -p -- "${mode1_work_root}" "${mode1_log_dir}"
    for stale_path in "${mode1_work_root}"/*; do
        [[ -e "${stale_path}" ]] || continue
        rm -rf -- "${stale_path}"
    done

    date_list="$(mktemp "${ORGANIZED_ABS}/run2.2_mode1_dates.tmp.XXXXXX")" ||
        die "cannot create mode=1 date list"
    while IFS= read -r SAFE_PATH; do
        extract_safe_date "${SAFE_PATH}"
    done < "${SAFE_LIST}" | sort -u > "${date_list}"
    total="$(wc -l < "${date_list}" | awk '{print $1}')"
    (( total > 0 )) || die "mode=1 date list is empty"

    process_mode1_date() {
        local preview_date="$1"
        local preview_index="$2"
        local preview_work="${mode1_work_root}/${preview_date}.$$"
        local preview_safe_list="${preview_work}/SAFE_filelist_date"
        local preview_log="${mode1_log_dir}/${preview_date}.log"
        local safe_path safe_date_value orbit_path preview_status

        mkdir -p -- "${preview_work}"
        while IFS= read -r safe_path; do
            safe_date_value="$(extract_safe_date "${safe_path}")" || continue
            [[ "${safe_date_value}" == "${preview_date}" ]] && printf '%s\n' "${safe_path}" >> "${preview_safe_list}"
        done < "${SAFE_LIST}"

        if [[ ! -s "${preview_safe_list}" ]]; then
            printf 'empty_date_safe_list\n' > "${mode1_work_root}/${preview_date}.failed"
            rm -rf -- "${preview_work}"
            return 0
        fi

        for orbit_path in "${ORGANIZED_ABS}"/*.EOF; do
            [[ -f "${orbit_path}" ]] || continue
            ln -s -- "${orbit_path}" "${preview_work}/$(basename -- "${orbit_path}")"
        done

        printf '[PREVIEW START %d/%d] %s\n' "${preview_index}" "${total}" "${preview_date}"
        set +e
        (
            cd -- "${preview_work}"
            "${ORGANIZER_PATH}" "${preview_safe_list}" "${PINS_FILE}" 1 "${POLARIZATION}"
        ) > "${preview_log}" 2>&1
        preview_status=$?
        set -e

        if (( preview_status != 0 )); then
            printf 'organizer_exit_%d\n' "${preview_status}" > "${mode1_work_root}/${preview_date}.failed"
        elif mode2_log_has_critical_errors "${preview_log}"; then
            printf 'critical_error_in_log\n' > "${mode1_work_root}/${preview_date}.failed"
        elif [[ ! -s "${preview_work}/organize_mode1_summary.txt" ]]; then
            printf 'missing_mode1_summary\n' > "${mode1_work_root}/${preview_date}.failed"
        else
            [[ ! -f "${preview_work}/organize_mode1_good_dates.txt" ]] || cp -- "${preview_work}/organize_mode1_good_dates.txt" "${mode1_work_root}/${preview_date}.good"
            [[ ! -f "${preview_work}/organize_mode1_skip_dates.txt" ]] || cp -- "${preview_work}/organize_mode1_skip_dates.txt" "${mode1_work_root}/${preview_date}.skip"
            cp -- "${preview_work}/organize_mode1_summary.txt" "${mode1_work_root}/${preview_date}.summary"
            printf '[PREVIEW DONE %d/%d] %s\n' "${preview_index}" "${total}" "${preview_date}"
        fi
        rm -rf -- "${preview_work}"
        return 0
    }

    wait_for_preview_batch() {
        for ((worker_index = 0; worker_index < ${#preview_pids[@]}; worker_index++)); do
            worker_pid="${preview_pids[worker_index]}"
            worker_date="${preview_dates[worker_index]}"
            if ! wait "${worker_pid}"; then
                printf 'worker_process_failed\n' > "${mode1_work_root}/${worker_date}.failed"
            fi
        done
        preview_pids=()
        preview_dates=()
    }

    preview_pids=()
    preview_dates=()
    index=0
    while IFS= read -r date_value; do
        [[ -n "${date_value}" ]] || continue
        index=$((index + 1))
        process_mode1_date "${date_value}" "${index}" &
        preview_pids+=("$!")
        preview_dates+=("${date_value}")
        if (( ${#preview_pids[@]} >= JOBS )); then
            wait_for_preview_batch
        fi
    done < "${date_list}"
    (( ${#preview_pids[@]} == 0 )) || wait_for_preview_batch

    : > "${ORIGINAL_GOOD_DATES}"
    : > "${ORIGINAL_SKIP_DATES}"
    : > "${PREVIEW_LOG}"
    : > "${mode1_failed}"
    while IFS= read -r date_value; do
        if [[ -f "${mode1_work_root}/${date_value}.failed" ]]; then
            printf '%s\t%s\t%s\n' "${date_value}" "$(cat "${mode1_work_root}/${date_value}.failed")" "${mode1_log_dir}/${date_value}.log" >> "${mode1_failed}"
            continue
        fi
        [[ ! -f "${mode1_work_root}/${date_value}.good" ]] || cat "${mode1_work_root}/${date_value}.good" >> "${ORIGINAL_GOOD_DATES}"
        [[ ! -f "${mode1_work_root}/${date_value}.skip" ]] || cat "${mode1_work_root}/${date_value}.skip" >> "${ORIGINAL_SKIP_DATES}"
        {
            printf '===== %s =====\n' "${date_value}"
            cat "${mode1_log_dir}/${date_value}.log"
            printf '\n'
        } >> "${PREVIEW_LOG}"
    done < "${date_list}"

    sort -u -o "${ORIGINAL_GOOD_DATES}" -- "${ORIGINAL_GOOD_DATES}"
    sort -u -o "${ORIGINAL_SKIP_DATES}" -- "${ORIGINAL_SKIP_DATES}"
    failed_count="$(wc -l < "${mode1_failed}" | awk '{print $1}')"
    if (( failed_count > 0 )); then
        rm -f -- "${date_list}"
        die "${failed_count} mode=1 dates failed; inspect ${mode1_failed}"
    fi

    good_count="$(wc -l < "${ORIGINAL_GOOD_DATES}" | awk '{print $1}')"
    skip_count="$(awk '{print $1}' "${ORIGINAL_SKIP_DATES}" | sort -u | wc -l | awk '{print $1}')"
    stopped_count="$(grep -c 'stopped_in_middle' "${ORIGINAL_SKIP_DATES}" || true)"
    cover_count="$(grep -c 'not_enough_scenes_or_not_cover_pins' "${ORIGINAL_SKIP_DATES}" || true)"
    {
        printf 'Re-organizable frame records : %d\n' "${good_count}"
        printf 'Re-organizable dates         : %d\n' "${good_count}"
        printf 'Skipped dates                : %d\n' "${skip_count}"
        printf 'Stopped in middle            : %d\n' "${stopped_count}"
        printf 'Not enough scenes            : %d\n' "${cover_count}"
    } > "${ORGANIZED_ABS}/organize_mode1_summary.txt"
    {
        printf '\n Good dates:\n'
        sed 's/^/ /' "${ORIGINAL_GOOD_DATES}"
        printf '%s\n' '------------------------------------------------------------'
        printf ' Skipped dates and reasons:\n'
        sed 's/^/ /' "${ORIGINAL_SKIP_DATES}"
        printf '%s\n' '============================================================'
    } >> "${PREVIEW_LOG}"
    rm -f -- "${date_list}"
}

usage() {
    cat <<'EOF'
用法：./run2.2_organize_frames.sh MODE [DIRECTION] [选项]

MODE：
  1                      只执行 mode=1 预检并保存结果
  2                      读取已保存的预检结果，直接执行 mode=2

DIRECTION（可选）：
  ascending              升轨；适用于父目录没有 Ascending 名称的服务器
  descending             降轨；适用于父目录没有 Descending 名称的服务器
  若省略，脚本从当前 T* 目录的父目录自动识别

选项：
  --pins FILE            两行经纬度文件（默认：organized/pins.ll）
  --organized-dir DIR    Run 2.1 输出目录（默认：organized）
  --organizer FILE       organize_files_tops_linux_nex_xinw.csh 路径或命令
  --direction DIR        Ascending 或 Descending（默认从当前路径识别）
  --polarization POL     极化方式（默认：vv）
  --jobs N               mode=1/mode=2 并行日期数（默认：5）
  --allow-existing       兼容旧命令；新版会自动验证并跳过已有帧
  -h, --help             显示帮助

pins.ll 必须恰好两行，每行格式：longitude latitude
  Descending：第1行左上点，第2行右下点
  Ascending ：第1行右下点，第2行左上点
若 pins.ll 不存在或为空，脚本会交互询问两个点；每次同时输入“经度 纬度”。

示例：
  ./run2.2_organize_frames.sh 1
  ./run2.2_organize_frames.sh 2
  ./run2.2_organize_frames.sh 1 ascending
  ./run2.2_organize_frames.sh 2 ascending
  ./run2.2_organize_frames.sh 1 --direction Ascending
EOF
}

MODE=""
EXECUTE=0
PINS_FILE=""
ORGANIZED_DIR="organized"
ORGANIZER="organize_files_tops_linux_nex_xinw.csh"
DIRECTION=""
POLARIZATION="vv"
JOBS=5
ALLOW_EXISTING=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        1|2)
            [[ -z "${MODE}" ]] || die "mode was specified more than once"
            MODE="$1"
            shift
            ;;
        [Aa][Ss][Cc][Ee][Nn][Dd][Ii][Nn][Gg]|[Dd][Ee][Ss][Cc][Ee][Nn][Dd][Ii][Nn][Gg])
            [[ -z "${DIRECTION}" ]] || die "direction was specified more than once"
            DIRECTION="$1"
            shift
            ;;
        --execute)
            [[ -z "${MODE}" ]] || die "mode was specified more than once"
            MODE=2
            EXECUTE=1
            shift
            ;;
        --pins)
            [[ "$#" -ge 2 ]] || die "--pins requires a file"
            PINS_FILE="$2"
            shift 2
            ;;
        --organized-dir)
            [[ "$#" -ge 2 ]] || die "--organized-dir requires a directory"
            ORGANIZED_DIR="$2"
            shift 2
            ;;
        --organizer)
            [[ "$#" -ge 2 ]] || die "--organizer requires a file or command"
            ORGANIZER="$2"
            shift 2
            ;;
        --direction)
            [[ "$#" -ge 2 ]] || die "--direction requires Ascending or Descending"
            DIRECTION="$2"
            shift 2
            ;;
        --polarization)
            [[ "$#" -ge 2 ]] || die "--polarization requires a value"
            POLARIZATION="$2"
            shift 2
            ;;
        --jobs)
            [[ "$#" -ge 2 ]] || die "--jobs requires a positive integer"
            JOBS="$2"
            shift 2
            ;;
        --allow-existing)
            ALLOW_EXISTING=1
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

if [[ -z "${MODE}" ]]; then
    usage >&2
    die "missing MODE: use 1 for preview or 2 for execution"
fi

if [[ "${MODE}" == "2" ]]; then
    EXECUTE=1
else
    EXECUTE=0
fi

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"

for command_name in awk find grep sort wc tee csh mktemp cksum; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "cannot find command: ${command_name}"
done

WORK_DIR="$(pwd -P)"
TRACK="$(basename -- "${WORK_DIR}")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number directory (current: ${WORK_DIR})"

if [[ -z "${DIRECTION}" ]]; then
    DIRECTION="$(basename -- "$(dirname -- "${WORK_DIR}")")"
fi
DIRECTION_LOWER="$(printf '%s' "${DIRECTION}" | tr '[:upper:]' '[:lower:]')"
case "${DIRECTION_LOWER}" in
    ascending)
        DIRECTION="Ascending"
        ;;
    descending)
        DIRECTION="Descending"
        ;;
    *)
        die "cannot detect orbit direction from ${WORK_DIR}; use '${0} ${MODE} ascending' or '${0} ${MODE} descending'"
        ;;
esac

[[ -d "${ORGANIZED_DIR}" ]] ||
    die "organized directory not found: ${ORGANIZED_DIR}; complete Run 2.1 first"
ORGANIZED_ABS="$(cd -- "${ORGANIZED_DIR}" && pwd -P)"
SAFE_LIST="${ORGANIZED_ABS}/SAFE_filelist"
[[ -s "${SAFE_LIST}" ]] || die "SAFE list missing or empty: ${SAFE_LIST}"

if [[ -z "${PINS_FILE}" ]]; then
    PINS_FILE="${ORGANIZED_ABS}/pins.ll"
elif [[ "${PINS_FILE}" != /* ]]; then
    PINS_FILE="${WORK_DIR}/${PINS_FILE}"
fi

if [[ ! -s "${PINS_FILE}" ]]; then
    [[ ! -e "${PINS_FILE}" || -f "${PINS_FILE}" ]] ||
        die "pins path exists but is not a regular file: ${PINS_FILE}"
    PINS_PARENT="$(dirname -- "${PINS_FILE}")"
    [[ -d "${PINS_PARENT}" ]] || die "pins parent directory not found: ${PINS_PARENT}"

    printf '[INPUT] pins.ll not found or empty: %s\n' "${PINS_FILE}"
    printf '[INPUT] Direction: %s\n' "${DIRECTION}"
    printf '[INPUT] Enter one point per line: longitude latitude (separated by a space)\n'

    if [[ "${DIRECTION}" == "Descending" ]]; then
        printf 'Upper-left point (longitude latitude, example: 100.123456 36.123456)\n> '
        IFS= read -r INPUT_POINT1 || die "input cancelled"
        printf 'Lower-right point (longitude latitude, example: 102.123456 34.123456)\n> '
        IFS= read -r INPUT_POINT2 || die "input cancelled"
    else
        printf 'Lower-right point (longitude latitude, example: 102.123456 34.123456)\n> '
        IFS= read -r INPUT_POINT1 || die "input cancelled"
        printf 'Upper-left point (longitude latitude, example: 100.123456 36.123456)\n> '
        IFS= read -r INPUT_POINT2 || die "input cancelled"
    fi

    PINS_TMP="$(mktemp "${PINS_FILE}.tmp.XXXXXX")" ||
        die "cannot create temporary pins file"
    if ! printf '%s\n%s\n' "${INPUT_POINT1}" "${INPUT_POINT2}" > "${PINS_TMP}"; then
        rm -f -- "${PINS_TMP}"
        die "cannot write temporary pins file"
    fi

    INPUT_VALIDATION="$(validate_pins_file "${PINS_TMP}")"
    case "${INPUT_VALIDATION}" in
        FORMAT_ERROR*|RANGE_ERROR*|COUNT_ERROR*|ORDER_ERROR*)
            rm -f -- "${PINS_TMP}"
            die "invalid coordinate input (${INPUT_VALIDATION}); pins.ll was not created"
            ;;
    esac

    read -r INPUT_LON1 INPUT_LAT1 INPUT_LON2 INPUT_LAT2 <<< "${INPUT_VALIDATION}"
    if ! pins_order_is_valid "${DIRECTION}" \
        "${INPUT_LON1}" "${INPUT_LAT1}" "${INPUT_LON2}" "${INPUT_LAT2}"; then
        rm -f -- "${PINS_TMP}"
        if [[ "${DIRECTION}" == "Descending" ]]; then
            die "Descending input order error: first point must be upper-left; pins.ll was not created"
        else
            die "Ascending input order error: first point must be lower-right; pins.ll was not created"
        fi
    fi

    mv -f -- "${PINS_TMP}" "${PINS_FILE}"
    printf '[OK] Created pins file: %s\n' "${PINS_FILE}"
fi

if [[ -x "${ORGANIZER}" ]]; then
    ORGANIZER_PATH="$(cd -- "$(dirname -- "${ORGANIZER}")" && pwd -P)/$(basename -- "${ORGANIZER}")"
elif ORGANIZER_PATH="$(command -v "${ORGANIZER}" 2>/dev/null)"; then
    :
else
    die "organizer not found or not executable: ${ORGANIZER}"
fi

for command_name in \
    download_sentinel_orbits_linux.csh \
    make_s1a_tops \
    ext_orb_s1a \
    SAT_llt2rat \
    shift_atime_PRM.csh \
    create_frame_tops.csh; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required GMTSAR command not found: ${command_name}"
done

SAFE_TOTAL=0
while IFS= read -r safe_path; do
    [[ -n "${safe_path}" ]] || continue
    [[ "${safe_path}" == /* ]] || die "SAFE_filelist contains a non-absolute path: ${safe_path}"
    [[ -d "${safe_path}" && "${safe_path}" == *.SAFE ]] ||
        die "SAFE path does not exist or does not end in .SAFE: ${safe_path}"
    SAFE_TOTAL=$((SAFE_TOTAL + 1))
done < "${SAFE_LIST}"
(( SAFE_TOTAL > 0 )) || die "no valid SAFE paths found in ${SAFE_LIST}"

PIN_VALIDATION="$(validate_pins_file "${PINS_FILE}")"

case "${PIN_VALIDATION}" in
    FORMAT_ERROR*|RANGE_ERROR*|COUNT_ERROR*|ORDER_ERROR*)
        die "invalid pins.ll (${PIN_VALIDATION}); require exactly two 'lon lat' lines"
        ;;
esac

read -r LON1 LAT1 LON2 LAT2 <<< "${PIN_VALIDATION}"
if ! pins_order_is_valid "${DIRECTION}" "${LON1}" "${LAT1}" "${LON2}" "${LAT2}"; then
    if [[ "${DIRECTION}" == "Descending" ]]; then
        die "Descending pins order error: line 1 must be upper-left; line 2 lower-right"
    else
        die "Ascending pins order error: line 1 must be lower-right; line 2 upper-left"
    fi
fi

EOF_TOTAL="$(find "${ORGANIZED_ABS}" -maxdepth 1 -type f -name '*.EOF' -print | wc -l | awk '{print $1}')"
(( EOF_TOTAL > 0 )) || die "no orbit .EOF files found; complete Run 2.1 first"

EXISTING_FRAME_COUNT="$(find "${ORGANIZED_ABS}" -mindepth 1 -maxdepth 1 -type d -name 'F????_F????' -print | wc -l | awk '{print $1}')"
if (( EXECUTE == 1 && EXISTING_FRAME_COUNT > 0 )); then
    printf '[INFO] Found %d existing frame directories; completed dates will be validated and skipped.\n' "${EXISTING_FRAME_COUNT}"
fi

LOCK_DIR=""
if command -v flock >/dev/null 2>&1; then
    exec 9> .run2.2_organize_frames.lock
    flock -n 9 || die "another Run 2.2 process is already running"
else
    LOCK_DIR=".run2.2_organize_frames.lock.d"
    mkdir "${LOCK_DIR}" 2>/dev/null ||
        die "another Run 2.2 process may be running (or remove stale ${LOCK_DIR})"
    trap 'rmdir -- "${LOCK_DIR}" 2>/dev/null || true' EXIT
fi

PREVIEW_LOG="${ORGANIZED_ABS}/run2.2_mode1_preview.log"
EXECUTE_LOG="${ORGANIZED_ABS}/run2.2_mode2_execute.log"
PREVIEW_SUMMARY="${ORGANIZED_ABS}/run2.2_mode1_summary.txt"
PREVIEW_STATE="${ORGANIZED_ABS}/run2.2_mode1_preview.state"
GOOD_DATES="${ORGANIZED_ABS}/run2.2_mode1_good_dates.txt"
SKIP_DATES="${ORGANIZED_ABS}/run2.2_mode1_skip_dates.txt"
ORIGINAL_GOOD_DATES="${ORGANIZED_ABS}/organize_mode1_good_dates.txt"
ORIGINAL_SKIP_DATES="${ORGANIZED_ABS}/organize_mode1_skip_dates.txt"
MODE2_SAFE_LIST="${ORGANIZED_ABS}/SAFE_filelist_mode2"
MODE2_INPUT_ERRORS="${ORGANIZED_ABS}/run2.2_mode1_input_errors.txt"
MODE2_MISSING_DATES="${ORGANIZED_ABS}/run2.2_mode1_missing_dates.txt"
MODE2_SUCCESS_DATES="${ORGANIZED_ABS}/run2.2_mode2_success_dates.txt"
MODE2_FAILED_DATES="${ORGANIZED_ABS}/run2.2_mode2_failed_dates.txt"
MODE2_DATE_LOG_DIR="${ORGANIZED_ABS}/run2.2_mode2_date_logs"
MODE2_WORK_ROOT="${ORGANIZED_ABS}/.run2.2_mode2_work"
SUMMARY_LOG="${WORK_DIR}/run2.2_organize_frames.log"

SAFE_SIGNATURE="$(file_signature "${SAFE_LIST}")"
PINS_SIGNATURE="$(file_signature "${PINS_FILE}")"
ORGANIZER_SIGNATURE="$(file_signature "${ORGANIZER_PATH}")"
MODE2_SAFE_SIGNATURE=""
MODE2_SAFE_TOTAL=0
GOOD_FRAME_COUNT=""

if (( EXECUTE == 1 )); then
    [[ -s "${PREVIEW_SUMMARY}" ]] ||
        die "mode=1 preview result not found; run ./run2.2_organize_frames.sh 1 first"

    prepare_mode2_safe_list reuse
    MODE2_SAFE_SIGNATURE="$(file_signature "${MODE2_SAFE_LIST}")"

    GOOD_FRAME_COUNT="$(awk -F: '/Re-organizable frame records/ {gsub(/[[:space:]]/, "", $2); print $2}' "${PREVIEW_SUMMARY}")"
    [[ "${GOOD_FRAME_COUNT}" =~ ^[0-9]+$ ]] ||
        die "cannot parse the saved mode=1 frame count; run preview again"
    (( GOOD_FRAME_COUNT > 0 )) ||
        die "saved mode=1 result contains no re-organizable frames"

    if [[ -s "${PREVIEW_STATE}" ]]; then
        [[ "$(state_value "${PREVIEW_STATE}" safe_list_signature)" == "${SAFE_SIGNATURE}" ]] ||
            die "SAFE_filelist changed after mode=1; run preview again"
        [[ "$(state_value "${PREVIEW_STATE}" pins_signature)" == "${PINS_SIGNATURE}" ]] ||
            die "pins.ll changed after mode=1; run preview again"
        [[ "$(state_value "${PREVIEW_STATE}" organizer_signature)" == "${ORGANIZER_SIGNATURE}" ]] ||
            die "organizer changed after mode=1; run preview again"
        [[ "$(state_value "${PREVIEW_STATE}" direction)" == "${DIRECTION}" ]] ||
            die "direction differs from mode=1; run preview again"
        [[ "$(state_value "${PREVIEW_STATE}" polarization)" == "${POLARIZATION}" ]] ||
            die "polarization differs from mode=1; run preview again"
        [[ "$(state_value "${PREVIEW_STATE}" good_frame_count)" == "${GOOD_FRAME_COUNT}" ]] ||
            die "mode=1 summary and state do not match; run preview again"
        SAVED_MODE2_SIGNATURE="$(state_value "${PREVIEW_STATE}" mode2_safe_signature)"
        if [[ -n "${SAVED_MODE2_SIGNATURE}" && "${SAVED_MODE2_SIGNATURE}" != "${MODE2_SAFE_SIGNATURE}" ]]; then
            die "filtered mode=2 SAFE list changed after mode=1; run preview again"
        fi
    else
        # Compatibility with a mode=1 result made by an older Run 2.2 script.
        [[ ! "${SAFE_LIST}" -nt "${PREVIEW_SUMMARY}" ]] ||
            die "SAFE_filelist is newer than the saved preview; run preview again"
        [[ ! "${PINS_FILE}" -nt "${PREVIEW_SUMMARY}" ]] ||
            die "pins.ll is newer than the saved preview; run preview again"
        [[ ! "${ORGANIZER_PATH}" -nt "${PREVIEW_SUMMARY}" ]] ||
            die "organizer is newer than the saved preview; run preview again"
        printf '[WARN] Preview state file is absent; accepting the existing compatible mode=1 summary.\n'
    fi
fi

{
    printf '%s\n' '========================================'
    printf 'Run 2.2: organize Sentinel-1 TOPS frames\n'
    printf 'Mode           : %s\n' "$([[ "${EXECUTE}" -eq 1 ]] && printf 'EXECUTE' || printf 'PREVIEW')"
    printf 'Work directory : %s\n' "${WORK_DIR}"
    printf 'Organized dir  : %s\n' "${ORGANIZED_ABS}"
    printf 'Direction      : %s\n' "${DIRECTION}"
    printf 'Track          : %s\n' "${TRACK}"
    printf 'SAFE total     : %d\n' "${SAFE_TOTAL}"
    if (( EXECUTE == 1 )); then
        printf 'Mode 2 SAFE   : %d\n' "${MODE2_SAFE_TOTAL}"
    fi
    printf 'Parallel jobs : %d\n' "${JOBS}"
    printf 'Orbit files    : %d\n' "${EOF_TOTAL}"
    printf 'Pins line 1    : %s %s\n' "${LON1}" "${LAT1}"
    printf 'Pins line 2    : %s %s\n' "${LON2}" "${LAT2}"
    printf 'Polarization   : %s\n' "${POLARIZATION}"
    printf 'Organizer      : %s\n' "${ORGANIZER_PATH}"
    printf 'Start time     : %s\n' "$(date '+%F %T')"
    printf '%s\n' '========================================'
} | tee "${SUMMARY_LOG}"

if (( EXECUTE == 0 )); then
    printf '[INFO] Running mode=1 with up to %d dates in parallel.\n' "${JOBS}" | tee -a "${SUMMARY_LOG}"
    run_mode1_parallel

    ORIGINAL_SUMMARY="${ORGANIZED_ABS}/organize_mode1_summary.txt"
    [[ -s "${ORIGINAL_SUMMARY}" ]] || die "mode=1 did not create organize_mode1_summary.txt"
    cp -f -- "${ORIGINAL_SUMMARY}" "${PREVIEW_SUMMARY}"
    GOOD_FRAME_COUNT="$(awk -F: '/Re-organizable frame records/ {gsub(/[[:space:]]/, "", $2); print $2}' "${PREVIEW_SUMMARY}")"
    [[ "${GOOD_FRAME_COUNT}" =~ ^[0-9]+$ ]] || die "cannot parse re-organizable frame count"

    printf '[INFO] Re-organizable frame records: %d\n' "${GOOD_FRAME_COUNT}" | tee -a "${SUMMARY_LOG}"
    (( GOOD_FRAME_COUNT > 0 )) || die "no frames can be reorganized with the current pins.ll"

    prepare_mode2_safe_list refresh
    MODE2_SAFE_SIGNATURE="$(file_signature "${MODE2_SAFE_LIST}")"
    GOOD_DATE_TOTAL="$(wc -l < "${GOOD_DATES}" | awk '{print $1}')"
    SKIP_DATE_TOTAL="$(wc -l < "${SKIP_DATES}" | awk '{print $1}')"
    printf '[INFO] Good dates saved       : %d\n' "${GOOD_DATE_TOTAL}" | tee -a "${SUMMARY_LOG}"
    printf '[INFO] Skipped dates saved    : %d\n' "${SKIP_DATE_TOTAL}" | tee -a "${SUMMARY_LOG}"
    printf '[INFO] SAFE selected for mode2: %d\n' "${MODE2_SAFE_TOTAL}" | tee -a "${SUMMARY_LOG}"

    PREVIEW_STATE_TMP="$(mktemp "${PREVIEW_STATE}.tmp.XXXXXX")" ||
        die "cannot create preview state file"
    {
        printf 'version=1\n'
        printf 'safe_list_signature=%s\n' "${SAFE_SIGNATURE}"
        printf 'pins_signature=%s\n' "${PINS_SIGNATURE}"
        printf 'organizer_signature=%s\n' "${ORGANIZER_SIGNATURE}"
        printf 'mode2_safe_signature=%s\n' "${MODE2_SAFE_SIGNATURE}"
        printf 'direction=%s\n' "${DIRECTION}"
        printf 'polarization=%s\n' "${POLARIZATION}"
        printf 'good_frame_count=%s\n' "${GOOD_FRAME_COUNT}"
    } > "${PREVIEW_STATE_TMP}"
    mv -f -- "${PREVIEW_STATE_TMP}" "${PREVIEW_STATE}"

    printf '[OK] Run 2.2 preview passed; inspect %s\n' "${PREVIEW_SUMMARY}" | tee -a "${SUMMARY_LOG}"
    printf '[NEXT] Run ./run2.2_organize_frames.sh 2 to start mode=2 directly\n' | tee -a "${SUMMARY_LOG}"
    exit 0
fi

printf '[INFO] Using saved mode=1 result: %d re-organizable frame records\n' "${GOOD_FRAME_COUNT}" | tee -a "${SUMMARY_LOG}"
printf '[INFO] Starting mode=2 by date from %s\n' "${MODE2_SAFE_LIST}" | tee -a "${SUMMARY_LOG}"
printf '[INFO] Each date uses an isolated work directory; one failed date will not contaminate later dates.\n' | tee -a "${SUMMARY_LOG}"
printf '[INFO] Running up to %d dates in parallel.\n' "${JOBS}" | tee -a "${SUMMARY_LOG}"

mkdir -p -- "${MODE2_DATE_LOG_DIR}" "${MODE2_WORK_ROOT}"
for STALE_WORK in "${MODE2_WORK_ROOT}"/*; do
    [[ -e "${STALE_WORK}" ]] || continue
    rm -rf -- "${STALE_WORK}"
done
[[ -f "${MODE2_SUCCESS_DATES}" ]] || : > "${MODE2_SUCCESS_DATES}"
FAILED_TMP="$(mktemp "${MODE2_FAILED_DATES}.tmp.XXXXXX")" || die "cannot create failed-date file"
DATE_LIST_TMP="$(mktemp "${MODE2_SAFE_LIST}.dates.XXXXXX")" || die "cannot create mode=2 date list"
while IFS= read -r SAFE_PATH; do
    extract_safe_date "${SAFE_PATH}"
done < "${MODE2_SAFE_LIST}" | sort -u > "${DATE_LIST_TMP}"

TOTAL_MODE2_DATES="$(wc -l < "${DATE_LIST_TMP}" | awk '{print $1}')"
(( TOTAL_MODE2_DATES > 0 )) || die "mode=2 date list is empty"
: > "${EXECUTE_LOG}"
MODE2_SUCCEEDED=0
MODE2_SKIPPED=0
MODE2_FAILED=0
MODE2_INDEX=0

process_mode2_date() {
    local MODE2_DATE="$1"
    local MODE2_INDEX="$2"
    local DATE_WORK DATE_SAFE_LIST DATE_LOG SAFE_PATH SAFE_DATE_VALUE ORBIT_PATH
    local DATE_STATUS DATE_FAILURE_REASON FRAME_OUTPUT_COUNT OUTPUT_SAFE_COUNT
    local FRAME_PATH NEW_SAFE DEST_SAFE DEST_FRAME ORBIT_DEST iw xml_count tiff_count

    if date_output_exists "${MODE2_DATE}" && date_output_is_valid "${MODE2_DATE}"; then
        printf '%s\n' "${MODE2_DATE}" >> "${MODE2_SUCCESS_DATES}"
        printf '[SKIP %d/%d] %s already has validated frame output\n' "${MODE2_INDEX}" "${TOTAL_MODE2_DATES}" "${MODE2_DATE}" | tee -a "${EXECUTE_LOG}"
        return 0
    fi

    DATE_WORK="${MODE2_WORK_ROOT}/${MODE2_DATE}.$$"
    DATE_SAFE_LIST="${DATE_WORK}/SAFE_filelist_date"
    DATE_LOG="${MODE2_DATE_LOG_DIR}/${MODE2_DATE}.log"
    mkdir -p -- "${DATE_WORK}"

    while IFS= read -r SAFE_PATH; do
        SAFE_DATE_VALUE="$(extract_safe_date "${SAFE_PATH}")" || continue
        [[ "${SAFE_DATE_VALUE}" == "${MODE2_DATE}" ]] && printf '%s\n' "${SAFE_PATH}" >> "${DATE_SAFE_LIST}"
    done < "${MODE2_SAFE_LIST}"

    if [[ ! -s "${DATE_SAFE_LIST}" ]]; then
        printf '%s\t%s\t%s\n' "${MODE2_DATE}" "empty_date_safe_list" "${DATE_LOG}" >> "${FAILED_TMP}"
        printf '[FAILED %d/%d] %s: empty per-date SAFE list\n' "${MODE2_INDEX}" "${TOTAL_MODE2_DATES}" "${MODE2_DATE}" | tee -a "${EXECUTE_LOG}"
        rm -rf -- "${DATE_WORK}"
        return 0
    fi

    for ORBIT_PATH in "${ORGANIZED_ABS}"/*.EOF; do
        [[ -f "${ORBIT_PATH}" ]] || continue
        ln -s -- "${ORBIT_PATH}" "${DATE_WORK}/$(basename -- "${ORBIT_PATH}")"
    done

    printf '[START %d/%d] %s (%s SAFE)\n' "${MODE2_INDEX}" "${TOTAL_MODE2_DATES}" "${MODE2_DATE}" "$(wc -l < "${DATE_SAFE_LIST}" | awk '{print $1}')" | tee -a "${EXECUTE_LOG}"
    set +e
    (
        cd -- "${DATE_WORK}"
        "${ORGANIZER_PATH}" "${DATE_SAFE_LIST}" "${PINS_FILE}" 2 "${POLARIZATION}"
    ) > "${DATE_LOG}" 2>&1
    DATE_STATUS=$?
    set -e

    DATE_FAILURE_REASON=""
    if (( DATE_STATUS != 0 )); then
        DATE_FAILURE_REASON="organizer_exit_${DATE_STATUS}"
    elif mode2_log_has_critical_errors "${DATE_LOG}"; then
        DATE_FAILURE_REASON="critical_error_in_log"
    elif ! grep -Eq 'Created Frame F[0-9][0-9][0-9][0-9] - F[0-9][0-9][0-9][0-9]' "${DATE_LOG}"; then
        DATE_FAILURE_REASON="no_valid_created_frame_message"
    fi

    FRAME_OUTPUT_COUNT=0
    OUTPUT_SAFE_COUNT=0
    if [[ -z "${DATE_FAILURE_REASON}" ]]; then
        for FRAME_PATH in "${DATE_WORK}"/F????_F????; do
            [[ -d "${FRAME_PATH}" ]] || continue
            FRAME_OUTPUT_COUNT=$((FRAME_OUTPUT_COUNT + 1))
            for NEW_SAFE in "${FRAME_PATH}"/*.SAFE; do
                [[ -d "${NEW_SAFE}" ]] || continue
                OUTPUT_SAFE_COUNT=$((OUTPUT_SAFE_COUNT + 1))
                for iw in 1 2 3; do
                    xml_count="$(find "${NEW_SAFE}/annotation" -maxdepth 1 -type f -iname "*iw${iw}*${POLARIZATION}*.xml" -print 2>/dev/null | wc -l | awk '{print $1}')"
                    tiff_count="$(find "${NEW_SAFE}/measurement" -maxdepth 1 -type f -iname "*iw${iw}*${POLARIZATION}*.tiff" -print 2>/dev/null | wc -l | awk '{print $1}')"
                    if [[ "${xml_count}" -ne 1 || "${tiff_count}" -ne 1 ]]; then
                        DATE_FAILURE_REASON="invalid_output_IW${iw}_$(basename -- "${NEW_SAFE}")"
                    fi
                done
                DEST_SAFE="${ORGANIZED_ABS}/$(basename -- "${FRAME_PATH}")/$(basename -- "${NEW_SAFE}")"
                if [[ -e "${DEST_SAFE}" ]]; then
                    DATE_FAILURE_REASON="output_collision_$(basename -- "${NEW_SAFE}")"
                fi
            done
        done
        (( FRAME_OUTPUT_COUNT > 0 )) || DATE_FAILURE_REASON="no_frame_directory"
        (( OUTPUT_SAFE_COUNT > 0 )) || DATE_FAILURE_REASON="no_safe_output"
    fi

    if [[ -n "${DATE_FAILURE_REASON}" ]]; then
        {
            printf '\n[RUN2.2] Failure reason: %s\n' "${DATE_FAILURE_REASON}"
            printf '[RUN2.2] Work-directory listing before cleanup:\n'
            find "${DATE_WORK}" -maxdepth 2 -print
        } >> "${DATE_LOG}" 2>&1
        printf '%s\t%s\t%s\n' "${MODE2_DATE}" "${DATE_FAILURE_REASON}" "${DATE_LOG}" >> "${FAILED_TMP}"
        printf '[FAILED %d/%d] %s: %s (log: %s)\n' "${MODE2_INDEX}" "${TOTAL_MODE2_DATES}" "${MODE2_DATE}" "${DATE_FAILURE_REASON}" "${DATE_LOG}" | tee -a "${EXECUTE_LOG}"
        rm -rf -- "${DATE_WORK}"
        return 0
    fi

    for FRAME_PATH in "${DATE_WORK}"/F????_F????; do
        [[ -d "${FRAME_PATH}" ]] || continue
        DEST_FRAME="${ORGANIZED_ABS}/$(basename -- "${FRAME_PATH}")"
        mkdir -p -- "${DEST_FRAME}"
        for NEW_SAFE in "${FRAME_PATH}"/*.SAFE; do
            [[ -d "${NEW_SAFE}" ]] || continue
            mv -- "${NEW_SAFE}" "${DEST_FRAME}/"
        done
    done

    for ORBIT_PATH in "${DATE_WORK}"/*.EOF; do
        [[ -f "${ORBIT_PATH}" && ! -L "${ORBIT_PATH}" ]] || continue
        ORBIT_DEST="${ORGANIZED_ABS}/$(basename -- "${ORBIT_PATH}")"
        [[ -e "${ORBIT_DEST}" ]] || cp -- "${ORBIT_PATH}" "${ORBIT_DEST}"
    done

    printf '%s\n' "${MODE2_DATE}" >> "${MODE2_SUCCESS_DATES}"
    printf '[DONE %d/%d] %s: %d SAFE output in %d frame directories\n' "${MODE2_INDEX}" "${TOTAL_MODE2_DATES}" "${MODE2_DATE}" "${OUTPUT_SAFE_COUNT}" "${FRAME_OUTPUT_COUNT}" | tee -a "${EXECUTE_LOG}"
    rm -rf -- "${DATE_WORK}"
    return 0
}

WORKER_PIDS=()
WORKER_DATES=()

wait_for_worker_batch() {
    local worker_index worker_pid worker_date
    for ((worker_index = 0; worker_index < ${#WORKER_PIDS[@]}; worker_index++)); do
        worker_pid="${WORKER_PIDS[worker_index]}"
        worker_date="${WORKER_DATES[worker_index]}"
        if ! wait "${worker_pid}"; then
            printf '%s\t%s\t%s\n' "${worker_date}" "worker_process_failed" "${MODE2_DATE_LOG_DIR}/${worker_date}.log" >> "${FAILED_TMP}"
            printf '[FAILED] %s: worker process terminated unexpectedly\n' "${worker_date}" | tee -a "${EXECUTE_LOG}"
        fi
    done
    WORKER_PIDS=()
    WORKER_DATES=()
}

while IFS= read -r MODE2_DATE; do
    [[ -n "${MODE2_DATE}" ]] || continue
    MODE2_INDEX=$((MODE2_INDEX + 1))
    process_mode2_date "${MODE2_DATE}" "${MODE2_INDEX}" &
    WORKER_PIDS+=("$!")
    WORKER_DATES+=("${MODE2_DATE}")
    if (( ${#WORKER_PIDS[@]} >= JOBS )); then
        wait_for_worker_batch
    fi
done < "${DATE_LIST_TMP}"

if (( ${#WORKER_PIDS[@]} > 0 )); then
    wait_for_worker_batch
fi

sort -u -o "${MODE2_SUCCESS_DATES}" -- "${MODE2_SUCCESS_DATES}"
MODE2_SUCCEEDED="$(grep -c '^\[DONE' "${EXECUTE_LOG}" || true)"
MODE2_SKIPPED="$(grep -c '^\[SKIP' "${EXECUTE_LOG}" || true)"
MODE2_FAILED="$(wc -l < "${FAILED_TMP}" | awk '{print $1}')"

mv -f -- "${FAILED_TMP}" "${MODE2_FAILED_DATES}"
rm -f -- "${DATE_LIST_TMP}"
FRAME_TOTAL="$(find "${ORGANIZED_ABS}" -mindepth 1 -maxdepth 1 -type d -name 'F????_F????' -print | wc -l | awk '{print $1}')"

{
    printf '%s\n' '========================================'
    printf 'Run 2.2 mode=2 final validation\n'
    printf 'Dates total      : %d\n' "${TOTAL_MODE2_DATES}"
    printf 'Dates succeeded  : %d\n' "${MODE2_SUCCEEDED}"
    printf 'Dates skipped    : %d\n' "${MODE2_SKIPPED}"
    printf 'Dates failed     : %d\n' "${MODE2_FAILED}"
    printf 'Frame directories: %d\n' "${FRAME_TOTAL}"
    printf 'Success list     : %s\n' "${MODE2_SUCCESS_DATES}"
    printf 'Failed list      : %s\n' "${MODE2_FAILED_DATES}"
    printf 'Execute log      : %s\n' "${EXECUTE_LOG}"
    printf 'Finish time      : %s\n' "$(date '+%F %T')"
    printf '%s\n' '========================================'
} | tee -a "${SUMMARY_LOG}" "${EXECUTE_LOG}"

(( MODE2_FAILED == 0 )) || die "${MODE2_FAILED} dates failed; inspect ${MODE2_FAILED_DATES}"
(( MODE2_SUCCEEDED + MODE2_SKIPPED == TOTAL_MODE2_DATES )) || die "mode=2 date accounting mismatch"
(( FRAME_TOTAL > 0 )) || die "no F????_F???? frame directories are available"

printf '[OK] Run 2.2 mode=2 completed successfully\n' | tee -a "${SUMMARY_LOG}" "${EXECUTE_LOG}"
