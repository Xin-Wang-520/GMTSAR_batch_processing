#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 23, 2026

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

FRAMES=(F1 F2 F3)
TRANS_MIN_BYTES=$((20 * 1024 * 1024))

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./run3.6_merge_F123.sh
  ./run3.6_merge_F123.sh 1 MERGE_JOBS
  ./run3.6_merge_F123.sh 2 MERGE_JOBS

No arguments:
  Print the command guide and inspect the Run 3.5 outputs.
  No files are deleted and no merge processing starts.

Mode 1 (preview):
  1. Verify the F1/F2/F3 pair sets and required grids.
  2. If grids are missing, request explicit DELETE confirmation before
     deleting that pair directory from all three frames.
  3. Delete temporary F*/intf_20*.in and F*/intf_20*.log files.
  4. Select the first, middle and last records directly from merge_list.
  5. Merge them and plot corr.grd, mask.grd and phasefilt.grd as GMT PDFs.

Mode 2 (full merge):
  Require a completed mode-1 preview, replace the preview output
  directories, and merge all accepted interferogram pairs.

MERGE_JOBS:
  Maximum number of interferogram pairs merged concurrently.
  Default: 15. Reduce it for computers with limited CPU or memory.
EOF
}

show_guide() {
    cat <<'EOF'
========================================
Run 3.6 command guide (processing NOT started)

Step 1 - merge the first, middle and last merge_list records and plot them:
  ./run3.6_merge_F123.sh 1 15

Step 2 - after inspecting the plots, merge all pairs:
  ./run3.6_merge_F123.sh 2 15

Parallel setting:
  15 = merge at most fifteen interferogram pairs concurrently (default)
  Use a smaller value, such as 5 or 3, if CPU or memory is limited.

This command will:
  1. Confirm that F1/F2/F3 have identical interferogram-pair directories.
  2. Check corr.grd, mask.grd and phasefilt.grd for every pair.
     If any one frame is incomplete, the same pair must be removed from
     F1/F2/F3. Deletion requires typing DELETE at the terminal.
  3. Remove Run 3.5 temporary files only:
       F*/intf_20*.in
       F*/intf_20*.log
     F*/intf.in and F*/itp.log are NOT removed.
  4. Create merge/ and generate intflist and merge_list.
  5. Mode 1 selects the first, middle and last records directly from the final
     master-first merge_list and creates:
       merge/run3.6_check_merge_seams_plots/<pair>_corr.pdf
       merge/run3.6_check_merge_seams_plots/<pair>_mask.pdf
       merge/run3.6_check_merge_seams_plots/<pair>_phasefilt.pdf
  6. Mode 1 stops after plotting. Inspect the F1/F2/F3 seams.
  7. Mode 2 removes merge/20* preview-result directories and preview control
     files, keeps only run3.6_check_merge_seams_plots/, and then merges all pairs.
  8. Mode 2 reuses merge/trans.dat only when it is larger than 20 MiB.
     A missing, empty or <= 20 MiB file is removed and generated again with
     the standard GMTSAR SAT_llt2rat program.

Long full-merge server run (after mode 1 is accepted):
  nohup ./run3.6_merge_F123.sh 2 15 \
    > run3.6_merge_F123.nohup.log 2>&1 &

Monitor:
  tail -f run3.6_merge_F123.nohup.log
  tail -f merge/merge_batch.log

Important:
  If missing grids are detected under nohup, deletion cannot be confirmed.
  The script stops safely. Rerun mode 1 in an interactive terminal to review
  the deletion plan and type DELETE.
========================================
EOF
}

