#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 25, 2026
#
# Run 3.10: validated, resumable parallel unwrapping for merge/20* pairs.

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

MERGE_DIR="merge"
DEFAULT_JOBS="5"
DEFAULT_CORR_THRESHOLD="0.0001"
DEFAULT_MAX_DISCONTINUITY="0"
PID_FILE="merge/run3.10_unwrap.pid"
FAILED_REPORT="merge/run3.10_failed_pairs.tsv"
MISSING_INPUT_REPORT="merge/run3.10_missing_inputs.tsv"
LOG_DIR_NAME="run3.10_unwrap_logs"
NOHUP_LOG_NAME="run3.10_unwrap_merge_parallel.nohup.log"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./run3.10_unwrap_merge_parallel.sh
  ./run3.10_unwrap_merge_parallel.sh 1 [CORR_THRESHOLD] [PAIR]
  ./run3.10_unwrap_merge_parallel.sh 2 JOBS [CORR_THRESHOLD]

No arguments:
  Check all inputs and existing unwrap outputs, then print this guide.
  No processing is started and no files under merge/ are modified.

Mode 1 - preview one pre-SNAPHU input:
  ./run3.10_unwrap_merge_parallel.sh 1
  ./run3.10_unwrap_merge_parallel.sh 1 0.0001
  ./run3.10_unwrap_merge_parallel.sh 1 0.0001 2021051_2021063

  CORR_THRESHOLD    Correlation threshold; default: 0.0001.
  PAIR              Exact merge/<pair>/ directory name. If omitted, the
                    middle pair in the sorted interferogram list is selected.

  Applied valid-pixel inputs:
    corr.grd >= CORR_THRESHOLD
    mask.grd
    merge/mask_def.grd
    merge/landmask_ra.grd

  Outputs:
    merge/run3.10_presnaphu_preview/<pair>_combined_mask_presnaphu.pdf
    merge/run3.10_presnaphu_preview/<pair>_phase_presnaphu.pdf

  The first PDF shows only the combined valid-pixel mask without phasefilt.grd.
  The second PDF shows phasefilt.grd multiplied by that combined mask.
  Mode 1 does not run nearest_grid or SNAPHU and does not create unwrap.grd.

Mode 2 - formal resumable parallel unwrapping:
  ./run3.10_unwrap_merge_parallel.sh 2 5 0.0001

  JOBS                 Maximum interferograms unwrapped concurrently.
                       Recommended default: 5.
  CORR_THRESHOLD       Correlation threshold passed to snaphu_interp.csh.
                       Default: 0.0001.
  MAX_DISCONTINUITY    Fixed internally at 0 for continuous SBAS deformation.
                       Users do not need to provide this argument.

  Mode 2 automatically submits itself through nohup and returns the terminal
  immediately. Do not add nohup or "&" manually.

Formal processing:
  1. Check merge/landmask_ra.grd and merge/mask_def.grd.
  2. Check every merge/20* directory for non-empty corr.grd, mask.grd and
     phasefilt.grd.
  3. Confirm the two common masks match the phasefilt.grd radar grid.
  4. Skip pairs that already contain both non-empty unwrap.grd and unwrap.pdf.
  5. Run only pending pairs through GMTSAR unwrap_parallel.csh.
  6. Wait for completion and validate every pair.
  7. Write a failure report if unwrap.grd or unwrap.pdf is missing.

Outputs in every merge/<pair>/:
  unwrap.grd
  unwrap.pdf
  conncomp.grd
  phasefilt_interp.grd
  landmask_ra.grd -> ../landmask_ra.grd
  mask_def.grd    -> ../mask_def.grd

Run-level files in merge/:
  intflist
  unwrap_pending_intflist
  run3.10_unwrap_logs/<pair>.log
  run3.10_failed_pairs.tsv     (only when failures exist)

Monitor mode 2:
  tail -f run3.10_unwrap_merge_parallel.nohup.log
  tail -f merge/run3.10_unwrap_logs/<pair>.log
EOF
}

require_track_root() {
    local root track
    root="$(pwd -P)"
    track="$(basename -- "${root}")"
    [[ "${track}" =~ ^T[0-9]+$ ]] ||
        die "run this script in a T-number track directory (current: ${root})"
    [[ -d "${MERGE_DIR}" ]] || die "cannot find ${MERGE_DIR}/"
}

