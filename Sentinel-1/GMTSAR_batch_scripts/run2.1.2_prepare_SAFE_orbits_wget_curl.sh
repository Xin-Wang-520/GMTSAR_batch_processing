#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Contact: xinw11@mail.ustc.edu.cn
# Citation: Xin Wang et al. (2026), Near instantaneously triggered Mw 5.9 aftershock during the 2025 Mw 7.1 Dingri earthquake revealed by radar interferometry, Earth and Planetary Science Letters, 686, 120070.
# Run 2.1.2 wget/curl: standalone SAFE-list preparation and robust orbit download
# Last updated: September 26, 2026

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

WGET_LIMIT_SECONDS="${RUN212_WGET_LIMIT_SECONDS:-30}"
CURL_LIMIT_SECONDS="${RUN212_CURL_LIMIT_SECONDS:-30}"
INDEX_CACHE_DAYS="${RUN212_INDEX_CACHE_DAYS:-7}"
MAX_RETRY_PASSES="${RUN212_MAX_RETRY_PASSES:-5}"
RETRY_DELAY_SECONDS="${RUN212_RETRY_DELAY_SECONDS:-5}"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：
  ./run2.1.2_prepare_SAFE_orbits_wget_curl.sh [选项]       # 只检查和预览
  ./run2.1.2_prepare_SAFE_orbits_wget_curl.sh 1 [选项]     # 后台处理全部日期
  ./run2.1.2_prepare_SAFE_orbits_wget_curl.sh 2 [选项]     # 自动重试上次失败日期

在 InSAR_processing/Descending/T*/、InSAR_processing/Ascending/T*/ 或
InSAR_processing/T*/ 中运行：创建 organized/、生成 SAFE_filelist，并在脚本
内部先用 wget 下载；wget 失败或 ZIP 损坏时自动改用 curl。
成功下载的月份轨道索引会在 organized/ 中缓存7天，补跑时优先复用。
模式2最多自动执行5轮；全部成功时提前结束。

选项：
  --mode 1|2           1=POEORB 精密轨道（默认），2=RESORB 快速轨道
  --source-safe DIR    清理后 SAFE 来源目录
  --direction DIR      Ascending 或 Descending；路径中没有方向时可明确指定
  --organized-dir DIR  输出目录（默认：organized）
  --foreground         正式模式在前台运行（用于排错）
  -h, --help           显示帮助
EOF
}

fetch_index() {
    local url="$1"
    local output="$2"
    local temporary="${output}.part"
    local now modified age_seconds cache_limit_seconds

    cache_limit_seconds=$((INDEX_CACHE_DAYS * 86400))
    if [[ -s "${output}" ]] && grep -q '\.EOF\.zip' "${output}"; then
        now="$(date +%s)"
        modified="$(stat -c '%Y' "${output}" 2>/dev/null || printf '0')"
        age_seconds=$((now - modified))
        if (( age_seconds >= 0 && age_seconds <= cache_limit_seconds )); then
            printf '[INDEX/CACHE] Reuse %s (age %d day(s))\n' \
                "${output}" "$((age_seconds / 86400))"
            return 0
        fi
        printf '[INDEX/CACHE] %s is older than %d day(s); try to refresh\n' \
            "${output}" "${INDEX_CACHE_DAYS}"
    fi

    rm -f -- "${temporary}"
    printf '[INDEX/WGET] %s\n' "${url}"
    if timeout "${WGET_LIMIT_SECONDS}s" \
        wget --timeout=30 --read-timeout=30 --tries=1 -q \
        -O "${temporary}" "${url}" && [[ -s "${temporary}" ]]; then
        mv -f -- "${temporary}" "${output}"
        return 0
    fi

    rm -f -- "${temporary}"
    printf '[INDEX/CURL] wget failed; retry with curl\n'
    if timeout "${CURL_LIMIT_SECONDS}s" \
        curl -fLsS --retry 0 --connect-timeout 30 \
        --max-time "${CURL_LIMIT_SECONDS}" -o "${temporary}" "${url}" && \
        [[ -s "${temporary}" ]]; then
        mv -f -- "${temporary}" "${output}"
        return 0
    fi

    rm -f -- "${temporary}"
    if [[ -s "${output}" ]] && grep -q '\.EOF\.zip' "${output}"; then
        printf '[INDEX/CACHE] Network refresh failed; use stale cache %s\n' "${output}"
        return 0
    fi
    return 1
}