list_pair_directories() {
    local directory="$1"
    local path
    shopt -s nullglob
    for path in "${directory}"/*; do
        [[ -d "${path}" ]] && basename -- "${path}"
    done
    shopt -u nullglob
}

count_cleanup_files() {
    local frame path count=0
    shopt -s nullglob
    for frame in "${FRAMES[@]}"; do
        for path in "${frame}"/intf_20*.in "${frame}"/intf_20*.log; do
            [[ -e "${path}" || -L "${path}" ]] && count=$((count + 1))
        done
    done
    shopt -u nullglob
    printf '%d\n' "${count}"
}

make_pair_lists() {
    local temp_dir="$1"
    local frame
    for frame in "${FRAMES[@]}"; do
        [[ -d "${frame}/intf_all" ]] || die "cannot find ${frame}/intf_all"
        list_pair_directories "${frame}/intf_all" | sort > "${temp_dir}/${frame}.pairs"
        [[ -s "${temp_dir}/${frame}.pairs" ]] || die "no pair directories found in ${frame}/intf_all"
    done
}

check_pair_lists() {
    local temp_dir="$1"
    local f1_count f2_count f3_count
    f1_count="$(wc -l < "${temp_dir}/F1.pairs" | awk '{print $1}')"
    f2_count="$(wc -l < "${temp_dir}/F2.pairs" | awk '{print $1}')"
    f3_count="$(wc -l < "${temp_dir}/F3.pairs" | awk '{print $1}')"

    printf 'Interferogram directories:\n'
    printf '  F1: %s\n' "${f1_count}"
    printf '  F2: %s\n' "${f2_count}"
    printf '  F3: %s\n' "${f3_count}"

    if ! cmp -s "${temp_dir}/F1.pairs" "${temp_dir}/F2.pairs"; then
        printf '[CHECK ERROR] F1 and F2 pair sets differ. First differences:\n' >&2
        diff -u "${temp_dir}/F1.pairs" "${temp_dir}/F2.pairs" | head -n 20 >&2 || true
        return 1
    fi
    if ! cmp -s "${temp_dir}/F1.pairs" "${temp_dir}/F3.pairs"; then
        printf '[CHECK ERROR] F1 and F3 pair sets differ. First differences:\n' >&2
        diff -u "${temp_dir}/F1.pairs" "${temp_dir}/F3.pairs" | head -n 20 >&2 || true
        return 1
    fi

    printf '[CHECK OK] F1/F2/F3 contain the same %s interferogram pairs.\n' "${f1_count}"
}

check_required_grids() {
    local temp_dir="$1"
    local report_file="$2"
    local frame pair grid missing_csv
    local total corr_count mask_count phasefilt_count

    : > "${report_file}"
    printf 'Required-grid completeness:\n'

    for frame in "${FRAMES[@]}"; do
        total=0
        corr_count=0
        mask_count=0
        phasefilt_count=0

        while IFS= read -r pair; do
            [[ -n "${pair}" ]] || continue
            total=$((total + 1))
            missing_csv=""

            for grid in corr.grd mask.grd phasefilt.grd; do
                if [[ -s "${frame}/intf_all/${pair}/${grid}" ]]; then
                    case "${grid}" in
                        corr.grd) corr_count=$((corr_count + 1)) ;;
                        mask.grd) mask_count=$((mask_count + 1)) ;;
                        phasefilt.grd) phasefilt_count=$((phasefilt_count + 1)) ;;
                    esac
                else
                    [[ -z "${missing_csv}" ]] || missing_csv+=","
                    missing_csv+="${grid}"
                fi
            done

            if [[ -n "${missing_csv}" ]]; then
                printf '%s\t%s\t%s\n' \
                    "${frame}" "${pair}" "${missing_csv}" >> "${report_file}"
            fi
        done < "${temp_dir}/${frame}.pairs"

        printf '  %s: pairs=%d  corr.grd=%d  mask.grd=%d  phasefilt.grd=%d\n' \
            "${frame}" "${total}" "${corr_count}" "${mask_count}" "${phasefilt_count}"
    done

    if [[ -s "${report_file}" ]]; then
        printf '[CHECK ERROR] Missing or empty required grids:\n' >&2
        while IFS=$'\t' read -r frame pair missing_csv; do
            printf '  %s  %s  missing: %s\n' \
                "${frame}" "${pair}" "${missing_csv}" >&2
        done < "${report_file}"
        return 1
    fi

    printf '%s\n' '[CHECK OK] Every pair contains non-empty corr.grd, mask.grd and phasefilt.grd.'
}

confirm_and_delete_missing_pairs() {
    local missing_report="$1"
    local temp_dir="$2"
    local bad_pairs_file="${temp_dir}/bad_pairs.list"
    local frame pair missing confirmation target
    local pair_count directory_count=0

    awk -F'\t' 'NF >= 2 {print $2}' "${missing_report}" | sort -u > "${bad_pairs_file}"
    pair_count="$(wc -l < "${bad_pairs_file}" | awk '{print $1}')"
    (( pair_count > 0 )) || die "missing-grid report is empty"

    cp "${missing_report}" run3.6_missing_grids.tsv

    printf '%s\n' '========================================'
    printf '[DELETE PLAN] %d incomplete interferogram pair(s) were found.\n' "${pair_count}"
    printf '%s\n' 'Missing-grid sources:'
    while IFS=$'\t' read -r frame pair missing; do
        printf '  %s  %s  missing: %s\n' "${frame}" "${pair}" "${missing}"
    done < "${missing_report}"

    printf '%s\n' 'The following pair IDs will be deleted from F1, F2 and F3:'
    while IFS= read -r pair; do
        [[ "${pair}" =~ ^[0-9]{7,8}_[0-9]{7,8}$ ]] ||
            die "unsafe interferogram directory name in deletion plan: ${pair}"
        printf '  %s\n' "${pair}"
    done < "${bad_pairs_file}"
    printf 'Maximum directories to delete: %d pairs x 3 frames = %d\n' \
        "${pair_count}" "$((pair_count * 3))"
    printf 'Detailed report: %s/run3.6_missing_grids.tsv\n' "${ROOT_DIR}"
    printf '%s\n' '========================================'

    if [[ ! -t 0 ]]; then
        die "interactive deletion approval is required; rerun './run3.6_merge_F123.sh 1 15' in a terminal"
    fi

    printf '%s' 'Type DELETE to remove these pair directories from F1/F2/F3, or press Enter to cancel: '
    IFS= read -r confirmation
    if [[ "${confirmation}" != "DELETE" ]]; then
        die "deletion was not approved; no pair directories were removed"
    fi

    : > run3.6_deleted_pairs.tsv
    while IFS= read -r pair; do
        for frame in "${FRAMES[@]}"; do
            target="${frame}/intf_all/${pair}"
            if [[ -d "${target}" ]]; then
                rm -rf -- "${target}"
                directory_count=$((directory_count + 1))
                printf '%s\t%s\t%s\n' "${frame}" "${pair}" "${target}" >> run3.6_deleted_pairs.tsv
            fi
        done
    done < "${bad_pairs_file}"

    printf '[DELETE OK] Removed %d pair directories after explicit approval.\n' "${directory_count}"
    printf 'Deletion record: %s/run3.6_deleted_pairs.tsv\n' "${ROOT_DIR}"
    printf '%s\n' '[KEEP] F1/F2/F3 intf.in files were not changed.'
}

check_common_inputs() {
    local frame
    for frame in "${FRAMES[@]}"; do
        [[ -d "${frame}" ]] || die "cannot find ${frame}/"
        [[ -d "${frame}/intf_all" ]] || die "cannot find ${frame}/intf_all/"
    done
    [[ -s F1/batch_tops.config ]] || die "cannot find or empty: F1/batch_tops.config"
    [[ -e topo/dem.grd ]] || die "cannot find topo/dem.grd"
}

default_check() {
    local temp_dir cleanup_count result=0
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/run3.6.check.XXXXXX")"

    printf 'Default input check (processing NOT started)\n'
    printf 'Track root: %s\n' "$(pwd -P)"

    if check_common_inputs && make_pair_lists "${temp_dir}" && check_pair_lists "${temp_dir}"; then
        if ! check_required_grids "${temp_dir}" "${temp_dir}/missing_grids.tsv"; then
            result=1
        fi
    else
        result=1
    fi

    cleanup_count="$(count_cleanup_files)"
    printf 'Temporary intf_20*.in/log files found: %s\n' "${cleanup_count}"
    printf '[INFO] These files were NOT deleted.\n'
    printf '[INFO] Merge processing was NOT started.\n'
    rm -rf -- "${temp_dir}"
    return "${result}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (( $# == 0 )); then
    show_guide
    default_check
    exit $?
fi

(( $# == 2 )) ||
    die "use no arguments for the guide, or use: ./run3.6_merge_F123.sh MODE MERGE_JOBS"
MODE="$1"
[[ "${MODE}" == "1" || "${MODE}" == "2" ]] || die "MODE must be 1 (preview) or 2 (full merge)"
MERGE_JOBS="$2"
[[ "${MERGE_JOBS}" =~ ^[1-9][0-9]*$ ]] ||
    die "MERGE_JOBS must be a positive integer: ${MERGE_JOBS}"

for command_name in awk basename cmp cp diff find gmt grep head mktemp mv nohup sed sort tail tcsh wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

CREATE_MERGE_INPUT="${CREATE_MERGE_INPUT:-$(command -v create_merge_input.csh || true)}"
MERGE_BATCH_SCRIPT="${MERGE_BATCH_SCRIPT:-$(command -v merge_batch_parallel.sh || true)}"
[[ -n "${CREATE_MERGE_INPUT}" ]] ||
    die "create_merge_input.csh was not found in PATH"
[[ -n "${MERGE_BATCH_SCRIPT}" ]] ||
    die "merge_batch_parallel.sh was not found in PATH"

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number track directory (current: ${ROOT_DIR})"

check_common_inputs

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run3.6.XXXXXX")"
PREVIEW_TRANS_PLACEHOLDER=0
cleanup_run36_exit() {
    rm -rf -- "${TEMP_DIR}"
    if (( PREVIEW_TRANS_PLACEHOLDER == 1 )) && \
        [[ ( -e merge/trans.dat || -L merge/trans.dat ) && ! -s merge/trans.dat ]]; then
        rm -f -- merge/trans.dat
    fi
}
trap cleanup_run36_exit EXIT
make_pair_lists "${TEMP_DIR}"
check_pair_lists "${TEMP_DIR}" || die "pair-set validation failed; merge was not started"
if check_required_grids "${TEMP_DIR}" "${TEMP_DIR}/missing_grids.tsv"; then
    rm -f -- run3.6_missing_grids.tsv
else
    confirm_and_delete_missing_pairs "${TEMP_DIR}/missing_grids.tsv" "${TEMP_DIR}"

    make_pair_lists "${TEMP_DIR}"
    check_pair_lists "${TEMP_DIR}" ||
        die "pair sets differ after approved deletion; merge was not started"
    check_required_grids "${TEMP_DIR}" "${TEMP_DIR}/missing_after_delete.tsv" ||
        die "required grids are still incomplete after approved deletion"
fi
EXPECTED_PAIRS="$(wc -l < "${TEMP_DIR}/F1.pairs" | awk '{print $1}')"

for merge_pid_file in merge/merge_batch.pid merge/preview_merge.pid; do
    if [[ -s "${merge_pid_file}" ]]; then
        old_pid="$(awk 'NR == 1 {print $1; exit}' "${merge_pid_file}")"
        if [[ "${old_pid}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${old_pid}" 2>/dev/null; then
            die "a Run 3.6 merge job is already running (PID ${old_pid}, file ${merge_pid_file})"
        fi
    fi
done

if [[ -d merge/intf_all ]] && find merge/intf_all -mindepth 1 -print -quit | grep -q .; then
    die "merge/intf_all already contains results; move or inspect it before rerunning Run 3.6"
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.6: merge F1/F2/F3 interferograms'
if [[ "${MODE}" == "1" ]]; then
    printf '%s\n' 'Run mode               : 1 (three-pair preview)'
else
    printf '%s\n' 'Run mode               : 2 (full merge)'
fi
printf 'Track root             : %s\n' "${ROOT_DIR}"
printf 'Interferogram pairs    : %s\n' "${EXPECTED_PAIRS}"
printf 'Parallel merge jobs    : %s\n' "${MERGE_JOBS}"
printf 'Merge-list generator   : %s\n' "${CREATE_MERGE_INPUT}"
printf 'Parallel merge driver  : %s\n' "${MERGE_BATCH_SCRIPT}"
printf '%s\n' '========================================'

printf '[STEP 1] Remove temporary Run 3.5 intf_20*.in/log files\n'
CLEANUP_FILES=()
shopt -s nullglob
for frame in "${FRAMES[@]}"; do
    for path in "${frame}"/intf_20*.in "${frame}"/intf_20*.log; do
        [[ -e "${path}" || -L "${path}" ]] && CLEANUP_FILES+=("${path}")
    done
done
shopt -u nullglob

if (( ${#CLEANUP_FILES[@]} > 0 )); then
    rm -f -- "${CLEANUP_FILES[@]}"
fi
printf '[CLEANUP OK] Removed %d temporary files.\n' "${#CLEANUP_FILES[@]}"
printf '[KEEP] F*/intf.in, F*/itp.log and F*/intf_all/ were preserved.\n'

printf '[STEP 2] Create merge/intflist and merge/merge_list\n'
mkdir -p merge
cp "${TEMP_DIR}/F1.pairs" merge/intflist

(
    cd merge
    tcsh "${CREATE_MERGE_INPUT}" intflist .. 0 > merge_list
)
[[ -s merge/merge_list ]] || die "merge/merge_list was not generated"

MERGE_LINES="$(awk 'NF {count++} END {print count+0}' merge/merge_list)"
(( MERGE_LINES == EXPECTED_PAIRS )) ||
    die "merge_list has ${MERGE_LINES} lines; expected ${EXPECTED_PAIRS}"

BAD_SEGMENTS="$(awk -F, 'NF != 3 {count++} END {print count+0}' merge/merge_list)"
(( BAD_SEGMENTS == 0 )) ||
    die "merge_list contains ${BAD_SEGMENTS} line(s) without exactly three F1/F2/F3 segments"

printf '[MERGE LIST OK] %s lines, each containing F1/F2/F3 inputs.\n' "${MERGE_LINES}"

printf '[STEP 3] Prepare merge configuration and master-first ordering\n'
cp F1/batch_tops.config merge/batch_tops.config

MASTER_IMAGE="$(awk -F= '
    $1 ~ /^[[:space:]]*master_image[[:space:]]*$/ {
        value=$2
        sub(/[[:space:]]*#.*/, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
    }
' merge/batch_tops.config)"
[[ -n "${MASTER_IMAGE}" ]] || die "failed to read master_image from merge/batch_tops.config"

MASTER_DATE="$(printf '%s\n' "${MASTER_IMAGE}" | grep -oE '[0-9]{8}' | head -n 1)"
[[ -n "${MASTER_DATE}" ]] || die "failed to extract master date from ${MASTER_IMAGE}"

cp merge/merge_list "${TEMP_DIR}/merge_list.before_master_sort"
rm -f -- merge/merge_list.orig
awk -v f1="S1_${MASTER_DATE}_ALL_F1.PRM" \
    -v f2="S1_${MASTER_DATE}_ALL_F2.PRM" \
    -v f3="S1_${MASTER_DATE}_ALL_F3.PRM" '
{
    is_top=0
    nseg=split($0, seg, ",")
    for (i=1; i<=nseg; i++) {
        n=split(seg[i], field, ":")
        if (n >= 3 && (field[2] == f1 || field[2] == f2 || field[2] == f3)) {
            is_top=1
            break
        }
    }
    if (is_top) top[++ntop]=$0
    else rest[++nrest]=$0
}
END {
    for (i=1; i<=ntop; i++) print top[i]
    for (i=1; i<=nrest; i++) print rest[i]
}
' "${TEMP_DIR}/merge_list.before_master_sort" > merge/merge_list

if grep -qE '^[[:space:]]*proc_stage[[:space:]]*=' merge/batch_tops.config; then
    sed -i -E 's|^[[:space:]]*proc_stage[[:space:]]*=.*|proc_stage = 1|' merge/batch_tops.config
else
    printf '%s\n' 'proc_stage = 1' >> merge/batch_tops.config
fi

ln -sfn ../topo/dem.grd merge/dem.grd
printf 'Master image           : %s\n' "${MASTER_IMAGE}"
printf 'Merge proc_stage       : 1\n'
printf 'DEM link               : merge/dem.grd -> ../topo/dem.grd\n'

run_merge_driver() {
    local input_list="$1"
    local log_name="$2"
    local pid_name="$3"
    local config_name="$4"
    local merge_pid merge_status

    rm -f -- "merge/${log_name}" "merge/${pid_name}"
    (
        cd merge
        # The original GMTSAR driver has no job-count argument. GNU Parallel
        # reads default options from PARALLEL, so this limits its job count.
        export PARALLEL="--jobs ${MERGE_JOBS}"
        exec nohup "${MERGE_BATCH_SCRIPT}" "${input_list}" "${config_name}"
    ) > "merge/${log_name}" 2>&1 &
    merge_pid="$!"
    printf '%s\n' "${merge_pid}" > "merge/${pid_name}"
    printf '[STARTED] PID=%s, log=%s/merge/%s\n' \
        "${merge_pid}" "${ROOT_DIR}" "${log_name}"
    printf '[WAIT] Parallel merge is running...\n'

    set +e
    wait "${merge_pid}"
    merge_status="$?"
    set -e

    if (( merge_status != 0 )); then
        printf '[FAILED] merge_batch_parallel.sh exited with status %d\n' "${merge_status}" >&2
        printf '%s\n' 'Last 30 log lines:' >&2
        tail -n 30 "merge/${log_name}" | sed 's/^/  /' >&2
        return 1
    fi
}

set_config_value() {
    local config_file="$1"
    local key="$2"
    local value="$3"

    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${config_file}"; then
        sed -i -E \
            "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" \
            "${config_file}"
    else
        printf '%s = %s\n' "${key}" "${value}" >> "${config_file}"
    fi
}

pair_id_from_merge_line() {
    awk -F, '{
        split($1, field, ":")
        path=field[1]
        sub(/\/$/, "", path)
        n=split(path, part, "/")
        print part[n]
    }'
}

plot_preview_grid() {
    local pair="$1"
    local grid="$2"
    local stem="${grid%.grd}"
    local cpt_args tick label unit

    case "${grid}" in
        corr.grd)
            cpt_args='-Cgray -T0/1/0.05 -Z -M --COLOR_NAN=gray'
            tick='0.2'
            label='Correlation'
            unit='dimensionless'
            ;;
        mask.grd)
            cpt_args='-Cgray -T0/1/0.05 -Z -M --COLOR_NAN=gray'
            tick='0.2'
            label='Mask'
            unit='0/1'
            ;;
        phasefilt.grd)
            cpt_args='-Crainbow -T-3.15/3.15/0.05 -Z --COLOR_NAN=gray'
            tick='1.57'
            label='Filtered phase'
            unit='rad'
            ;;
        *) die "unsupported preview grid: ${grid}" ;;
    esac

    (
        cd merge/run3.6_check_merge_seams_plots
        # cpt_args is intentionally split into GMT command options.
        # shellcheck disable=SC2086
        gmt makecpt ${cpt_args} > "${pair}_${stem}.cpt"
        # Follow the GMT classic plotting style used by GMTSAR geocode.csh:
        # Range/Azimuth axes, a top horizontal color bar, then PDF conversion.
        gmt grdimage "../${pair}/${grid}" -JX6.5i \
            -C"${pair}_${stem}.cpt" \
            -Bxaf+lRange -Byaf+lAzimuth -BWSen \
            -X1.3i -Y3i -P -K > "${pair}_${stem}.ps"
        gmt psscale -R"../${pair}/${grid}" -J \
            -DJTC+w5i/0.2i+h \
            -C"${pair}_${stem}.cpt" \
            -Bxa"${tick}"+l"${label}" -By+l"${unit}" \
            -O >> "${pair}_${stem}.ps"
        gmt psconvert -Tf -P -A -Z "${pair}_${stem}.ps"
        rm -f -- "${pair}_${stem}.cpt"
        [[ -s "${pair}_${stem}.pdf" ]] ||
            die "GMT PDF was not generated: ${pair}_${stem}.pdf"
    )
}

