#!/usr/bin/env bash
# Run 4.5: extract burst-SBAS displacement time series at multiple geographic
# points and mark the points on the geographic velocity map.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

DEFAULT_POINTS_FILE="run4.5_points.txt"
DEFAULT_WINDOW=5
LANDSLIDE_DATE="${LANDSLIDE_DATE:-2025-05-25}"
LANDSLIDE_LABEL="${LANDSLIDE_LABEL:-Landslide}"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 4.5: extract multi-point burst SBAS time series

Usage:
  ./run4.5_extract_multi_point_timeseries_pin_burst.sh [POINTS_FILE] [WINDOW_X WINDOW_Y]
  ./run4.5_extract_multi_point_timeseries_pin_burst.sh LONGITUDE LATITUDE LABEL [WINDOW_X WINDOW_Y]

If POINTS_FILE is omitted, run4.5_points.txt in the track root is used.
LONGITUDE LATITUDE LABEL directly extracts one command-line point.
This script always reads sbas_burst_pin; the default sampling window is 5 x 5 nodes.

POINTS_FILE format (longitude latitude [label]):
  # longitude latitude label
  118.774 30.010 Luosixing
  118.790 30.020 Point02

Rules:
  - Blank lines and lines beginning with # are ignored.
  - If label is omitted, P01, P02, ... are assigned automatically.
  - Labels must be unique; unsafe filename characters are changed to _.
  - WINDOW_X and WINDOW_Y must be positive odd integers.

Examples:
  ./run4.5_extract_multi_point_timeseries_pin_burst.sh
  ./run4.5_extract_multi_point_timeseries_pin_burst.sh my_points.txt
  ./run4.5_extract_multi_point_timeseries_pin_burst.sh my_points.txt 3 3
  ./run4.5_extract_multi_point_timeseries_pin_burst.sh 118.781 29.993 luoshixing
  ./run4.5_extract_multi_point_timeseries_pin_burst.sh 118.781 29.993 luoshixing 3 3

Optional event marker:
  LANDSLIDE_DATE=2025-05-25 LANDSLIDE_LABEL=Landslide ./run4.5_extract_multi_point_timeseries_pin_burst.sh ...

Inputs:
  burst/topo/dem.grd
  sbas_burst_pin/supermaster.PRM
  sbas_burst_pin/scene.tab
  sbas_burst_pin/disp_<YYYYDDD>.grd
  sbas_burst_pin/vel_ll.grd

Outputs in sbas_burst_pin/run4.5_time_series/:
  points_radar.tsv
  time_series_all.tsv
  time_series_<label>.dat
  time_series_<label>.pdf/.png
  time_series_all.pdf/.png
  vel_ll_points.pdf/.png
  run4.5_complete

The existing vel_ll.grd, vel_ll.pdf and displacement grids are read only.
========================================
EOF
}

is_positive_odd_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] && (( 10#$1 % 2 == 1 ))
}

is_number() {
    awk -v value="$1" 'BEGIN {
        exit !(value ~ /^[-+]?[0-9]+([.][0-9]*)?$/ ||
               value ~ /^[-+]?[.][0-9]+$/)
    }'
}

