#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 22, 2026

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
  ./run3.5_intf_tops_parallel_F123.sh
  ./run3.5_intf_tops_parallel_F123.sh JOBS_PER_FRAME

No arguments:
  Print the command guide and check F1/F2/F3 intf.in, batch_tops.config,
  proc_stage, and topo_phase. No processing starts.

JOBS_PER_FRAME:
  Number of interferogram pairs processed concurrently inside each frame.
  F1/F2/F3 are also run concurrently, so the approximate maximum number of
  active pair jobs is 3 x JOBS_PER_FRAME.

Recommended command:
  ./run3.5_intf_tops_parallel_F123.sh 5
EOF
}

show_run_guide() {
    cat <<'EOF'
========================================
Run 3.5 command guide (processing NOT started)

Recommended run:
  ./run3.5_intf_tops_parallel_F123.sh 5

Equivalent command inside every frame:
  nohup intf_tops_parallel.csh intf.in batch_tops.config 5 >& itp.log &

Parallel structure:
  Concurrent frames          : 3 (F1, F2, F3)
  Pair jobs per frame        : 5 (recommended)
  Maximum active pair jobs   : about 15

Important configuration:
  proc_stage must be 2 because Run 3.4 has already generated topo_ra.grd.
  topo_phase must be 1.

Frame logs:
  F1/itp.log
  F2/itp.log
  F3/itp.log

Pair outputs:
  F1/intf_all/<date1>_<date2>/
  F2/intf_all/<date1>_<date2>/
  F3/intf_all/<date1>_<date2>/

For a long server run:
  nohup ./run3.5_intf_tops_parallel_F123.sh 5 \
    > run3.5_intf_tops_parallel.nohup.log 2>&1 &

Monitor:
  tail -f run3.5_intf_tops_parallel.nohup.log
  tail -f F1/itp.log
========================================
EOF
}

guide_config_value() {
    local config="$1"
    local key="$2"
    awk -F= -v key="${key}" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            value=$2
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "${config}"
}