if [[ "${MODE}" == "1" ]]; then
    [[ ! -s merge/run3.6_preview_complete ]] ||
        die "a completed preview already exists; inspect it and run mode 2"

    printf '[STEP 4] Select the first, middle and last records from merge_list\n'
    MIDDLE_LINE="$(( (MERGE_LINES + 1) / 2 ))"
    awk -v middle="${MIDDLE_LINE}" -v last="${MERGE_LINES}" '
        NR == 1 || NR == middle || NR == last
    ' merge/merge_list > merge/preview_merge_list
    TARGET_LINES="$(wc -l < merge/preview_merge_list | awk '{print $1}')"
    (( TARGET_LINES == 3 )) || die "failed to select first/middle/last preview records from merge_list"
    pair_id_from_merge_line < merge/preview_merge_list > merge/run3.6_preview_pairs.txt
    cp merge/run3.6_preview_pairs.txt merge/run3.6_preview_plot_pairs.txt

    printf '%s\n' 'merge_list preview targets:'
    awk 'NR == 1 {label="first"} NR == 2 {label="middle"} NR == 3 {label="last"} {print "  " label ": " $0}' \
        merge/run3.6_preview_plot_pairs.txt
    PREVIEW_LINES="$(wc -l < merge/preview_merge_list | awk '{print $1}')"
    printf 'Preview processing records: %s\n' "${PREVIEW_LINES}"

    while IFS= read -r pair; do
        [[ "${pair}" =~ ^[0-9]{7,8}_[0-9]{7,8}$ ]] ||
            die "invalid preview pair directory name: ${pair}"
        [[ ! -e "merge/${pair}" ]] ||
            die "preview output already exists: merge/${pair}; inspect or move it first"
    done < merge/run3.6_preview_pairs.txt

    printf '[PREVIEW CONFIG] Disable unwrap, geocoding and real trans.dat generation\n'
    cp merge/batch_tops.config merge/preview_batch_tops.config
    set_config_value merge/preview_batch_tops.config threshold_snaphu 0
    set_config_value merge/preview_batch_tops.config threshold_geocode 0
    set_config_value merge/preview_batch_tops.config correct_iono 0

    if [[ ! -s merge/trans.dat ]]; then
        rm -f -- merge/trans.dat
        : > merge/trans.dat
        PREVIEW_TRANS_PLACEHOLDER=1
        printf '%s\n' '[PREVIEW] Temporary empty trans.dat placeholder created; no LUT will be computed.'
    else
        printf '%s\n' '[PREVIEW] Existing non-empty merge/trans.dat will be reused.'
    fi

    run_merge_driver \
        preview_merge_list preview_merge.log preview_merge.pid preview_batch_tops.config

    if (( PREVIEW_TRANS_PLACEHOLDER == 1 )); then
        rm -f -- merge/trans.dat
        PREVIEW_TRANS_PLACEHOLDER=0
        printf '%s\n' '[PREVIEW] Empty trans.dat placeholder removed.'
    fi

    printf '[STEP 5] Validate and plot preview grids with GMT\n'
    mkdir -p merge/run3.6_check_merge_seams_plots
    while IFS= read -r pair; do
        for grid in corr.grd mask.grd phasefilt.grd; do
            [[ -s "merge/${pair}/${grid}" ]] ||
                die "preview output missing or empty: merge/${pair}/${grid}"
            plot_preview_grid "${pair}" "${grid}"
        done
    done < merge/run3.6_preview_plot_pairs.txt

    date '+%Y-%m-%d %H:%M:%S' > merge/run3.6_preview_complete
    printf '%s\n' '========================================'
    printf '%s\n' '[PREVIEW DONE] The first, middle and last merge_list records were plotted as PDFs.'
    printf 'Plots: %s/merge/run3.6_check_merge_seams_plots/\n' "${ROOT_DIR}"
    printf '%s\n' 'Inspect corr, mask and phasefilt for seams between F1/F2/F3.'
    printf '%s\n' 'If accepted, run the full merge:'
    printf '%s\n' '  ./run3.6_merge_F123.sh 2 15'
    printf '%s\n' '[INFO] Full merge was NOT started.'
    printf '%s\n' '========================================'
    exit 0