ydoy_to_iso() {
    awk -v code="$1" '
        function leap(y) {return (y%400==0 || (y%4==0 && y%100!=0))}
        BEGIN {
            if (length(code) != 7 || code !~ /^[0-9]+$/) exit 1
            y=substr(code,1,4)+0
            d=substr(code,5,3)+0
            md[1]=31; md[2]=28+leap(y); md[3]=31; md[4]=30
            md[5]=31; md[6]=30; md[7]=31; md[8]=31
            md[9]=30; md[10]=31; md[11]=30; md[12]=31
            if (d < 0 || d > 364+leap(y)) exit 1
            d=d+1
            m=1
            while (d > md[m]) {d-=md[m]; m++}
            printf "%04d-%02d-%02d",y,m,d
        }'
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi

# Direct single-point mode. It calls the normal file mode with a temporary
# one-record point list, so both modes use exactly the same extraction logic.
if (( $# == 3 || $# == 5 )) && is_number "$1" && is_number "$2"; then
    DIRECT_POINTS="$(mktemp "${TMPDIR:-/tmp}/run4.5-direct-points.XXXXXX")"
    trap 'rm -f -- "$DIRECT_POINTS"' EXIT INT TERM
    printf '%s %s %s\n' "$1" "$2" "$3" > "$DIRECT_POINTS"
    if (( $# == 5 )); then
        "$0" "$DIRECT_POINTS" "$4" "$5"
    else
        "$0" "$DIRECT_POINTS"
    fi
    exit $?
fi

(( $# <= 3 )) || die "too many arguments; use --help"

POINTS_INPUT="${1:-$DEFAULT_POINTS_FILE}"
BRANCH="pin"
WINDOW_X="${2:-$DEFAULT_WINDOW}"
WINDOW_Y="${3:-$DEFAULT_WINDOW}"
is_positive_odd_integer "$WINDOW_X" ||
    die "WINDOW_X must be a positive odd integer"
is_positive_odd_integer "$WINDOW_Y" ||
    die "WINDOW_Y must be a positive odd integer"

for command_name in awk basename cat date find gmt ln mkdir mktemp mv \
                    SAT_llt2rat sort tr wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

[[ "$LANDSLIDE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
    die "LANDSLIDE_DATE must use YYYY-MM-DD format: $LANDSLIDE_DATE"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT)"

if [[ "$POINTS_INPUT" = /* ]]; then
    POINTS_FILE="$POINTS_INPUT"
else
    POINTS_FILE="$ROOT/$POINTS_INPUT"
fi
[[ -s "$POINTS_FILE" ]] || {
    usage
    die "points file is missing or empty: $POINTS_FILE"
}

SBAS_DIR="$ROOT/sbas_burst_pin"

TOPO_DIR="$ROOT/burst/topo"
DEM="$TOPO_DIR/dem.grd"
PRM="$SBAS_DIR/supermaster.PRM"
LED="$SBAS_DIR/supermaster.LED"
SCENE_TAB="$SBAS_DIR/scene.tab"
VEL_LL="$SBAS_DIR/vel_ll.grd"
VEL_CPT="$SBAS_DIR/vel_ll.cpt"
BATCH_CONFIG="$ROOT/burst/batch_tops.config"
OUTPUT_DIR="$SBAS_DIR/run4.5_time_series"

for file in "$DEM" "$PRM" "$LED" "$SCENE_TAB" "$VEL_LL"; do
    [[ -s "$file" ]] || die "missing or empty: $file"
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run4.5-burst.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT INT TERM

# Use the renamed SBAS master LED without changing the original PRM or LED.
SAT_WORK="$TMP/sat_llt2rat"
SAT_PRM="$SAT_WORK/supermaster.PRM"
mkdir -p "$SAT_WORK"
if ! awk '
    $1 == "led_file" {
        print "led_file = supermaster.LED"
        found=1
        next
    }
    {print}
    END {if (!found) exit 42}
' "$PRM" > "$SAT_PRM"; then
    die "supermaster.PRM contains no led_file field: $PRM"
fi
[[ -s "$SAT_PRM" ]] || die "failed to prepare the temporary supermaster.PRM"
ln -s "$LED" "$SAT_WORK/supermaster.LED"

NORMALIZED_POINTS="$TMP/points.tsv"
awk '
    BEGIN {OFS="\t"}
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    {
        n++
        if (NF < 2) {
            printf "line %d has fewer than two fields\n",NR > "/dev/stderr"
            bad=1; next
        }
        lon=$1; lat=$2
        label=(NF >= 3 ? $3 : sprintf("P%02d",n))
        gsub(/[^[:alnum:]_.-]/,"_",label)
        if (label == "") label=sprintf("P%02d",n)
        print label,lon,lat
    }
    END {if (bad || n == 0) exit 1}
' "$POINTS_FILE" > "$NORMALIZED_POINTS" ||
    die "invalid points file: $POINTS_FILE"

POINT_COUNT="$(wc -l < "$NORMALIZED_POINTS" | tr -d ' ')"
(( POINT_COUNT > 0 )) || die "no point records found in $POINTS_FILE"

DUPLICATE_LABELS="$TMP/duplicate_labels.txt"
awk -F'\t' '{count[$1]++} END {for (key in count) if (count[key] > 1) print key}' \
    "$NORMALIZED_POINTS" | sort > "$DUPLICATE_LABELS"
[[ ! -s "$DUPLICATE_LABELS" ]] || {
    cat "$DUPLICATE_LABELS" >&2
    die "point labels must be unique"
}

while IFS=$'\t' read -r label lon lat; do
    is_number "$lon" || die "$label longitude is not numeric: $lon"
    is_number "$lat" || die "$label latitude is not numeric: $lat"
    awk -v lon="$lon" -v lat="$lat" \
        'BEGIN {exit !(lon >= -180 && lon <= 180 && lat >= -90 && lat <= 90)}' ||
        die "$label longitude/latitude is outside the valid geographic range"
done < "$NORMALIZED_POINTS"

SCENES="$TMP/scenes.tsv"
awk '
    NF && substr($1,1,1) != "#" {
        if (length($1) != 7 || $1 !~ /^[0-9]+$/) {
            printf "invalid scene code on line %d: %s\n",NR,$1 > "/dev/stderr"
            bad=1
        } else print $1
    }
    END {if (bad) exit 1}
' "$SCENE_TAB" | sort -n -u > "$SCENES" ||
    die "scene.tab contains an invalid YYYYDDD scene code"

SCENE_COUNT="$(wc -l < "$SCENES" | tr -d ' ')"
(( SCENE_COUNT > 0 )) || die "scene.tab contains no acquisition records"

MISSING_SCENES="$TMP/missing_scenes.txt"
: > "$MISSING_SCENES"
while IFS= read -r scene; do
    grid="$SBAS_DIR/disp_${scene}.grd"
    [[ -s "$grid" ]] || printf '%s\n' "$grid" >> "$MISSING_SCENES"
done < "$SCENES"
if [[ -s "$MISSING_SCENES" ]]; then
    head -n 20 "$MISSING_SCENES" >&2
    MISSING_COUNT="$(wc -l < "$MISSING_SCENES" | tr -d ' ')"
    die "$MISSING_COUNT displacement grids are missing or empty"
fi

FIRST_SCENE="$(head -n 1 "$SCENES")"
FIRST_GRID="$SBAS_DIR/disp_${FIRST_SCENE}.grd"
GRID_SIGNATURE="$(gmt grdinfo "$FIRST_GRID" -C | awk 'NR==1 {
    print $2,$3,$4,$5,$8,$9,$10,$11,$12
}')"
read -r XMIN XMAX YMIN YMAX XINC YINC NCOL NROW REGISTRATION <<< "$GRID_SIGNATURE"
[[ -n "$REGISTRATION" ]] || die "cannot read the displacement-grid geometry"

# SAT_llt2rat returns coordinates in the original SLC geometry.  When
# batch_tops.config uses region_cut, GMTSAR writes the cropped interferogram
# and SBAS grids with a new 0-based origin.  Subtract the region_cut origin so
# geographic points and disp_*.grd use the same local radar coordinate system.
REGION_CUT='full grid'
RADAR_OFFSET_RANGE=0
RADAR_OFFSET_AZIMUTH=0
if [[ -s "$BATCH_CONFIG" ]]; then
    CONFIG_REGION="$(awk -F= '
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == "region_cut") {
                value=$2
                gsub(/[[:space:]]/, "", value)
                print value
                exit
            }
        }
    ' "$BATCH_CONFIG")"
    if [[ -n "$CONFIG_REGION" ]]; then
        if [[ "$CONFIG_REGION" =~ ^[-+]?[0-9]+([.][0-9]+)?/[-+]?[0-9]+([.][0-9]+)?/[-+]?[0-9]+([.][0-9]+)?/[-+]?[0-9]+([.][0-9]+)?$ ]]; then
            REGION_CUT="$CONFIG_REGION"
            IFS=/ read -r RADAR_OFFSET_RANGE _ RADAR_OFFSET_AZIMUTH _ <<< "$CONFIG_REGION"
        else
            die "invalid region_cut in $BATCH_CONFIG: $CONFIG_REGION"
        fi
    fi
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 4.5 multi-point burst SBAS time-series check'
printf 'Track root        : %s\n' "$ROOT"
printf 'SBAS branch       : %s\n' "$BRANCH"
printf 'SBAS directory    : %s\n' "$SBAS_DIR"
printf 'Points file       : %s\n' "$POINTS_FILE"
printf 'Input points      : %s\n' "$POINT_COUNT"
printf 'Scene count       : %s\n' "$SCENE_COUNT"
printf 'Sampling window   : %s x %s nodes\n' "$WINDOW_X" "$WINDOW_Y"
printf 'Landslide marker : %s (%s)\n' "$LANDSLIDE_DATE" "$LANDSLIDE_LABEL"
printf 'Radar grid        : %s\n' "$GRID_SIGNATURE"
printf 'Source region_cut : %s\n' "$REGION_CUT"
printf 'Radar origin shift: %s / %s\n' "$RADAR_OFFSET_RANGE" "$RADAR_OFFSET_AZIMUTH"
printf 'Output directory  : %s\n' "$OUTPUT_DIR"
printf '%s\n' '========================================'

mkdir -p "$OUTPUT_DIR"

POINTS_RADAR="$OUTPUT_DIR/points_radar.tsv"
CURRENT_POINTS="$TMP/current_points_radar.tsv"
POINTS_MAP="$TMP/points_map.tsv"
: > "$CURRENT_POINTS"

HALF_X=$((WINDOW_X / 2))
HALF_Y=$((WINDOW_Y / 2))

while IFS=$'\t' read -r label lon lat; do
    elevation="$(
        printf '%s %s\n' "$lon" "$lat" |
            gmt grdtrack -G"$DEM" -fg |
            awk 'NF >= 3 && $3 != "NaN" {print $3; exit}'
    )"
    [[ -n "$elevation" ]] ||
        die "$label is outside dem.grd or its DEM elevation is NaN"

    radar="$(
        cd "$SAT_WORK"
        printf '%s %s %s\n' "$lon" "$lat" "$elevation" |
            SAT_llt2rat "$(basename -- "$SAT_PRM")" 1 |
            awk 'NF >= 2 && $1 ~ /^[-+0-9.]/ && $2 ~ /^[-+0-9.]/ {
                print $1,$2; exit
            }'
    )"
    [[ -n "$radar" ]] || die "SAT_llt2rat returned no coordinate for $label"
    read -r full_radar_range full_radar_azimuth <<< "$radar"
    radar_range="$(awk -v value="$full_radar_range" -v offset="$RADAR_OFFSET_RANGE" \
        'BEGIN {printf "%.0f",value-offset}')"
    radar_azimuth="$(awk -v value="$full_radar_azimuth" -v offset="$RADAR_OFFSET_AZIMUTH" \
        'BEGIN {printf "%.0f",value-offset}')"

    awk -v x="$radar_range" -v y="$radar_azimuth" \
        -v xmin="$XMIN" -v xmax="$XMAX" -v ymin="$YMIN" -v ymax="$YMAX" \
        'BEGIN {exit !(x >= xmin && x <= xmax && y >= ymin && y <= ymax)}' ||
        die "$label local radar coordinate ($radar_range,$radar_azimuth) is outside disp grids; full coordinate=$full_radar_range,$full_radar_azimuth; region_cut=$REGION_CUT"

    nearest_range="$(awk -v x="$radar_range" -v x0="$XMIN" -v dx="$XINC" \
        'BEGIN {printf "%.12g",x0+int((x-x0)/dx+0.5)*dx}')"
    nearest_azimuth="$(awk -v y="$radar_azimuth" -v y0="$YMIN" -v dy="$YINC" \
        'BEGIN {printf "%.12g",y0+int((y-y0)/dy+0.5)*dy}')"

    read -r cut_xmin cut_xmax cut_ymin cut_ymax <<< "$(
        awk -v x="$nearest_range" -v y="$nearest_azimuth" \
            -v dx="$XINC" -v dy="$YINC" -v hx="$HALF_X" -v hy="$HALF_Y" \
            -v xmin="$XMIN" -v xmax="$XMAX" -v ymin="$YMIN" -v ymax="$YMAX" '
            BEGIN {
                a=x-hx*dx; b=x+hx*dx; c=y-hy*dy; d=y+hy*dy
                if (a < xmin) a=xmin; if (b > xmax) b=xmax
                if (c < ymin) c=ymin; if (d > ymax) d=ymax
                printf "%.12g %.12g %.12g %.12g",a,b,c,d
            }'
    )"
    cut_region="$cut_xmin/$cut_xmax/$cut_ymin/$cut_ymax"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$lon" "$lat" "$elevation" \
        "$full_radar_range" "$full_radar_azimuth" "$radar_range" "$radar_azimuth" \
        "$nearest_range" "$nearest_azimuth" "$cut_region" >> "$CURRENT_POINTS"
    printf '[POINT] %-16s lon/lat=%s/%s  full=%s/%s  SBAS=%s/%s  region=%s\n' \
        "$label" "$lon" "$lat" "$full_radar_range" "$full_radar_azimuth" \
        "$radar_range" "$radar_azimuth" "$cut_region"
done < "$NORMALIZED_POINTS"

# Keep all point results in one directory. A new label is appended, while an
# existing label replaces only its own record and files. No backup directory
# is created and the existing output directory is never copied or renamed.
MERGED_POINTS="$TMP/points_radar_merged.tsv"
printf '# label\tlongitude\tlatitude\televation_m\tfull_range\tfull_azimuth\tsbas_range\tsbas_azimuth\tnearest_range\tnearest_azimuth\tsampling_region\n' \
    > "$MERGED_POINTS"
if [[ -s "$POINTS_RADAR" ]]; then
    awk -F'\t' '
        NR==FNR {new_label[$1]=1; next}
        $1 !~ /^#/ && !($1 in new_label) {print}
    ' "$CURRENT_POINTS" "$POINTS_RADAR" >> "$MERGED_POINTS"
fi
cat "$CURRENT_POINTS" >> "$MERGED_POINTS"
mv -- "$MERGED_POINTS" "$POINTS_RADAR"

TOTAL_POINT_COUNT="$(awk -F'\t' '$1 !~ /^#/ {n++} END {print n+0}' "$POINTS_RADAR")"
awk -F'\t' '$1 !~ /^#/ {print $2"\t"$3"\t"$1}' "$POINTS_RADAR" > "$POINTS_MAP"
printf '[ACCUMULATE] Added or replaced %s point(s); total stored points=%s\n' \
    "$POINT_COUNT" "$TOTAL_POINT_COUNT"

ALL_SERIES="$OUTPUT_DIR/time_series_all.tsv"


POINT_INDEX=0
while IFS=$'\t' read -r label lon lat elevation full_radar_range full_radar_azimuth \
        radar_range radar_azimuth nearest_range nearest_azimuth cut_region; do
    [[ "$label" == \#* ]] && continue
    POINT_INDEX=$((POINT_INDEX + 1))
    series="$OUTPUT_DIR/time_series_${label}.dat"
    printf '# date_ydoy date_iso displacement_mm std_mm longitude latitude radar_range radar_azimuth\n' \
        > "$series"

    SCENE_INDEX=0
    while IFS= read -r scene; do
        SCENE_INDEX=$((SCENE_INDEX + 1))
        iso="$(ydoy_to_iso "$scene")" || die "invalid scene date: $scene"
        grid="$SBAS_DIR/disp_${scene}.grd"
        cut_grid="$TMP/${label}_${scene}.grd"
        gmt grdcut "$grid" -R"$cut_region" -G"$cut_grid" >/dev/null
        stats="$(gmt grdinfo "$cut_grid" -L2 -C | awk 'NR==1 {print $12,$13}')"
        read -r mean std <<< "$stats"
        [[ -n "$mean" && -n "$std" ]] ||
            die "cannot calculate mean/std for $label in disp_${scene}.grd"

        printf '%s %s %s %s %s %s %s %s\n' \
            "$scene" "$iso" "$mean" "$std" "$lon" "$lat" \
            "$radar_range" "$radar_azimuth" >> "$series"
    done < "$SCENES"
    printf '[EXTRACT] %-16s %s/%s scenes\n' "$label" "$SCENE_INDEX" "$SCENE_COUNT"
done < "$CURRENT_POINTS"

# Rebuild the combined table from every stored point, including points from
# preceding direct calls such as L2 followed by L1.
printf '# label\tlongitude\tlatitude\tdate_ydoy\tdate_iso\tdisplacement_mm\tstd_mm\n' \
    > "$ALL_SERIES"
while IFS=$'\t' read -r label lon lat elevation full_radar_range full_radar_azimuth \
        radar_range radar_azimuth nearest_range nearest_azimuth cut_region; do
    [[ "$label" == \#* ]] && continue
    series="$OUTPUT_DIR/time_series_${label}.dat"
    [[ -s "$series" ]] || die "stored point is missing its time series: $series"
    awk -v label="$label" -v lon="$lon" -v lat="$lat" '
        $1 !~ /^#/ && NF >= 4 {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",label,lon,lat,$1,$2,$3,$4
        }
    ' "$series" >> "$ALL_SERIES"
done < "$POINTS_RADAR"

COLOR_LIST=(red blue darkgreen orange purple brown cyan magenta navy gold3)
DATE_MIN="$(ydoy_to_iso "$(head -n 1 "$SCENES")")"
DATE_MAX="$(ydoy_to_iso "$(tail -n 1 "$SCENES")")"

plot_one_series() {
    local label="$1" lon="$2" lat="$3" series="$4" index="$5"
    local color="${COLOR_LIST[$(( (index - 1) % ${#COLOR_LIST[@]} ))]}"
    local valid="$TMP/${label}_valid.txt"
    local event_line="$TMP/${label}_event_line.txt"
    local event_text="$TMP/${label}_event_text.txt"
    local ymin ymax pad

    awk '$1 !~ /^#/ && $3 != "NaN" && $4 != "NaN" {print $2,$3,$4}' "$series" > "$valid"
    [[ -s "$valid" ]] || die "$label has no valid displacement samples"
    read -r ymin ymax <<< "$(awk '
        NR==1 {lo=$2-$3; hi=$2+$3}
        {if ($2-$3<lo) lo=$2-$3; if ($2+$3>hi) hi=$2+$3}
        END {print lo,hi}
    ' "$valid")"
    read -r ymin ymax <<< "$(awk -v lo="$ymin" -v hi="$ymax" '
        BEGIN {
            span=hi-lo
            if (span <= 0) span=(lo==0 ? 2 : 0.2*(lo<0?-lo:lo))
            pad=0.08*span
            printf "%.12g %.12g",lo-pad,hi+pad
        }')"

    printf '%s %s\n%s %s\n' "$LANDSLIDE_DATE" "$ymin" \
        "$LANDSLIDE_DATE" "$ymax" > "$event_line"
    printf '%s %s %s: %s\n' "$LANDSLIDE_DATE" "$ymax" \
        "$LANDSLIDE_LABEL" "$LANDSLIDE_DATE" > "$event_text"

    gmt begin "$OUTPUT_DIR/time_series_${label}" pdf,png
        gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 9p \
            FONT_LABEL 11p FONT_TITLE 12p FORMAT_DATE_MAP yyyy-mm
        gmt basemap -R"$DATE_MIN/$DATE_MAX/$ymin/$ymax" -JX15c/8c \
            -Bxa6Of3O+l"Date" -Byaf+l"LOS displacement (mm)" \
            -BWSen+t"$label  ($lon E, $lat N)"
        gmt plot "$event_line" -f0T -W1p,black,-
        gmt text "$event_text" -f0T -F+f8p,Helvetica,black+jTL -D0.10c/-0.12c
        gmt plot "$valid" -f0T -Ey+w7p+p0.7p,"$color"
        gmt plot "$valid" -f0T -W1.2p,"$color"
        gmt plot "$valid" -f0T -Sc0.10c -G"$color" -W0.25p,black
    gmt end
}

POINT_INDEX=0
while IFS=$'\t' read -r label lon lat elevation full_radar_range full_radar_azimuth \
        radar_range radar_azimuth nearest_range nearest_azimuth cut_region; do
    [[ "$label" == \#* ]] && continue
    POINT_INDEX=$((POINT_INDEX + 1))
    plot_one_series "$label" "$lon" "$lat" \
        "$OUTPUT_DIR/time_series_${label}.dat" "$POINT_INDEX"
done < "$POINTS_RADAR"

GLOBAL_RANGE="$(awk -F'\t' '
    substr($1,1,1)!="#" && $6!="NaN" && $7!="NaN" {
        lo=$6-$7; hi=$6+$7
        if (!n++ || lo<min) min=lo
        if (n==1 || hi>max) max=hi
    }
    END {if (n) print min,max}
' "$ALL_SERIES")"
[[ -n "$GLOBAL_RANGE" ]] || die "no valid values available for the overview plot"
read -r GLOBAL_YMIN GLOBAL_YMAX <<< "$GLOBAL_RANGE"
read -r GLOBAL_YMIN GLOBAL_YMAX <<< "$(awk -v lo="$GLOBAL_YMIN" -v hi="$GLOBAL_YMAX" '
    BEGIN {
        span=hi-lo; if (span<=0) span=2; pad=0.08*span
        printf "%.12g %.12g",lo-pad,hi+pad
    }')"

EVENT_LINE_ALL="$TMP/landslide_event_line_all.txt"
printf '%s %s\n%s %s\n' "$LANDSLIDE_DATE" "$GLOBAL_YMIN" \
    "$LANDSLIDE_DATE" "$GLOBAL_YMAX" > "$EVENT_LINE_ALL"

gmt begin "$OUTPUT_DIR/time_series_all" pdf,png
    gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 9p \
        FONT_LABEL 11p FONT_TITLE 13p FORMAT_DATE_MAP yyyy-mm
    gmt basemap -R"$DATE_MIN/$DATE_MAX/$GLOBAL_YMIN/$GLOBAL_YMAX" -JX16c/9c \
        -Bxa6Of3O+l"Date" -Byaf+l"LOS displacement (mm)" \
        -BWSen+t"Burst SBAS displacement time series"
    gmt plot "$EVENT_LINE_ALL" -f0T -W1p,black,- -l"$LANDSLIDE_LABEL: $LANDSLIDE_DATE"
    POINT_INDEX=0
    while IFS=$'\t' read -r label lon lat elevation full_radar_range full_radar_azimuth \
            radar_range radar_azimuth nearest_range nearest_azimuth cut_region; do
        [[ "$label" == \#* ]] && continue
        POINT_INDEX=$((POINT_INDEX + 1))
        color="${COLOR_LIST[$(( (POINT_INDEX - 1) % ${#COLOR_LIST[@]} ))]}"
        series="$OUTPUT_DIR/time_series_${label}.dat"
        awk '$1 !~ /^#/ && $3 != "NaN" && $4 != "NaN" {print $2,$3,$4}' "$series" > "$TMP/${label}_overview.txt"
        gmt plot "$TMP/${label}_overview.txt" -f0T -Ey+w5p+p0.45p,"$color"
        gmt plot "$TMP/${label}_overview.txt" -f0T -W1.2p,"$color" -l"$label"
        gmt plot "$TMP/${label}_overview.txt" -f0T -Sc0.08c -G"$color" -W0.2p,black
    done < "$POINTS_RADAR"
    gmt legend -DjTR+w5.5c+o0.2c -F+p0.5p+gwhite@20
gmt end

MAP_CPT="$VEL_CPT"
if [[ ! -s "$MAP_CPT" ]]; then
    MAP_CPT="$OUTPUT_DIR/vel_ll_points.cpt"
    gmt grd2cpt "$VEL_LL" -Cjet -Z > "$MAP_CPT"
fi

gmt begin "$OUTPUT_DIR/vel_ll_points" pdf,png
    gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 10p \
        FONT_LABEL 11p FONT_TITLE 13p COLOR_NAN gray
    gmt grdimage "$VEL_LL" -JM15c -C"$MAP_CPT" \
        -Baf -BWSen+t"Burst SBAS velocity and Run 4.5 points"
    gmt plot "$POINTS_MAP" -i0,1 -Sc0.28c -Gwhite -W1.2p,black
    gmt text "$POINTS_MAP" -i0,1,t2 -F+f9p,Helvetica-Bold,black+jBL \
        -D0.13c/0.13c
    gmt colorbar -DJBC+w10c/0.3c+h+o0c/1.0c -C"$MAP_CPT" \
        -Baf+l"Velocity (mm/yr)"
gmt end

for output in \
    "$OUTPUT_DIR/time_series_all.pdf" \
    "$OUTPUT_DIR/time_series_all.png" \
    "$OUTPUT_DIR/vel_ll_points.pdf" \
    "$OUTPUT_DIR/vel_ll_points.png"; do
    [[ -s "$output" ]] || die "expected plot was not generated: $output"
done

{
    printf 'status=COMPLETE\n'
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'branch=%s\n' "$BRANCH"
    printf 'points_file=%s\n' "$POINTS_FILE"
    printf 'point_count=%s\n' "$TOTAL_POINT_COUNT"
    printf 'scene_count=%s\n' "$SCENE_COUNT"
    printf 'sampling_window=%s/%s\n' "$WINDOW_X" "$WINDOW_Y"
    printf 'landslide_date=%s\n' "$LANDSLIDE_DATE"
    printf 'landslide_label=%s\n' "$LANDSLIDE_LABEL"
    printf 'region_cut=%s\n' "$REGION_CUT"
    printf 'radar_origin_shift=%s/%s\n' "$RADAR_OFFSET_RANGE" "$RADAR_OFFSET_AZIMUTH"
    printf 'points_radar=%s\n' "$POINTS_RADAR"
    printf 'time_series_all=%s\n' "$ALL_SERIES"
    printf 'overview_pdf=%s/time_series_all.pdf\n' "$OUTPUT_DIR"
    printf 'velocity_points_pdf=%s/vel_ll_points.pdf\n' "$OUTPUT_DIR"
} > "$OUTPUT_DIR/run4.5_complete"

printf '%s\n' '========================================'
printf '%s\n' '[DONE] Run 4.5 multi-point time-series extraction completed.'
printf 'Point coordinates : %s\n' "$POINTS_RADAR"
printf 'All observations  : %s\n' "$ALL_SERIES"
printf 'Time-series plots : %s/time_series_<label>.pdf/.png\n' "$OUTPUT_DIR"
printf 'Overview plot     : %s/time_series_all.pdf/.png\n' "$OUTPUT_DIR"
printf 'Marked velocity   : %s/vel_ll_points.pdf/.png\n' "$OUTPUT_DIR"
printf 'Original products : unchanged\n'
printf '%s\n' '========================================'
