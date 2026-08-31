#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 23, 2026
#
# Run 3.7: validate and plot merged corr.grd and phasefilt.grd products.

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

OUTPUT_NAME="run3.7_corr_phasefilt_jpg"
CHECK_MARKER="merge/run3.7_check_complete"
MISSING_REPORT="merge/run3.7_missing_grids.tsv"

# Plot settings follow the Run 3.6 seam-check figures.
PLOT_DPI="${RUN37_DPI:-120}"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./run3.7_plot_merge_corr_phasefilt.sh
  ./run3.7_plot_merge_corr_phasefilt.sh 1
  ./run3.7_plot_merge_corr_phasefilt.sh 2
  ./run3.7_plot_merge_corr_phasefilt.sh 2 yearly [PLOT_JOBS]
  ./run3.7_plot_merge_corr_phasefilt.sh 2 DATE [PLOT_JOBS]
  ./run3.7_plot_merge_corr_phasefilt.sh 2 PAIR_ID [PLOT_JOBS]
  ./run3.7_plot_merge_corr_phasefilt.sh 2 all [PLOT_JOBS]
  ./run3.7_plot_merge_corr_phasefilt.sh 2 @PAIR_LIST [PLOT_JOBS]

No arguments:
  Print this guide. No check or plotting starts.

Mode 1 - validate all merged interferograms:
  Confirm that every merge/20* pair directory contains non-empty:
    corr.grd
    phasefilt.grd
  No interferogram directories or grids are deleted.

Mode 2 - create JPG previews:
  No selector or yearly
             Recommended default: group by the year of the first acquisition
             and plot pairs at approximately the 25% and 75% positions of
             that year's sorted pair list.
             If a year contains only one pair, plot that pair once.
  DATE       Plot every pair containing this acquisition date,
             for example 2021051.
  PAIR_ID    Plot one exact pair, for example 2021051_2021063.
  all        Plot every validated merged interferogram.
  @FILE      Plot pair IDs listed in FILE, one pair per line.
  PLOT_JOBS  Maximum pairs plotted concurrently; default: 5.

Outputs:
  merge/run3.7_corr_phasefilt_jpg/corr/<pair>_corr.jpg
  merge/run3.7_corr_phasefilt_jpg/phasefilt/<pair>_phasefilt.jpg

No per-pair output directories or plot.log files are retained.

Recommended workflow:
  ./run3.7_plot_merge_corr_phasefilt.sh 1
  ./run3.7_plot_merge_corr_phasefilt.sh 2

Other choices:
  ./run3.7_plot_merge_corr_phasefilt.sh 2 2021051 5
  ./run3.7_plot_merge_corr_phasefilt.sh 2 2021051_2021063 1
  ./run3.7_plot_merge_corr_phasefilt.sh 2 all 5
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
    done < <(find merge -mindepth 1 -maxdepth 1 -type d -name '20*' -print0)
    sort -u -o "${output_file}" "${output_file}"
    [[ -s "${output_file}" ]] || die "no merged interferogram directories found under merge/"
}

validate_merged_grids() {
    local pair_list="$1"
    local report_file="$2"
    local pair grid missing_csv
    local pair_count=0 corr_count=0 phase_count=0

    : > "${report_file}"
    while IFS= read -r pair; do
        [[ -n "${pair}" ]] || continue
        pair_count=$((pair_count + 1))
        missing_csv=""

        for grid in corr.grd phasefilt.grd; do
            if [[ -s "merge/${pair}/${grid}" ]]; then
                case "${grid}" in
                    corr.grd) corr_count=$((corr_count + 1)) ;;
                    phasefilt.grd) phase_count=$((phase_count + 1)) ;;
                esac
            else
                [[ -z "${missing_csv}" ]] || missing_csv+=","
                missing_csv+="${grid}"
            fi
        done

        if [[ -n "${missing_csv}" ]]; then
            printf '%s\t%s\n' "${pair}" "${missing_csv}" >> "${report_file}"
        fi
    done < "${pair_list}"

    printf '%s\n' '========================================'
    printf '%s\n' 'Run 3.7 merged-grid validation'
    printf 'Merged pair directories : %d\n' "${pair_count}"
    printf 'Non-empty corr.grd      : %d\n' "${corr_count}"
    printf 'Non-empty phasefilt.grd : %d\n' "${phase_count}"
    printf '%s\n' '========================================'

    if [[ -s "${report_file}" ]]; then
        printf '%s\n' '[CHECK ERROR] Missing or empty merged grids:' >&2
        while IFS=$'\t' read -r pair missing_csv; do
            printf '  %s  missing: %s\n' "${pair}" "${missing_csv}" >&2
        done < "${report_file}"
        return 1
    fi

    printf '[CHECK OK] All %d merged pairs contain non-empty corr.grd and phasefilt.grd.\n' \
        "${pair_count}"
}

