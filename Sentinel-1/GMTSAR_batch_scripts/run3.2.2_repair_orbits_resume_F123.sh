#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Run only after Run 3.2 reports incomplete output because an EOF basename in
# data.in differs from an available orbit with the same validity interval.

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
  ./run3.2.2_repair_orbits_resume_F123.sh
  ./run3.2.2_repair_orbits_resume_F123.sh 1
  ./run3.2.2_repair_orbits_resume_F123.sh 2 [NCORES] [PREPROC_MODE] [ESD_MODE]

This recovery script is used only after Run 3.2 reports failed or incomplete
F1/F2/F3 output because data.in names an unavailable EOF file while another
EOF with the same V<start>_<end> validity interval is already present.

No arguments:
  Print this guide only. No checking or processing is started.

Mode 1 - inspect replacements and pending acquisitions:
  Inspect F1/F2/F3, show orbit-name replacements and pending acquisitions.
  No data.in or preprocessing output is modified.

Mode 2 - apply replacements and resume Run 3.2:
  1. match missing EOF basenames by the exact validity interval;
  2. update data.in after saving data.in.before_run3.2.2;
  3. create run3.2.2_pending_data.in containing the master plus only
     acquisitions missing PRM, LED or SLC output;
  4. rerun only those incomplete acquisitions;
  5. rebuild and validate the complete baseline/output set.

Defaults:
  NCORES=5, PREPROC_MODE=1 (standard), ESD_MODE=1 (median; PREPROC_MODE=2 only)

Examples:
  ./run3.2.2_repair_orbits_resume_F123.sh
  ./run3.2.2_repair_orbits_resume_F123.sh 1
  ./run3.2.2_repair_orbits_resume_F123.sh 2 5 1
  ./run3.2.2_repair_orbits_resume_F123.sh 2 5 2 1
EOF
}

