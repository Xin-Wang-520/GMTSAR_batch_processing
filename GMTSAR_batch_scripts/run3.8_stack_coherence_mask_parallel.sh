#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 23, 2026
#
# Run 3.8: parallel stack-average coherence and coherence-mask generation.

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

DEFAULT_THRESHOLD="0.075"
DEFAULT_BATCH="50"
DEFAULT_JOBS="5"
LIST_NAME="grid_list"
FRAMES_PATTERN='20*'

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./run3.8_stack_coherence_mask_parallel.sh
  ./run3.8_stack_coherence_mask_parallel.sh THRESHOLD [BATCH] [JOBS]

No arguments:
  Print this guide and check merged corr.grd completeness.
  No files are created, removed or modified.

Formal processing:
  ./run3.8_stack_coherence_mask_parallel.sh 0.075 50 5

Arguments:
  THRESHOLD  Mean-coherence threshold used to create mask_def.grd.
             Default recommendation: 0.075
  BATCH      Number of corr.grd files summed by each batch job.
             Default: 50
  JOBS       Maximum batch jobs running concurrently.
             Default: 5; reduce it further if CPU, memory or storage I/O is limited.

Processing:
  1. Confirm every merge/20* pair has a non-empty corr.grd.
  2. Regenerate merge/grid_list from the validated merged products.
  3. Sum corr.grd files in parallel batches.
  4. Generate mean_corr.grd from all listed coherence grids.
  5. Generate mask_def.grd:
       1   = mean_corr >= THRESHOLD
       NaN = mean_corr <  THRESHOLD
  6. Plot mask_def.pdf with a gray NaN background and red valid mask.
  7. Remove temporary batch grids and logs after successful completion.

Outputs in merge/:
  grid_list
  mean_corr.grd
  mask_def.grd
  mask_def.pdf
EOF
}

require_track_root() {
    local root track
    root="$(pwd -P)"
    track="$(basename -- "${root}")"
    [[ "${track}" =~ ^T[0-9]+$ ]] ||
        die "run this script in a T-number track directory (current: ${root})"
    [[ -d merge ]] || die "cannot find merge/"
}

