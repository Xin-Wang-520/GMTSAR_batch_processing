#!/usr/bin/env bash
# Run 3.12: set a common stable-area phase reference for LT-1 detrended unwrap grids.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

INTF_DIR="intf_all"
INPUT_NAME="unwrap_detrend.grd"
OUTPUT_NAME="unwrap_detrend_ref_pin.grd"
INFO_NAME="reference_detrend.info"
REPORT_NAME="run3.12_reference_values.tsv"
OVERVIEW_DIR="run3.12_reference_overview"
PAIR_PDF_NAME="unwrap_detrend_ref_pin.pdf"
OVERVIEW_PNG_NAME="unwrap_detrend_ref_pin_all.png"
DEFAULT_JOBS=5
DEFAULT_WINDOW=5

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Run 3.12: reference LT-1 detrended unwrapped phase to a stable area

Check only:
  ./run3.12_reference_detrend_LT1_parallel.sh

Use a stable radar-coordinate pin and a 5 x 5 pixel mean (recommended):
  ./run3.12_reference_detrend_LT1_parallel.sh 1 \
    --pin RANGE AZIMUTH --window 5 --jobs 5

Use a manually selected radar-coordinate rectangle:
  ./run3.12_reference_detrend_LT1_parallel.sh 1 \
    --region XMIN/XMAX/YMIN/YMAX --jobs 5

Options:
  --pin X Y       Stable point in radar coordinates. It is snapped to the
                  nearest grid node, then an N x N neighborhood is used.
  --window N      Odd pixel count for --pin; default: 5 (5 x 5 = 25 pixels).
  --region R      Stable rectangle as xmin/xmax/ymin/ymax.
  --jobs N        Parallel interferograms; default: 5.
  --stat S        mean or median; default: mean. Median is more resistant to
                  isolated bad pixels and follows the older Run 3.13 method.

Exactly one of --pin and --region is required in formal mode.

For every pair, the selected stable-area value is subtracted from the complete
detrended grid:
  unwrap_detrend_ref_pin.grd = unwrap_detrend.grd - reference_value

Outputs:
  intf_all/<pair>/unwrap_detrend_ref_pin.grd
  intf_all/<pair>/reference_detrend.info
  intf_all/<pair>/unwrap_detrend_ref_pin.pdf
  run3.12_reference_values.tsv
  run3.12_reference_overview/unwrap_detrend_ref_pin_all.png

Every PDF uses the GMT jet palette. The true reference rectangle is outlined in
red, and a red square marks its center so a small 5 x 5 window remains visible
on a full radar image. The original unwrap_detrend.grd files are retained.
EOF
}

grid_signature() {
    gmt grdinfo "$1" -C |
        awk '{print $2, $3, $4, $5, $8, $9, $10, $11, $12}'
}

is_number() {
    awk -v value="$1" 'BEGIN {
        exit !(value ~ /^[-+]?[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$/ ||
               value ~ /^[-+]?[.][0-9]+([eE][-+]?[0-9]+)?$/)
    }'
}

symmetric_grid_limit() {
    gmt grdinfo "$1" -C | awk '{
        lo=$6; hi=$7
        if(lo<0)lo=-lo
        if(hi<0)hi=-hi
        maximum=(lo>hi ? lo : hi)
        if(!(maximum>0))maximum=1
        printf "%.15g", maximum
    }'
}