fi

[[ -s merge/run3.6_preview_complete ]] ||
    die "mode-1 preview is not complete; run './run3.6_merge_F123.sh 1 15' first"
[[ -s merge/run3.6_preview_pairs.txt ]] ||
    die "preview pair list is missing: merge/run3.6_preview_pairs.txt"
[[ -s merge/run3.6_preview_plot_pairs.txt ]] ||
    die "preview plot-pair list is missing: merge/run3.6_preview_plot_pairs.txt"
[[ ! -s merge/run3.6_full_complete ]] ||
    die "a completed full merge is already recorded in merge/run3.6_full_complete"

printf '[STEP 4] Keep seam-check PDFs and remove all mode-1 preview artifacts\n'

[[ -d merge/run3.6_check_merge_seams_plots ]] ||
    die "seam-check PDF directory is missing: merge/run3.6_check_merge_seams_plots"

REMOVED_20_DIRS=0
while IFS= read -r -d '' preview_dir; do
    rm -rf -- "${preview_dir}"
    REMOVED_20_DIRS=$((REMOVED_20_DIRS + 1))
done < <(find merge -mindepth 1 -maxdepth 1 -type d -name '20*' -print0)
printf '[CLEANUP OK] Removed %d merge/20* preview-result directories.\n' \
    "${REMOVED_20_DIRS}"

