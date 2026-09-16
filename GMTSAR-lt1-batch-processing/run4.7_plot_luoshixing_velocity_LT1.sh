#!/usr/bin/env bash
# Run 4.7: crop and plot the Luoshixing LT-1 SBAS LOS velocity region.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

DEFAULT_WEST="118.770"
DEFAULT_EAST="118.781"
DEFAULT_SOUTH="29.991"
DEFAULT_NORTH="30.010"
DEFAULT_NAME="luoshixing"
DEFAULT_POINT_LON="118.776820"
DEFAULT_POINT_LAT="30.003311"
DEFAULT_POINT_LABEL="Luoshixing"
SBAS_DIR="sbas_detrend"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'EOF'
Run 4.7: crop and plot the Luoshixing LT-1 SBAS velocity

Usage:
  ./run4.7_plot_luoshixing_velocity_LT1.sh
  ./run4.7_plot_luoshixing_velocity_LT1.sh 1
  ./run4.7_plot_luoshixing_velocity_LT1.sh 1 \
    --upper-left LON LAT --lower-right LON LAT [options]

Default geographic rectangle:
  upper left  = 118.770 30.010
  lower right = 118.781 29.991
  marked point = 118.776820 30.003311 (Luoshixing)

Options:
  --point LON LAT      Point marked by an unfilled red square.
  --point-label TEXT   Point label (default: Luoshixing).
  --name NAME          Output region name (default: luoshixing).

No arguments:
  Check the input and report the requested region without creating files.

Formal mode:
  Crop sbas_detrend/vel_ll.grd, calculate the cropped grid's actual value
  range, and use max(abs(min),abs(max)) as symmetric jet color limits.

Outputs in run4.7_luoshixing_velocity/ under the track root:
  vel_ll_luoshixing.grd
  vel_ll_luoshixing.cpt
  vel_ll_luoshixing.png
  vel_ll_luoshixing.pdf
  velocity_region_report.txt
  run4.7_complete
EOF
}

is_number() {
    awk -v x="$1" 'BEGIN {
        exit !(x ~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)$/)
    }'
}

FORMAL=0
WEST="$DEFAULT_WEST"
EAST="$DEFAULT_EAST"
SOUTH="$DEFAULT_SOUTH"
NORTH="$DEFAULT_NORTH"
REGION_NAME="$DEFAULT_NAME"
POINT_LON="$DEFAULT_POINT_LON"
POINT_LAT="$DEFAULT_POINT_LAT"
POINT_LABEL="$DEFAULT_POINT_LABEL"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