process_pair() (
    set -euo pipefail
    pair="$1"
    pair_dir="${ROOT_DIR}/${INTF_DIR}/${pair}"
    input="${pair_dir}/${INPUT_NAME}"
    output="${pair_dir}/${OUTPUT_NAME}"
    info="${pair_dir}/${INFO_NAME}"
    values="${TMP_DIR}/${pair}.values"
    # macOS still ships Bash 3.2, which has no BASHPID variable.  Each pair
    # has its own directory, so $$ is sufficient to keep these names private.
    output_tmp="${pair_dir}/.${OUTPUT_NAME}.tmp.$$"
    info_tmp="${pair_dir}/.${INFO_NAME}.tmp.$$"
    cpt_tmp="${TMP_DIR}/${pair}.reference.cpt"
    pdf_tmp_stem=".run3.12_reference_plot.$$"
    pdf_tmp="${pair_dir}/${pdf_tmp_stem}.pdf"

    cleanup_pair() {
        rm -f -- "${values}" "${output_tmp}" "${info_tmp}" \
            "${cpt_tmp}" "${pdf_tmp}" \
            "${pair_dir}/gmt.conf" "${pair_dir}/gmt.history" \
            "${pair_dir}/.gmtcommands4"
    }
    trap cleanup_pair EXIT

    if [[ "${REFERENCE_MODE}" == "pin" ]]; then
        gmt grdtrack "${POINT_FILE}" -G"${input}" -Z > "${values}"
        total_count="${WINDOW_POINT_COUNT}"
    else
        cut_grid="${TMP_DIR}/${pair}.reference.grd"
        trap 'cleanup_pair; rm -f -- "${cut_grid}"' EXIT
        gmt grdcut "${input}" -R"${REFERENCE_REGION}" -G"${cut_grid}"
        gmt grd2xyz "${cut_grid}" -s | awk '{print $NF}' > "${values}"
        total_count="$(gmt grdinfo "${cut_grid}" -C |
            awk '{printf "%.0f", $10*$11; exit}')"
    fi

    valid_count="$(awk 'tolower($1)!="nan" && $1!="" {n++} END{print n+0}' "${values}")"
    (( valid_count > 0 )) || {
        printf '[ERROR] %s: stable area contains no valid pixels\n' "${pair}" >&2
        exit 1
    }
    if [[ "${REFERENCE_MODE}" == "pin" && "${valid_count}" -ne "${WINDOW_POINT_COUNT}" ]]; then
        printf '[ERROR] %s: only %s/%s pixels in the %sx%s pin window are valid\n' \
            "${pair}" "${valid_count}" "${WINDOW_POINT_COUNT}" "${WINDOW}" "${WINDOW}" >&2
        exit 1
    fi

    if [[ "${STATISTIC}" == "mean" ]]; then
        reference_value="$(awk 'tolower($1)!="nan" && $1!="" {sum+=$1; n++}
            END {if(n==0)exit 1; printf "%.15g", sum/n}' "${values}")"
    else
        reference_value="$(awk 'tolower($1)!="nan" && $1!="" {print $1}' "${values}" |
            sort -g | awk '{v[++n]=$1} END {
                if(n==0)exit 1
                if(n%2)printf "%.15g", v[(n+1)/2]
                else printf "%.15g", (v[n/2]+v[n/2+1])/2
            }')"
    fi
    is_number "${reference_value}" || {
        printf '[ERROR] %s: invalid reference value: %s\n' "${pair}" "${reference_value}" >&2
        exit 1
    }

    gmt grdmath "${input}" "${reference_value}" SUB = "${output_tmp}"
    [[ -s "${output_tmp}" ]] || exit 1
    [[ "$(grid_signature "${input}")" == "$(grid_signature "${output_tmp}")" ]] || {
        printf '[ERROR] %s: referenced grid geometry changed\n' "${pair}" >&2
        exit 1
    }

    phase_limit="$(symmetric_grid_limit "${output_tmp}")"
    gmt makecpt -Cjet -T-"${phase_limit}"/"${phase_limit}" > "${cpt_tmp}"
    (
        cd "${pair_dir}"
        gmt begin "${pdf_tmp_stem}" pdf
            gmt set MAP_TITLE_OFFSET 8p FONT_TITLE 13p \
                FONT_LABEL 10p FONT_ANNOT_PRIMARY 8p
            gmt grdimage "${output_tmp}" -C"${cpt_tmp}" \
                -Bxa+lRange -Bya+lAzimuth \
                -BWSen+t"LT-1 ${pair}: referenced detrended phase"
            gmt plot "${BOX_FILE}" -W1.8p,red
            gmt plot "${MARKER_FILE}" -Ss0.20c -Gred -W0.8p,black
            gmt colorbar -C"${cpt_tmp}" -DJBC+w4i/0.16i+h+o0i/0.42i \
                -Baf+l"Referenced phase (rad)"
        gmt end
    )
    [[ -s "${pdf_tmp}" ]] || {
        printf '[ERROR] %s: reference PDF was not generated\n' "${pair}" >&2
        exit 1
    }

    {
        printf 'mode=%s\n' "${REFERENCE_MODE}"
        printf 'requested_pin=%s\n' "${REQUESTED_PIN}"
        printf 'snapped_pin=%s\n' "${SNAPPED_PIN}"
        printf 'region=%s\n' "${REFERENCE_REGION}"
        printf 'window=%s\n' "${WINDOW}"
        printf 'statistic=%s\n' "${STATISTIC}"
        printf 'valid_pixels=%s\n' "${valid_count}"
        printf 'total_pixels=%s\n' "${total_count}"
        printf 'reference_value_rad=%s\n' "${reference_value}"
        printf 'input=%s\n' "${INPUT_NAME}"
        printf 'output=%s\n' "${OUTPUT_NAME}"
        printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "${info_tmp}"

    mv -f -- "${output_tmp}" "${output}"
    mv -f -- "${info_tmp}" "${info}"
    mv -f -- "${pdf_tmp}" "${pair_dir}/${PAIR_PDF_NAME}"
    printf '[DONE] %s reference=%s rad valid=%s/%s\n' \
        "${pair}" "${reference_value}" "${valid_count}" "${total_count}"
)