make_pair_list() {
    local output_file="$1"
    local path pair

    : > "${output_file}"
    while IFS= read -r -d '' path; do
        pair="$(basename -- "${path}")"
        [[ "${pair}" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] || continue
        printf '%s\n' "${pair}" >> "${output_file}"
    done < <(find merge -mindepth 1 -maxdepth 1 -type d -name "${FRAMES_PATTERN}" -print0)

    sort -u -o "${output_file}" "${output_file}"
    [[ -s "${output_file}" ]] ||
        die "no merged interferogram directories found under merge/"
}

check_corr_inputs() {
    local pair_list="$1"
    local corr_list="$2"
    local missing_list="$3"
    local pair
    local pair_count=0 corr_count=0

    : > "${corr_list}"
    : > "${missing_list}"

    while IFS= read -r pair; do
        [[ -n "${pair}" ]] || continue
        pair_count=$((pair_count + 1))
        if [[ -s "merge/${pair}/corr.grd" ]]; then
            # Store paths relative to merge/, where GMT processing runs.
            printf '%s/corr.grd\n' "${pair}" >> "${corr_list}"
            corr_count=$((corr_count + 1))
        else
            printf '%s\n' "${pair}" >> "${missing_list}"
        fi
    done < "${pair_list}"

    printf '%s\n' '========================================'
    printf '%s\n' 'Run 3.8 merged-coherence input check'
    printf 'Merged pair directories : %d\n' "${pair_count}"
    printf 'Non-empty corr.grd      : %d\n' "${corr_count}"
    printf '%s\n' '========================================'

    if [[ -s "${missing_list}" ]]; then
        printf '%s\n' '[CHECK ERROR] Missing or empty corr.grd:' >&2
        while IFS= read -r pair; do
            printf '  %s  missing: corr.grd\n' "${pair}" >&2
        done < "${missing_list}"
        return 1
    fi

    printf '[CHECK OK] All %d merged pairs contain a non-empty corr.grd.\n' \
        "${pair_count}"
}

validate_parameters() {
    [[ "${THRESHOLD}" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
        die "THRESHOLD must be numeric: ${THRESHOLD}"
    awk -v value="${THRESHOLD}" 'BEGIN {exit !(value >= 0 && value <= 1)}' ||
        die "THRESHOLD must be between 0 and 1: ${THRESHOLD}"
    [[ "${BATCH}" =~ ^[1-9][0-9]*$ ]] ||
        die "BATCH must be a positive integer: ${BATCH}"
    [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] ||
        die "JOBS must be a positive integer: ${JOBS}"
}

if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    usage
    exit 0
fi

for command_name in awk basename cp find head mktemp sort split wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

require_track_root
ROOT_DIR="$(pwd -P)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run3.8.XXXXXX")"
trap 'rm -rf -- "${TEMP_DIR}"' EXIT
PAIR_LIST="${TEMP_DIR}/pairs.txt"
VALID_CORR_LIST="${TEMP_DIR}/corr.txt"
MISSING_LIST="${TEMP_DIR}/missing.txt"

make_pair_list "${PAIR_LIST}"

if ! check_corr_inputs "${PAIR_LIST}" "${VALID_CORR_LIST}" "${MISSING_LIST}"; then
    printf '%s\n' '[INFO] Stack processing was not started.' >&2
    exit 1
fi

if (( $# == 0 )); then
    usage
    printf '%s\n' '========================================'
    printf '%s\n' '[CHECK ONLY] Inputs are complete; processing was NOT started.'
    printf '%s\n' '[NEXT] Recommended formal run:'
    printf '%s\n' '  ./run3.8_stack_coherence_mask_parallel.sh 0.075 50 5'
    printf '%s\n' '========================================'
    exit 0
fi

(( $# >= 1 && $# <= 3 )) ||
    die "formal usage: ./run3.8_stack_coherence_mask_parallel.sh THRESHOLD [BATCH] [JOBS]"
THRESHOLD="$1"
BATCH="${2:-${DEFAULT_BATCH}}"
JOBS="${3:-${DEFAULT_JOBS}}"
validate_parameters

for command_name in gmt xargs; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

cd merge
cp "${VALID_CORR_LIST}" "${LIST_NAME}"
CT="$(wc -l < "${LIST_NAME}" | awk '{print $1}')"
(( CT > 0 )) || die "generated list is empty: merge/${LIST_NAME}"
FIRST="$(head -n 1 "${LIST_NAME}")"
[[ -s "${FIRST}" ]] || die "first corr grid is missing or empty: merge/${FIRST}"

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.8: parallel stack coherence mask'
printf 'Track root             : %s\n' "${ROOT_DIR}"
printf 'Working directory      : %s\n' "$(pwd -P)"
printf 'Coherence grids        : %s\n' "${CT}"
printf 'Threshold              : %s\n' "${THRESHOLD}"
printf 'Grids per batch        : %s\n' "${BATCH}"
printf 'Parallel batch jobs    : %s\n' "${JOBS}"
printf 'Grid list              : %s/merge/%s\n' "${ROOT_DIR}" "${LIST_NAME}"
printf '%s\n' '========================================'

printf '%s\n' '[STEP 1] Remove old Run 3.8 outputs and prepare temporary batches'
rm -rf -- stack_batches
rm -f -- mean_corr.grd mask_def.grd mask_sum.grd mask_sum_next.grd \
    mask_def.cpt mask_def.ps mask_def.pdf
mkdir -p stack_batches

printf '%s\n' '[STEP 2] Split coherence-grid list into batches'
split -l "${BATCH}" -d -a 5 "${LIST_NAME}" stack_batches/batch_
NBATCH="$(find stack_batches -maxdepth 1 -type f -name 'batch_[0-9]*' | wc -l | awk '{print $1}')"
(( NBATCH > 0 )) || die "no batch lists were generated"
printf 'Batch lists            : %s\n' "${NBATCH}"

printf '%s\n' '[STEP 3] Create the isolated batch-sum worker'
cat > stack_batches/run_one_batch.sh <<'EOF_WORKER'
#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

BLIST="$1"
OUT="$2"
LOG="$3"

{
    printf 'Batch list : %s\n' "${BLIST}"
    printf 'Output     : %s\n' "${OUT}"
    printf 'Start      : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"

    files=()
    while IFS= read -r file; do
        [[ -n "${file}" ]] && files+=("${file}")
    done < "${BLIST}"
    n="${#files[@]}"
    (( n > 0 )) || {
        printf '[ERROR] Empty batch: %s\n' "${BLIST}" >&2
        exit 1
    }

    for file in "${files[@]}"; do
        [[ -s "${file}" ]] || {
            printf '[ERROR] Missing or empty grid: %s\n' "${file}" >&2
            exit 1
        }
    done

    if (( n == 1 )); then
        cp "${files[0]}" "${OUT}"
    else
        command=(gmt grdmath "${files[0]}")
        for ((i=1; i<n; i++)); do
            command+=("${files[i]}" ADD)
        done
        command+=(= "${OUT}")
        printf '[RUN]'
        printf ' %q' "${command[@]}"
        printf '\n'
        "${command[@]}"
    fi

    printf 'End        : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[OK] %s\n' "${OUT}"
} > "${LOG}" 2>&1
EOF_WORKER
chmod +x stack_batches/run_one_batch.sh

printf '%s\n' '[STEP 4] Sum batches in parallel'
: > stack_batches/batch_jobs.txt
INDEX=0
while IFS= read -r BLIST; do
    INDEX=$((INDEX + 1))
    OUT="$(printf 'stack_batches/batch_sum_%05d.grd' "${INDEX}")"
    LOG="$(printf 'stack_batches/batch_sum_%05d.log' "${INDEX}")"
    printf "stack_batches/run_one_batch.sh '%s' '%s' '%s'\\n" \
        "${BLIST}" "${OUT}" "${LOG}" >> stack_batches/batch_jobs.txt
done < <(find stack_batches -maxdepth 1 -type f -name 'batch_[0-9]*' | sort)

if command -v parallel >/dev/null 2>&1; then
    parallel --jobs "${JOBS}" --halt soon,fail=1 < stack_batches/batch_jobs.txt
else
    printf '%s\n' '[WARN] GNU parallel not found; using xargs -P.'
    xargs -I{} -P "${JOBS}" bash -c '{}' < stack_batches/batch_jobs.txt
fi

BATCH_GRIDS=()
while IFS= read -r BATCH_GRID; do
    [[ -n "${BATCH_GRID}" ]] && BATCH_GRIDS+=("${BATCH_GRID}")
done < <(find stack_batches -maxdepth 1 -type f -name 'batch_sum_*.grd' | sort)
(( ${#BATCH_GRIDS[@]} == NBATCH )) ||
    die "generated ${#BATCH_GRIDS[@]} batch grids; expected ${NBATCH}"

printf '%s\n' '[STEP 5] Combine batch sums'
gmt grdmath "${FIRST}" 0 MUL = mask_sum.grd
for BATCH_GRID in "${BATCH_GRIDS[@]}"; do
    printf 'Add batch sum: %s\n' "${BATCH_GRID}"
    gmt grdmath mask_sum.grd "${BATCH_GRID}" ADD = mask_sum_next.grd
    mv -f -- mask_sum_next.grd mask_sum.grd
done

printf '%s\n' '[STEP 6] Calculate mean coherence'
gmt grdmath mask_sum.grd "${CT}" DIV = mean_corr.grd
[[ -s mean_corr.grd ]] || die "mean_corr.grd was not generated"

printf '%s\n' '[STEP 7] Create the threshold mask'
gmt grdmath mean_corr.grd "${THRESHOLD}" GE 0 NAN = mask_def.grd
[[ -s mask_def.grd ]] || die "mask_def.grd was not generated"

printf '%s\n' '[STEP 8] Inspect output grids'
gmt grdinfo mean_corr.grd | head
GMT_MASK_INFO="$(gmt grdinfo mask_def.grd)"
printf '%s\n' "${GMT_MASK_INFO}" | head

printf '%s\n' '[STEP 9] Plot mask_def.pdf (gray background, red valid mask)'
rm -f -- mask_def.cpt mask_def.ps mask_def.pdf gmt.conf gmt.history .gmtcommands4
cat > mask_def.cpt <<'EOF_CPT'
0.0  245 245 245   0.2  255 210 210
0.2  255 210 210   0.4  255 160 160
0.4  255 160 160   0.6  255 100 100
0.6  255 100 100   0.8  255  50  50
0.8  255  50  50   1.0  255   0   0
B    160 160 160
F    255   0   0
N    160 160 160
EOF_CPT

gmt grdimage mask_def.grd \
    -JX6.5i \
    -Cmask_def.cpt \
    -Bxaf+lRange \
    -Byaf+lAzimuth \
    -BWSen+t"Coherence mask: mean corr >= ${THRESHOLD}" \
    -X1.2i -Y2.8i -P -K > mask_def.ps

gmt psscale \
    -Rmask_def.grd -J \
    -DJBC+w5.0i/0.25i+h+o0i/0.35i \
    -Cmask_def.cpt \
    -Bxa0.2f0.1 \
    -O >> mask_def.ps

gmt psconvert -Tf -P -A -Z mask_def.ps
[[ -s mask_def.pdf ]] || die "mask_def.pdf was not generated"
rm -f -- mask_def.cpt gmt.conf gmt.history .gmtcommands4

printf '%s\n' '[STEP 10] Remove successful-run temporary files'
rm -f -- mask_sum.grd mask_sum_next.grd
rm -rf -- stack_batches

printf '%s\n' '========================================'
printf '%s\n' '[DONE] Run 3.8 completed successfully.'
printf 'Input corr grids : %s\n' "${CT}"
printf 'Threshold        : %s\n' "${THRESHOLD}"
printf 'Mean coherence   : %s/merge/mean_corr.grd\n' "${ROOT_DIR}"
printf 'Mask grid        : %s/merge/mask_def.grd\n' "${ROOT_DIR}"
printf 'Mask figure      : %s/merge/mask_def.pdf\n' "${ROOT_DIR}"
printf '%s\n' '========================================'
