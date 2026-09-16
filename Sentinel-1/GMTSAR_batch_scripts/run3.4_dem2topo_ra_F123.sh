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
  ./run3.4_dem2topo_ra_F123.sh
  ./run3.4_dem2topo_ra_F123.sh 1

No arguments:
  Print the command guide and expected inputs/outputs. No processing starts.

Mode 1:
  Validate F1/F2/F3, link each master PRM/LED into topo/, run the three
  dem2topo_ra.csh jobs concurrently, wait for all jobs, and automatically
  validate command status, trans.dat, and topo_ra.grd.
EOF
}

show_run_guide() {
    cat <<'EOF'
========================================
Run 3.4 command guide (processing NOT started)

Run:
  ./run3.4_dem2topo_ra_F123.sh 1

The script will:
  1. Read master_image from F1/F2/F3 batch_tops.config.
  2. Check each master PRM, LED, and topo/dem.grd.
  3. Link the master PRM/LED into each topo directory.
  4. Run F1/F2/F3 dem2topo_ra.csh jobs concurrently.
  5. Wait for all three jobs and automatically check their results.

Expected outputs:
  F1/topo/trans.dat      F1/topo/topo_ra.grd
  F2/topo/trans.dat      F2/topo/topo_ra.grd
  F3/topo/trans.dat      F3/topo/topo_ra.grd

Logs:
  F1/topo/dem2topo_ra.log
  F2/topo/dem2topo_ra.log
  F3/topo/dem2topo_ra.log

For a long server run:
  nohup ./run3.4_dem2topo_ra_F123.sh 1 > run3.4_dem2topo_ra.nohup.log 2>&1 &
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
(( $# == 1 )) || die "use no arguments for help, or use mode 1 to run"
[[ "$1" == "1" ]] || die "only MODE=1 is supported"

for command_name in awk grep head nohup sed tail dem2topo_ra.csh; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

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

# Preflight every frame before starting any job.
for frame in "${FRAMES[@]}"; do
    config="${frame}/batch_tops.config"
    raw_dir="${frame}/raw"
    topo_dir="${frame}/topo"
    pid_file="${topo_dir}/dem2topo_ra.pid"

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
            die "${frame} already has a running dem2topo_ra process (PID ${old_pid})"
        fi
    fi

    MASTER_IMAGES+=("${master_image}")
    printf '[INPUT OK] %s: master=%s\n' "${frame}" "${master_image}"
done

printf '%s\n' '========================================'
printf 'Run 3.4 mode 1: dem2topo_ra F1/F2/F3\n'
printf 'Track root: %s\n' "${ROOT_DIR}"
printf '%s\n' 'All three frames passed preflight.'
printf '%s\n' 'The script will wait and check all three results automatically.'
printf '%s\n' '========================================'

PIDS=()
PID_FRAMES=()

for index in "${!FRAMES[@]}"; do
    frame="${FRAMES[index]}"
    master_image="${MASTER_IMAGES[index]}"
    topo_dir="${frame}/topo"
    log_file="${ROOT_DIR}/${topo_dir}/dem2topo_ra.log"

    ln -sfn "../raw/${master_image}.PRM" "${topo_dir}/${master_image}.PRM"
    ln -sfn "../raw/${master_image}.LED" "${topo_dir}/${master_image}.LED"

    rm -f -- \
        "${topo_dir}/dem2topo_ra.log" \
        "${topo_dir}/dem2topo_ra.pid" \
        "${topo_dir}/trans.dat" \
        "${topo_dir}/tmp_dem_ra.grd" \
        "${topo_dir}/topo_ra.grd"

    (
        cd "${topo_dir}"
        exec nohup dem2topo_ra.csh "${master_image}.PRM" dem.grd 0
    ) > "${log_file}" 2>&1 &

    pid="$!"
    printf '%s\n' "${pid}" > "${topo_dir}/dem2topo_ra.pid"
    PIDS+=("${pid}")
    PID_FRAMES+=("${frame}")

    printf '[STARTED] %s: master=%s, PID=%s\n' \
        "${frame}" "${master_image}" "${pid}"
    printf '          log=%s\n' "${log_file}"
done

printf '%s\n' '========================================'
printf '%s\n' '[WAIT] All three jobs were started. Waiting for completion...'
printf '%s\n' '========================================'

FAILED=0
set +e
for index in "${!PIDS[@]}"; do
    pid="${PIDS[index]}"
    frame="${PID_FRAMES[index]}"
    topo_dir="${frame}/topo"
    log_file="${topo_dir}/dem2topo_ra.log"

    wait "${pid}"
    command_status="$?"

    frame_failed=0
    if (( command_status != 0 )); then
        printf '[FAILED] %s: dem2topo_ra.csh exited with status %d\n' \
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
    printf '[ERROR] Run 3.4 finished with %d failed frame(s).\n' "${FAILED}" >&2
    exit 1
fi

printf '%s\n' '[DONE] Run 3.4 completed successfully for F1, F2, and F3.'
printf '%s\n' 'Outputs:'
printf '%s\n' '  F1/topo/trans.dat  F1/topo/topo_ra.grd'
printf '%s\n' '  F2/topo/trans.dat  F2/topo/topo_ra.grd'
printf '%s\n' '  F3/topo/trans.dat  F3/topo/topo_ra.grd'
printf '%s\n' '========================================'
