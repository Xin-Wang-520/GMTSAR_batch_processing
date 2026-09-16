#!/usr/bin/env bash
# Run 3.11: remove a possible ionospheric/orbital long-wavelength trend from
# LT-1 unwrap grids with a robust six-parameter surface.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

MERGE_DIR="intf_all"
OUTPUT_DIR="run3.11_detrend_overview"
DEFAULT_JOBS=5

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Run 3.11: remove possible ionospheric/orbital long-wavelength trend

Usage:
  ./run3.11_detrend_unwrap_LT1_parallel.sh
  ./run3.11_detrend_unwrap_LT1_parallel.sh 1 [--jobs N]

No arguments:
  Check existing intf_all/20*/unwrap.grd files only.

Mode 1:
  Run this operation for every unwrapped pair:

    gmt grdtrend unwrap.grd -N6r \
        -Tunwrap_trend.grd \
        -Dunwrap_detrend.grd

Purpose:
  Remove a smooth long-wavelength component that may be caused by ionospheric
  delay or residual orbital ramps. This is polynomial detrending, not a
  split-spectrum or external-TEC ionospheric correction. Inspect the comparison
  PNGs because broad real deformation may also be included in the fitted trend.

Outputs:
  intf_all/<pair>/unwrap_detrend.grd
  run3.11_detrend_overview/<pair>_detrend_comparison.png
  run3.11_detrend_overview/unwrap_detrend_all.png

Each PNG is one row by three columns:
  original unwrap | fitted N6r trend | detrended unwrap

The panels use the GMT jet color palette and preserve the actual radar-grid
width-to-height ratio.

unwrap_trend.grd is temporary and is deleted after its comparison is plotted.
unwrap_detrend_all.png places every detrended interferogram in one multi-panel
figure using one common jet color scale.

Example:
  ./run3.11_detrend_unwrap_LT1_parallel.sh 1 --jobs 5
EOF
}

grid_signature() {
    gmt grdinfo "$1" -C |
        awk '{print $2, $3, $4, $5, $8, $9, $10, $11, $12}'
}

z_limits() {
    gmt grdinfo "$1" -C | awk '{print $6, $7; exit}'
}

symmetric_limit() {
    awk '{
        for(i=1;i<=NF;i++) {
            value=$i
            if(value<0)value=-value
            if(value>maximum)maximum=value
        }
    } END {
        if(!(maximum>0))maximum=1
        printf "%.12g", maximum
    }'
}

process_pair() (
    set -euo pipefail
    pair="$1"
    pair_dir="${ROOT_DIR}/${MERGE_DIR}/${pair}"
    output_dir="${ROOT_DIR}/${OUTPUT_DIR}"
    tag="run3.11_tmp_${BASHPID}"
    trend="${tag}_trend.grd"
    detrend="${tag}_detrend.grd"
    phase_cpt="${tag}_phase.cpt"
    trend_cpt="${tag}_trend.cpt"
    plot="${tag}_comparison"
    panel_width="3.5"

    cd "${pair_dir}"
    cleanup() {
        rm -f -- "${trend}" "${detrend}" "${phase_cpt}" "${trend_cpt}" \
            "${plot}.png" gmt.conf gmt.history .gmtcommands4 unwrap_trend.grd
    }
    trap cleanup EXIT

    [[ -s unwrap.grd ]] || die "${pair}: missing or empty unwrap.grd"
    printf '[DETREND] %s (-N6r)\n' "${pair}"
    gmt grdtrend unwrap.grd -N6r -T"${trend}" -D"${detrend}"
    [[ -s "${trend}" && -s "${detrend}" ]] ||
        die "${pair}: grdtrend did not create both grids"

    original_signature="$(grid_signature unwrap.grd)"
    detrend_signature="$(grid_signature "${detrend}")"
    [[ "${original_signature}" == "${detrend_signature}" ]] ||
        die "${pair}: unwrap_detrend grid geometry differs from unwrap.grd"

    original_limits="$(z_limits unwrap.grd)"
    detrend_limits="$(z_limits "${detrend}")"
    trend_limits="$(z_limits "${trend}")"
    phase_limit="$(printf '%s\n%s\n' "${original_limits}" "${detrend_limits}" |
        symmetric_limit)"
    trend_limit="$(printf '%s\n' "${trend_limits}" | symmetric_limit)"

    gmt makecpt -Cjet -T-"${phase_limit}"/"${phase_limit}" -Z > "${phase_cpt}"
    gmt makecpt -Cjet -T-"${trend_limit}"/"${trend_limit}" -Z > "${trend_cpt}"

    # Preserve the actual radar-grid aspect ratio instead of stretching every
    # panel to the same fixed tall rectangle.
    read -r grid_w grid_e grid_s grid_n < <(
        gmt grdinfo unwrap.grd -C | awk '{print $2, $3, $4, $5; exit}'
    )
    panel_height="$(awk -v width="${panel_width}" \
        -v west="${grid_w}" -v east="${grid_e}" \
        -v south="${grid_s}" -v north="${grid_n}" '
        BEGIN {
            x=east-west
            y=north-south
            if (!(x>0 && y>0)) exit 1
            printf "%.4f", width*y/x
        }')" || die "${pair}: failed to calculate plot aspect ratio"
    printf '[PLOT] %s panel size: %si x %si (actual grid aspect ratio)\n' \
        "${pair}" "${panel_width}" "${panel_height}"

    gmt begin "${plot}" png
        gmt set MAP_TITLE_OFFSET 8p FONT_TITLE 13p \
            FONT_HEADING 15p FONT_LABEL 10p FONT_ANNOT_PRIMARY 8p
        gmt subplot begin 1x3 -Fs"${panel_width}i/${panel_height}i" -M0.12i \
            -T"LT-1 ${pair}: possible ionospheric/orbital trend removal (-N6r)"

        gmt subplot set 0,0
        gmt grdimage unwrap.grd -C"${phase_cpt}" \
            -Bxa+lRange -Bya+lAzimuth -BWSen+t"Original unwrap"
        gmt colorbar -C"${phase_cpt}" \
            -DJBC+w2.5i/0.12i+h+o0i/0.38i -Baf+l"Phase (rad)"

        gmt subplot set 0,1
        gmt grdimage "${trend}" -C"${trend_cpt}" \
            -Bxa+lRange -Bya -BWSen+t"Trend (N6r)"
        gmt colorbar -C"${trend_cpt}" \
            -DJBC+w2.5i/0.12i+h+o0i/0.38i -Baf+l"Trend (rad)"

        gmt subplot set 0,2
        gmt grdimage "${detrend}" -C"${phase_cpt}" \
            -Bxa+lRange -Bya -BWSen+t"Detrended unwrap"
        gmt colorbar -C"${phase_cpt}" \
            -DJBC+w2.5i/0.12i+h+o0i/0.38i -Baf+l"Phase (rad)"

        gmt subplot end
    gmt end

    [[ -s "${plot}.png" ]] || die "${pair}: comparison PNG was not generated"
    mv -f -- "${detrend}" unwrap_detrend.grd
    mv -f -- "${plot}.png" "${output_dir}/${pair}_detrend_comparison.png"
    printf '[DONE] %s\n' "${pair}"
)