make_pair_list() {
    local output_file="$1"
    local path pair

    : > "${output_file}"
    while IFS= read -r -d '' path; do
        pair="$(basename -- "${path}")"
        [[ "${pair}" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] || continue
        printf '%s\n' "${pair}" >> "${output_file}"
    done < <(find "${MERGE_DIR}" -mindepth 1 -maxdepth 1 -type d -name '20*' -print0)
    sort -u -o "${output_file}" "${output_file}"
    [[ -s "${output_file}" ]] || die "no merged interferogram directories found under ${MERGE_DIR}/"
}

grid_signature() {
    local grid="$1"
    gmt grdinfo "${grid}" -C | awk '{
        print $2, $3, $4, $5, $8, $9, $10, $11, $12
    }'
}

check_inputs_and_outputs() {
    local pair_list="$1"
    local missing_report="$2"
    local pending_list="$3"
    local pair grid missing_csv
    local total=0 corr_count=0 mask_count=0 phase_count=0
    local unwrap_count=0 pdf_count=0 complete_count=0

    : > "${missing_report}"
    : > "${pending_list}"

    [[ -s "${MERGE_DIR}/landmask_ra.grd" ]] ||
        die "missing, broken or empty: ${MERGE_DIR}/landmask_ra.grd"
    [[ -s "${MERGE_DIR}/mask_def.grd" ]] ||
        die "missing, broken or empty: ${MERGE_DIR}/mask_def.grd"

    TEMPLATE_GRID="$(find "${MERGE_DIR}" -mindepth 2 -maxdepth 2 -type f \
        -path "${MERGE_DIR}/20*/phasefilt.grd" -print | sort | head -n 1)"
    [[ -n "${TEMPLATE_GRID}" && -s "${TEMPLATE_GRID}" ]] ||
        die "cannot find a non-empty ${MERGE_DIR}/20*/phasefilt.grd template"
    TEMPLATE_PAIR="$(basename -- "$(dirname -- "${TEMPLATE_GRID}")")"

    TEMPLATE_SIGNATURE="$(grid_signature "${TEMPLATE_GRID}")"
    LANDMASK_SIGNATURE="$(grid_signature "${MERGE_DIR}/landmask_ra.grd")"
    MASKDEF_SIGNATURE="$(grid_signature "${MERGE_DIR}/mask_def.grd")"
    [[ -n "${TEMPLATE_SIGNATURE}" && -n "${LANDMASK_SIGNATURE}" && -n "${MASKDEF_SIGNATURE}" ]] ||
        die "failed to read grid geometry"
    [[ "${LANDMASK_SIGNATURE}" == "${TEMPLATE_SIGNATURE}" ]] ||
        die "landmask_ra.grd geometry does not match ${TEMPLATE_GRID}"
    [[ "${MASKDEF_SIGNATURE}" == "${TEMPLATE_SIGNATURE}" ]] ||
        die "mask_def.grd geometry does not match ${TEMPLATE_GRID}"

    while IFS= read -r pair; do
        [[ -n "${pair}" ]] || continue
        total=$((total + 1))
        missing_csv=""

        for grid in corr.grd mask.grd phasefilt.grd; do
            if [[ -s "${MERGE_DIR}/${pair}/${grid}" ]]; then
                case "${grid}" in
                    corr.grd) corr_count=$((corr_count + 1)) ;;
                    mask.grd) mask_count=$((mask_count + 1)) ;;
                    phasefilt.grd) phase_count=$((phase_count + 1)) ;;
                esac
            else
                [[ -z "${missing_csv}" ]] || missing_csv+=","
                missing_csv+="${grid}"
            fi
        done

        if [[ -n "${missing_csv}" ]]; then
            printf '%s\t%s\n' "${pair}" "${missing_csv}" >> "${missing_report}"
            continue
        fi

        [[ -s "${MERGE_DIR}/${pair}/unwrap.grd" ]] && unwrap_count=$((unwrap_count + 1))
        [[ -s "${MERGE_DIR}/${pair}/unwrap.pdf" ]] && pdf_count=$((pdf_count + 1))
        if [[ -s "${MERGE_DIR}/${pair}/unwrap.grd" && -s "${MERGE_DIR}/${pair}/unwrap.pdf" ]]; then
            complete_count=$((complete_count + 1))
        else
            printf '%s\n' "${pair}" >> "${pending_list}"
        fi
    done < "${pair_list}"

    printf '%s\n' '========================================'
    printf '%s\n' 'Run 3.10 unwrap input/output check'
    printf 'Interferogram pairs    : %d\n' "${total}"
    printf 'Non-empty corr.grd     : %d\n' "${corr_count}"
    printf 'Non-empty mask.grd     : %d\n' "${mask_count}"
    printf 'Non-empty phasefilt.grd: %d\n' "${phase_count}"
    printf 'Existing unwrap.grd    : %d\n' "${unwrap_count}"
    printf 'Existing unwrap.pdf    : %d\n' "${pdf_count}"
    printf 'Completed pairs        : %d\n' "${complete_count}"
    printf 'Pending pairs          : %d\n' "$((total - complete_count))"
    printf 'Template signature     : %s\n' "${TEMPLATE_SIGNATURE}"
    printf '%s\n' '========================================'

    if [[ -s "${missing_report}" ]]; then
        printf '%s\n' '[CHECK ERROR] Missing or empty required inputs:' >&2
        while IFS=$'\t' read -r pair missing_csv; do
            printf '  %s  missing: %s\n' "${pair}" "${missing_csv}" >&2
        done < "${missing_report}"
        return 1
    fi

    printf '[CHECK OK] All %d pairs have corr.grd, mask.grd and phasefilt.grd.\n' "${total}"
    printf '%s\n' '[CHECK OK] landmask_ra.grd and mask_def.grd match the phase grid.'
}