fetch_orbit_zip() {
    local url="$1"
    local output="$2"
    local temporary="${output}.part"

    rm -f -- "${temporary}"
    printf '[ORBIT/WGET] %s\n' "${url}"
    if timeout "${WGET_LIMIT_SECONDS}s" \
        wget --timeout=30 --read-timeout=30 --tries=1 \
        -O "${temporary}" "${url}" && \
        unzip -tq "${temporary}" >/dev/null 2>&1; then
        mv -f -- "${temporary}" "${output}"
        return 0
    fi

    rm -f -- "${temporary}"
    printf '[ORBIT/CURL] wget failed or ZIP validation failed; retry with curl\n'
    if timeout "${CURL_LIMIT_SECONDS}s" \
        curl -fL --retry 0 --connect-timeout 30 \
        --max-time "${CURL_LIMIT_SECONDS}" -o "${temporary}" "${url}" && \
        unzip -tq "${temporary}" >/dev/null 2>&1; then
        mv -f -- "${temporary}" "${output}"
        return 0
    fi

    rm -f -- "${temporary}" "${output}"
    return 1
}

compact_to_epoch() {
    local value="$1"
    date -d "${value:0:4}-${value:4:2}-${value:6:2} ${value:9:2}:${value:11:2}:${value:13:2} UTC" +%s
}