while (( $# > 0 )); do
    case "$1" in
        1)
            FORMAL=1
            shift
            ;;
        --upper-left|--ul)
            (( $# >= 3 )) || die "$1 requires longitude and latitude"
            WEST="$2"
            NORTH="$3"
            shift 3
            ;;
        --lower-right|--lr)
            (( $# >= 3 )) || die "$1 requires longitude and latitude"
            EAST="$2"
            SOUTH="$3"
            shift 3
            ;;
        --name)
            (( $# >= 2 )) || die "--name requires a value"
            REGION_NAME="$2"
            shift 2
            ;;
        --point)
            (( $# >= 3 )) || die "--point requires longitude and latitude"
            POINT_LON="$2"
            POINT_LAT="$3"
            shift 3
            ;;
        --point-label)
            (( $# >= 2 )) || die "--point-label requires text"
            POINT_LABEL="$2"
            shift 2
            ;;
        *)
            die "unknown argument: $1 (use --help)"
            ;;
    esac
done

for value in "$WEST" "$EAST" "$SOUTH" "$NORTH"; do
    is_number "$value" || die "coordinate is not numeric: $value"
done
is_number "$POINT_LON" || die "point longitude is not numeric: $POINT_LON"
is_number "$POINT_LAT" || die "point latitude is not numeric: $POINT_LAT"
awk -v w="$WEST" -v e="$EAST" -v s="$SOUTH" -v n="$NORTH" 'BEGIN {
    exit !(w>=-180 && e<=180 && s>=-90 && n<=90 && w<e && s<n)
}' || die "require upper-left west/north and lower-right east/south"
awk -v x="$POINT_LON" -v y="$POINT_LAT" \
    -v w="$WEST" -v e="$EAST" -v s="$SOUTH" -v n="$NORTH" 'BEGIN {
        exit !(x>=w && x<=e && y>=s && y<=n)
    }' || die "marked point $POINT_LON/$POINT_LAT is outside the requested rectangle"

REGION_NAME="$(printf '%s' "$REGION_NAME" | tr -c '[:alnum:]_.-' '_')"
[[ -n "$REGION_NAME" ]] || die "region name is empty"

for command_name in awk gmt mkdir tr; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" == "Ascending" || "$TRACK" == "Descending" ]] ||
    die "run in an LT-1 Ascending or Descending directory (current: $ROOT)"

INPUT_GRID="$ROOT/$SBAS_DIR/vel_ll.grd"
[[ -s "$INPUT_GRID" ]] ||
    die "missing or empty: $INPUT_GRID; complete Run 4.4 first"

INPUT_INFO="$(gmt grdinfo "$INPUT_GRID" -Cn)"
# With -Cn, grdinfo starts directly with west/east/south/north; there is no
# leading filename column.
read -r INPUT_W INPUT_E INPUT_S INPUT_N _ _ INPUT_DX INPUT_DY INPUT_NX INPUT_NY INPUT_REG _ <<< "$INPUT_INFO"
[[ -n "${INPUT_REG:-}" ]] || die "failed to read vel_ll.grd geometry"

# proj_ra2ll may store equivalent longitudes in another 360-degree domain
# (for example -241.230 equals 118.770 E). Choose the shift that places the
# requested rectangle inside the native grid, then restore conventional
# longitudes on the cropped output before plotting.
LON_SHIFT=""
for candidate_shift in 0 -360 360; do
    if awk -v w="$WEST" -v e="$EAST" -v shift="$candidate_shift" \
        -v gw="$INPUT_W" -v ge="$INPUT_E" 'BEGIN {
            exit !((w+shift)>=gw && (e+shift)<=ge)
        }'; then
        LON_SHIFT="$candidate_shift"
        break
    fi
done
[[ -n "$LON_SHIFT" ]] ||
    die "requested longitude range $WEST/$EAST is outside vel_ll.grd native coverage $INPUT_W/$INPUT_E, including +/-360-degree equivalents"
awk -v s="$SOUTH" -v n="$NORTH" -v gs="$INPUT_S" -v gn="$INPUT_N" 'BEGIN {
    exit !(s>=gs && n<=gn)
}' || die "requested latitude range $SOUTH/$NORTH is outside vel_ll.grd coverage $INPUT_S/$INPUT_N"

CUT_WEST="$(awk -v x="$WEST" -v shift="$LON_SHIFT" 'BEGIN{printf "%.12g",x+shift}')"
CUT_EAST="$(awk -v x="$EAST" -v shift="$LON_SHIFT" 'BEGIN{printf "%.12g",x+shift}')"
CUT_REGION="$CUT_WEST/$CUT_EAST/$SOUTH/$NORTH"

OUTPUT_DIR="$ROOT/run4.7_${REGION_NAME}_velocity"
STEM="vel_ll_${REGION_NAME}"
REQUESTED_REGION="$WEST/$EAST/$SOUTH/$NORTH"

printf '%s\n' '========================================================================'
printf '%s\n' 'LT-1 Run 4.7 local SBAS velocity map'
printf 'Mode:              %s\n' "$([[ "$FORMAL" -eq 1 ]] && printf FORMAL || printf CHECK)"
printf 'Track:             %s\n' "$TRACK"
printf 'Input grid:        %s\n' "$INPUT_GRID"
printf 'Native coverage:   %s/%s/%s/%s\n' "$INPUT_W" "$INPUT_E" "$INPUT_S" "$INPUT_N"
printf 'Region name:       %s\n' "$REGION_NAME"
printf 'Upper left:        %s %s\n' "$WEST" "$NORTH"
printf 'Lower right:       %s %s\n' "$EAST" "$SOUTH"
printf 'Marked point:      %s %s (%s)\n' "$POINT_LON" "$POINT_LAT" "$POINT_LABEL"
printf 'Requested region:  %s\n' "$REQUESTED_REGION"
printf 'Longitude shift:   %s degrees\n' "$LON_SHIFT"
printf 'Native cut region: %s\n' "$CUT_REGION"
printf 'Output directory:  %s\n' "$OUTPUT_DIR"
printf 'Map projection:    Mercator with geographic aspect ratio\n'
printf 'Color scale:       symmetric jet from cropped-grid actual max |velocity|\n'
printf '%s\n' '========================================================================'

if (( FORMAL == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] No grid or figure was created.'
    exit 0
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_GRID="$OUTPUT_DIR/${STEM}.grd"
OUTPUT_CPT="$OUTPUT_DIR/${STEM}.cpt"
OUTPUT_BASE="$OUTPUT_DIR/${STEM}"
rm -f -- "$OUTPUT_GRID" "$OUTPUT_CPT" \
    "$OUTPUT_BASE.pdf" "$OUTPUT_BASE.png" \
    "$OUTPUT_DIR/velocity_region_report.txt" "$OUTPUT_DIR/run4.7_complete"

printf '%s\n' '[STEP 1] Crop vel_ll.grd to the Luoshixing rectangle'
gmt grdcut "$INPUT_GRID" -R"$CUT_REGION" -G"$OUTPUT_GRID"
[[ -s "$OUTPUT_GRID" ]] || die "gmt grdcut did not generate $OUTPUT_GRID"

if awk -v shift="$LON_SHIFT" 'BEGIN{exit !(shift!=0)}'; then
    NATIVE_CROP_INFO="$(gmt grdinfo "$OUTPUT_GRID" -Cn)"
    read -r NATIVE_W NATIVE_E NATIVE_S NATIVE_N _ <<< "$NATIVE_CROP_INFO"
    DISPLAY_W="$(awk -v x="$NATIVE_W" -v shift="$LON_SHIFT" 'BEGIN{printf "%.12g",x-shift}')"
    DISPLAY_E="$(awk -v x="$NATIVE_E" -v shift="$LON_SHIFT" 'BEGIN{printf "%.12g",x-shift}')"
    gmt grdedit "$OUTPUT_GRID" -R"$DISPLAY_W/$DISPLAY_E/$NATIVE_S/$NATIVE_N"
fi

CROP_INFO="$(gmt grdinfo "$OUTPUT_GRID" -Cn)"
read -r CROP_W CROP_E CROP_S CROP_N VEL_MIN VEL_MAX CROP_DX CROP_DY CROP_NX CROP_NY CROP_REG _ <<< "$CROP_INFO"
for value in "$VEL_MIN" "$VEL_MAX" "$CROP_NX" "$CROP_NY"; do
    [[ -n "$value" ]] || die "failed to read cropped-grid information"
done

ABS_MAX="$(awk -v lo="$VEL_MIN" -v hi="$VEL_MAX" 'BEGIN {
    if (lo<0) lo=-lo
    if (hi<0) hi=-hi
    maximum=(lo>hi ? lo : hi)
    if (!(maximum>0)) exit 1
    printf "%.12g", maximum
}')" || die "cropped grid has no non-zero finite velocity values"
CPT_MIN="$(awk -v x="$ABS_MAX" 'BEGIN {printf "%.12g",-x}')"
CPT_MAX="$ABS_MAX"
CPT_INC="$(awk -v x="$ABS_MAX" 'BEGIN {printf "%.12g",2*x/100}')"

# Use about four major intervals and round to a readable 1/2/5 x 10^n tick.
CPT_TICK="$(awk -v maximum="$ABS_MAX" 'BEGIN {
    raw=(2*maximum)/4
    power=int(log(raw)/log(10))
    if (raw<1) power--
    base=10^power
    normalized=raw/base
    if (normalized<1.5) nice=1
    else if (normalized<3.5) nice=2
    else if (normalized<7.5) nice=5
    else nice=10
    printf "%.12g", nice*base
}')"

