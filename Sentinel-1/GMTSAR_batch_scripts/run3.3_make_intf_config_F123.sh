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
  ./run3.3_make_intf_config_F123.sh
  ./run3.3_make_intf_config_F123.sh 1 [THRESHOLD_TIME] [THRESHOLD_BASELINE]
  ./run3.3_make_intf_config_F123.sh 2

Modes:
  1 = PREVIEW
      Select pairs in F1 and create F1/baseline.pdf for inspection.
      Defaults: time threshold=60 days, spatial baseline threshold=150 m.

  2 = FINALIZE
      Accept the latest F1 preview and copy its intf.in/config to F2/F3.
      Mode 2 does not rerun pair selection.

Pair-selector command:
  select_pairs_new.csh baseline_table.dat threshold_time threshold_baseline

Run without arguments to print a short guide without processing.
EOF
}

show_run_guide() {
    cat <<'EOF'
========================================
Run 3.3 command guide (processing NOT started)

Step 1 - create and inspect the time-space baseline plot:
  ./run3.3_make_intf_config_F123.sh 1 60 150

  60  = time baseline threshold, days
  150 = spatial baseline threshold, meters
  Pair list: F1/intf.in
  Plot: F1/baseline.pdf
  Config: F1/batch_tops.config
  Master source: the first record of F1/raw/data.in (selected by Run 3.1)
  master_image: S1_<first-record date>_ALL_F1

If the network is not suitable, rerun mode 1 with new thresholds.

Step 2 - accept the latest preview and create F2/F3 files:
  ./run3.3_make_intf_config_F123.sh 2
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

MODE="$1"
ARGC="$#"
[[ "${MODE}" == "1" || "${MODE}" == "2" ]] ||
    die "MODE must be 1 (preview) or 2 (finalize)"

CONFIG_SRC="${CONFIG_SRC:-/home/xinw/bin/own/batch_tops.config}"
SELECT_SCRIPT="${SELECT_SCRIPT:-/home/xinw/bin/own/select_pairs_new.csh}"
MASTER_TEMPLATE_REGEX='^[[:space:]]*master_image[[:space:]]*='
FRAMES=(F1 F2 F3)
PREVIEW_INFO="F1/run3.3_preview.info"

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number directory (current: ${ROOT_DIR})"

for frame in "${FRAMES[@]}"; do
    [[ -d "${frame}" ]] || die "frame directory not found: ${ROOT_DIR}/${frame}"
done

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

extract_info_value() {
    local key="$1"
    awk -F= -v key="${key}" '$1 == key { print $2; exit }' "${PREVIEW_INFO}"
}

prepare_f1_preview() {
    local threshold_time="$1"
    local threshold_baseline="$2"
    local data_count baseline_count first_line master_token master_date master_f1
    local intf_count

    for command_name in awk cp grep head sed tcsh tee wc; do
        command -v "${command_name}" >/dev/null 2>&1 ||
            die "required command not found: ${command_name}"
    done

    [[ -s F1/raw/baseline_table.dat ]] ||
        die "F1/raw/baseline_table.dat not found or empty; complete Run 3.2 first"
    [[ -s F1/raw/data.in ]] ||
        die "F1/raw/data.in not found or empty; complete Run 3.1 first"
    [[ -f "${CONFIG_SRC}" ]] || die "configuration template not found: ${CONFIG_SRC}"
    [[ -f "${SELECT_SCRIPT}" ]] || die "pair-selection script not found: ${SELECT_SCRIPT}"

    data_count="$(wc -l < F1/raw/data.in | awk '{print $1}')"
    baseline_count="$(wc -l < F1/raw/baseline_table.dat | awk '{print $1}')"
    (( data_count >= 2 )) || die "F1/raw/data.in requires at least two records"
    [[ "${baseline_count}" -eq "${data_count}" ]] ||
        die "F1 baseline lines=${baseline_count}, data.in records=${data_count}"

    printf '%s\n' '========================================'
    printf 'Run 3.3 mode 1: preview pair network\n'
    printf 'Track root       : %s\n' "${ROOT_DIR}"
    printf 'Track            : %s\n' "${TRACK}"
    printf 'Time threshold   : %s days\n' "${threshold_time}"
    printf 'Spatial baseline : %s m\n' "${threshold_baseline}"
    printf 'Pair list output : %s/F1/intf.in\n' "${ROOT_DIR}"
    printf 'Config output    : %s/F1/batch_tops.config\n' "${ROOT_DIR}"
    printf 'Master source    : first record of F1/raw/data.in (from Run 3.1)\n'
    printf 'F1 records       : %d\n' "${data_count}"
    printf 'Pair selector    : %s\n' "${SELECT_SCRIPT}"
    printf '%s\n' '========================================'

    cp -- F1/raw/baseline_table.dat F1/baseline_table.dat
    cp -- F1/raw/data.in F1/data.in
    cp -- "${CONFIG_SRC}" F1/batch_tops.config

    first_line="$(awk 'NR == 1 { print; exit }' F1/data.in)"
    master_token="$(
        printf '%s\n' "${first_line}" |
            grep -oE '[0-9]{8}[tT][0-9]{6}' |
            head -n 1 || true
    )"
    master_date="${master_token:0:8}"
    [[ "${master_date}" =~ ^[0-9]{8}$ ]] ||
        die "failed to extract the master date from the first line of F1/data.in"

    master_f1="S1_${master_date}_ALL_F1"
    if grep -qE "${MASTER_TEMPLATE_REGEX}" F1/batch_tops.config; then
        sed -i.bak -E \
            "s|^[[:space:]]*master_image[[:space:]]*=.*|master_image = ${master_f1}|" \
            F1/batch_tops.config
    else
        cp -- F1/batch_tops.config F1/batch_tops.config.bak
        printf 'master_image = %s\n' "${master_f1}" >> F1/batch_tops.config
    fi

    grep -qE "^[[:space:]]*master_image[[:space:]]*=[[:space:]]*${master_f1}[[:space:]]*$" \
        F1/batch_tops.config ||
        die "failed to set master_image in F1/batch_tops.config"
    printf '[MASTER SOURCE] First record of F1/raw/data.in -> %s\n' "${master_date}"
    printf '[CONFIG] F1/batch_tops.config: master_image = %s\n' "${master_f1}"

    rm -f -- \
        F1/intf.in \
        F1/baseline.ps \
        F1/baseline.jpg \
        F1/baseline.jpeg \
        F1/baseline.pdf \
        F1/tmp \
        "${PREVIEW_INFO}"

    printf '[RUN] tcsh %s baseline_table.dat %s %s\n' \
        "${SELECT_SCRIPT}" "${threshold_time}" "${threshold_baseline}"
    (
        cd F1
        tcsh "${SELECT_SCRIPT}" baseline_table.dat \
            "${threshold_time}" "${threshold_baseline}" \
            2>&1 | tee select_pairs_new.log
    )

    [[ -s F1/intf.in ]] || die "F1/intf.in was not generated or is empty"
    [[ -s F1/baseline.ps ]] || die "F1/baseline.ps was not generated or is empty"
    [[ -s F1/baseline.pdf ]] ||
        die "F1/baseline.pdf was not generated; select_pairs_new.csh should use psconvert -Tf"

    intf_count="$(wc -l < F1/intf.in | awk '{print $1}')"
    (( intf_count > 0 )) || die "F1/intf.in contains no selected pairs"

    {
        printf 'threshold_time=%s\n' "${threshold_time}"
        printf 'threshold_baseline=%s\n' "${threshold_baseline}"
        printf 'master_date=%s\n' "${master_date}"
        printf 'pair_count=%s\n' "${intf_count}"
        printf 'plot=F1/baseline.pdf\n'
    } > "${PREVIEW_INFO}"

    printf '\n%s\n' '========================================'
    printf '[PREVIEW DONE] Selected pairs: %d\n' "${intf_count}"
    printf '[PAIR LIST] %s/F1/intf.in (%d pairs)\n' "${ROOT_DIR}" "${intf_count}"
    printf '[PREVIEW PLOT] %s/F1/baseline.pdf\n' "${ROOT_DIR}"
    printf '[CONFIG] %s/F1/batch_tops.config\n' "${ROOT_DIR}"
    printf '[MASTER IMAGE] %s (date from first record of F1/raw/data.in)\n' \
        "${master_f1}"
    printf '[INFO] F2/F3 files were not generated in mode 1.\n'
    printf '[NEXT] Inspect the plot. If accepted, run:\n'
    printf '       ./run3.3_make_intf_config_F123.sh 2\n'
    printf '%s\n' '========================================'
}