rm -f -- \
    merge/preview_merge.log \
    merge/preview_merge.pid \
    merge/preview_merge_list \
    merge/preview_target_merge_list \
    merge/preview_batch_tops.config \
    merge/run3.6_preview_complete \
    merge/run3.6_preview_pairs.txt \
    merge/run3.6_preview_plot_pairs.txt

printf '%s\n' '[CLEANUP OK] Preview control files removed.'
printf 'Kept seam-check plots: %s/merge/run3.6_check_merge_seams_plots/\n' "${ROOT_DIR}"

printf '[STEP 5] Validate trans.dat, start the full parallel merge and wait for completion\n'
TRANS_SIZE_BYTES=0
if [[ -e merge/trans.dat || -L merge/trans.dat ]]; then
    TRANS_SIZE_BYTES="$(wc -c < merge/trans.dat | awk '{print $1}')"
    [[ "${TRANS_SIZE_BYTES}" =~ ^[0-9]+$ ]] ||
        die "failed to determine merge/trans.dat size"
fi

if (( TRANS_SIZE_BYTES > TRANS_MIN_BYTES )); then
    printf '[STANDARD TRANS] Existing merge/trans.dat is %.2f MiB (> 20 MiB); reuse it.\n' \
        "$(awk -v bytes="${TRANS_SIZE_BYTES}" 'BEGIN {print bytes / 1024 / 1024}')"
else
    if [[ -e merge/trans.dat || -L merge/trans.dat ]]; then
        printf '[STANDARD TRANS] Existing merge/trans.dat is %.2f MiB (<= 20 MiB); remove and regenerate it.\n' \
            "$(awk -v bytes="${TRANS_SIZE_BYTES}" 'BEGIN {print bytes / 1024 / 1024}')"
        rm -f -- merge/trans.dat
    else
        printf '%s\n' '[STANDARD TRANS] merge/trans.dat is absent; generate it now.'
    fi
    printf '%s\n' '[STANDARD TRANS] Generator: GMTSAR SAT_llt2rat.'
fi

run_merge_driver merge_list merge_batch.log merge_batch.pid batch_tops.config
date '+%Y-%m-%d %H:%M:%S' > merge/run3.6_full_complete

printf '%s\n' '========================================'
printf '[DONE] Run 3.6 full merge command completed successfully.\n'
printf 'Merge-list pairs : %s\n' "${EXPECTED_PAIRS}"
printf 'Merge directory  : %s/merge\n' "${ROOT_DIR}"
printf 'Merge log        : %s/merge/merge_batch.log\n' "${ROOT_DIR}"
printf '%s\n' '========================================'