download_orbits() {
    local safe_list="$1"
    local mode="$2"
    local failure_list="$3"
    local failures=0
    local safe_path safe sat start_token stop_token date1 year month n1 n2
    local orbit_type url index orbit file key candidate cstart cend desired_start desired_end
    local candidate_start candidate_end
    declare -A processed=()
    declare -A index_ready=()

    : > "${failure_list}"

    while IFS= read -r safe_path; do
        safe="${safe_path##*/}"
        [[ "${safe}" == *.SAFE ]] || continue

        IFS='_' read -r sat _ _ _ _ start_token stop_token _ <<< "${safe}"
        date1="${start_token:0:8}"
        if [[ ! "${sat}" =~ ^S1[ABC]$ || ! "${date1}" =~ ^[0-9]{8}$ ]]; then
            printf '[ERROR] Cannot parse SAFE name: %s\n' "${safe}"
            printf 'UNKNOWN\t%s\tparse_SAFE_name\n' "${safe_path}" >> "${failure_list}"
            failures=$((failures + 1))
            continue
        fi

        key="${sat}_${date1}_${mode}"
        [[ -n "${processed[${key}]:-}" ]] && continue
        processed["${key}"]=1

        printf '\n----------------------------------------\n'
        printf 'Finding orbit for %s\n' "${safe}"

        if [[ "${mode}" == "1" ]]; then
            orbit_type="POEORB"
            n1="$(date -d "${date1} -1 day" +%Y%m%d)"
            n2="$(date -d "${date1} +1 day" +%Y%m%d)"
            year="${n1:0:4}"
            month="${n1:4:2}"
            printf 'Required orbit dates: %s to %s\n' "${n1}" "${n2}"

            file="$(find . -maxdepth 1 -type f -name "${sat}_OPER_AUX_POEORB_OPOD_*_V${n1}T*_${n2}T*.EOF" -print -quit)"
            if [[ -n "${file}" && -s "${file}" ]]; then
                printf 'Orbit already exists: %s -> skip\n' "${file#./}"
                continue
            fi

            url="https://step.esa.int/auxdata/orbits/Sentinel-1/${orbit_type}/${sat}/${year}/${month}/"
            index="tmp_orbit_${orbit_type}_${sat}_${year}${month}.html"
            if [[ -z "${index_ready[${index}]:-}" ]]; then
                if ! fetch_index "${url}" "${index}"; then
                    printf '[ERROR] Cannot download orbit index: %s\n' "${url}"
                    printf '%s\t%s\tindex_download_failed\n' "${date1}" "${safe_path}" >> "${failure_list}"
                    failures=$((failures + 1))
                    continue
                fi
                index_ready["${index}"]=1
            fi

            orbit="$(grep -oE 'href="[^"]+\.EOF\.zip"' "${index}" | \
                sed 's/^href="//;s/"$//' | \
                grep "${sat}_OPER_AUX_POEORB_OPOD_" | \
                grep "V${n1}T" | grep "_${n2}T" | head -n 1 || true)"
        else
            orbit_type="RESORB"
            year="${date1:0:4}"
            month="${date1:4:2}"
            url="https://step.esa.int/auxdata/orbits/Sentinel-1/${orbit_type}/${sat}/${year}/${month}/"
            index="tmp_orbit_${orbit_type}_${sat}_${year}${month}.html"
            if [[ -z "${index_ready[${index}]:-}" ]]; then
                if ! fetch_index "${url}" "${index}"; then
                    printf '[ERROR] Cannot download orbit index: %s\n' "${url}"
                    printf '%s\t%s\tindex_download_failed\n' "${date1}" "${safe_path}" >> "${failure_list}"
                    failures=$((failures + 1))
                    continue
                fi
                index_ready["${index}"]=1
            fi

            desired_start=$(( $(compact_to_epoch "${start_token}") - 3000 ))
            desired_end=$(( $(compact_to_epoch "${stop_token}") + 3000 ))
            orbit=""
            while IFS= read -r candidate; do
                if [[ "${candidate}" =~ _V([0-9]{8}T[0-9]{6})_([0-9]{8}T[0-9]{6})\.EOF\.zip$ ]]; then
                    cstart="${BASH_REMATCH[1]}"
                    cend="${BASH_REMATCH[2]}"
                    candidate_start="$(compact_to_epoch "${cstart}")"
                    candidate_end="$(compact_to_epoch "${cend}")"
                    if (( candidate_start <= desired_start && candidate_end >= desired_end )); then
                        orbit="${candidate}"
                        break
                    fi
                fi
            done < <(grep -oE 'href="[^"]+\.EOF\.zip"' "${index}" | \
                sed 's/^href="//;s/"$//' | grep "${sat}_OPER_AUX_RESORB_OPOD_" || true)
        fi

        if [[ -z "${orbit}" ]]; then
            printf '[ERROR] No matching %s orbit found for %s\n' "${orbit_type}" "${date1}"
            printf '%s\t%s\tno_matching_%s\n' "${date1}" "${safe_path}" "${orbit_type}" >> "${failure_list}"
            failures=$((failures + 1))
            continue
        fi

        file="${orbit%.zip}"
        if [[ -s "${file}" ]]; then
            printf 'Orbit already exists: %s -> skip\n' "${file}"
            continue
        fi

        if [[ -s "${orbit}" ]]; then
            if unzip -tq "${orbit}" >/dev/null 2>&1; then
                printf 'Valid ZIP already exists: %s\n' "${orbit}"
            else
                printf '[CLEAN] Remove incomplete ZIP: %s\n' "${orbit}"
                rm -f -- "${orbit}"
            fi
        fi

        if [[ ! -s "${orbit}" ]] && ! fetch_orbit_zip "${url}${orbit}" "${orbit}"; then
            printf '[ERROR] Failed to download orbit: %s\n' "${orbit}"
            printf '%s\t%s\torbit_download_failed\n' "${date1}" "${safe_path}" >> "${failure_list}"
            failures=$((failures + 1))
            continue
        fi

        if unzip -oq "${orbit}" "${file}" && [[ -s "${file}" ]]; then
            rm -f -- "${orbit}"
            printf '[OK] %s\n' "${file}"
        else
            printf '[ERROR] Failed to unzip orbit: %s\n' "${orbit}"
            printf '%s\t%s\torbit_unzip_failed\n' "${date1}" "${safe_path}" >> "${failure_list}"
            failures=$((failures + 1))
        fi
    done < "${safe_list}"

    # Keep successful monthly index pages for later mode-2 retries.  Only
    # incomplete temporary downloads are disposable.
    rm -f -- tmp_orbit_POEORB_*.html.part tmp_orbit_RESORB_*.html.part \
        2>/dev/null || true
    (( failures == 0 ))
}