make_reference_overview() (
    set -euo pipefail
    first_grid="${ROOT_DIR}/${INTF_DIR}/${FIRST_PAIR}/${OUTPUT_NAME}"
    overview_stem="${OVERVIEW_PNG_NAME%.png}"
    overview_cpt="${TMP_DIR}/run3.12_overview_jet.cpt"

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
            gmt grdinfo "${ROOT_DIR}/${INTF_DIR}/${pair}/${OUTPUT_NAME}" -C |
                awk '{print $6, $7}'
        done < "${PAIR_LIST}" | awk '{
            for(i=1;i<=NF;i++) {
                value=$i; if(value<0)value=-value
                if(value>maximum)maximum=value
            }
        } END {if(!(maximum>0))maximum=1; printf "%.15g", maximum}'
    )"

    read -r W E S N < <(
        gmt grdinfo "${first_grid}" -C | awk '{print $2, $3, $4, $5; exit}'
    )
    panel_width="2.2"
    panel_height="$(awk -v width="${panel_width}" -v w="${W}" -v e="${E}" \
        -v s="${S}" -v n="${N}" 'BEGIN {
        x=e-w; y=n-s
        if(!(x>0 && y>0))exit 1
        printf "%.4f", width*y/x
    }')" || die "failed to calculate overview panel aspect ratio"

    mkdir -p "${ROOT_DIR}/${OVERVIEW_DIR}"
    cd "${ROOT_DIR}/${OVERVIEW_DIR}"
    trap 'rm -f -- "${overview_cpt}" gmt.conf gmt.history .gmtcommands4' EXIT
    gmt makecpt -Cjet -T-"${common_limit}"/"${common_limit}" > "${overview_cpt}"

    printf '[OVERVIEW] Plotting %s referenced grids as %sx%s panels\n' \
        "${PAIR_COUNT}" "${rows}" "${columns}"
    gmt begin "${overview_stem}" png
        gmt set MAP_TITLE_OFFSET 4p FONT_HEADING 16p FONT_TITLE 8p \
            FONT_LABEL 7p FONT_ANNOT_PRIMARY 6p
        gmt subplot begin "${rows}x${columns}" \
            -Fs"${panel_width}i/${panel_height}i" -M0.08i \
            -T"LT-1 referenced detrended phase: ${PAIR_COUNT} interferograms"

        index=0
        while IFS= read -r pair; do
            row=$(( index / columns ))
            column=$(( index % columns ))
            grid="${ROOT_DIR}/${INTF_DIR}/${pair}/${OUTPUT_NAME}"
            gmt subplot set "${row},${column}"
            gmt grdimage "${grid}" -C"${overview_cpt}" -Baf -BWSen+t"${pair}"
            index=$(( index + 1 ))
        done < "${PAIR_LIST}"

        gmt subplot end
        gmt colorbar -C"${overview_cpt}" \
            -DJBC+w6i/0.16i+h+o0i/0.45i \
            -Baf+l"Referenced detrended phase (rad), common scale"
    gmt end

    [[ -s "${OVERVIEW_PNG_NAME}" ]] ||
        die "combined reference overview PNG was not generated"
)

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