plot_one_grid() {
    local pair="$1"
    local grid="$2"
    local stem="${grid%.grd}"
    local source_grid="${ROOT_DIR}/merge/${pair}/${grid}"
    local cpt tick label unit

    case "${grid}" in
        corr.grd)
            cpt="${pair}_corr.cpt"
            gmt makecpt -Cgray -T0/1/0.05 -Z -M --COLOR_NAN=gray > "${cpt}"
            tick='0.2'
            label='Correlation'
            unit='dimensionless'
            ;;
        phasefilt.grd)
            cpt="${pair}_phasefilt.cpt"
            gmt makecpt -Crainbow -T-3.15/3.15/0.05 -Z --COLOR_NAN=gray > "${cpt}"
            tick='1.57'
            label='Filtered phase'
            unit='rad'
            ;;
        *)
            printf '[PLOT ERROR] Unsupported grid: %s\n' "${grid}" >&2
            return 1
            ;;
    esac

    gmt grdimage "${source_grid}" -JX6.5i \
        -C"${cpt}" \
        -Bxaf+lRange -Byaf+lAzimuth -BWSen \
        -X1.3i -Y3i -P -K > "${pair}_${stem}.ps"
    gmt psscale -R"${source_grid}" -J \
        -DJTC+w5i/0.2i+h \
        -C"${cpt}" \
        -Bxa"${tick}"+l"${label}" -By+l"${unit}" \
        -O >> "${pair}_${stem}.ps"
    gmt psconvert -Tj -E"${PLOT_DPI}" -P -A -Z "${pair}_${stem}.ps"
    rm -f -- "${cpt}"

    [[ -s "${pair}_${stem}.jpg" ]] || {
        printf '[PLOT ERROR] JPG not generated: %s/%s_%s.jpg\n' \
            "$(pwd -P)" "${pair}" "${stem}" >&2
        return 1
    }
}

plot_one_pair() {
    local pair="$1"
    local work_dir="${OUTPUT_DIR}/.tmp/${pair}"

    [[ -s "${ROOT_DIR}/merge/${pair}/corr.grd" ]] || {
        printf '[PLOT ERROR] Missing: merge/%s/corr.grd\n' "${pair}" >&2
        return 1
    }
    [[ -s "${ROOT_DIR}/merge/${pair}/phasefilt.grd" ]] || {
        printf '[PLOT ERROR] Missing: merge/%s/phasefilt.grd\n' "${pair}" >&2
        return 1
    }

    # Each parallel GMT job uses an isolated hidden directory. It is removed
    # on both success and failure; only the final categorized JPGs are kept.
    rm -rf -- "${work_dir}"
    mkdir -p "${work_dir}"
    (
        trap 'rm -rf -- "${work_dir}"' EXIT
        cd "${work_dir}"
        plot_one_grid "${pair}" corr.grd
        plot_one_grid "${pair}" phasefilt.grd
        mv -f -- "${pair}_corr.jpg" "${OUTPUT_DIR}/corr/"
        mv -f -- "${pair}_phasefilt.jpg" "${OUTPUT_DIR}/phasefilt/"
    )

    printf '[PLOT OK] %s\n' "${pair}"
}

if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    usage
    exit 0
fi