RUN_MODE="${1:-}"
if [[ "${RUN_MODE}" == "-h" || "${RUN_MODE}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ -z "${RUN_MODE}" ]]; then
    usage
    exit 0
fi
case "${RUN_MODE}" in
    1)
        (( $# == 1 )) || { usage; die "mode 1 takes no additional arguments"; }
        CHECK_ONLY=1
        ;;
    2)
        CHECK_ONLY=0
        ;;
    *)
        usage
        die "first argument must be 1 (inspect) or 2 (formal recovery)"
        ;;
esac
(( $# <= 4 )) || { usage; die "too many arguments"; }

NCORES="${2:-5}"
PREPROC_MODE="${3:-1}"
ESD_MODE="${4:-1}"
PREPROC_SCRIPT="${PREPROC_SCRIPT:-/home/xinw/bin/own/preproc_batch_tops_parallel_new_wx.csh}"
FRAMES=(F1 F2 F3)

[[ "${NCORES}" =~ ^[1-9][0-9]*$ ]] || die "NCORES must be a positive integer"
[[ "${PREPROC_MODE}" == "1" || "${PREPROC_MODE}" == "2" ]] || die "PREPROC_MODE must be 1 or 2"
[[ "${ESD_MODE}" == "0" || "${ESD_MODE}" == "1" || "${ESD_MODE}" == "2" ]] ||
    die "ESD_MODE must be 0, 1 or 2"
[[ -f "${PREPROC_SCRIPT}" ]] || die "custom preprocessor not found: ${PREPROC_SCRIPT}"

for required_command in awk find sort sed tcsh parallel gmt baseline_table.csh; do
    command -v "${required_command}" >/dev/null 2>&1 ||
        die "required command not found: ${required_command}"
done

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number track directory (current: ${ROOT_DIR})"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run3.2.2.XXXXXX")"
cleanup() {
    rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

extract_validity() {
    local orbit_name="$1"
    if [[ "${orbit_name}" =~ _(V[0-9]{8}T[0-9]{6}_[0-9]{8}T[0-9]{6})[.]EOF$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

extract_acquisition() {
    local image_name="$1"
    if [[ "${image_name}" =~ ([0-9]{8})[Tt][0-9]{6} ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

find_orbit_candidate() {
    local raw_dir="$1"
    local validity="$2"
    local candidate
    local -a all_candidates=()
    local -a precise_candidates=()

    while IFS= read -r candidate; do
        [[ -e "${candidate}" ]] || continue
        all_candidates+=("${candidate}")
        if [[ "$(basename -- "${candidate}")" == *"_AUX_POEORB_"* ]]; then
            precise_candidates+=("${candidate}")
        fi
    done < <(
        find "${raw_dir}" -mindepth 1 -maxdepth 1 \
            -name "*_${validity}.EOF" -print | sort
    )

    if (( ${#precise_candidates[@]} == 1 )); then
        basename -- "${precise_candidates[0]}"
        return 0
    fi
    if (( ${#precise_candidates[@]} > 1 )); then
        printf '[AMBIGUOUS] %s has multiple POEORB candidates:\n' "${validity}" >&2
        printf '  %s\n' "${precise_candidates[@]}" >&2
        return 2
    fi
    if (( ${#all_candidates[@]} == 1 )); then
        basename -- "${all_candidates[0]}"
        return 0
    fi
    if (( ${#all_candidates[@]} == 0 )); then
        return 1
    fi
    printf '[AMBIGUOUS] %s has multiple orbit candidates:\n' "${validity}" >&2
    printf '  %s\n' "${all_candidates[@]}" >&2
    return 2
}

acquisition_complete() {
    local raw_dir="$1"
    local acquisition="$2"
    local kind
    local file
    local -a matches=()

    for kind in PRM LED SLC; do
        matches=()
        while IFS= read -r file; do
            matches+=("${file}")
        done < <(
            find "${raw_dir}" -mindepth 1 -maxdepth 1 -type f \
                -name "*${acquisition}*ALL*${kind}" -print
        )
        (( ${#matches[@]} > 0 )) || return 1
        for file in "${matches[@]}"; do
            [[ -s "${file}" ]] || return 1
        done
    done
    return 0
}

prepare_frame() {
    local frame="$1"
    local raw_dir="${ROOT_DIR}/${frame}/raw"
    local data_file="${raw_dir}/data.in"
    local corrected="${WORK_DIR}/${frame}.data.in.corrected"
    local pending="${WORK_DIR}/${frame}.pending"
    local replacements="${WORK_DIR}/${frame}.replacements.tsv"
    local unresolved="${WORK_DIR}/${frame}.unresolved.tsv"
    local line prefix image orbit validity candidate fixed acquisition
    local line_number=0 replacement_count=0 pending_count=0 unresolved_count=0
    local master_line=""

    [[ -d "${raw_dir}" ]] || die "raw directory not found: ${raw_dir}"
    [[ -s "${data_file}" ]] || die "data.in not found or empty: ${data_file}"
    [[ -s "${raw_dir}/preproc_all.log" ]] ||
        die "${frame}/raw/preproc_all.log not found; run Run 3.2 before Run 3.2.2"
    [[ -e "${raw_dir}/dem.grd" ]] || die "dem.grd missing in ${raw_dir}"

    : > "${corrected}"
    : > "${pending}"
    : > "${replacements}"
    : > "${unresolved}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_number=$((line_number + 1))
        [[ -n "${line}" ]] || continue
        prefix="${line%:*}"
        image="${line%%:*}"
        orbit="${line##*:}"
        fixed="${line}"

        if [[ ! -e "${raw_dir}/${orbit}" ]]; then
            if ! validity="$(extract_validity "${orbit}")"; then
                printf '%s\t%s\t%s\n' "${line_number}" "invalid_EOF_name" "${orbit}" \
                    >> "${unresolved}"
                unresolved_count=$((unresolved_count + 1))
            else
                if candidate="$(find_orbit_candidate "${raw_dir}" "${validity}")"; then
                    fixed="${prefix}:${candidate}"
                    printf '%s\t%s\t%s\t%s\n' \
                        "${line_number}" "${validity}" "${orbit}" "${candidate}" \
                        >> "${replacements}"
                    replacement_count=$((replacement_count + 1))
                else
                    printf '%s\t%s\t%s\n' "${line_number}" "${validity}" "${orbit}" \
                        >> "${unresolved}"
                    unresolved_count=$((unresolved_count + 1))
                fi
            fi
        fi

        printf '%s\n' "${fixed}" >> "${corrected}"
        if (( line_number == 1 )); then
            master_line="${fixed}"
            continue
        fi

        if ! acquisition="$(extract_acquisition "${image}")"; then
            printf '%s\t%s\t%s\n' "${line_number}" "invalid_image_date" "${image}" \
                >> "${unresolved}"
            unresolved_count=$((unresolved_count + 1))
            continue
        fi
        if ! acquisition_complete "${raw_dir}" "${acquisition}"; then
            printf '%s\n' "${fixed}" >> "${pending}"
            pending_count=$((pending_count + 1))
        fi
    done < "${data_file}"

    [[ -n "${master_line}" ]] || die "cannot read master record from ${data_file}"

    printf '%s\n' '----------------------------------------'
    printf '%s: records=%d, orbit replacements=%d, pending acquisitions=%d, unresolved=%d\n' \
        "${frame}" "${line_number}" "${replacement_count}" "${pending_count}" \
        "${unresolved_count}"
    if [[ -s "${replacements}" ]]; then
        printf 'Orbit replacements for %s:\n' "${frame}"
        awk -F '\t' '{printf "  line %s: %s -> %s (validity %s)\n",$1,$3,$4,$2}' \
            "${replacements}"
    fi
    if [[ -s "${pending}" ]]; then
        printf 'Pending acquisition dates for %s:\n' "${frame}"
        while IFS= read -r line; do
            image="${line%%:*}"
            acquisition="$(extract_acquisition "${image}")"
            printf '  %s\n' "${acquisition}"
        done < "${pending}"
    fi
    if [[ -s "${unresolved}" ]]; then
        printf '[UNRESOLVED] %s:\n' "${frame}" >&2
        sed 's/^/  /' "${unresolved}" >&2
    fi

    printf '%d\t%d\t%d\n' "${replacement_count}" "${pending_count}" "${unresolved_count}" \
        > "${WORK_DIR}/${frame}.summary"
}

validate_full_frame() {
    local frame="$1"
    local raw_dir="${ROOT_DIR}/${frame}/raw"
    local expected prm_count led_count slc_count baseline_count
    expected="$(wc -l < "${raw_dir}/data.in" | awk '{print $1}')"
    prm_count="$(find "${raw_dir}" -mindepth 1 -maxdepth 1 -type f -name '*ALL*PRM' -print | wc -l | awk '{print $1}')"
    led_count="$(find "${raw_dir}" -mindepth 1 -maxdepth 1 -type f -name '*ALL*LED' -print | wc -l | awk '{print $1}')"
    slc_count="$(find "${raw_dir}" -mindepth 1 -maxdepth 1 -type f -name '*ALL*SLC' -print | wc -l | awk '{print $1}')"
    [[ -s "${raw_dir}/baseline_table.dat" ]] || return 1
    baseline_count="$(wc -l < "${raw_dir}/baseline_table.dat" | awk '{print $1}')"
    if [[ "${prm_count}" -ne "${expected}" || "${led_count}" -ne "${expected}" ||
          "${slc_count}" -ne "${expected}" || "${baseline_count}" -ne "${expected}" ]]; then
        printf '[OUTPUT ERROR] %s: expected=%d PRM=%d LED=%d SLC=%d baseline=%d\n' \
            "${frame}" "${expected}" "${prm_count}" "${led_count}" "${slc_count}" \
            "${baseline_count}" >&2
        return 1
    fi
    printf '[OUTPUT OK] %s: PRM=%d LED=%d SLC=%d baseline=%d\n' \
        "${frame}" "${prm_count}" "${led_count}" "${slc_count}" "${baseline_count}"
}

run_frame() {
    local frame="$1"
    local raw_dir="${ROOT_DIR}/${frame}/raw"
    local corrected="${WORK_DIR}/${frame}.data.in.corrected"
    local pending="${WORK_DIR}/${frame}.pending"
    local replacement_count pending_count unresolved_count status
    read -r replacement_count pending_count unresolved_count \
        < "${WORK_DIR}/${frame}.summary"

    (( unresolved_count == 0 )) || {
        printf '[FAILED] %s has %d unresolved orbit/input records\n' \
            "${frame}" "${unresolved_count}" >&2
        return 1
    }

    if [[ ! -e "${raw_dir}/data.in.before_run3.2.2" ]]; then
        cp -p -- "${raw_dir}/data.in" "${raw_dir}/data.in.before_run3.2.2"
    fi
    cp -- "${corrected}" "${raw_dir}/data.in.run3.2.2.tmp"
    mv -f -- "${raw_dir}/data.in.run3.2.2.tmp" "${raw_dir}/data.in"
    cp -- "${WORK_DIR}/${frame}.replacements.tsv" \
        "${raw_dir}/run3.2.2_orbit_replacements.tsv"

    if (( pending_count == 0 )); then
        printf '[SKIP] %s has no incomplete acquisition output\n' "${frame}"
        validate_full_frame "${frame}"
        return
    fi

    {
        head -n 1 "${corrected}"
        cat "${pending}"
    } > "${raw_dir}/run3.2.2_pending_data.in"

    (
        cd -- "${raw_dir}"
        {
            printf '%s\n' '========================================'
            printf 'Run 3.2.2 recovery frame: %s\n' "${frame}"
            printf 'Start time              : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            printf 'Pending acquisitions    : %d\n' "${pending_count}"
            printf 'Orbit replacements      : %d\n' "${replacement_count}"
            printf 'NCORES                   : %d\n' "${NCORES}"
            printf 'PREPROC_MODE             : %s\n' "${PREPROC_MODE}"
            printf 'ESD_MODE                 : %s\n' "${ESD_MODE}"
            printf '%s\n' '========================================'
        } > run3.2.2_preproc.log

        set +e
        if [[ "${PREPROC_MODE}" == "2" ]]; then
            tcsh "${PREPROC_SCRIPT}" run3.2.2_pending_data.in dem.grd \
                "${NCORES}" "${PREPROC_MODE}" "${ESD_MODE}" >> run3.2.2_preproc.log 2>&1
        else
            tcsh "${PREPROC_SCRIPT}" run3.2.2_pending_data.in dem.grd \
                "${NCORES}" "${PREPROC_MODE}" >> run3.2.2_preproc.log 2>&1
        fi
        status=$?
        set -e
        printf 'Finish time             : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
            >> run3.2.2_preproc.log
        printf 'Exit status             : %d\n' "${status}" >> run3.2.2_preproc.log
        exit "${status}"
    ) || {
        printf '[FAILED] %s recovery preprocessing failed; inspect %s/run3.2.2_preproc.log\n' \
            "${frame}" "${raw_dir}" >&2
        return 1
    }

    validate_full_frame "${frame}"
}

printf '%s\n' '========================================'
printf 'Run 3.2.2: repair EOF names and resume incomplete Run 3.2 output\n'
printf 'Track root       : %s\n' "${ROOT_DIR}"
printf 'Run mode         : %s\n' "$([[ ${CHECK_ONLY} == 1 ]] && printf '1 (inspect only)' || printf '2 (formal recovery)')"
printf 'NCORES per frame : %s\n' "${NCORES}"
printf 'Preprocess mode  : %s\n' "${PREPROC_MODE}"
printf 'ESD mode         : %s\n' "${ESD_MODE}"
printf 'Custom script    : %s\n' "${PREPROC_SCRIPT}"
printf '%s\n' '========================================'

TOTAL_PENDING=0
TOTAL_UNRESOLVED=0
for frame in "${FRAMES[@]}"; do
    prepare_frame "${frame}"
    read -r _ pending_count unresolved_count < "${WORK_DIR}/${frame}.summary"
    TOTAL_PENDING=$((TOTAL_PENDING + pending_count))
    TOTAL_UNRESOLVED=$((TOTAL_UNRESOLVED + unresolved_count))
done

printf '%s\n' '========================================'
printf 'Total pending acquisitions: %d\n' "${TOTAL_PENDING}"
printf 'Total unresolved records   : %d\n' "${TOTAL_UNRESOLVED}"

if (( CHECK_ONLY == 1 )); then
    printf '[CHECK ONLY] No data.in or preprocessing output was modified.\n'
    if (( TOTAL_UNRESOLVED > 0 )); then
        printf '[NOT READY] Resolve the orbit ambiguity/missing validity intervals first.\n' >&2
        exit 1
    fi
    if (( TOTAL_PENDING == 0 )); then
        printf '[INFO] No incomplete acquisitions need Run 3.2.2.\n'
    else
        printf '[NEXT] Resume only incomplete acquisitions:\n'
        printf '  ./run3.2.2_repair_orbits_resume_F123.sh 2 %s %s' "${NCORES}" "${PREPROC_MODE}"
        if [[ "${PREPROC_MODE}" == "2" ]]; then
            printf ' %s' "${ESD_MODE}"
        fi
        printf '\n'
    fi
    printf '%s\n' '========================================'
    exit 0
fi

(( TOTAL_UNRESOLVED == 0 )) || die "unresolved records remain; formal recovery was not started"
if (( TOTAL_PENDING == 0 )); then
    printf '[DONE] Nothing needs to be rerun. Existing outputs are complete.\n'
    exit 0
fi

PIDS=()
PID_FRAMES=()
for frame in "${FRAMES[@]}"; do
    read -r _ pending_count _ < "${WORK_DIR}/${frame}.summary"
    if (( pending_count > 0 )); then
        printf '[START] %s recovery\n' "${frame}"
        run_frame "${frame}" &
        PIDS+=("$!")
        PID_FRAMES+=("${frame}")
    else
        run_frame "${frame}"
    fi
done

FAILED=0
set +e
for ((index=0; index<${#PIDS[@]}; index++)); do
    if wait "${PIDS[index]}"; then
        printf '[SUCCESS] %s recovery completed\n' "${PID_FRAMES[index]}"
    else
        printf '[FAILED] %s recovery failed\n' "${PID_FRAMES[index]}" >&2
        FAILED=$((FAILED + 1))
    fi
done
set -e

printf '%s\n' '========================================'
(( FAILED == 0 )) || die "Run 3.2.2 finished with ${FAILED} failed frame(s)"
printf '[DONE] Run 3.2.2 repaired EOF basenames and completed pending acquisitions.\n'
printf 'Per-frame logs: F*/raw/run3.2.2_preproc.log\n'
printf '%s\n' '========================================'