validate_parameters() {
    [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer: ${JOBS}"
    [[ "${CORR_THRESHOLD}" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
        die "CORR_THRESHOLD must be numeric: ${CORR_THRESHOLD}"
    awk -v value="${CORR_THRESHOLD}" 'BEGIN {exit !(value >= 0 && value <= 1)}' ||
        die "CORR_THRESHOLD must be between 0 and 1: ${CORR_THRESHOLD}"
    [[ "${MAX_DISCONTINUITY}" =~ ^[0-9]+([.][0-9]*)?$ ]] ||
        die "MAX_DISCONTINUITY must be zero or a positive number: ${MAX_DISCONTINUITY}"
}

check_existing_process() {
    local old_pid
    if [[ -s "${PID_FILE}" ]]; then
        old_pid="$(awk 'NR == 1 {print $1; exit}' "${PID_FILE}")"
        if [[ "${old_pid}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${old_pid}" 2>/dev/null; then
            die "another Run 3.10 job is running (PID ${old_pid}, file ${PID_FILE})"
        fi
    fi
}

validate_threshold() {
    local value="$1"
    [[ "${value}" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
        die "CORR_THRESHOLD must be numeric: ${value}"
    awk -v value="${value}" 'BEGIN {exit !(value >= 0 && value <= 1)}' ||
        die "CORR_THRESHOLD must be between 0 and 1: ${value}"
}

make_presnaphu_preview() {
    local pair_list="$1" requested_pair="$2" threshold="$3"
    local pair pair_count middle_line pair_source pair_dir output_dir
    local mask_output_base phase_output_base
    local preview_tmp mask_all mask_tmp phase_preview mask_cpt phase_cpt

    validate_threshold "${threshold}"
    if [[ -n "${requested_pair}" ]]; then
        grep -Fxq -- "${requested_pair}" "${pair_list}" ||
            die "preview pair not found under ${MERGE_DIR}/: ${requested_pair}"
        pair="${requested_pair}"
        pair_source='user selected'
    else
        pair_count="$(wc -l < "${pair_list}" | awk '{print $1}')"
        middle_line=$(( (pair_count + 1) / 2 ))
        pair="$(sed -n "${middle_line}p" "${pair_list}")"
        pair_source='automatic middle pair'
    fi

    pair_dir="${MERGE_DIR}/${pair}"
    output_dir="${MERGE_DIR}/run3.10_presnaphu_preview"
    mask_output_base="${ROOT_DIR}/${output_dir}/${pair}_combined_mask_presnaphu"
    phase_output_base="${ROOT_DIR}/${output_dir}/${pair}_phase_presnaphu"
    mkdir -p "${output_dir}"
    preview_tmp="$(mktemp -d "${TEMP_DIR}/preview.XXXXXX")"
    mask_all="${preview_tmp}/mask_all.grd"
    mask_tmp="${preview_tmp}/mask_tmp.grd"
    phase_preview="${preview_tmp}/phase_presnaphu.grd"
    mask_cpt="${preview_tmp}/mask.cpt"
    phase_cpt="${preview_tmp}/phase.cpt"

    printf '%s\n' '========================================'
    printf '%s\n' 'Run 3.10 mode 1: preview pre-SNAPHU input'
    printf 'Track root             : %s\n' "${ROOT_DIR}"
    printf 'Interferogram pair     : %s (%s)\n' "${pair}" "${pair_source}"
    printf 'Correlation threshold  : %s\n' "${threshold}"
    printf '%s\n' 'Applied inputs:'
    printf '  %s/phasefilt.grd\n' "${pair_dir}"
    printf '  %s/corr.grd >= %s\n' "${pair_dir}" "${threshold}"
    printf '  %s/mask.grd\n' "${pair_dir}"
    printf '  %s/mask_def.grd\n' "${MERGE_DIR}"
    printf '  %s/landmask_ra.grd\n' "${MERGE_DIR}"
    printf '%s\n' '========================================'

    printf '%s\n' '[STEP 1] Build the combined valid-pixel mask'
    gmt grdmath \
        "${pair_dir}/corr.grd" "${threshold}" GE 0 NAN \
        "${pair_dir}/mask.grd" 0 GT 0 NAN MUL \
        = "${mask_all}"
    gmt grdmath \
        "${mask_all}" "${MERGE_DIR}/mask_def.grd" 0 GT 0 NAN MUL \
        = "${mask_tmp}"
    mv "${mask_tmp}" "${mask_all}"
    gmt grdmath \
        "${mask_all}" "${MERGE_DIR}/landmask_ra.grd" 0 GT 0 NAN MUL \
        = "${mask_tmp}"
    mv "${mask_tmp}" "${mask_all}"

    printf '%s\n' '[STEP 2] Plot the combined mask without phasefilt.grd'
    gmt makecpt -Cgray -T0/1/0.05 -Z > "${mask_cpt}"
    rm -f -- "${mask_output_base}.pdf"
    gmt begin "${mask_output_base}" pdf
        gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 10p \
            FONT_LABEL 11p FONT_TITLE 13p COLOR_NAN gray
        gmt grdimage "${mask_all}" -JX7i -C"${mask_cpt}" \
            -Bxaf+l"Range" -Byaf+l"Azimuth" \
            -BWSen+t"Combined pre-SNAPHU mask: ${pair}, corr >= ${threshold}"
    gmt end

    printf '%s\n' '[STEP 3] Apply the combined mask to phasefilt.grd'
    gmt grdmath "${pair_dir}/phasefilt.grd" "${mask_all}" MUL = "${phase_preview}"

    printf '%s\n' '[STEP 4] Plot the masked wrapped phase as PDF'
    gmt makecpt -Ccyclic -T-3.141592653589793/3.141592653589793/0.02 -Z > "${phase_cpt}"
    rm -f -- "${phase_output_base}.pdf"
    gmt begin "${phase_output_base}" pdf
        gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 10p \
            FONT_LABEL 11p FONT_TITLE 13p COLOR_NAN gray
        gmt grdimage "${phase_preview}" -JX7i -C"${phase_cpt}" \
            -Bxaf+l"Range" -Byaf+l"Azimuth" \
            -BWSen+t"Pre-SNAPHU wrapped phase: ${pair}, corr >= ${threshold}"
        gmt colorbar -DJTC+w5.5i/0.2i+h -C"${phase_cpt}" \
            -Bxa1.57f0.785+l"Wrapped phase" -By+l"rad"
    gmt end

    [[ -s "${mask_output_base}.pdf" ]] || die "combined-mask preview PDF was not generated"
    [[ -s "${phase_output_base}.pdf" ]] || die "phase preview PDF was not generated"
    printf '%s\n' '========================================'
    printf '%s\n' '[PREVIEW DONE] No unwrapping was started.'
    printf 'Combined-mask PDF: %s.pdf\n' "${mask_output_base}"
    printf 'Masked-phase PDF : %s.pdf\n' "${phase_output_base}"
    printf '%s\n' 'If the mask coverage is acceptable, run mode 2:'
    printf '%s\n' '  ./run3.10_unwrap_merge_parallel.sh 2 5 0.0001'
    printf '%s\n' '========================================'
}

if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    usage
    exit 0
fi

ACTION='check'
PREVIEW_PAIR=''
PREVIEW_THRESHOLD="${DEFAULT_CORR_THRESHOLD}"
INTERNAL_RUN=0

if [[ "${1:-}" == '--internal-run' ]]; then
    INTERNAL_RUN=1
    ACTION='process'
    shift
elif (( $# > 0 )); then
    case "$1" in
        1)
            ACTION='preview'
            shift
            (( $# <= 2 )) ||
                die "mode 1 usage: ./run3.10_unwrap_merge_parallel.sh 1 [CORR_THRESHOLD] [PAIR]"

            # Preferred syntax: mode 1, threshold, optional pair directory.
            # The former pair-first syntax is also accepted for compatibility.
            if (( $# == 0 )); then
                PREVIEW_THRESHOLD="${DEFAULT_CORR_THRESHOLD}"
                PREVIEW_PAIR=''
            elif [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
                PREVIEW_THRESHOLD="$1"
                PREVIEW_PAIR="${2:-}"
            else
                PREVIEW_PAIR="$1"
                PREVIEW_THRESHOLD="${2:-${DEFAULT_CORR_THRESHOLD}}"
            fi
            ;;
        2)
            shift
            (( $# >= 1 && $# <= 2 )) ||
                die "mode 2 usage: ./run3.10_unwrap_merge_parallel.sh 2 JOBS [CORR_THRESHOLD]"
            JOBS="$1"
            CORR_THRESHOLD="${2:-${DEFAULT_CORR_THRESHOLD}}"
            # SBAS processing assumes continuous deformation by default.
            MAX_DISCONTINUITY="${DEFAULT_MAX_DISCONTINUITY}"
            validate_parameters
            command -v nohup >/dev/null 2>&1 || die "required command not found: nohup"
            require_track_root
            check_existing_process

            ROOT_DIR="$(pwd -P)"
            SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
            SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "$0")"
            NOHUP_LOG="${ROOT_DIR}/${NOHUP_LOG_NAME}"

            nohup "${SCRIPT_PATH}" --internal-run \
                "${JOBS}" "${CORR_THRESHOLD}" "${MAX_DISCONTINUITY}" \
                > "${NOHUP_LOG}" 2>&1 < /dev/null &
            BACKGROUND_PID=$!

            printf '%s\n' '========================================'
            printf '%s\n' 'Run 3.10 mode 2 submitted through nohup'
            printf 'Background PID         : %s\n' "${BACKGROUND_PID}"
            printf 'Parallel unwrap jobs   : %s\n' "${JOBS}"
            printf 'Correlation threshold  : %s\n' "${CORR_THRESHOLD}"
            printf 'Maximum discontinuity  : %s (fixed SBAS default)\n' "${MAX_DISCONTINUITY}"
            printf 'Main log               : %s\n' "${NOHUP_LOG}"
            printf '%s\n' 'The terminal may now be closed safely.'
            printf '%s\n' 'Monitor:'
            printf '  tail -f %s\n' "${NOHUP_LOG_NAME}"
            printf '%s\n' '========================================'
            exit 0
            ;;
        *)
            die "first argument must be mode 1 (preview) or mode 2 (formal unwrapping)"
            ;;
    esac
fi

for command_name in awk basename cp dirname find gmt grep head mkdir mktemp mv sed sort tail wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

require_track_root
ROOT_DIR="$(pwd -P)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run3.10.XXXXXX")"
PROCESS_STARTED=0
cleanup_exit() {
    rm -rf -- "${TEMP_DIR}"
    if (( PROCESS_STARTED == 1 )); then
        rm -f -- "${ROOT_DIR}/${PID_FILE}"
    fi
}
trap cleanup_exit EXIT INT TERM

PAIR_LIST="${TEMP_DIR}/all_pairs.txt"
MISSING_TEMP="${TEMP_DIR}/missing.tsv"
PENDING_TEMP="${TEMP_DIR}/pending.txt"
TEMPLATE_PAIR=""
TEMPLATE_GRID=""
TEMPLATE_SIGNATURE=""
LANDMASK_SIGNATURE=""
MASKDEF_SIGNATURE=""
make_pair_list "${PAIR_LIST}"

if ! check_inputs_and_outputs "${PAIR_LIST}" "${MISSING_TEMP}" "${PENDING_TEMP}"; then
    if (( $# > 0 )); then
        cp "${MISSING_TEMP}" "${MISSING_INPUT_REPORT}"
        printf 'Missing-input report: %s/%s\n' "${ROOT_DIR}" "${MISSING_INPUT_REPORT}" >&2
    fi
    printf '%s\n' '[INFO] Unwrapping was not started.' >&2
    exit 1
fi

if [[ "${ACTION}" == 'check' ]]; then
    usage
    printf '%s\n' '========================================'
    printf '%s\n' '[CHECK ONLY] No preview or unwrapping was started.'
    if [[ -s "${PENDING_TEMP}" ]]; then
        printf 'Pending pairs: %s\n' "$(wc -l < "${PENDING_TEMP}" | awk '{print $1}')"
        printf '%s\n' '[NEXT] Preview one pre-SNAPHU input:'
        printf '%s\n' '  ./run3.10_unwrap_merge_parallel.sh 1'
        printf '%s\n' '[NEXT] Formal resumable unwrapping:'
        printf '%s\n' '  ./run3.10_unwrap_merge_parallel.sh 2 5 0.0001'
    else
        printf '%s\n' '[COMPLETE] Every pair already has unwrap.grd and unwrap.pdf.'
    fi
    printf '%s\n' '========================================'
    exit 0
fi

if [[ "${ACTION}" == 'preview' ]]; then
    make_presnaphu_preview "${PAIR_LIST}" "${PREVIEW_PAIR}" "${PREVIEW_THRESHOLD}"
    exit 0
fi

(( INTERNAL_RUN == 1 )) || die "internal Run 3.10 mode error"
(( $# >= 1 && $# <= 3 )) || die "invalid internal mode 2 arguments"
JOBS="$1"
CORR_THRESHOLD="${2:-${DEFAULT_CORR_THRESHOLD}}"
MAX_DISCONTINUITY="${3:-${DEFAULT_MAX_DISCONTINUITY}}"
validate_parameters

for command_name in parallel snaphu_interp.csh tcsh unwrap_parallel.csh; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

check_existing_process
printf '%s\n' "$$" > "${PID_FILE}"
PROCESS_STARTED=1
rm -f -- "${MISSING_INPUT_REPORT}" "${FAILED_REPORT}"

cp "${PAIR_LIST}" "${MERGE_DIR}/intflist"
cp "${PENDING_TEMP}" "${MERGE_DIR}/unwrap_pending_intflist"
PENDING_COUNT="$(wc -l < "${PENDING_TEMP}" | awk '{print $1}')"
TOTAL_COUNT="$(wc -l < "${PAIR_LIST}" | awk '{print $1}')"

if (( PENDING_COUNT == 0 )); then
    printf '%s\n' '[COMPLETE] Every pair already has unwrap.grd and unwrap.pdf; nothing to run.'
    exit 0
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.10 mode 2: resumable parallel unwrapping'
printf 'Track root             : %s\n' "${ROOT_DIR}"
printf 'Total pairs            : %s\n' "${TOTAL_COUNT}"
printf 'Skipped complete pairs : %s\n' "$((TOTAL_COUNT - PENDING_COUNT))"
printf 'Pending pairs          : %s\n' "${PENDING_COUNT}"
printf 'Parallel unwrap jobs   : %s\n' "${JOBS}"
printf 'Correlation threshold  : %s\n' "${CORR_THRESHOLD}"
printf 'Maximum discontinuity  : %s (fixed SBAS default)\n' "${MAX_DISCONTINUITY}"
printf 'Unwrap driver          : %s\n' "$(command -v unwrap_parallel.csh)"
printf 'SNAPHU wrapper         : %s\n' "$(command -v snaphu_interp.csh)"
printf '%s\n' '========================================'

cd "${MERGE_DIR}"
mkdir -p "${LOG_DIR_NAME}"
# GMTSAR unwrap_parallel.csh invokes `unwrap_intf.csh` without `./`.
export PATH="$(pwd -P):${PATH}"

printf '%s\n' '[STEP 1] Generate the per-pair unwrap worker'
cat > unwrap_intf.csh <<EOF_WORKER
#!/bin/csh -f

set pair = \$1
set pair_log = "../${LOG_DIR_NAME}/\${pair}.log"

cd \$pair
ln -sfn ../landmask_ra.grd .
ln -sfn ../mask_def.grd .

# Remove temporary products that may remain after an interrupted attempt.
rm -f mask_patch.grd corr_patch.grd phase_patch.grd landmask_ra_patch.grd
rm -f mask_def_patch.grd mask2_patch.grd corr_tmp.grd phase_tmp.grd
rm -f phase.in corr.in unwrap.out conncomp.out tmp.grd unwrap_grad.grd

snaphu_interp.csh ${CORR_THRESHOLD} ${MAX_DISCONTINUITY} >& \$pair_log
set unwrap_status = \$status

cd ..
exit \$unwrap_status
EOF_WORKER
chmod +x unwrap_intf.csh

printf '%s\n' '[STEP 2] Remove stale GMTSAR command files and pending-pair logs'
rm -f -- unwrap.cmd
while IFS= read -r pair; do
    [[ -n "${pair}" ]] || continue
    rm -f -- "${LOG_DIR_NAME}/${pair}.log" "log_${pair}.txt"
done < unwrap_pending_intflist

printf '%s\n' '[STEP 3] Run GMTSAR unwrap_parallel.csh and wait for completion'
printf 'Command: unwrap_parallel.csh unwrap_pending_intflist %s\n' "${JOBS}"
set +e
unwrap_parallel.csh unwrap_pending_intflist "${JOBS}"
DRIVER_STATUS="$?"
set -e
printf 'unwrap_parallel.csh exit status: %s\n' "${DRIVER_STATUS}"

# The GMTSAR driver writes auxiliary log_<pair>.txt and unwrap.cmd files.
rm -f -- unwrap.cmd log_*.txt

printf '%s\n' '[STEP 4] Validate unwrap.grd and unwrap.pdf for every pair'
: > "${ROOT_DIR}/${FAILED_REPORT}"
SUCCESS_COUNT=0
while IFS= read -r pair; do
    [[ -n "${pair}" ]] || continue
    missing_csv=""
    [[ -s "${pair}/unwrap.grd" ]] || missing_csv='unwrap.grd'
    if [[ ! -s "${pair}/unwrap.pdf" ]]; then
        [[ -z "${missing_csv}" ]] || missing_csv+=','
        missing_csv+='unwrap.pdf'
    fi

    if [[ -n "${missing_csv}" ]]; then
        printf '%s\t%s\t%s/%s/%s/%s.log\n' \
            "${pair}" "${missing_csv}" "${ROOT_DIR}" "${MERGE_DIR}" "${LOG_DIR_NAME}" "${pair}" \
            >> "${ROOT_DIR}/${FAILED_REPORT}"
    else
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
done < intflist

if [[ -s "${ROOT_DIR}/${FAILED_REPORT}" ]]; then
    FAILED_COUNT="$(wc -l < "${ROOT_DIR}/${FAILED_REPORT}" | awk '{print $1}')"
    printf '%s\n' '========================================' >&2
    printf '[FAILED] %s/%s pairs are incomplete.\n' "${FAILED_COUNT}" "${TOTAL_COUNT}" >&2
    printf 'Failure report: %s/%s\n' "${ROOT_DIR}" "${FAILED_REPORT}" >&2
    printf '%s\n' 'First failures:' >&2
    head -n 20 "${ROOT_DIR}/${FAILED_REPORT}" | sed 's/^/  /' >&2
    printf '%s\n' 'Rerun the same command to process only incomplete pairs.' >&2
    printf '%s\n' '========================================' >&2
    exit 1
fi

rm -f -- "${ROOT_DIR}/${FAILED_REPORT}"
printf '%s\n' '========================================'
printf '[DONE] All %s interferogram pairs contain non-empty unwrap.grd and unwrap.pdf.\n' \
    "${TOTAL_COUNT}"
printf 'Newly processed pairs : %s\n' "${PENDING_COUNT}"
printf 'Previously complete   : %s\n' "$((TOTAL_COUNT - PENDING_COUNT))"
printf 'Per-pair logs         : %s/%s/%s/\n' "${ROOT_DIR}" "${MERGE_DIR}" "${LOG_DIR_NAME}"
printf '%s\n' '========================================'