make_all_detrend_overview() (
    set -euo pipefail
    output_dir="${ROOT_DIR}/${OUTPUT_DIR}"
    overview_name="unwrap_detrend_all"
    overview_cpt="run3.11_overview_jet.cpt"
    first_pair="$(sed -n '1p' "${PAIR_LIST}")"
    first_grid="${ROOT_DIR}/${MERGE_DIR}/${first_pair}/unwrap_detrend.grd"

    if (( PAIR_COUNT <= 4 )); then
        columns=2
    elif (( PAIR_COUNT <= 9 )); then
        columns=3
    elif (( PAIR_COUNT <= 16 )); then
        columns=4
    else
        columns=5
    fi
    rows=$(( (PAIR_COUNT + columns - 1) / columns ))

    common_limit="$(
        while IFS= read -r pair; do
            z_limits "${ROOT_DIR}/${MERGE_DIR}/${pair}/unwrap_detrend.grd"
        done < "${PAIR_LIST}" | symmetric_limit
    )"

    read -r grid_w grid_e grid_s grid_n < <(
        gmt grdinfo "${first_grid}" -C |
            awk '{print $2, $3, $4, $5; exit}'
    )
    panel_width="2.2"
    panel_height="$(awk -v width="${panel_width}" \
        -v west="${grid_w}" -v east="${grid_e}" \
        -v south="${grid_s}" -v north="${grid_n}" '
        BEGIN {
            x=east-west
            y=north-south
            if (!(x>0 && y>0)) exit 1
            printf "%.4f", width*y/x
        }')" || die "failed to calculate overview aspect ratio"

    cd "${output_dir}"
    cleanup_overview() {
        rm -f -- "${overview_cpt}" gmt.conf gmt.history .gmtcommands4
    }
    trap cleanup_overview EXIT

    gmt makecpt -Cjet -T-"${common_limit}"/"${common_limit}" -Z > "${overview_cpt}"
    printf '[OVERVIEW] Plotting %s detrended grids as %sx%s panels\n' \
        "${PAIR_COUNT}" "${rows}" "${columns}"

    gmt begin "${overview_name}" png
        gmt set MAP_TITLE_OFFSET 4p FONT_HEADING 16p FONT_TITLE 8p \
            FONT_LABEL 7p FONT_ANNOT_PRIMARY 6p
        gmt subplot begin "${rows}x${columns}" \
            -Fs"${panel_width}i/${panel_height}i" -M0.08i \
            -T"LT-1 detrended unwrap overview: ${PAIR_COUNT} interferograms (-N6r)"

        index=0
        while IFS= read -r pair; do
            row=$(( index / columns ))
            column=$(( index % columns ))
            grid="${ROOT_DIR}/${MERGE_DIR}/${pair}/unwrap_detrend.grd"
            gmt subplot set "${row},${column}"
            gmt grdimage "${grid}" -C"${overview_cpt}" \
                -Baf -BWSen+t"${pair}"
            index=$(( index + 1 ))
        done < "${PAIR_LIST}"

        gmt subplot end
        gmt colorbar -C"${overview_cpt}" \
            -DJBC+w6i/0.16i+h+o0i/0.45i \
            -Baf+l"Detrended phase (rad), common scale"
    gmt end

    [[ -s "${overview_name}.png" ]] ||
        die "combined detrended overview PNG was not generated"
)

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