finalize_f2_f3() {
    local threshold_time threshold_baseline master_date preview_pair_count
    local master_f1 intf_count frame frame_intf_count expected_master master_setting

    (( ARGC == 1 )) || die "mode 2 takes no threshold arguments; use: ./run3.3_make_intf_config_F123.sh 2"
    for command_name in awk cp grep head sed wc; do
        command -v "${command_name}" >/dev/null 2>&1 ||
            die "required command not found: ${command_name}"
    done

    [[ -s "${PREVIEW_INFO}" ]] ||
        die "preview record not found: ${PREVIEW_INFO}; run mode 1 first"
    [[ -s F1/intf.in ]] || die "F1/intf.in not found or empty; rerun mode 1"
    [[ -s F1/batch_tops.config ]] || die "F1/batch_tops.config not found; rerun mode 1"
    [[ -s F1/baseline.pdf ]] || die "F1/baseline.pdf not found or empty; rerun mode 1"

    threshold_time="$(extract_info_value threshold_time)"
    threshold_baseline="$(extract_info_value threshold_baseline)"
    master_date="$(extract_info_value master_date)"
    preview_pair_count="$(extract_info_value pair_count)"

    [[ "${master_date}" =~ ^[0-9]{8}$ ]] || die "invalid master_date in ${PREVIEW_INFO}"
    [[ "${preview_pair_count}" =~ ^[1-9][0-9]*$ ]] ||
        die "invalid pair_count in ${PREVIEW_INFO}"

    intf_count="$(wc -l < F1/intf.in | awk '{print $1}')"
    [[ "${intf_count}" -eq "${preview_pair_count}" ]] ||
        die "F1/intf.in changed after preview: lines=${intf_count}, preview=${preview_pair_count}"

    master_f1="S1_${master_date}_ALL_F1"
    grep -qE "^[[:space:]]*master_image[[:space:]]*=[[:space:]]*${master_f1}[[:space:]]*$" \
        F1/batch_tops.config ||
        die "F1/batch_tops.config changed after preview; rerun mode 1"

    printf '%s\n' '========================================'
    printf 'Run 3.3 mode 2: finalize F2/F3 files\n'
    printf 'Track root       : %s\n' "${ROOT_DIR}"
    printf 'Time threshold   : %s days\n' "${threshold_time}"
    printf 'Spatial baseline : %s m\n' "${threshold_baseline}"
    printf 'Master date      : %s\n' "${master_date}"
    printf 'Accepted pairs   : %d\n' "${intf_count}"
    printf 'Preview plot     : %s/F1/baseline.pdf\n' "${ROOT_DIR}"
    printf '%s\n' '========================================'

    for frame in F2 F3; do
        cp -- F1/intf.in "${frame}/intf.in"
        cp -- F1/batch_tops.config "${frame}/batch_tops.config"

        sed -i.bak "s/_F1/_${frame}/g" "${frame}/intf.in"
        sed -i.bak "s/_F1/_${frame}/g" "${frame}/batch_tops.config"

        expected_master="S1_${master_date}_ALL_${frame}"
        grep -qE "^[[:space:]]*master_image[[:space:]]*=[[:space:]]*${expected_master}[[:space:]]*$" \
            "${frame}/batch_tops.config" ||
            die "failed to set master_image in ${frame}/batch_tops.config"

        frame_intf_count="$(wc -l < "${frame}/intf.in" | awk '{print $1}')"
        [[ "${frame_intf_count}" -eq "${intf_count}" ]] ||
            die "${frame}/intf.in lines=${frame_intf_count}, expected=${intf_count}"
    done

    printf '\n========== Final summary ==========\n'
    for frame in "${FRAMES[@]}"; do
        frame_intf_count="$(wc -l < "${frame}/intf.in" | awk '{print $1}')"
        master_setting="$(
            grep -E '^[[:space:]]*master_image[[:space:]]*=' \
                "${frame}/batch_tops.config" |
                head -n 1
        )"
        printf '%s: pairs=%d; %s\n' "${frame}" "${frame_intf_count}" "${master_setting}"
    done

    printf '%s\n' '========================================'
    printf '[DONE] Run 3.3 accepted the preview and generated F2/F3 files.\n'
    printf '%s\n' '========================================'
}

if [[ "${MODE}" == "1" ]]; then
    (( $# <= 3 )) || die "mode 1 usage: ./run3.3_make_intf_config_F123.sh 1 [TIME] [BASELINE]"
    THRESHOLD_TIME="${2:-60}"
    THRESHOLD_BASELINE="${3:-150}"
    is_number "${THRESHOLD_TIME}" ||
        die "THRESHOLD_TIME must be a non-negative number (days)"
    is_number "${THRESHOLD_BASELINE}" ||
        die "THRESHOLD_BASELINE must be a non-negative number (meters)"
    prepare_f1_preview "${THRESHOLD_TIME}" "${THRESHOLD_BASELINE}"
else
    finalize_f2_f3
fi