ORIGINAL_ARGS=("$@")
RUN_FORMAL=0
RETRY_FAILED_ONLY=0
RUN_FOREGROUND=0
ORBIT_MODE=1
SOURCE_SAFE=""
DIRECTION_OPTION=""
ORGANIZED_DIR="organized"
DATA_ROOT="${RUN212_WGET_CURL_DATA_ROOT:-${RUN21_DATA_ROOT:-/data2/xinw}}"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        1|2)
            (( RUN_FORMAL == 0 )) || die "run selection was specified more than once"
            RUN_FORMAL=1
            [[ "$1" == "2" ]] && RETRY_FAILED_ONLY=1
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
        --direction)
            [[ "$#" -ge 2 ]] || die "--direction requires Ascending or Descending"
            DIRECTION_OPTION="$2"
            shift 2
            ;;
        --organized-dir)
            [[ "$#" -ge 2 ]] || die "--organized-dir requires a directory"
            ORGANIZED_DIR="$2"
            shift 2
            ;;
        --foreground)
            RUN_FOREGROUND=1
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

[[ "${ORBIT_MODE}" == "1" || "${ORBIT_MODE}" == "2" ]] || die "--mode must be 1 or 2"
[[ "${INDEX_CACHE_DAYS}" =~ ^[0-9]+$ ]] ||
    die "RUN212_INDEX_CACHE_DAYS must be a non-negative integer"
[[ "${MAX_RETRY_PASSES}" =~ ^[1-9][0-9]*$ ]] ||
    die "RUN212_MAX_RETRY_PASSES must be a positive integer"
[[ "${RETRY_DELAY_SECONDS}" =~ ^[0-9]+$ ]] ||
    die "RUN212_RETRY_DELAY_SECONDS must be a non-negative integer"
[[ -z "${DIRECTION_OPTION}" || "${DIRECTION_OPTION}" == "Ascending" || \
   "${DIRECTION_OPTION}" == "Descending" ]] ||
    die "--direction must be Ascending or Descending"

for command_name in find sort awk grep sed wget curl unzip date stat wc tee timeout; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "cannot find command: ${command_name}"
done

WORK_DIR="$(pwd -P)"
TRACK="$(basename -- "${WORK_DIR}")"
PARENT_NAME="$(basename -- "$(dirname -- "${WORK_DIR}")")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number directory (current: ${WORK_DIR})"

if [[ -n "${DIRECTION_OPTION}" ]]; then
    DIRECTION="${DIRECTION_OPTION}"
elif [[ "${PARENT_NAME}" == "Ascending" || "${PARENT_NAME}" == "Descending" ]]; then
    DIRECTION="${PARENT_NAME}"
else
    DIRECTION="AUTO"
fi