if (( $# == 0 )); then
    usage
    printf '%s\n' '[INFO] No checking or plotting was started.'
    exit 0
fi

MODE="$1"
[[ "${MODE}" == '1' || "${MODE}" == '2' ]] ||
    die "MODE must be 1 (check) or 2 (plot)"

for command_name in awk basename find grep mktemp mv sort wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

require_track_root
ROOT_DIR="$(pwd -P)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run3.7.XXXXXX")"
trap 'rm -rf -- "${TEMP_DIR}"' EXIT
ALL_PAIRS="${TEMP_DIR}/all_pairs.txt"
make_pair_list "${ALL_PAIRS}"

if [[ "${MODE}" == '1' ]]; then
    (( $# == 1 )) || die "mode 1 usage: ./run3.7_plot_merge_corr_phasefilt.sh 1"

    if validate_merged_grids "${ALL_PAIRS}" "${TEMP_DIR}/missing.tsv"; then
        rm -f -- "${MISSING_REPORT}"
        {
            date '+%Y-%m-%d %H:%M:%S'
            printf 'pairs=%s\n' "$(wc -l < "${ALL_PAIRS}" | awk '{print $1}')"
        } > "${CHECK_MARKER}"
        printf 'Validation marker: %s/%s\n' "${ROOT_DIR}" "${CHECK_MARKER}"
        printf '%s\n' '[NEXT] Recommended: plot the 25% and 75% pairs of every year:'
        printf '%s\n' '  ./run3.7_plot_merge_corr_phasefilt.sh 2'
        printf '%s\n' '[OTHER] Plot all pairs with five concurrent plotting jobs:'
        printf '%s\n' '  ./run3.7_plot_merge_corr_phasefilt.sh 2 all 5'
        exit 0
    fi

    cp "${TEMP_DIR}/missing.tsv" "${MISSING_REPORT}"
    rm -f -- "${CHECK_MARKER}"
    printf 'Missing-grid report: %s/%s\n' "${ROOT_DIR}" "${MISSING_REPORT}" >&2
    exit 1
fi

(( $# >= 1 && $# <= 3 )) ||
    die "mode 2 usage: ./run3.7_plot_merge_corr_phasefilt.sh 2 [SELECTOR] [PLOT_JOBS]"
SELECTOR="${2:-yearly}"
PLOT_JOBS="${3:-5}"
[[ "${PLOT_JOBS}" =~ ^[1-9][0-9]*$ ]] ||
    die "PLOT_JOBS must be a positive integer: ${PLOT_JOBS}"
[[ -s "${CHECK_MARKER}" ]] ||
    die "mode-1 validation is not complete; run './run3.7_plot_merge_corr_phasefilt.sh 1' first"

for command_name in gmt xargs; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

# Recheck all merged products before plotting, even when mode 1 was completed.
validate_merged_grids "${ALL_PAIRS}" "${TEMP_DIR}/missing.tsv" || {
    cp "${TEMP_DIR}/missing.tsv" "${MISSING_REPORT}"
    rm -f -- "${CHECK_MARKER}"
    die "merged grids changed after mode 1; inspect ${MISSING_REPORT}"
}

SELECTED_PAIRS="${TEMP_DIR}/selected_pairs.txt"
case "${SELECTOR}" in
    yearly)
        # ALL_PAIRS is sorted. Group by the year of the first acquisition and
        # select the nearest-rank 25% and 75% entries in each yearly list:
        #   q25 = ceil(n / 4), q75 = ceil(3n / 4)
        # If both positions are identical, emit that pair only once.
        awk -F_ '
            {
                year=substr($1, 1, 4)
                if (!(year in seen)) {
                    seen[year]=1
                    order[++nyear]=year
                }
                count[year]++
                pair[year SUBSEP count[year]]=$0
            }
            END {
                for (i=1; i<=nyear; i++) {
                    year=order[i]
                    n=count[year]
                    q25=int((n + 3) / 4)
                    q75=int((3 * n + 3) / 4)
                    print pair[year SUBSEP q25]
                    if (q75 != q25) print pair[year SUBSEP q75]
                }
            }
        ' "${ALL_PAIRS}" > "${SELECTED_PAIRS}"
        ;;
    all)
        cp "${ALL_PAIRS}" "${SELECTED_PAIRS}"
        ;;
    @*)
        LIST_FILE="${SELECTOR#@}"
        [[ -s "${LIST_FILE}" ]] || die "pair-list file not found or empty: ${LIST_FILE}"
        awk 'NF && $1 !~ /^#/ {print $1}' "${LIST_FILE}" | sort -u > "${SELECTED_PAIRS}"
        ;;
    20[0-9][0-9][0-9][0-9][0-9]|20[0-9][0-9][0-9][0-9][0-9][0-9]|20[0-9][0-9][0-9][0-9][0-9][0-9][0-9])
        # A single acquisition date selects every pair that contains it.
        awk -F_ -v date="${SELECTOR}" '$1 == date || $2 == date' \
            "${ALL_PAIRS}" > "${SELECTED_PAIRS}"
        ;;
    *)
        # Otherwise treat the selector as one exact pair ID; validation below
        # rejects malformed or unavailable IDs.
        printf '%s\n' "${SELECTOR}" > "${SELECTED_PAIRS}"
        ;;