printf '[STEP 2] Actual velocity range: %s to %s mm/yr; symmetric CPT: %s to %s\n' \
    "$VEL_MIN" "$VEL_MAX" "$CPT_MIN" "$CPT_MAX"
gmt makecpt -Cjet -T"${CPT_MIN}/${CPT_MAX}/${CPT_INC}" -Z -D > "$OUTPUT_CPT"
[[ -s "$OUTPUT_CPT" ]] || die "failed to generate $OUTPUT_CPT"

printf '%s\n' '[STEP 3] Plot local velocity PDF and PNG'
gmt begin "$OUTPUT_BASE" pdf,png
    gmt set MAP_FRAME_TYPE plain \
        FONT_ANNOT_PRIMARY 10p FONT_LABEL 11p FONT_TITLE 13p COLOR_NAN gray
    gmt grdimage "$OUTPUT_GRID" -R"$CROP_W/$CROP_E/$CROP_S/$CROP_N" \
        -JM15c -C"$OUTPUT_CPT" -Baf \
        -BWSen+t"Luoshixing landslide LT-1 LOS velocity"
    # Unfilled square: the velocity pixels inside remain visible.
    printf '%s %s\n' "$POINT_LON" "$POINT_LAT" | \
        gmt plot -Ss0.42c -W1.6p,red
    printf '%s %s %s\n' "$POINT_LON" "$POINT_LAT" "$POINT_LABEL" | \
        gmt text -F+f10p,Helvetica-Bold,black+jBL -D0.18c/0.18c -Gwhite@25
    gmt colorbar -C"$OUTPUT_CPT" -DJBC+w10c/0.3c+h+o0c/1.0c \
        -Bxa"${CPT_TICK}"+l"LOS velocity (mm/yr)"