default_input_check() {
    local root_dir track frame intf_file config pair_count proc_stage topo_phase
    local failed=0

    root_dir="$(pwd -P)"
    track="$(basename -- "${root_dir}")"

    printf '%s\n' 'Default input check (processing NOT started)'
    printf 'Track root: %s\n' "${root_dir}"

    if [[ ! "${track}" =~ ^T[0-9]+$ ]]; then
        printf '[CHECK ERROR] Run this script in a T-number directory.\n' >&2
        printf '[INFO] No processing was started.\n'
        return 1
    fi

    for frame in F1 F2 F3; do
        intf_file="${root_dir}/${frame}/intf.in"
        config="${root_dir}/${frame}/batch_tops.config"

        printf '%s:\n' "${frame}"
        if [[ -s "${intf_file}" ]]; then
            pair_count="$(awk 'NF && $0 !~ /^[[:space:]]*#/ {count++} END {print count+0}' "${intf_file}")"
            printf '  intf.in          : OK (%s pairs)\n' "${pair_count}"
            if (( pair_count == 0 )); then
                failed=1
            fi
        else
            printf '  intf.in          : MISSING OR EMPTY\n'
            failed=1
        fi

        if [[ -s "${config}" ]]; then
            printf '  batch_tops.config: OK\n'
            proc_stage="$(guide_config_value "${config}" proc_stage)"
            topo_phase="$(guide_config_value "${config}" topo_phase)"

            if [[ "${proc_stage}" == "2" ]]; then
                printf '  proc_stage       : 2 (OK)\n'
            else
                printf '  proc_stage       : %s (ERROR; must be 2)\n' "${proc_stage:-missing}"
                failed=1
            fi

            if [[ "${topo_phase}" == "1" ]]; then
                printf '  topo_phase       : 1 (OK)\n'
            else
                printf '  topo_phase       : %s (ERROR; must be 1)\n' "${topo_phase:-missing}"
                failed=1
            fi
        else
            printf '  batch_tops.config: MISSING OR EMPTY\n'
            printf '  proc_stage       : unavailable\n'
            printf '  topo_phase       : unavailable\n'
            failed=1
        fi
    done

    printf '%s\n' '========================================'
    if (( failed == 0 )); then
        printf '%s\n' '[CHECK OK] F1/F2/F3 intf.in and configurations are ready.'
    else
        printf '%s\n' '[CHECK ERROR] Fix the items above before starting Run 3.5.' >&2
    fi
    printf '%s\n' '[INFO] No processing was started.'
    return "${failed}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (( $# == 0 )); then
    show_run_guide
    if default_input_check; then
        exit 0
    else
        exit 1
    fi
fi

(( $# == 1 )) || die "use no arguments for help, or provide JOBS_PER_FRAME"

JOBS_PER_FRAME="$1"
[[ "${JOBS_PER_FRAME}" =~ ^[1-9][0-9]*$ ]] ||
    die "JOBS_PER_FRAME must be a positive integer: ${JOBS_PER_FRAME}"

for command_name in awk find grep head nohup parallel sed sort tail tcsh uniq wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

INTF_PARALLEL_SCRIPT="${INTF_PARALLEL_SCRIPT:-$(command -v intf_tops_parallel.csh || true)}"
[[ -n "${INTF_PARALLEL_SCRIPT}" && -f "${INTF_PARALLEL_SCRIPT}" ]] ||
    die "intf_tops_parallel.csh was not found; set INTF_PARALLEL_SCRIPT=/full/path/intf_tops_parallel.csh"
command -v intf_tops.csh >/dev/null 2>&1 ||
    die "intf_tops.csh was not found in PATH"

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
FRAMES=(F1 F2 F3)

[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number directory (current: ${ROOT_DIR})"

pid_is_running() {
    local pid="$1"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${pid}" 2>/dev/null
}

config_value() {
    local config="$1"
    local key="$2"
    awk -F= -v key="${key}" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            value=$2
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "${config}"
}

clock_id_from_prm() {
    awk '$1 == "SC_clock_start" {printf "%d", int($3); exit}' "$1"
}

prepare_frame() {
    local frame="$1"
    local frame_dir="${ROOT_DIR}/${frame}"
    local intf_file="${frame_dir}/intf.in"
    local config="${frame_dir}/batch_tops.config"
    local raw_dir="${frame_dir}/raw"
    local topo_dir="${frame_dir}/topo"
    local pid_file="${frame_dir}/itp.pid"
    local expected_file="${frame_dir}/run3.5_expected_pairs.tsv"
    local clean_intf="${frame_dir}/.run3.5_intf_clean.tmp"
    local proc_stage topo_phase shift_topo threshold_geocode pair_count
    local duplicate_count line ref rep ref_prm rep_prm ref_id rep_id date1 date2
    local work_dir
    declare -A checked_images=()

    [[ -d "${frame_dir}" ]] || die "frame directory not found: ${frame_dir}"
    [[ -s "${intf_file}" ]] || die "missing or empty: ${intf_file}"
    [[ -s "${config}" ]] || die "missing or empty: ${config}"
    [[ -d "${raw_dir}" ]] || die "raw directory not found: ${raw_dir}"
    [[ -d "${topo_dir}" ]] || die "topo directory not found: ${topo_dir}"

    if [[ -s "${pid_file}" ]]; then
        old_pid="$(awk 'NR == 1 {print $1; exit}' "${pid_file}")"
        if pid_is_running "${old_pid}"; then
            die "${frame} already has a running Run 3.5 process (PID ${old_pid})"
        fi
    fi

    proc_stage="$(config_value "${config}" proc_stage)"
    topo_phase="$(config_value "${config}" topo_phase)"
    shift_topo="$(config_value "${config}" shift_topo)"
    threshold_geocode="$(config_value "${config}" threshold_geocode)"

    [[ "${proc_stage}" == "2" ]] ||
        die "${config}: proc_stage must be 2 after Run 3.4 (current: ${proc_stage:-missing})"
    [[ "${topo_phase}" == "1" ]] ||
        die "${config}: topo_phase must be 1 (current: ${topo_phase:-missing})"
    [[ "${shift_topo}" == "0" || "${shift_topo}" == "1" ]] ||
        die "${config}: shift_topo must be 0 or 1 (current: ${shift_topo:-missing})"
    [[ "${threshold_geocode}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        die "${config}: invalid threshold_geocode: ${threshold_geocode:-missing}"

    [[ -s "${topo_dir}/topo_ra.grd" ]] ||
        die "missing or empty: ${topo_dir}/topo_ra.grd; complete Run 3.4 first"
    if [[ "${shift_topo}" == "1" ]]; then
        [[ -s "${topo_dir}/topo_shift.grd" ]] ||
            die "${config} requests shift_topo=1 but ${topo_dir}/topo_shift.grd is missing"
    fi
    if awk -v value="${threshold_geocode}" 'BEGIN {exit !(value != 0)}'; then
        [[ -s "${topo_dir}/trans.dat" ]] ||
            die "geocoding is enabled but ${topo_dir}/trans.dat is missing or empty"
    fi

    awk 'NF && $0 !~ /^[[:space:]]*#/ {print}' "${intf_file}" > "${clean_intf}"
    pair_count="$(wc -l < "${clean_intf}" | awk '{print $1}')"
    (( pair_count > 0 )) || die "no interferogram pairs found in ${intf_file}"

    duplicate_count="$(sort "${clean_intf}" | uniq -d | wc -l | awk '{print $1}')"
    (( duplicate_count == 0 )) ||
        die "${intf_file} contains ${duplicate_count} duplicate pair(s)"

    : > "${expected_file}"
    while IFS= read -r line; do
        [[ "${line}" =~ ^S1_[0-9]{8}_ALL_${frame}:S1_[0-9]{8}_ALL_${frame}$ ]] ||
            die "${intf_file}: invalid pair format: ${line}"

        ref="${line%%:*}"
        rep="${line#*:}"

        for image in "${ref}" "${rep}"; do
            if [[ -z "${checked_images[${image}]+x}" ]]; then
                for extension in PRM LED SLC; do
                    [[ -e "${raw_dir}/${image}.${extension}" ]] ||
                        die "required input missing: ${raw_dir}/${image}.${extension}"
                done
                checked_images["${image}"]=1
            fi
        done

        ref_prm="${raw_dir}/${ref}.PRM"
        rep_prm="${raw_dir}/${rep}.PRM"
        ref_id="$(clock_id_from_prm "${ref_prm}")"
        rep_id="$(clock_id_from_prm "${rep_prm}")"
        [[ -n "${ref_id}" && -n "${rep_id}" ]] ||
            die "failed to read SC_clock_start for pair: ${line}"

        date1="${ref:3:8}"
        date2="${rep:3:8}"
        work_dir="${frame_dir}/intf/${ref_id}_${rep_id}"
        [[ ! -e "${work_dir}" ]] ||
            die "stale/interrupted work directory found: ${work_dir}; inspect it before rerunning"

        printf '%s\t%s_%s\tintf_%s_%s.log\n' \
            "${line}" "${ref_id}" "${rep_id}" "${date1}" "${date2}" >> "${expected_file}"
    done < "${clean_intf}"
    rm -f -- "${clean_intf}"

    printf '[INPUT OK] %s: pairs=%d, proc_stage=%s, topo_phase=%s, geocode_threshold=%s\n' \
        "${frame}" "${pair_count}" "${proc_stage}" "${topo_phase}" "${threshold_geocode}"
}

for frame in "${FRAMES[@]}"; do
    prepare_frame "${frame}"
done

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.5: parallel TOPS interferograms for F1/F2/F3'
printf 'Track root                : %s\n' "${ROOT_DIR}"
printf 'Concurrent frames         : %d\n' "${#FRAMES[@]}"
printf 'Pair jobs per frame       : %s\n' "${JOBS_PER_FRAME}"
printf 'Maximum active pair jobs  : about %d\n' "$(( ${#FRAMES[@]} * JOBS_PER_FRAME ))"
printf 'Parallel driver           : %s\n' "${INTF_PARALLEL_SCRIPT}"
printf '%s\n' '========================================'

PIDS=()
PID_FRAMES=()

for frame in "${FRAMES[@]}"; do
    frame_dir="${ROOT_DIR}/${frame}"
    log_file="${frame_dir}/itp.log"
    pid_file="${frame_dir}/itp.pid"

    rm -f -- "${log_file}" "${pid_file}" "${frame_dir}/run3.5_failed_pairs.tsv"

    (
        cd "${frame_dir}"
        exec nohup tcsh "${INTF_PARALLEL_SCRIPT}" \
            intf.in batch_tops.config "${JOBS_PER_FRAME}"
    ) > "${log_file}" 2>&1 &

    pid="$!"
    printf '%s\n' "${pid}" > "${pid_file}"
    PIDS+=("${pid}")
    PID_FRAMES+=("${frame}")

    printf '[STARTED] %s: PID=%s, log=%s\n' "${frame}" "${pid}" "${log_file}"
done

printf '%s\n' '========================================'
printf '%s\n' '[WAIT] F1/F2/F3 are running. Waiting for completion...'
printf '%s\n' '========================================'

FAILED_FRAMES=0
set +e
for index in "${!PIDS[@]}"; do
    pid="${PIDS[index]}"
    frame="${PID_FRAMES[index]}"
    frame_dir="${ROOT_DIR}/${frame}"
    expected_file="${frame_dir}/run3.5_expected_pairs.tsv"
    failed_file="${frame_dir}/run3.5_failed_pairs.tsv"
    log_file="${frame_dir}/itp.log"

    wait "${pid}"
    command_status="$?"
    : > "${failed_file}"

    while IFS=$'\t' read -r pair output_dir pair_log; do
        reason=""
        if [[ ! -s "${frame_dir}/${pair_log}" ]]; then
            reason="pair_log_missing_or_empty"
        elif ! grep -q 'END STACK OF TOPS INTERFEROGRAMS' "${frame_dir}/${pair_log}"; then
            reason="completion_marker_missing"
        elif [[ ! -d "${frame_dir}/intf_all/${output_dir}" ]]; then
            reason="output_directory_missing"
        elif ! find "${frame_dir}/intf_all/${output_dir}" -maxdepth 1 -type f -name '*.grd' -print -quit |
            grep -q .; then
            reason="no_grd_output"
        fi

        if [[ -n "${reason}" ]]; then
            printf '%s\t%s\t%s\n' "${pair}" "${reason}" "${pair_log}" >> "${failed_file}"
        fi
    done < "${expected_file}"

    failed_count="$(wc -l < "${failed_file}" | awk '{print $1}')"
    expected_count="$(wc -l < "${expected_file}" | awk '{print $1}')"

    if (( command_status == 0 && failed_count == 0 )); then
        printf '[SUCCESS] %s: %d/%d pairs passed validation\n' \
            "${frame}" "${expected_count}" "${expected_count}"
        rm -f -- "${failed_file}"
    else
        printf '[FAILED] %s: driver_status=%d, failed_pairs=%d/%d\n' \
            "${frame}" "${command_status}" "${failed_count}" "${expected_count}" >&2
        printf '         frame log : %s\n' "${log_file}" >&2
        printf '         pair list : %s\n' "${failed_file}" >&2
        if [[ -s "${log_file}" ]]; then
            printf '%s\n' '         Last 20 frame-log lines:' >&2
            tail -n 20 "${log_file}" | sed 's/^/           /' >&2
        fi
        FAILED_FRAMES="$((FAILED_FRAMES + 1))"
    fi
done
set -e

printf '%s\n' '========================================'
if (( FAILED_FRAMES > 0 )); then
    printf '[ERROR] Run 3.5 finished with %d failed frame(s).\n' "${FAILED_FRAMES}" >&2
    exit 1
fi

printf '%s\n' '[DONE] Run 3.5 completed successfully for F1, F2, and F3.'
printf '%s\n' 'Outputs: F1/intf_all/  F2/intf_all/  F3/intf_all/'
printf '%s\n' 'Logs   : F1/itp.log    F2/itp.log    F3/itp.log'
printf '%s\n' '========================================'