esac

[[ -s "${SELECTED_PAIRS}" ]] || die "no pairs selected"
while IFS= read -r pair; do
    [[ "${pair}" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] ||
        die "invalid pair ID: ${pair}"
    grep -qxF "${pair}" "${ALL_PAIRS}" ||
        die "selected pair is not present under merge/: ${pair}"
done < "${SELECTED_PAIRS}"

OUTPUT_DIR="${ROOT_DIR}/merge/${OUTPUT_NAME}"
mkdir -p "${OUTPUT_DIR}/corr" "${OUTPUT_DIR}/phasefilt" "${OUTPUT_DIR}/.tmp"
SELECTED_COUNT="$(wc -l < "${SELECTED_PAIRS}" | awk '{print $1}')"

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.7: plot merged corr and phasefilt JPG previews'
printf 'Track root         : %s\n' "${ROOT_DIR}"
printf 'Selection          : %s\n' "${SELECTOR}"
printf 'Selected pairs     : %s\n' "${SELECTED_COUNT}"
printf 'Parallel plot jobs : %s\n' "${PLOT_JOBS}"
printf 'JPG resolution     : %s dpi\n' "${PLOT_DPI}"
printf 'Output directory   : %s\n' "${OUTPUT_DIR}"
printf '%s\n' 'Mask plotting      : disabled'
printf '%s\n' '========================================'

export ROOT_DIR OUTPUT_DIR PLOT_DPI
export -f plot_one_grid plot_one_pair

set +e
xargs -I{} -P "${PLOT_JOBS}" bash -c \
    'set -euo pipefail; plot_one_pair "$1"' _ {} < "${SELECTED_PAIRS}"
PLOT_STATUS="$?"
set -e
(( PLOT_STATUS == 0 )) ||
    die "one or more plotting jobs failed; inspect the terminal error output"
rmdir "${OUTPUT_DIR}/.tmp" 2>/dev/null || true

MISSING_JPG=0
while IFS= read -r pair; do
    for stem in corr phasefilt; do
        if [[ ! -s "${OUTPUT_DIR}/${stem}/${pair}_${stem}.jpg" ]]; then
            printf '[OUTPUT ERROR] Missing JPG: %s/%s/%s_%s.jpg\n' \
                "${OUTPUT_DIR}" "${stem}" "${pair}" "${stem}" >&2
            MISSING_JPG=$((MISSING_JPG + 1))
        fi
    done
done < "${SELECTED_PAIRS}"
(( MISSING_JPG == 0 )) || die "${MISSING_JPG} expected JPG file(s) are missing"

printf '%s\n' '========================================'
printf '[DONE] Created %d JPG files for %d merged interferogram pairs.\n' \
    "$((SELECTED_COUNT * 2))" "${SELECTED_COUNT}"
printf 'Output: %s\n' "${OUTPUT_DIR}"
printf '%s\n' '========================================'
