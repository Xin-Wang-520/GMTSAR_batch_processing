#!/usr/bin/env bash
# Retry only the F1/F2/F3 interferogram pairs reported as failed by Run 3.5.

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
  ./run3.5.2_retry_failed_pairs_F123.sh
  ./run3.5.2_retry_failed_pairs_F123.sh 1
  ./run3.5.2_retry_failed_pairs_F123.sh 2

No arguments:
  Print this guide. No files are changed.

Mode 1 - preview:
  Read F1/F2/F3/run3.5_failed_pairs.tsv and show all pairs that need retrying.
  Validate their PRM/LED/SLC inputs and show the incomplete directories that
  mode 2 will remove. No files are created, removed or modified.

Mode 2 - formal retry:
  Retry every incomplete pair reported by Run 3.5, one pair at a time.
  Only directories belonging to failed pairs are removed. Malformed output
  directories such as F2/intf_all/_2024254 are deleted directly.

Typical workflow after Run 3.5 reports one or more failures:
  ./run3.5.2_retry_failed_pairs_F123.sh 1
  nohup ./run3.5.2_retry_failed_pairs_F123.sh 2 \
    > run3.5.2_retry_failed_pairs.nohup.log 2>&1 &
EOF
}

config_value() {
    local config="$1" key="$2"
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

prm_value() {
    awk -v key="$2" '$1 == key {print $3; exit}' "$1"
}

clock_id() {
    awk '$1 == "SC_clock_start" {printf "%d", int($3); exit}' "$1"
}

pair_is_complete() {
    local frame_dir="$1" pair_id="$2" pair_log="$3"
    local output_dir="${frame_dir}/intf_all/${pair_id}"
    [[ -s "${frame_dir}/${pair_log}" ]] || return 1
    grep -q 'END STACK OF TOPS INTERFEROGRAMS' "${frame_dir}/${pair_log}" || return 1
    grep -q 'Incorrect satellite id in prm file' "${frame_dir}/${pair_log}" && return 1
    [[ -s "${output_dir}/corr.grd" ]] || return 1
    [[ -s "${output_dir}/mask.grd" ]] || return 1
    [[ -s "${output_dir}/phasefilt.grd" ]] || return 1
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || {
    usage
    exit 0
}

if (( $# == 0 )); then
    usage
    exit 0
fi

(( $# == 1 )) || die "use no arguments for help, or provide MODE 1 or 2"
MODE="$1"
[[ "${MODE}" == "1" || "${MODE}" == "2" ]] || die "MODE must be 1 or 2"

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
FRAMES=(F1 F2 F3)
[[ "${TRACK}" =~ ^T[0-9]+$ ]] || die "run this script in a T-number track directory"

declare -a ENTRIES=()
declare -A SEEN=()
declare -A FRAME_COUNTS=([F1]=0 [F2]=0 [F3]=0)
ALREADY_COMPLETE=0

for frame in "${FRAMES[@]}"; do
    frame_dir="${ROOT_DIR}/${frame}"
    failed_file="${frame_dir}/run3.5_failed_pairs.tsv"
    config="${frame_dir}/batch_tops.config"
    [[ -d "${frame_dir}" ]] || die "frame directory not found: ${frame_dir}"
    [[ -s "${config}" ]] || die "configuration missing or empty: ${config}"
    [[ "$(config_value "${config}" proc_stage)" == "2" ]] ||
        die "${config}: proc_stage must be 2"
    [[ "$(config_value "${config}" topo_phase)" == "1" ]] ||
        die "${config}: topo_phase must be 1"
    [[ -s "${failed_file}" ]] || continue

    while IFS=$'\t' read -r pair reason pair_log remainder; do
        [[ -n "${pair}" ]] || continue
        [[ "${pair}" =~ ^S1_([0-9]{8})_ALL_(${frame}):S1_([0-9]{8})_ALL_(${frame})$ ]] ||
            die "invalid pair in ${failed_file}: ${pair}"

        ref="${pair%%:*}"
        rep="${pair#*:}"
        ref_date="${BASH_REMATCH[1]}"
        rep_date="${BASH_REMATCH[3]}"
        pair_log="${pair_log:-intf_${ref_date}_${rep_date}.log}"
        raw_dir="${frame_dir}/raw"

        for stem in "${ref}" "${rep}"; do
            for suffix in PRM LED SLC; do
                [[ -s "${raw_dir}/${stem}.${suffix}" ]] ||
                    die "missing, empty or broken input: ${raw_dir}/${stem}.${suffix}"
            done
        done

        ref_prm="${raw_dir}/${ref}.PRM"
        rep_prm="${raw_dir}/${rep}.PRM"
        ref_sc="$(prm_value "${ref_prm}" SC_identity)"
        rep_sc="$(prm_value "${rep_prm}" SC_identity)"
        ref_id="$(clock_id "${ref_prm}")"
        rep_id="$(clock_id "${rep_prm}")"
        [[ "${ref_sc}" =~ ^[0-9]+$ && "${rep_sc}" =~ ^[0-9]+$ ]] ||
            die "invalid SC_identity for ${frame}: ${pair}"
        (( ref_sc == 1 || ref_sc == 2 || ref_sc == 4 || ref_sc == 5 || ref_sc == 6 || ref_sc > 6 )) ||
            die "unsupported SC_identity ${ref_sc}: ${ref_prm}"
        (( rep_sc == 1 || rep_sc == 2 || rep_sc == 4 || rep_sc == 5 || rep_sc == 6 || rep_sc > 6 )) ||
            die "unsupported SC_identity ${rep_sc}: ${rep_prm}"
        [[ "${ref_id}" =~ ^[0-9]+$ && "${rep_id}" =~ ^[0-9]+$ ]] ||
            die "cannot read SC_clock_start for ${frame}: ${pair}"

        pair_id="${ref_id}_${rep_id}"
        if pair_is_complete "${frame_dir}" "${pair_id}" "${pair_log}"; then
            printf '[SKIP COMPLETE] %s %s -> intf_all/%s\n' "${frame}" "${pair}" "${pair_id}"
            ALREADY_COMPLETE="$((ALREADY_COMPLETE + 1))"
            continue
        fi

        key="${frame}:${pair}"
        [[ -z "${SEEN[${key}]+x}" ]] || continue
        SEEN["${key}"]=1
        ENTRIES+=("${frame}"$'\t'"${pair}"$'\t'"${pair_id}"$'\t'"${rep_id}"$'\t'"${pair_log}"$'\t'"${reason:-reported_failure}")
        FRAME_COUNTS["${frame}"]="$((FRAME_COUNTS[${frame}] + 1))"
    done < "${failed_file}"
done

TOTAL="${#ENTRIES[@]}"
printf '%s\n' '========================================'
printf '%s\n' 'Run 3.5.2: retry failed F1/F2/F3 interferogram pairs'
printf 'Run mode             : %s (%s)\n' "${MODE}" "$([[ "${MODE}" == "1" ]] && printf PREVIEW || printf FORMAL)"
printf 'Track root           : %s\n' "${ROOT_DIR}"
printf 'Pairs needing retry  : %d\n' "${TOTAL}"
printf 'Already complete     : %d\n' "${ALREADY_COMPLETE}"
printf 'F1 / F2 / F3 pending : %d / %d / %d\n' \
    "${FRAME_COUNTS[F1]}" "${FRAME_COUNTS[F2]}" "${FRAME_COUNTS[F3]}"
printf 'Retry scheduling     : sequential (one failed pair at a time)\n'
printf '%s\n' '========================================'

(( TOTAL > 0 )) || die "no incomplete pairs remain in the Run 3.5 failure reports"

index=0
for entry in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r frame pair pair_id rep_id pair_log reason <<< "${entry}"
    index="$((index + 1))"
    frame_dir="${ROOT_DIR}/${frame}"
    printf '[%d/%d] %s  %s\n' "${index}" "${TOTAL}" "${frame}" "${pair}"
    printf '        reason          : %s\n' "${reason}"
    printf '        expected output : %s/intf_all/%s\n' "${frame}" "${pair_id}"
    [[ ! -e "${frame_dir}/intf/${pair_id}" ]] ||
        printf '        mode 2 removes  : %s/intf/%s\n' "${frame}" "${pair_id}"
    [[ ! -e "${frame_dir}/intf_all/${pair_id}" ]] ||
        printf '        mode 2 removes  : %s/intf_all/%s\n' "${frame}" "${pair_id}"
    [[ ! -e "${frame_dir}/intf/_${rep_id}" ]] ||
        printf '        mode 2 removes  : %s/intf/_%s (malformed)\n' "${frame}" "${rep_id}"
    [[ ! -e "${frame_dir}/intf_all/_${rep_id}" ]] ||
        printf '        mode 2 removes  : %s/intf_all/_%s (malformed)\n' "${frame}" "${rep_id}"
done

if [[ "${MODE}" == "1" ]]; then
    printf '%s\n' '========================================'
    printf '%s\n' '[CHECK OK] The failed-pair raw inputs are ready.'
    printf '%s\n' '[CHECK ONLY] No files were created, removed or modified.'
    printf '%s\n' '[NEXT] nohup ./run3.5.2_retry_failed_pairs_F123.sh 2 > run3.5.2_retry_failed_pairs.nohup.log 2>&1 &'
    printf '%s\n' '========================================'
    exit 0
fi

INTF_TOPS="${INTF_TOPS_SCRIPT:-$(command -v intf_tops.csh || true)}"
[[ -n "${INTF_TOPS}" && -x "${INTF_TOPS}" ]] || die "intf_tops.csh was not found or is not executable"

STAMP="$(date +%Y%m%d_%H%M%S)"
for frame in "${FRAMES[@]}"; do
    [[ -s "${ROOT_DIR}/${frame}/run3.5_failed_pairs.tsv" ]] || continue
    cp -p -- "${ROOT_DIR}/${frame}/run3.5_failed_pairs.tsv" \
        "${ROOT_DIR}/${frame}/run3.5_failed_pairs.before_run3.5.2_${STAMP}.tsv"
    : > "${ROOT_DIR}/${frame}/run3.5.2_failed_pairs.tsv"
done

FAILED_TOTAL=0
index=0
for entry in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r frame pair pair_id rep_id pair_log old_reason <<< "${entry}"
    index="$((index + 1))"
    frame_dir="${ROOT_DIR}/${frame}"
    ref="${pair%%:*}"
    rep="${pair#*:}"
    ref_date="${ref:3:8}"
    rep_date="${rep:3:8}"
    retry_input="${frame_dir}/run3.5.2_retry_${ref_date}_${rep_date}.in"
    retry_log="${frame_dir}/run3.5.2_retry_${ref_date}_${rep_date}.log"

    printf '[RUN %d/%d] %s %s\n' "${index}" "${TOTAL}" "${frame}" "${pair}"
    rm -rf -- \
        "${frame_dir}/intf/${pair_id}" \
        "${frame_dir}/intf_all/${pair_id}" \
        "${frame_dir}/intf/_${rep_id}" \
        "${frame_dir}/intf_all/_${rep_id}"
    printf '[CLEANUP] Removed failed-pair and malformed directories only.\n'

    if [[ -s "${frame_dir}/${pair_log}" ]]; then
        mkdir -p -- "${frame_dir}/run3.5.2_previous_pair_logs_${STAMP}"
        mv -- "${frame_dir}/${pair_log}" "${frame_dir}/run3.5.2_previous_pair_logs_${STAMP}/"
    fi
    printf '%s\n' "${pair}" > "${retry_input}"

    set +e
    (
        cd "${frame_dir}"
        "${INTF_TOPS}" "$(basename -- "${retry_input}")" batch_tops.config
    ) > "${retry_log}" 2>&1
    status="$?"
    set -e

    # Restore the conventional Run 3.5 pair-log name while retaining the
    # explicitly named Run 3.5.2 retry log.
    cp -- "${retry_log}" "${frame_dir}/${pair_log}"

    reason=""
    output_dir="${frame_dir}/intf_all/${pair_id}"
    if (( status != 0 )); then
        reason="driver_status_${status}"
    elif grep -q 'Incorrect satellite id in prm file' "${retry_log}"; then
        reason="incorrect_satellite_id"
    elif ! grep -q 'END STACK OF TOPS INTERFEROGRAMS' "${retry_log}"; then
        reason="completion_marker_missing"
    elif [[ ! -d "${output_dir}" ]]; then
        reason="output_directory_missing"
    else
        for grid in corr.grd mask.grd phasefilt.grd; do
            if [[ ! -s "${output_dir}/${grid}" ]]; then
                reason="missing_${grid}"
                break
            fi
        done
    fi

    if [[ -n "${reason}" ]]; then
        printf '%s\t%s\t%s\n' "${pair}" "${reason}" "$(basename -- "${retry_log}")" >> \
            "${frame_dir}/run3.5.2_failed_pairs.tsv"
        printf '[FAILED] %s %s: %s; log=%s\n' "${frame}" "${pair}" "${reason}" "${retry_log}" >&2
        FAILED_TOTAL="$((FAILED_TOTAL + 1))"
    else
        printf '[OK] %s/%s: corr.grd, mask.grd and phasefilt.grd are complete.\n' "${frame}" "${pair_id}"
    fi
done

for frame in "${FRAMES[@]}"; do
    retry_failed="${ROOT_DIR}/${frame}/run3.5.2_failed_pairs.tsv"
    [[ -e "${retry_failed}" ]] || continue
    if [[ -s "${retry_failed}" ]]; then
        cp -- "${retry_failed}" "${ROOT_DIR}/${frame}/run3.5_failed_pairs.tsv"
    else
        rm -f -- "${retry_failed}" "${ROOT_DIR}/${frame}/run3.5_failed_pairs.tsv"
    fi
done

printf '%s\n' '========================================'
if (( FAILED_TOTAL > 0 )); then
    printf '[ERROR] %d/%d retried pairs remain incomplete.\n' "${FAILED_TOTAL}" "${TOTAL}" >&2
    printf '%s\n' 'Inspect F*/run3.5.2_failed_pairs.tsv and the per-pair retry logs.' >&2
    exit 1
fi

printf '[SUCCESS] All %d failed pairs were regenerated and validated.\n' "${TOTAL}"
printf '%s\n' '[KEEP] Previously successful interferogram directories were untouched.'
printf '%s\n' '========================================'
