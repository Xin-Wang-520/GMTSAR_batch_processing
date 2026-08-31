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
  ./run3.4_dem2topo_ra_parallel_F123.sh
  ./run3.4_dem2topo_ra_parallel_F123.sh 1 [threads_per_frame] [interpolation_mode]

No arguments:
  Print the command guide. No processing starts.

Mode 1:
  Run F1/F2/F3 concurrently with dem2topo_ra_parallel.csh.
  SAT_llt2rat_para uses 5 OpenMP threads per frame by default.
  Interpolation mode 0 uses GMT surface and is the default/recommended method.
  Interpolation mode 1 uses GMT triangulate. In the current small-area test,
  its interpolation stage was about 30 times faster than GMT surface, but it
  may show triangular facets; use it mainly for a quick preview.

Examples:
  ./run3.4_dem2topo_ra_parallel_F123.sh 1
  ./run3.4_dem2topo_ra_parallel_F123.sh 1 5 0
  ./run3.4_dem2topo_ra_parallel_F123.sh 1 5 1
EOF
}

show_run_guide() {
    cat <<'EOF'
========================================
Run 3.4 parallel command guide (processing NOT started)

Default run:
  ./run3.4_dem2topo_ra_parallel_F123.sh 1

Default parallel settings:
  Frames running concurrently : 3 (F1, F2, F3)
  Threads per frame           : 5
  Maximum SAT threads         : about 15
  GMT interpolation           : 0 = surface (default/recommended)

Adjust threads per frame when the computer has fewer CPU cores:
  ./run3.4_dem2topo_ra_parallel_F123.sh 1 3

Interpolation choices:
  0 = GMT surface: original, smooth and recommended for final processing
  1 = GMT triangulate: about 30x faster in the current interpolation test,
      but may show triangular facets; recommended mainly for a quick preview

Speed note:
  The 30x value applies to the interpolation stage in the current small-area
  test. Total speedup for a complete track also depends on SAT coordinate
  conversion, data size, CPU, memory, and disk speed.

Examples:
  Default surface interpolation with 5 threads per frame:
    ./run3.4_dem2topo_ra_parallel_F123.sh 1 5 0

  Faster triangulate interpolation with 5 threads per frame:
    ./run3.4_dem2topo_ra_parallel_F123.sh 1 5 1

Required programs on the server:
  /home/xinw/bin/own/dem2topo_ra_parallel.csh
  /home/xinw/bin/own/SAT_llt2rat_para

Expected outputs:
  F1/topo/trans.dat      F1/topo/topo_ra.grd      F1/topo/topo_ra.pdf
  F2/topo/trans.dat      F2/topo/topo_ra.grd      F2/topo/topo_ra.pdf
  F3/topo/trans.dat      F3/topo/topo_ra.grd      F3/topo/topo_ra.pdf

For a long server run:
  nohup ./run3.4_dem2topo_ra_parallel_F123.sh 1 > run3.4_parallel.nohup.log 2>&1 &
========================================
[INFO] No processing was started.
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

(( $# >= 1 && $# <= 3 )) ||
    die "use no arguments for help, or use: $0 1 [threads_per_frame] [interpolation_mode]"
[[ "$1" == "1" ]] || die "only MODE=1 is supported"

THREADS_PER_FRAME="${2:-5}"
[[ "${THREADS_PER_FRAME}" =~ ^[1-9][0-9]*$ ]] ||
    die "threads_per_frame must be a positive integer: ${THREADS_PER_FRAME}"

INTERPOLATION_MODE="${3:-0}"
[[ "${INTERPOLATION_MODE}" == "0" || "${INTERPOLATION_MODE}" == "1" ]] ||
    die "interpolation_mode must be 0 (surface) or 1 (triangulate)"

if [[ "${INTERPOLATION_MODE}" == "0" ]]; then
    INTERPOLATION_NAME="surface (default/recommended)"
else
    INTERPOLATION_NAME="triangulate (fast preview)"
fi

DEM2TOPO_PARALLEL="${DEM2TOPO_PARALLEL:-/home/xinw/bin/own/dem2topo_ra_parallel.csh}"
SAT_LLT2RAT_PARA="${SAT_LLT2RAT_PARA:-/home/xinw/bin/own/SAT_llt2rat_para}"

for command_name in awk grep head sed tail tcsh; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

[[ -f "${DEM2TOPO_PARALLEL}" ]] ||
    die "parallel dem2topo script not found: ${DEM2TOPO_PARALLEL}"
[[ -x "${SAT_LLT2RAT_PARA}" ]] ||
    die "parallel SAT program not found or not executable: ${SAT_LLT2RAT_PARA}"

export SAT_LLT2RAT_PARA

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
FRAMES=(F1 F2 F3)
MASTER_IMAGES=()

[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number directory (current: ${ROOT_DIR})"

pid_is_running() {
    local pid="$1"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${pid}" 2>/dev/null
}

# Validate all three frames before starting any processing.
for frame in "${FRAMES[@]}"; do
    config="${frame}/batch_tops.config"
    raw_dir="${frame}/raw"
    topo_dir="${frame}/topo"
    pid_file="${topo_dir}/dem2topo_ra_parallel.pid"

    [[ -d "${frame}" ]] || die "frame directory not found: ${frame}"
    [[ -s "${config}" ]] ||
        die "${config} not found or empty; complete Run 3.3 mode 2 first"
    [[ -d "${raw_dir}" ]] || die "raw directory not found: ${raw_dir}"
    [[ -d "${topo_dir}" ]] || die "topo directory not found: ${topo_dir}"
    [[ -e "${topo_dir}/dem.grd" ]] ||
        die "DEM missing or broken: ${topo_dir}/dem.grd"

    master_image="$(
        grep -E '^[[:space:]]*master_image[[:space:]]*=' "${config}" |
            head -n 1 |
            awk -F= '{ gsub(/[[:space:]]/, "", $2); print $2 }'
    )"
    [[ -n "${master_image}" ]] ||
        die "failed to read master_image from ${config}"
    [[ "${master_image}" == *_ALL_"${frame}" ]] ||
        die "${config}: master_image does not end with _ALL_${frame}: ${master_image}"

    [[ -e "${raw_dir}/${master_image}.PRM" ]] ||
        die "master PRM missing: ${raw_dir}/${master_image}.PRM"
    [[ -e "${raw_dir}/${master_image}.LED" ]] ||
        die "master LED missing: ${raw_dir}/${master_image}.LED"

    if [[ -s "${pid_file}" ]]; then
        old_pid="$(awk 'NR == 1 { print $1; exit }' "${pid_file}")"
        if pid_is_running "${old_pid}"; then
            die "${frame} already has a running parallel dem2topo process (PID ${old_pid})"
        fi
    fi

    MASTER_IMAGES+=("${master_image}")
    printf '[INPUT OK] %s: master=%s\n' "${frame}" "${master_image}"
done

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.4 parallel mode 1: dem2topo_ra F1/F2/F3'
printf 'Track root             : %s\n' "${ROOT_DIR}"
printf 'Concurrent frames      : %d\n' "${#FRAMES[@]}"
printf 'SAT threads per frame  : %s\n' "${THREADS_PER_FRAME}"
printf 'Maximum SAT threads    : about %d\n' "$(( ${#FRAMES[@]} * THREADS_PER_FRAME ))"
printf 'GMT interpolation      : %s (mode %s)\n' \
    "${INTERPOLATION_NAME}" "${INTERPOLATION_MODE}"
printf 'Parallel driver        : %s\n' "${DEM2TOPO_PARALLEL}"
printf 'Parallel SAT program   : %s\n' "${SAT_LLT2RAT_PARA}"
printf '%s\n' 'All three frames passed preflight.'
printf '%s\n' '========================================'

PIDS=()
PID_FRAMES=()

for index in "${!FRAMES[@]}"; do
    frame="${FRAMES[index]}"
    master_image="${MASTER_IMAGES[index]}"
    topo_dir="${frame}/topo"
    log_file="${ROOT_DIR}/${topo_dir}/dem2topo_ra_parallel.log"

    ln -sfn "../raw/${master_image}.PRM" "${topo_dir}/${master_image}.PRM"
    ln -sfn "../raw/${master_image}.LED" "${topo_dir}/${master_image}.LED"

    rm -f -- \
        "${topo_dir}/dem2topo_ra_parallel.log" \
        "${topo_dir}/dem2topo_ra_parallel.pid" \
        "${topo_dir}/trans.dat" \
        "${topo_dir}/tmp_dem_ra.grd" \
        "${topo_dir}/topo_ra.grd" \
        "${topo_dir}/topo_ra.pdf"

    (
        cd "${topo_dir}"
        exec tcsh "${DEM2TOPO_PARALLEL}" \
            "${master_image}.PRM" dem.grd \
            "${INTERPOLATION_MODE}" "${THREADS_PER_FRAME}"
    ) > "${log_file}" 2>&1 &

    pid="$!"
    printf '%s\n' "${pid}" > "${topo_dir}/dem2topo_ra_parallel.pid"
    PIDS+=("${pid}")
    PID_FRAMES+=("${frame}")

    printf '[STARTED] %s: master=%s, PID=%s\n' \
        "${frame}" "${master_image}" "${pid}"
    printf '          log=%s\n' "${log_file}"
done

printf '%s\n' '========================================'
printf '%s\n' '[WAIT] All three parallel jobs started. Waiting for completion...'
printf '%s\n' '========================================'

FAILED=0
set +e
for index in "${!PIDS[@]}"; do
    pid="${PIDS[index]}"
    frame="${PID_FRAMES[index]}"
    topo_dir="${frame}/topo"
    log_file="${topo_dir}/dem2topo_ra_parallel.log"

    wait "${pid}"
    command_status="$?"

    frame_failed=0
    if (( command_status != 0 )); then
        printf '[FAILED] %s: parallel dem2topo exited with status %d\n' \
            "${frame}" "${command_status}" >&2
        frame_failed=1
    fi
    if [[ ! -s "${topo_dir}/trans.dat" ]]; then
        printf '[FAILED] %s: trans.dat missing or empty\n' "${frame}" >&2
        frame_failed=1
    fi
    if [[ ! -s "${topo_dir}/topo_ra.grd" ]]; then
        printf '[FAILED] %s: topo_ra.grd missing or empty\n' "${frame}" >&2
        frame_failed=1
    fi

    if (( frame_failed == 0 )); then
        printf '[SUCCESS] %s: trans.dat and topo_ra.grd generated\n' "${frame}"
        if [[ -s "${topo_dir}/topo_ra.pdf" ]]; then
            printf '          plot=%s/topo_ra.pdf\n' "${topo_dir}"
        fi
    else
        FAILED="$((FAILED + 1))"
        printf '[LOG] %s/%s\n' "${ROOT_DIR}" "${log_file}" >&2
        if [[ -s "${log_file}" ]]; then
            printf '%s\n' 'Last 20 log lines:' >&2
            tail -n 20 "${log_file}" | sed 's/^/  /' >&2
        fi
    fi
done
set -e

printf '%s\n' '========================================'
if (( FAILED > 0 )); then
    printf '[ERROR] Run 3.4 parallel finished with %d failed frame(s).\n' \
        "${FAILED}" >&2
    exit 1
fi

printf '%s\n' '[DONE] Parallel Run 3.4 completed successfully for F1, F2, and F3.'
printf 'GMT interpolation used: %s (mode %s)\n' \
    "${INTERPOLATION_NAME}" "${INTERPOLATION_MODE}"
printf '%s\n' 'Outputs:'
printf '%s\n' '  F1/topo/trans.dat  F1/topo/topo_ra.grd  F1/topo/topo_ra.pdf'
printf '%s\n' '  F2/topo/trans.dat  F2/topo/topo_ra.grd  F2/topo/topo_ra.pdf'
printf '%s\n' '  F3/topo/trans.dat  F3/topo/topo_ra.grd  F3/topo/topo_ra.pdf'
printf '%s\n' '========================================'