if [[ -z "${SOURCE_SAFE}" ]]; then
    if [[ "${DIRECTION}" == "AUTO" ]]; then
        SEARCH_DIRECTIONS=(Ascending Descending)
    else
        SEARCH_DIRECTIONS=("${DIRECTION}")
    fi

    SAFE_CANDIDATES=()
    CHECKED_CANDIDATES=()
    for data_name in HMF_Sentinel_data HMF_Sentinel1_data; do
        for candidate_direction in "${SEARCH_DIRECTIONS[@]}"; do
            candidate="${DATA_ROOT}/${data_name}/${candidate_direction}/${TRACK}/${TRACK}_SAFE"
            CHECKED_CANDIDATES+=("${candidate}")
            if [[ -d "${candidate}" ]]; then
                SAFE_CANDIDATES+=("${candidate}")
            fi
        done
    done

    if (( ${#SAFE_CANDIDATES[@]} == 0 )); then
        printf '[ERROR] SAFE source directory was not found. Checked:\n' >&2
        printf '  %s\n' "${CHECKED_CANDIDATES[@]}" >&2
        printf '[HINT] Specify it explicitly with --source-safe DIR.\n' >&2
        exit 1
    elif (( ${#SAFE_CANDIDATES[@]} > 1 )); then
        printf '[ERROR] Multiple SAFE source directories were found:\n' >&2
        printf '  %s\n' "${SAFE_CANDIDATES[@]}" >&2
        printf '[HINT] Select one with --source-safe DIR or --direction Ascending|Descending.\n' >&2
        exit 1
    fi

    SOURCE_SAFE="${SAFE_CANDIDATES[0]}"
fi

[[ -d "${SOURCE_SAFE}" ]] || die "SAFE source directory not found: ${SOURCE_SAFE}"
SOURCE_SAFE="$(cd -- "${SOURCE_SAFE}" && pwd -P)"

if [[ "${DIRECTION}" == "AUTO" ]]; then
    case "/${SOURCE_SAFE}/" in
        */Ascending/*) DIRECTION="Ascending" ;;
        */Descending/*) DIRECTION="Descending" ;;
        *) DIRECTION="not specified" ;;
    esac
fi

if [[ "${ORGANIZED_DIR}" = /* ]]; then
    ORGANIZED_ABS="${ORGANIZED_DIR}"
else
    ORGANIZED_ABS="${WORK_DIR}/${ORGANIZED_DIR}"
fi
SAFE_LIST="${ORGANIZED_ABS}/SAFE_filelist"
RETRY_SAFE_LIST="${ORGANIZED_ABS}/SAFE_filelist_retry_failed"
FAILURE_LIST="${ORGANIZED_ABS}/run2.1.2_failed_orbit_dates.tsv"
ORBIT_LOG="${ORGANIZED_ABS}/run2.1.2_wget_curl_orbit_download.log"
SUMMARY_LOG="${WORK_DIR}/run2.1.2_prepare_SAFE_orbits_wget_curl.log"

if (( RETRY_FAILED_ONLY == 1 )) && [[ ! -e "${FAILURE_LIST}" ]]; then
    die "failed-date list not found: ${FAILURE_LIST}; run mode 1 first"
fi
if (( RETRY_FAILED_ONLY == 1 )) && [[ ! -s "${FAILURE_LIST}" ]]; then
    printf '[DONE] The failed-date list is empty; no orbit needs to be downloaded.\n'
    exit 0
fi

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
printf 'Run 2.1.2 wget/curl: prepare SAFE list and Sentinel-1 orbits\n'
if (( RUN_FORMAL == 0 )); then
    RUN_DESCRIPTION="PREVIEW ONLY"
elif (( RETRY_FAILED_ONLY == 1 )); then
    RUN_DESCRIPTION="RETRY FAILED DATES"
else
    RUN_DESCRIPTION="FORMAL ALL DATES"
fi
printf 'Run mode       : %s\n' "${RUN_DESCRIPTION}"
printf 'Work directory : %s\n' "${WORK_DIR}"
printf 'Track          : %s\n' "${TRACK}"
printf 'Direction      : %s\n' "${DIRECTION}"
printf 'SAFE source    : %s\n' "${SOURCE_SAFE}"
printf 'SAFE total     : %d\n' "${SAFE_TOTAL}"
printf 'Organized dir  : %s\n' "${ORGANIZED_ABS}"
printf 'SAFE list      : %s\n' "${SAFE_LIST}"
printf 'Failed list    : %s\n' "${FAILURE_LIST}"
printf 'Orbit log      : %s\n' "${ORBIT_LOG}"
printf 'Existing list  : %s\n' "${EXISTING_LIST}"
printf 'Existing EOF   : %d\n' "${EXISTING_EOF}"
printf 'Orbit mode     : %s (%s)\n' "${ORBIT_MODE}" \
    "$([[ ${ORBIT_MODE} == 1 ]] && printf POEORB || printf RESORB)"
printf 'Downloader     : internal wget -> curl fallback\n'
printf 'Timeout policy : wget %ss + curl %ss, then skip date\n' \
    "${WGET_LIMIT_SECONDS}" "${CURL_LIMIT_SECONDS}"
printf 'Index cache    : reuse for %d day(s); stale fallback on network failure\n' \
    "${INDEX_CACHE_DAYS}"
if (( RETRY_FAILED_ONLY == 1 )); then
    printf 'Auto retries   : up to %d pass(es), %ss between retry passes\n' \
        "${MAX_RETRY_PASSES}" "${RETRY_DELAY_SECONDS}"
fi
printf '%s\n' '========================================'

if (( RUN_FORMAL == 0 )); then
    usage
    printf '[CHECK ONLY] No directory, SAFE list, log, lock or orbit file was created or modified.\n'
    printf '[NEXT] Formal run with the default POEORB mode:\n'
    printf '  ./run2.1.2_prepare_SAFE_orbits_wget_curl.sh 1\n'
    printf '[RETRY] Retry only the failed dates from the previous run:\n'
    printf '  ./run2.1.2_prepare_SAFE_orbits_wget_curl.sh 2\n'
    printf '[OPTION] Formal RESORB run:\n'
    printf '  ./run2.1.2_prepare_SAFE_orbits_wget_curl.sh 1 --mode 2\n'
    exit 0
fi

# Formal mode is detached by default. The child receives an environment flag
# so that it runs the processing body instead of spawning itself again.
if (( RUN_FOREGROUND == 0 )) && [[ "${RUN212_WGET_CURL_BACKGROUND_CHILD:-0}" != "1" ]]; then
    SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
    BACKGROUND_LOG="${WORK_DIR}/run2.1.2_prepare_SAFE_orbits_wget_curl.nohup.log"
    nohup env RUN212_WGET_CURL_BACKGROUND_CHILD=1 \
        "${SCRIPT_PATH}" "${ORIGINAL_ARGS[@]}" \
        </dev/null >"${BACKGROUND_LOG}" 2>&1 &
    BACKGROUND_PID=$!
    printf '[BACKGROUND] Run 2.1.2 wget/curl started successfully.\n'
    printf 'PID            : %d\n' "${BACKGROUND_PID}"
    printf 'Wrapper log    : %s\n' "${BACKGROUND_LOG}"
    printf 'Orbit log      : %s\n' "${ORBIT_LOG}"
    printf '[MONITOR] tail -f %q\n' "${ORBIT_LOG}"
    printf '[NOTE] Ctrl+C in this terminal will not stop the background task.\n'
    exit 0
fi

mkdir -p -- "${ORGANIZED_ABS}"
ORGANIZED_ABS="$(cd -- "${ORGANIZED_ABS}" && pwd -P)"
SAFE_LIST="${ORGANIZED_ABS}/SAFE_filelist"
RETRY_SAFE_LIST="${ORGANIZED_ABS}/SAFE_filelist_retry_failed"
FAILURE_LIST="${ORGANIZED_ABS}/run2.1.2_failed_orbit_dates.tsv"
ORBIT_LOG="${ORGANIZED_ABS}/run2.1.2_wget_curl_orbit_download.log"

LOCK_DIR=""
if command -v flock >/dev/null 2>&1; then
    exec 9> .run2.1.2_prepare_SAFE_orbits_wget_curl.lock
    flock -n 9 || die "another Run 2.1.2 wget/curl process is already running"
else
    LOCK_DIR=".run2.1.2_prepare_SAFE_orbits_wget_curl.lock.d"
    mkdir "${LOCK_DIR}" 2>/dev/null ||
        die "another Run 2.1.2 wget/curl process may be running (or remove stale ${LOCK_DIR})"
    trap 'rmdir -- "${LOCK_DIR}" 2>/dev/null || true' EXIT
fi

if (( RETRY_FAILED_ONLY == 1 )); then
    [[ -s "${FAILURE_LIST}" ]] || die "failed-date list not found or empty: ${FAILURE_LIST}"
    RETRY_SAFE_LIST_TMP="${RETRY_SAFE_LIST}.tmp.$$"
    awk -F '\t' 'NF >= 2 && $2 != "" {print $2}' "${FAILURE_LIST}" |
        sort -u > "${RETRY_SAFE_LIST_TMP}"
    RETRY_SAFE_TOTAL="$(wc -l < "${RETRY_SAFE_LIST_TMP}" | awk '{print $1}')"
    if (( RETRY_SAFE_TOTAL == 0 )); then
        rm -f -- "${RETRY_SAFE_LIST_TMP}"
        die "failed-date list contains no retryable SAFE paths: ${FAILURE_LIST}"
    fi
    mv -f -- "${RETRY_SAFE_LIST_TMP}" "${RETRY_SAFE_LIST}"
    ACTIVE_SAFE_LIST="${RETRY_SAFE_LIST}"
    ACTIVE_SAFE_TOTAL="${RETRY_SAFE_TOTAL}"
else
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
        die "SAFE source changed during validation (${SAFE_TOTAL} -> ${FORMAL_SAFE_TOTAL}); rerun Run 2.1.2 wget/curl"
    }
    mv -f -- "${SAFE_LIST_TMP}" "${SAFE_LIST}"
    ACTIVE_SAFE_LIST="${SAFE_LIST}"
    ACTIVE_SAFE_TOTAL="${FORMAL_SAFE_TOTAL}"
fi

{
    printf '%s\n' '========================================'
    printf 'Run 2.1.2 wget/curl: prepare SAFE list and Sentinel-1 orbits\n'
    printf 'Work directory : %s\n' "${WORK_DIR}"
    printf 'Track          : %s\n' "${TRACK}"
    printf 'Direction      : %s\n' "${DIRECTION}"
    printf 'SAFE source    : %s\n' "${SOURCE_SAFE}"
    printf 'Input list     : %s\n' "${ACTIVE_SAFE_LIST}"
    printf 'Failed list    : %s\n' "${FAILURE_LIST}"
    printf 'Orbit log      : %s\n' "${ORBIT_LOG}"
    printf 'Input SAFE     : %d\n' "${ACTIVE_SAFE_TOTAL}"
    printf 'Run selection  : %s\n' "${RUN_DESCRIPTION}"
    printf 'Orbit mode     : %s\n' "${ORBIT_MODE}"
    printf 'Downloader     : internal wget -> curl fallback\n'
    printf 'Timeout policy : wget %ss + curl %ss, then skip date\n' \
        "${WGET_LIMIT_SECONDS}" "${CURL_LIMIT_SECONDS}"
    printf 'Index cache    : reuse for %d day(s); stale fallback on network failure\n' \
        "${INDEX_CACHE_DAYS}"
    if (( RETRY_FAILED_ONLY == 1 )); then
        printf 'Auto retries   : up to %d pass(es), %ss between retry passes\n' \
            "${MAX_RETRY_PASSES}" "${RETRY_DELAY_SECONDS}"
    fi
    printf 'Start time     : %s\n' "$(date '+%F %T')"
    printf '%s\n' '========================================'
} | tee "${SUMMARY_LOG}"

printf '[RUN] Orbit downloader is running; output is being written to:\n'
printf '  %s\n' "${ORBIT_LOG}"
printf '[MONITOR] From another terminal, run:\n'
printf '  tail -f %q\n' "${ORBIT_LOG}"

if (( RETRY_FAILED_ONLY == 1 )); then
    PASS_LIMIT="${MAX_RETRY_PASSES}"
else
    PASS_LIMIT=1
fi

: > "${ORBIT_LOG}"
CURRENT_SAFE_LIST="${ACTIVE_SAFE_LIST}"
PREVIOUS_FAILED_COUNT="$(wc -l < "${CURRENT_SAFE_LIST}" | awk '{print $1}')"
DOWNLOAD_STATUS=1
PASSES_COMPLETED=0
STOP_REASON="pass_limit"

set +e
for ((pass=1; pass<=PASS_LIMIT; pass++)); do
    PASSES_COMPLETED="${pass}"
    {
        printf '\n%s\n' '========================================'
        printf '[PASS %d/%d] Input failed records: %d\n' \
            "${pass}" "${PASS_LIMIT}" "${PREVIOUS_FAILED_COUNT}"
        printf '%s\n' '========================================'
    } >> "${ORBIT_LOG}"

    (
        cd -- "${ORGANIZED_ABS}"
        download_orbits "${CURRENT_SAFE_LIST}" "${ORBIT_MODE}" "${FAILURE_LIST}"
    ) >> "${ORBIT_LOG}" 2>&1
    PASS_STATUS=$?

    CURRENT_FAILED_COUNT="$(awk 'NF {count++} END {print count+0}' "${FAILURE_LIST}")"
    CURRENT_EOF_TOTAL="$(find "${ORGANIZED_ABS}" -maxdepth 1 -type f \
        -name '*.EOF' -print | wc -l | awk '{print $1}')"
    {
        printf '[PASS %d RESULT] remaining failures=%d, EOF files=%d, status=%d\n' \
            "${pass}" "${CURRENT_FAILED_COUNT}" "${CURRENT_EOF_TOTAL}" "${PASS_STATUS}"
    } >> "${ORBIT_LOG}"

    if (( CURRENT_FAILED_COUNT == 0 )); then
        DOWNLOAD_STATUS=0
        STOP_REASON="all_complete"
        break
    fi

    DOWNLOAD_STATUS="${PASS_STATUS}"
    if (( pass >= PASS_LIMIT )); then
        STOP_REASON="pass_limit"
        break
    fi

    NEXT_SAFE_LIST_TMP="${RETRY_SAFE_LIST}.next.$$"
    awk -F '\t' 'NF >= 2 && $2 != "" {print $2}' "${FAILURE_LIST}" |
        sort -u > "${NEXT_SAFE_LIST_TMP}"
    NEXT_SAFE_TOTAL="$(wc -l < "${NEXT_SAFE_LIST_TMP}" | awk '{print $1}')"
    if (( NEXT_SAFE_TOTAL == 0 )); then
        rm -f -- "${NEXT_SAFE_LIST_TMP}"
        STOP_REASON="no_retryable_records"
        break
    fi
    mv -f -- "${NEXT_SAFE_LIST_TMP}" "${RETRY_SAFE_LIST}"
    CURRENT_SAFE_LIST="${RETRY_SAFE_LIST}"
    PREVIOUS_FAILED_COUNT="${CURRENT_FAILED_COUNT}"

    if (( RETRY_DELAY_SECONDS > 0 )); then
        printf '[WAIT] Sleep %d second(s) before the next automatic retry.\n' \
            "${RETRY_DELAY_SECONDS}" >> "${ORBIT_LOG}"
        sleep "${RETRY_DELAY_SECONDS}"
    fi
done
set -e

cat "${ORBIT_LOG}"
ERROR_COUNT="$(grep -c '\[ERROR\]' "${ORBIT_LOG}" || true)"
EOF_TOTAL="$(find "${ORGANIZED_ABS}" -maxdepth 1 -type f -name '*.EOF' -print | wc -l | awk '{print $1}')"
FAILED_RECORD_COUNT="$(awk 'NF {count++} END {print count+0}' "${FAILURE_LIST}")"
FAILED_DATE_COUNT="$(awk -F '\t' 'NF && $1 != "UNKNOWN" {seen[$1]=1} END {for (date in seen) count++; print count+0}' "${FAILURE_LIST}")"

{
    printf '%s\n' '========================================'
    printf 'Run 2.1.2 wget/curl final validation\n'
    printf 'Downloader status : %d\n' "${DOWNLOAD_STATUS}"
    printf 'Passes completed  : %d / %d\n' "${PASSES_COMPLETED}" "${PASS_LIMIT}"
    printf 'Stop reason       : %s\n' "${STOP_REASON}"
    printf 'Logged errors     : %d\n' "${ERROR_COUNT}"
    printf 'Failed dates      : %d\n' "${FAILED_DATE_COUNT}"
    printf 'Failed records    : %d\n' "${FAILED_RECORD_COUNT}"
    printf 'Failed list       : %s\n' "${FAILURE_LIST}"
    printf 'EOF files         : %d\n' "${EOF_TOTAL}"
    printf 'Orbit log         : %s\n' "${ORBIT_LOG}"
    printf 'Finish time       : %s\n' "$(date '+%F %T')"
    printf '%s\n' '========================================'
} | tee -a "${SUMMARY_LOG}"

if (( FAILED_RECORD_COUNT > 0 )); then
    {
        printf '[INCOMPLETE] %d date(s) still failed.\n' "${FAILED_DATE_COUNT}"
        printf '[FAILED LIST] %s\n' "${FAILURE_LIST}"
        printf '[NEXT] Network conditions may have changed; retry these dates later:\n'
        printf '  ./run2.1.2_prepare_SAFE_orbits_wget_curl.sh 2\n'
    } | tee -a "${SUMMARY_LOG}"
    exit 1
fi

(( DOWNLOAD_STATUS == 0 )) || die "orbit downloader exited with ${DOWNLOAD_STATUS}"
(( EOF_TOTAL > 0 )) || die "no .EOF orbit files found in ${ORGANIZED_ABS}"

printf '[OK] Run 2.1.2 wget/curl completed successfully\n' | tee -a "${SUMMARY_LOG}"
