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
Usage:
  ./run3.2_preproc_batch_tops_F123.sh NCORES_PER_FRAME MODE [ESD_MODE]

Run without arguments to print the recommended commands without starting:
  ./run3.2_preproc_batch_tops_F123.sh

MODE meaning in preproc_batch_tops_parallel_new_wx.csh:
  1 = standard preprocessing with preproc_batch_tops.csh
  2 = ESD preprocessing with preproc_batch_tops_esd.csh

ESD_MODE is used only when MODE=2:
  0 = average residual azimuth shift (constant correction)
  1 = median residual azimuth shift (constant correction; default)
  2 = spatial interpolation of residual azimuth shifts

Recommended normal processing:
  ./run3.2_preproc_batch_tops_F123.sh 5 1

ESD alternatives:
  ./run3.2_preproc_batch_tops_F123.sh 5 2 0  # average
  ./run3.2_preproc_batch_tops_F123.sh 5 2 1  # median
  ./run3.2_preproc_batch_tops_F123.sh 5 2 2  # interpolation
  Recommended/default ESD choice: median (ESD_MODE=1)

F1, F2, and F3 run concurrently. Each frame starts up to NCORES_PER_FRAME
pair jobs. The first argument can be reduced on a machine with fewer resources.

Override the custom csh path if needed:
  PREPROC_SCRIPT=/path/to/script.csh ./run3.2_preproc_batch_tops_F123.sh 5 1
EOF
}