gmt end
[[ -s "$OUTPUT_BASE.pdf" && -s "$OUTPUT_BASE.png" ]] ||
    die "GMT did not generate the Run 4.7 PDF and PNG"

{
    printf 'region_name=%s\n' "$REGION_NAME"
    printf 'track=%s\n' "$TRACK"
    printf 'input_grid=%s\n' "$INPUT_GRID"
    printf 'requested_region=%s\n' "$REQUESTED_REGION"
    printf 'marked_point=%s/%s\n' "$POINT_LON" "$POINT_LAT"
    printf 'marked_point_label=%s\n' "$POINT_LABEL"
    printf 'native_input_region=%s/%s/%s/%s\n' "$INPUT_W" "$INPUT_E" "$INPUT_S" "$INPUT_N"
    printf 'longitude_shift=%s\n' "$LON_SHIFT"
    printf 'native_cut_region=%s\n' "$CUT_REGION"
    printf 'actual_grid_region=%s/%s/%s/%s\n' "$CROP_W" "$CROP_E" "$CROP_S" "$CROP_N"
    printf 'grid_spacing=%s/%s\n' "$CROP_DX" "$CROP_DY"
    printf 'grid_dimensions=%s/%s\n' "$CROP_NX" "$CROP_NY"
    printf 'grid_registration=%s\n' "$CROP_REG"
    printf 'map_projection=Mercator_geographic_aspect\n'
    printf 'velocity_min_mm_per_year=%s\n' "$VEL_MIN"
    printf 'velocity_max_mm_per_year=%s\n' "$VEL_MAX"
    printf 'velocity_abs_max_mm_per_year=%s\n' "$ABS_MAX"
    printf 'cpt_range=%s/%s/%s\n' "$CPT_MIN" "$CPT_MAX" "$CPT_INC"
    printf 'colorbar_tick=%s\n' "$CPT_TICK"
} > "$OUTPUT_DIR/velocity_region_report.txt"

{
    printf 'status=COMPLETE\n'
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'region_name=%s\n' "$REGION_NAME"
    printf 'marked_point=%s/%s\n' "$POINT_LON" "$POINT_LAT"
    printf 'marked_point_label=%s\n' "$POINT_LABEL"
    printf 'grid=%s\n' "$OUTPUT_GRID"
    printf 'png=%s.png\n' "$OUTPUT_BASE"
    printf 'pdf=%s.pdf\n' "$OUTPUT_BASE"
    printf 'velocity_range=%s/%s\n' "$VEL_MIN" "$VEL_MAX"
    printf 'cpt_abs_max=%s\n' "$ABS_MAX"
} > "$OUTPUT_DIR/run4.7_complete"

printf '%s\n' '========================================================================'
printf '[SUCCESS] Cropped grid: %s\n' "$OUTPUT_GRID"
printf '[SUCCESS] Actual range: %s to %s mm/yr\n' "$VEL_MIN" "$VEL_MAX"
printf '[SUCCESS] Figure: %s.png and %s.pdf\n' "$OUTPUT_BASE" "$OUTPUT_BASE"
printf '[REPORT]  %s/velocity_region_report.txt\n' "$OUTPUT_DIR"
printf '%s\n' '========================================================================'