MODE=""
JOBS="${DEFAULT_JOBS}"
if (( $# > 0 )); then MODE="$1"; shift; fi
while (( $# > 0 )); do
    case "$1" in
        --jobs)
            (( $# >= 2 )) || die "--jobs requires a positive integer"
            JOBS="$2"
            shift 2
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -z "${MODE}" || "${MODE}" == "1" ]] || die "MODE must be 1"
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
for command_name in awk basename find gmt sort wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done
[[ -d "${MERGE_DIR}" ]] || die "cannot find ${MERGE_DIR}/"

ROOT_DIR="$(pwd -P)"
PAIR_LIST="$(mktemp)"
trap 'rm -f -- "${PAIR_LIST}"' EXIT
find "${MERGE_DIR}" -mindepth 2 -maxdepth 2 -type f \
    -path "${MERGE_DIR}/20*/unwrap.grd" -size +0c -print |
    while IFS= read -r grid; do basename -- "$(dirname -- "${grid}")"; done |
    sort -u > "${PAIR_LIST}"

PAIR_COUNT="$(wc -l < "${PAIR_LIST}" | awk '{print $1}')"
(( PAIR_COUNT > 0 )) || die "no non-empty ${MERGE_DIR}/20*/unwrap.grd files found"

printf '%s\n' '========================================================================'
printf '%s\n' 'LT-1 Run 3.11 possible ionospheric/orbital trend removal'
printf 'Mode:                %s\n' "$([[ -n "${MODE}" ]] && printf FORMAL || printf CHECK)"
printf 'Unwrapped pairs:     %s\n' "${PAIR_COUNT}"
printf 'Parallel jobs:       %s\n' "${JOBS}"
printf 'Trend model:         robust six-parameter surface (-N6r)\n'
printf 'Interpretation:      removes a possible ionospheric/orbital long-wave ramp\n'
printf 'Detrended grids:     intf_all/<pair>/unwrap_detrend.grd\n'
printf 'Comparison figures: %s/\n' "${OUTPUT_DIR}"
printf 'Temporary trends:    deleted after plotting\n'
printf '%s\n' '========================================================================'

if [[ -z "${MODE}" ]]; then
    usage
    printf '[CHECK ONLY] No files were modified.\n'
    exit 0
fi

mkdir -p "${OUTPUT_DIR}/logs"
FAILED_REPORT="${OUTPUT_DIR}/run3.11_failed_pairs.tsv"
: > "${FAILED_REPORT}"
PIDS=()
PAIRS=()

wait_batch() {
    local i
    for i in "${!PIDS[@]}"; do
        if wait "${PIDS[${i}]}"; then
            printf '[DONE] %s\n' "${PAIRS[${i}]}"
        else
            printf '[FAILED] %s (see %s/logs/%s.log)\n' \
                "${PAIRS[${i}]}" "${OUTPUT_DIR}" "${PAIRS[${i}]}"
            printf '%s\n' "${PAIRS[${i}]}" >> "${FAILED_REPORT}"
        fi
    done
    PIDS=()
    PAIRS=()
}

while IFS= read -r pair; do
    process_pair "${pair}" > "${OUTPUT_DIR}/logs/${pair}.log" 2>&1 &
    PIDS+=("$!")
    PAIRS+=("${pair}")
    if (( ${#PIDS[@]} >= JOBS )); then wait_batch; fi
done < "${PAIR_LIST}"
if (( ${#PIDS[@]} > 0 )); then wait_batch; fi

FAILED_COUNT="$(wc -l < "${FAILED_REPORT}" | awk '{print $1}')"
if (( FAILED_COUNT > 0 )); then
    die "${FAILED_COUNT} pair(s) failed; see ${FAILED_REPORT}"
fi
rm -f -- "${FAILED_REPORT}"

make_all_detrend_overview

DETREND_COUNT="$(find "${MERGE_DIR}" -mindepth 2 -maxdepth 2 -type f \
    -path "${MERGE_DIR}/20*/unwrap_detrend.grd" -size +0c | wc -l | awk '{print $1}')"
PNG_COUNT="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f \
    -name '*_detrend_comparison.png' -size +0c | wc -l | awk '{print $1}')"

printf '%s\n' '========================================================================'
printf '[SUCCESS] Detrended grids: %s\n' "${DETREND_COUNT}"
printf '[SUCCESS] Comparison PNGs: %s\n' "${PNG_COUNT}"
printf '[SUCCESS] Combined overview: %s/%s\n' \
    "${OUTPUT_DIR}" "unwrap_detrend_all.png"
printf '[OUTPUT]  %s/%s\n' "${ROOT_DIR}" "${OUTPUT_DIR}"
printf '[CLEANUP] Temporary unwrap_trend.grd files were removed.\n'
printf '%s\n' '========================================================================'