MODE=""
JOBS="${DEFAULT_JOBS}"
WINDOW="${DEFAULT_WINDOW}"
STATISTIC="mean"
REFERENCE_MODE=""
PIN_X=""
PIN_Y=""
REFERENCE_REGION=""

if (( $# > 0 )) && [[ "$1" == "1" ]]; then MODE=1; shift; fi
while (( $# > 0 )); do
    case "$1" in
        --pin)
            (( $# >= 3 )) || die "--pin requires RANGE and AZIMUTH"
            [[ -z "${REFERENCE_MODE}" ]] || die "use only one of --pin and --region"
            REFERENCE_MODE="pin"; PIN_X="$2"; PIN_Y="$3"; shift 3
            ;;
        --region)
            (( $# >= 2 )) || die "--region requires xmin/xmax/ymin/ymax"
            [[ -z "${REFERENCE_MODE}" ]] || die "use only one of --pin and --region"
            REFERENCE_MODE="region"; REFERENCE_REGION="$2"; shift 2
            ;;
        --window)
            (( $# >= 2 )) || die "--window requires an odd positive integer"
            WINDOW="$2"; shift 2
            ;;
        --jobs)
            (( $# >= 2 )) || die "--jobs requires a positive integer"
            JOBS="$2"; shift 2
            ;;
        --stat)
            (( $# >= 2 )) || die "--stat requires mean or median"
            STATISTIC="$2"; shift 2
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
[[ "${WINDOW}" =~ ^[1-9][0-9]*$ ]] || die "--window must be a positive integer"
(( WINDOW % 2 == 1 )) || die "--window must be odd so the pin is the center pixel"
[[ "${STATISTIC}" == "mean" || "${STATISTIC}" == "median" ]] ||
    die "--stat must be mean or median"
for command_name in awk basename find gmt sort wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
[[ "${TRACK}" == "Ascending" || "${TRACK}" == "Descending" ]] ||
    die "run this script in an LT-1 Ascending or Descending directory"
[[ -d "${INTF_DIR}" ]] || die "cannot find ${INTF_DIR}/"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT
# Keep all GMT modern-mode session files inside this run. This also prevents
# concurrent jobs from sharing or requiring a writable ~/.gmt directory.
GMT_USERDIR="${TMP_DIR}/gmt_user"
export GMT_USERDIR
mkdir -p "${GMT_USERDIR}"
PAIR_LIST="${TMP_DIR}/pairs"
find "${INTF_DIR}" -mindepth 2 -maxdepth 2 -type f \
    -path "${INTF_DIR}/20*/${INPUT_NAME}" -size +0c -print |
    while IFS= read -r grid; do basename -- "$(dirname -- "${grid}")"; done |
    sort -u > "${PAIR_LIST}"
PAIR_COUNT="$(wc -l < "${PAIR_LIST}" | awk '{print $1}')"
(( PAIR_COUNT > 0 )) || die "no non-empty ${INTF_DIR}/20*/${INPUT_NAME} files found; run Run 3.11 first"

FIRST_PAIR="$(sed -n '1p' "${PAIR_LIST}")"
FIRST_GRID="${INTF_DIR}/${FIRST_PAIR}/${INPUT_NAME}"
FIRST_SIGNATURE="$(grid_signature "${FIRST_GRID}")"
while IFS= read -r pair; do
    grid="${INTF_DIR}/${pair}/${INPUT_NAME}"
    [[ "$(grid_signature "${grid}")" == "${FIRST_SIGNATURE}" ]] ||
        die "${pair}: ${INPUT_NAME} geometry differs from ${FIRST_PAIR}"
done < "${PAIR_LIST}"

REQUESTED_PIN="none"
SNAPPED_PIN="none"
POINT_FILE="${TMP_DIR}/pin_points.txt"
BOX_FILE="${TMP_DIR}/reference_box.txt"
MARKER_FILE="${TMP_DIR}/reference_marker.txt"
WINDOW_POINT_COUNT=$(( WINDOW * WINDOW ))

if [[ -n "${MODE}" ]]; then
    [[ -n "${REFERENCE_MODE}" ]] || die "formal mode requires --pin X Y or --region XMIN/XMAX/YMIN/YMAX"
    if [[ "${REFERENCE_MODE}" == "pin" ]]; then
        is_number "${PIN_X}" && is_number "${PIN_Y}" || die "--pin values must be numeric radar coordinates"
        REQUESTED_PIN="${PIN_X}/${PIN_Y}"
        read -r W E S N DX DY REG < <(
            gmt grdinfo "${FIRST_GRID}" -C |
                awk '{print $2, $3, $4, $5, $8, $9, $12; exit}'
        )
        read -r SNAP_X SNAP_Y < <(awk -v x="${PIN_X}" -v y="${PIN_Y}" \
            -v w="${W}" -v s="${S}" -v dx="${DX}" -v dy="${DY}" -v reg="${REG}" '
            BEGIN {
                ox=w+(reg==1 ? dx/2 : 0); oy=s+(reg==1 ? dy/2 : 0)
                ix=int((x-ox)/dx+0.5); iy=int((y-oy)/dy+0.5)
                printf "%.15g %.15g\n", ox+ix*dx, oy+iy*dy
            }')
        SNAPPED_PIN="${SNAP_X}/${SNAP_Y}"
        HALF=$(( WINDOW / 2 ))
        read -r XMIN XMAX YMIN YMAX < <(awk -v x="${SNAP_X}" -v y="${SNAP_Y}" \
            -v dx="${DX}" -v dy="${DY}" -v h="${HALF}" '
            BEGIN {printf "%.15g %.15g %.15g %.15g\n", x-h*dx, x+h*dx, y-h*dy, y+h*dy}')
        REFERENCE_REGION="${XMIN}/${XMAX}/${YMIN}/${YMAX}"
        awk -v xmin="${XMIN}" -v xmax="${XMAX}" -v ymin="${YMIN}" -v ymax="${YMAX}" \
            -v w="${W}" -v e="${E}" -v s="${S}" -v n="${N}" \
            'BEGIN{exit !(xmin>=w && xmax<=e && ymin>=s && ymax<=n)}' ||
            die "the ${WINDOW}x${WINDOW} pin window ${REFERENCE_REGION} is outside the grid ${W}/${E}/${S}/${N}"
        awk -v x="${SNAP_X}" -v y="${SNAP_Y}" -v dx="${DX}" -v dy="${DY}" -v h="${HALF}" '
            BEGIN {for(j=-h;j<=h;j++)for(i=-h;i<=h;i++)printf "%.15g %.15g\n",x+i*dx,y+j*dy}' \
            > "${POINT_FILE}"
    else
        awk -v r="${REFERENCE_REGION}" 'BEGIN {
            n=split(r,a,"/"); if(n!=4)exit 1
            for(i=1;i<=4;i++)if(a[i]!~/^[-+]?[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$/)exit 1
            exit !(a[1]<a[2] && a[3]<a[4])
        }' || die "--region must be xmin/xmax/ymin/ymax with min < max"
        IFS=/ read -r XMIN XMAX YMIN YMAX <<< "${REFERENCE_REGION}"
        read -r DISPLAY_X DISPLAY_Y < <(awk -v xmin="${XMIN}" -v xmax="${XMAX}" \
            -v ymin="${YMIN}" -v ymax="${YMAX}" \
            'BEGIN{printf "%.15g %.15g\n",(xmin+xmax)/2,(ymin+ymax)/2}')
    fi

    if [[ "${REFERENCE_MODE}" == "pin" ]]; then
        DISPLAY_X="${SNAP_X}"
        DISPLAY_Y="${SNAP_Y}"
    fi
    {
        printf '%s %s\n' "${XMIN}" "${YMIN}"
        printf '%s %s\n' "${XMAX}" "${YMIN}"
        printf '%s %s\n' "${XMAX}" "${YMAX}"
        printf '%s %s\n' "${XMIN}" "${YMAX}"
        printf '%s %s\n' "${XMIN}" "${YMIN}"
    } > "${BOX_FILE}"
    printf '%s %s\n' "${DISPLAY_X}" "${DISPLAY_Y}" > "${MARKER_FILE}"
fi

printf '%s\n' '========================================================================'
printf '%s\n' 'LT-1 Run 3.12 stable-area phase reference'
printf 'Mode:                 %s\n' "$([[ -n "${MODE}" ]] && printf FORMAL || printf CHECK)"
printf 'Track:                %s\n' "${TRACK}"
printf 'Detrended pairs:      %s\n' "${PAIR_COUNT}"
printf 'Input:                %s/<pair>/%s\n' "${INTF_DIR}" "${INPUT_NAME}"
printf 'Output:               %s/<pair>/%s\n' "${INTF_DIR}" "${OUTPUT_NAME}"
printf 'Pair PDF:             %s/<pair>/%s\n' "${INTF_DIR}" "${PAIR_PDF_NAME}"
printf 'Combined PNG:         %s/%s\n' "${OVERVIEW_DIR}" "${OVERVIEW_PNG_NAME}"
if [[ -n "${REFERENCE_MODE}" ]]; then
    printf 'Reference mode:       %s\n' "${REFERENCE_MODE}"
    printf 'Requested pin:        %s\n' "${REQUESTED_PIN}"
    printf 'Snapped pin:          %s\n' "${SNAPPED_PIN}"
    printf 'Reference region:     %s\n' "${REFERENCE_REGION}"
    printf 'Window:               %sx%s pixels\n' "${WINDOW}" "${WINDOW}"
    printf 'Statistic:            %s\n' "${STATISTIC}"
fi
printf 'Parallel jobs:        %s\n' "${JOBS}"
printf '%s\n' '========================================================================'

if [[ -z "${MODE}" ]]; then
    usage
    printf '[CHECK ONLY] No files were modified.\n'
    exit 0
fi

FAILED="${TMP_DIR}/failed.tsv"
: > "${FAILED}"
PIDS=()
PAIRS=()
wait_batch() {
    local i
    for i in "${!PIDS[@]}"; do
        if wait "${PIDS[${i}]}"; then :; else
            printf '%s\tfailed\n' "${PAIRS[${i}]}" >> "${FAILED}"
            printf '[FAILED] %s\n' "${PAIRS[${i}]}" >&2
        fi
    done
    PIDS=(); PAIRS=()
}

while IFS= read -r pair; do
    process_pair "${pair}" &
    PIDS+=("$!"); PAIRS+=("${pair}")
    if (( ${#PIDS[@]} >= JOBS )); then wait_batch; fi
done < "${PAIR_LIST}"
if (( ${#PIDS[@]} > 0 )); then wait_batch; fi

[[ ! -s "${FAILED}" ]] || die "one or more pairs failed; failed pairs were printed above"

make_reference_overview

printf 'pair\treference_rad\tvalid_pixels\ttotal_pixels\tstatistic\tregion\n' > "${REPORT_NAME}"
while IFS= read -r pair; do
    info="${INTF_DIR}/${pair}/${INFO_NAME}"
    output="${INTF_DIR}/${pair}/${OUTPUT_NAME}"
    [[ -s "${info}" && -s "${output}" ]] || die "${pair}: missing final output or reference info"
    ref="$(awk -F= '$1=="reference_value_rad"{print $2}' "${info}")"
    valid="$(awk -F= '$1=="valid_pixels"{print $2}' "${info}")"
    total="$(awk -F= '$1=="total_pixels"{print $2}' "${info}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${pair}" "${ref}" "${valid}" "${total}" "${STATISTIC}" "${REFERENCE_REGION}" >> "${REPORT_NAME}"
done < "${PAIR_LIST}"

printf '%s\n' '========================================================================'
printf '[SUCCESS] Referenced grids: %s/%s\n' "${PAIR_COUNT}" "${PAIR_COUNT}"
printf '[SUCCESS] Reference report: %s/%s\n' "${ROOT_DIR}" "${REPORT_NAME}"
printf '[SUCCESS] Pair PDFs:        %s/%s\n' "${PAIR_COUNT}" "${PAIR_COUNT}"
printf '[SUCCESS] Combined PNG:     %s/%s/%s\n' \
    "${ROOT_DIR}" "${OVERVIEW_DIR}" "${OVERVIEW_PNG_NAME}"
printf '[NEXT] ./run4.1_update_sbas_intf_baseline_LT1.sh 1\n'
printf '%s\n' '========================================================================'