show_run_guide() {
    cat <<'EOF'
========================================
Run 3.2 command guide (processing NOT started)
NCORES per frame : 5
MODE              : 1 (standard)
Mode guidance     : standard mode is the normal/default choice

Normal run        : ./run3.2_preproc_batch_tops_F123.sh 5 1

ESD average       : ./run3.2_preproc_batch_tops_F123.sh 5 2 0
ESD median        : ./run3.2_preproc_batch_tops_F123.sh 5 2 1
ESD interpolation : ./run3.2_preproc_batch_tops_F123.sh 5 2 2
ESD recommendation: use median (ESD_MODE=1) by default when ESD is needed.

Parallel note     : 5 means up to 5 pair jobs per frame.
Total job estimate: F1/F2/F3 run together, so 3 x 5 = 15 jobs.
Lower resources   : replace 5 with 3 or 2.
Higher resources  : increase 5 only when CPU, memory, and disk I/O allow it.
========================================
[INFO] No processing was started. Run one complete command shown above.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if (( $# == 0 )); then
    show_run_guide
    exit 0
fi
(( $# >= 2 )) || die "NCORES_PER_FRAME and MODE are both required; run without arguments for examples"
(( $# <= 3 )) || die "too many arguments; use --help"

NCORES="$1"
MODE="$2"
ESD_MODE="${3:-1}"
PREPROC_SCRIPT="${PREPROC_SCRIPT:-/home/xinw/bin/own/preproc_batch_tops_parallel_new_wx.csh}"
FRAMES=(F1 F2 F3)

[[ "${NCORES}" =~ ^[1-9][0-9]*$ ]] || die "NCORES_PER_FRAME must be a positive integer"
[[ "${MODE}" == "1" || "${MODE}" == "2" ]] || die "MODE must be 1 (standard) or 2 (ESD)"
if [[ "${MODE}" == "2" && $# -ne 3 ]]; then
    die "ESD mode requires ESD_MODE: 0 (average), 1 (median), or 2 (interpolation)"
fi
[[ "${ESD_MODE}" == "0" || "${ESD_MODE}" == "1" || "${ESD_MODE}" == "2" ]] ||
    die "ESD_MODE must be 0 (average), 1 (median), or 2 (interpolation)"
[[ -f "${PREPROC_SCRIPT}" ]] || die "custom preprocessor not found: ${PREPROC_SCRIPT}"

for command_name in tcsh parallel awk find wc tee tail sed gmt baseline_table.csh; do
    command -v "${command_name}" >/dev/null 2>&1 || die "required command not found: ${command_name}"
done
if [[ "${MODE}" == "1" ]]; then
    command -v preproc_batch_tops.csh >/dev/null 2>&1 ||
        die "preproc_batch_tops.csh was not found in PATH"
else
    command -v preproc_batch_tops_esd.csh >/dev/null 2>&1 ||
        die "preproc_batch_tops_esd.csh was not found in PATH"
fi

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number directory (current: ${ROOT_DIR})"

LOCK_DIR=""
if command -v flock >/dev/null 2>&1; then
    exec 9> .run3.2_preproc.lock
    flock -n 9 || die "another Run 3.2 process is already running"
else
    LOCK_DIR=".run3.2_preproc.lock.d"
    mkdir "${LOCK_DIR}" 2>/dev/null || die "another Run 3.2 process may be running"
    trap 'rmdir -- "${LOCK_DIR}" 2>/dev/null || true' EXIT
fi

count_links() {
    local directory="$1"
    local pattern="$2"
    find "${directory}" -mindepth 1 -maxdepth 1 -type l -iname "${pattern}" -print |
        wc -l | awk '{print $1}'
}

count_outputs() {
    local directory="$1"
    local pattern="$2"
    find "${directory}" -mindepth 1 -maxdepth 1 -type f -name "${pattern}" -print |
        wc -l | awk '{print $1}'
}

validate_frame_input() {
    local frame="$1"
    local raw_dir="${ROOT_DIR}/${frame}/raw"
    local link
    local data_count xml_count tiff_count eof_count dem_count broken_count=0

    [[ -d "${raw_dir}" ]] || die "raw directory not found: ${raw_dir}; complete Run 2.4 first"
    [[ -s "${raw_dir}/data.in" ]] || die "data.in not found or empty: ${raw_dir}/data.in; complete Run 3.1 first"
    [[ -e "${raw_dir}/dem.grd" ]] || die "dem.grd link is missing or broken: ${raw_dir}/dem.grd"

    shopt -s nullglob
    for link in "${raw_dir}"/*; do
        [[ -L "${link}" ]] || continue
        if [[ ! -e "${link}" ]]; then
            printf '[BROKEN] %s -> %s\n' "${link}" "$(readlink -- "${link}")" >&2
            broken_count=$((broken_count + 1))
        fi
    done
    shopt -u nullglob
    (( broken_count == 0 )) || die "${frame}/raw contains ${broken_count} broken links"

    data_count="$(wc -l < "${raw_dir}/data.in" | awk '{print $1}')"
    xml_count="$(count_links "${raw_dir}" '*iw*vv*.xml')"
    tiff_count="$(count_links "${raw_dir}" '*iw*vv*.tiff')"
    eof_count="$(count_links "${raw_dir}" '*.EOF')"
    dem_count="$(count_links "${raw_dir}" 'dem.grd')"

    (( data_count >= 2 )) || die "${frame}/raw/data.in requires at least two records"
    [[ "${xml_count}" -eq "${data_count}" ]] ||
        die "${frame}: XML count=${xml_count}, data.in records=${data_count}"
    [[ "${tiff_count}" -eq "${data_count}" ]] ||
        die "${frame}: TIFF count=${tiff_count}, data.in records=${data_count}"
    (( eof_count > 0 )) || die "${frame}: no orbit EOF links found"
    [[ "${dem_count}" -eq 1 ]] || die "${frame}: expected exactly one dem.grd link"

    printf '[INPUT OK] %s: data=%d XML=%d TIFF=%d EOF=%d DEM=%d\n' \
        "${frame}" "${data_count}" "${xml_count}" "${tiff_count}" "${eof_count}" "${dem_count}"
}

clean_old_outputs() {
    local raw_dir="$1"
    local old_dir

    rm -f -- \
        "${raw_dir}/preproc.cmd" \
        "${raw_dir}/tmp_dirlist" \
        "${raw_dir}/baseline.ps" \
        "${raw_dir}/baseline.pdf" \
        "${raw_dir}/baseline_table.dat" \
        "${raw_dir}/table.gmt" \
        "${raw_dir}/prmlist"

    find "${raw_dir}" -mindepth 1 -maxdepth 1 -type f \
        \( -name 'log_*' -o -name '*.PRM' -o -name '*.LED' -o -name '*.SLC' \) \
        -delete

    shopt -s nullglob
    for old_dir in "${raw_dir}"/20??????_20??????; do
        [[ -d "${old_dir}" ]] || continue
        rm -rf -- "${old_dir}"
    done
    shopt -u nullglob
}

validate_frame_output() {
    local frame="$1"
    local raw_dir="$2"
    local expected_count="$3"
    local prm_count led_count slc_count baseline_count

    prm_count="$(count_outputs "${raw_dir}" '*ALL*.PRM')"
    led_count="$(count_outputs "${raw_dir}" '*ALL*.LED')"
    slc_count="$(count_outputs "${raw_dir}" '*ALL*.SLC')"

    if [[ "${prm_count}" -ne "${expected_count}" ]]; then
        printf '[OUTPUT ERROR] %s: PRM count=%d, expected=%d\n' \
            "${frame}" "${prm_count}" "${expected_count}" >&2
        return 1
    fi
    if [[ "${led_count}" -ne "${expected_count}" ]]; then
        printf '[OUTPUT ERROR] %s: LED count=%d, expected=%d\n' \
            "${frame}" "${led_count}" "${expected_count}" >&2
        return 1
    fi
    if [[ "${slc_count}" -ne "${expected_count}" ]]; then
        printf '[OUTPUT ERROR] %s: SLC count=%d, expected=%d\n' \
            "${frame}" "${slc_count}" "${expected_count}" >&2
        return 1
    fi
    if [[ ! -s "${raw_dir}/baseline_table.dat" ]]; then
        printf '[OUTPUT ERROR] %s: baseline_table.dat not generated\n' "${frame}" >&2
        return 1
    fi

    baseline_count="$(wc -l < "${raw_dir}/baseline_table.dat" | awk '{print $1}')"
    if [[ "${baseline_count}" -ne "${expected_count}" ]]; then
        printf '[OUTPUT ERROR] %s: baseline lines=%d, expected=%d\n' \
            "${frame}" "${baseline_count}" "${expected_count}" >&2
        return 1
    fi

    if [[ "${MODE}" == "1" ]]; then
        if [[ ! -s "${raw_dir}/baseline.ps" ]]; then
            printf '[OUTPUT ERROR] %s: baseline.ps not generated in standard mode\n' \
                "${frame}" >&2
            return 1
        fi
    fi

    printf '[OUTPUT OK] %s: PRM=%d LED=%d SLC=%d baseline=%d\n' \
        "${frame}" "${prm_count}" "${led_count}" "${slc_count}" "${baseline_count}"
}

run_one_frame() {
    local frame="$1"
    local raw_dir="${ROOT_DIR}/${frame}/raw"
    local expected_count command_status

    expected_count="$(wc -l < "${raw_dir}/data.in" | awk '{print $1}')"
    clean_old_outputs "${raw_dir}"

    (
        cd -- "${raw_dir}"
        {
            printf '%s\n' '========================================'
            printf 'Run 3.2 frame: %s\n' "${frame}"
            printf 'Start time   : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            printf 'Raw directory: %s\n' "${raw_dir}"
            printf 'Records      : %d\n' "${expected_count}"
            printf 'NCORES       : %d\n' "${NCORES}"
            printf 'MODE         : %s\n' "${MODE}"
            printf 'ESD_MODE     : %s\n' "${ESD_MODE}"
            printf 'Script       : %s\n' "${PREPROC_SCRIPT}"
            printf '%s\n' '========================================'
        } > preproc_all.log

        set +e
        if [[ "${MODE}" == "2" ]]; then
            tcsh "${PREPROC_SCRIPT}" data.in dem.grd "${NCORES}" "${MODE}" "${ESD_MODE}" \
                >> preproc_all.log 2>&1
        else
            tcsh "${PREPROC_SCRIPT}" data.in dem.grd "${NCORES}" "${MODE}" \
                >> preproc_all.log 2>&1
        fi
        command_status=$?
        set -e

        if (( command_status != 0 )); then
            printf '[FAIL] custom preprocessor exited with status %d\n' "${command_status}" \
                | tee -a preproc_all.log >&2
            tail -n 50 preproc_all.log >&2 || true
            exit "${command_status}"
        fi

        printf 'Finish time  : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> preproc_all.log
    )

    validate_frame_output "${frame}" "${raw_dir}" "${expected_count}" \
        >> "${raw_dir}/preproc_all.log" 2>&1 || {
            printf '[FAIL] %s output validation failed; inspect %s/preproc_all.log\n' \
                "${frame}" "${raw_dir}" >&2
            return 1
        }
    printf '[DONE] %s preprocessing completed successfully\n' "${frame}"
}

TOTAL_JOBS=$(( ${#FRAMES[@]} * NCORES ))
CPU_TOTAL="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')"

printf '%s\n' '========================================'
printf 'Run 3.2: preprocess F1/F2/F3 concurrently\n'
printf 'Track root             : %s\n' "${ROOT_DIR}"
printf 'Track                  : %s\n' "${TRACK}"
printf 'NCORES per frame       : %d\n' "${NCORES}"
printf 'Concurrent frames      : %d\n' "${#FRAMES[@]}"
printf 'Approximate total jobs : %d\n' "${TOTAL_JOBS}"
printf 'Detected CPU threads   : %s\n' "${CPU_TOTAL}"
printf 'MODE                    : %s (%s)\n' \
    "${MODE}" "$([[ "${MODE}" == "1" ]] && printf 'standard' || printf 'ESD')"
if [[ "${MODE}" == "1" ]]; then
    printf 'Mode guidance           : standard mode is the normal/default choice\n'
    printf 'ESD average             : ./run3.2_preproc_batch_tops_F123.sh %d 2 0\n' \
        "${NCORES}"
    printf 'ESD median              : ./run3.2_preproc_batch_tops_F123.sh %d 2 1\n' \
        "${NCORES}"
    printf 'ESD interpolation       : ./run3.2_preproc_batch_tops_F123.sh %d 2 2\n' \
        "${NCORES}"
    printf 'ESD recommendation      : use median (ESD_MODE=1) by default\n'
    printf 'Parallel guidance       : adjust the first argument for this computer\n'
else
    printf 'Mode guidance           : ESD processing is enabled\n'
    printf 'ESD method              : %s (%s)\n' "${ESD_MODE}" \
        "$([[ "${ESD_MODE}" == "0" ]] && printf 'average' || \
           { [[ "${ESD_MODE}" == "1" ]] && printf 'median' || printf 'interpolation'; })"
    printf 'ESD recommendation      : median (ESD_MODE=1) is the default ESD choice\n'
fi
printf 'Custom script           : %s\n' "${PREPROC_SCRIPT}"
printf '%s\n' '========================================'

if [[ "${CPU_TOTAL}" =~ ^[0-9]+$ ]] && (( TOTAL_JOBS > CPU_TOTAL )); then
    printf '[WARN] requested job total (%d) exceeds detected CPU threads (%d).\n' \
        "${TOTAL_JOBS}" "${CPU_TOTAL}"
fi

for frame in "${FRAMES[@]}"; do
    validate_frame_input "${frame}"
done

PIDS=()
PID_FRAMES=()
for frame in "${FRAMES[@]}"; do
    printf '[START] %s\n' "${frame}"
    run_one_frame "${frame}" &
    PIDS+=("$!")
    PID_FRAMES+=("${frame}")
done

FAILED=0
set +e
for ((index = 0; index < ${#PIDS[@]}; index++)); do
    if wait "${PIDS[index]}"; then
        printf '[SUCCESS] %s\n' "${PID_FRAMES[index]}"
    else
        status=$?
        printf '[FAILED] %s exited with status %d; inspect %s/%s/raw/preproc_all.log\n' \
            "${PID_FRAMES[index]}" "${status}" "${ROOT_DIR}" "${PID_FRAMES[index]}" >&2
        FAILED=$((FAILED + 1))
    fi
done
set -e

printf '%s\n' '========================================'
if (( FAILED > 0 )); then
    printf '[ERROR] Run 3.2 finished with %d failed frame(s).\n' "${FAILED}" >&2
    exit 1
fi
printf '[DONE] Run 3.2 completed successfully for F1, F2, and F3.\n'
printf '%s\n' '========================================'
