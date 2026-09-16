#!/usr/bin/env bash
# Run 4.4: geocode a standard GMTSAR SBAS velocity grid and create map/KMZ products.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

SBAS_DIR="sbas_demcorr_pin"
DEFAULT_FILTER_REQUEST="auto"
PREFERRED_FILTER_METERS="${VEL_FILTER_PREFERRED:-100}"
DEFAULT_CPT_ABS_MAX="${VEL_CPT_ABS_MAX:-auto}"
CPT_STEP="${VEL_CPT_STEP:-1}"
CPT_TICK_REQUEST="${VEL_CPT_TICK:-auto}"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 4.4: geocode the SBAS velocity grid and generate PDF/PNG/KML/KMZ

Usage:
  ./run4.4_geocode_sbas_velocity.sh
  ./run4.4_geocode_sbas_velocity.sh 1 [FILTER_METERS|auto] [CPT_ABS_MAX|auto]

No arguments:
  Check inputs and show the filter that automatic mode would select.
  No files are created, removed or modified.

Defaults:
  geographic filter = auto
  preferred filter  = 100 m
  velocity CPT      = automatic symmetric limits

Automatic filter selection:
  Scan F1/intf_all/<first_pair>/gauss_* and select the available numeric
  filter nearest to 100 m. The number after gauss_ is passed to
  proj_ra2ll.csh. If only one valid gauss_* exists, use it.

Examples:
  ./run4.4_geocode_sbas_velocity.sh 1
  ./run4.4_geocode_sbas_velocity.sh 1 auto
  ./run4.4_geocode_sbas_velocity.sh 1 400
  ./run4.4_geocode_sbas_velocity.sh 1 400 10

CPT_ABS_MAX:
  auto  Use rounded symmetric -M/+M limits from vel_ll.grd.
  N     Manually use -N/+N; for example 10 gives -10/+10 mm/yr.

Optional environment variables:
  VEL_FILTER_PREFERRED=100
  VEL_CPT_ABS_MAX=auto
  VEL_CPT_STEP=1
  VEL_CPT_TICK=auto

Inputs:
  sbas_demcorr_pin/vel.grd
  merge/trans.dat
  F1/intf_all/<first_pair>/gauss_<selected_filter>

Outputs in sbas_demcorr_pin/:
  vel_ll.grd
  vel_ll.cpt
  vel_ll.pdf                 normal GMT map
  vel_ll_map.png             normal GMT map PNG
  vel_ll.kml
  vel_ll.png                 transparent Google Earth overlay
  vel_ll.kmz                 doc.kml + vel_ll.png
  run4.4_complete
USAGE
}

is_positive_number() {
    awk -v x="$1" 'BEGIN {
        exit !(x ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && x > 0)
    }'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
(( $# <= 3 )) || die "expected no arguments, or: 1 [FILTER_METERS|auto] [CPT_ABS_MAX|auto]"
[[ $# -eq 0 || "$1" == "1" ]] || die "MODE must be 1"

FORMAL=0
(( $# == 0 )) || FORMAL=1
FILTER_REQUEST="${2:-$DEFAULT_FILTER_REQUEST}"
CPT_ABS_REQUEST="${3:-$DEFAULT_CPT_ABS_MAX}"

[[ "$FILTER_REQUEST" == "auto" ]] ||
    is_positive_number "$FILTER_REQUEST" ||
    die "FILTER_METERS must be auto or a positive number"
is_positive_number "$PREFERRED_FILTER_METERS" ||
    die "VEL_FILTER_PREFERRED must be a positive number"
is_positive_number "$CPT_STEP" || die "VEL_CPT_STEP must be positive"
if [[ "$CPT_ABS_REQUEST" != "auto" ]]; then
    is_positive_number "$CPT_ABS_REQUEST" ||
        die "CPT_ABS_MAX must be auto or a positive number"
fi
if [[ "$CPT_TICK_REQUEST" != "auto" ]]; then
    is_positive_number "$CPT_TICK_REQUEST" ||
        die "VEL_CPT_TICK must be auto or a positive number"
fi

for command_name in awk cp find gmt grd2kml.csh mktemp proj_ra2ll.csh sort wc zip; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number track directory (current: $ROOT)"
[[ -d "$SBAS_DIR" ]] || die "cannot find $SBAS_DIR/"
[[ -s "$SBAS_DIR/vel.grd" ]] ||
    die "missing or empty: $SBAS_DIR/vel.grd; confirm Run 4.3 completed"
[[ -s merge/trans.dat ]] || die "missing or empty: merge/trans.dat"

TRANS_BYTES="$(wc -c < merge/trans.dat | awk '{print $1}')"
(( TRANS_BYTES >= 20 * 1024 * 1024 )) ||
    die "merge/trans.dat is smaller than 20 MiB ($TRANS_BYTES bytes); it may be a preview placeholder"

FIRST_INTF_DIR="$(find F1/intf_all -mindepth 1 -maxdepth 1 -type d \
    -name '20*_20*' -print 2>/dev/null | sort | awk 'NR==1{print; exit}')"
[[ -n "$FIRST_INTF_DIR" ]] ||
    die "cannot find F1/intf_all/20*_20* interferogram directories"

FILTER_TABLE="$(mktemp "${TMPDIR:-/tmp}/run4.4-filters.XXXXXX")"
cleanup_filter_table() { rm -f -- "$FILTER_TABLE"; }
trap cleanup_filter_table EXIT INT TERM

find "$FIRST_INTF_DIR" -mindepth 1 -maxdepth 1 \
    \( -type f -o -type l \) -name 'gauss_*' -print |
awk '
    {
        path=$0
        name=path
        sub(/^.*\//,"",name)
        value=name
        sub(/^gauss_/,"",value)
        if (value ~ /^[0-9]+([.][0-9]+)?$/ && value+0 > 0)
            print value+0, path
    }
' | sort -n -k1,1 > "$FILTER_TABLE"
[[ -s "$FILTER_TABLE" ]] ||
    die "no numeric gauss_<meters> filter found in $FIRST_INTF_DIR"

AVAILABLE_FILTERS="$(awk '{printf "%s%s", (NR==1 ? "" : ","), $1}' "$FILTER_TABLE")"
if [[ "$FILTER_REQUEST" == "auto" ]]; then
    read -r FILTER_METERS GAUSS_SOURCE < <(
        awk -v preferred="$PREFERRED_FILTER_METERS" '
            NR==1 {
                best=$1; path=$2; distance=$1-preferred
                if (distance<0) distance=-distance
            }
            {
                current=$1-preferred
                if (current<0) current=-current
                if (current<distance || (current==distance && $1<best)) {
                    best=$1; path=$2; distance=current
                }
            }
            END {print best, path}
        ' "$FILTER_TABLE"
    )
    FILTER_MODE="auto_nearest_${PREFERRED_FILTER_METERS}m"
else
    FILTER_METERS="$FILTER_REQUEST"
    GAUSS_SOURCE="$(awk -v wanted="$FILTER_METERS" '$1==wanted {print $2; exit}' "$FILTER_TABLE")"
    [[ -n "$GAUSS_SOURCE" ]] ||
        die "requested gauss_${FILTER_METERS} is unavailable; available filters: $AVAILABLE_FILTERS"
    FILTER_MODE="manual"
fi
[[ -s "$GAUSS_SOURCE" ]] || die "selected filter is missing or empty: $GAUSS_SOURCE"
GAUSS_NAME="gauss_${FILTER_METERS}"
GAUSS_SOURCE="$ROOT/$GAUSS_SOURCE"

printf '%s\n' '========================================================================'
printf '%s\n' 'Run 4.4 geocode SBAS velocity'
printf 'Mode:                 %s\n' "$([[ "$FORMAL" -eq 1 ]] && printf FORMAL || printf CHECK)"
printf 'Track root:           %s\n' "$ROOT"
printf 'SBAS directory:       %s\n' "$SBAS_DIR"
printf 'Radar velocity:       %s/vel.grd\n' "$SBAS_DIR"
printf 'Projection table:     merge/trans.dat (%.1f MiB)\n' "$(awk -v b="$TRANS_BYTES" 'BEGIN{print b/1048576}')"
printf 'Available filters:    %s m\n' "$AVAILABLE_FILTERS"
printf 'Filter request:       %s\n' "$FILTER_REQUEST"
printf 'Selected filter:      %s m (%s)\n' "$FILTER_METERS" "$FILTER_MODE"
printf 'Filter source:        %s\n' "$GAUSS_SOURCE"
if [[ "$CPT_ABS_REQUEST" == "auto" ]]; then
    printf 'Velocity color range: automatic symmetric limits\n'
else
    printf 'Velocity color range: -%s/+%s mm/yr\n' "$CPT_ABS_REQUEST" "$CPT_ABS_REQUEST"
fi
printf '%s\n' '========================================================================'

if (( FORMAL == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] No geographic velocity product was created.'
    exit 0
fi

cd "$SBAS_DIR"
rm -f -- trans.dat vel_ll.grd vel_ll.cpt vel_ll.pdf vel_ll.png \
    vel_ll_map.png vel_ll.kml vel_ll.kmz vel_ll.legend.png run4.4_complete
rm -rf -- vel_ll
for old_gauss in gauss_*; do
    [[ -L "$old_gauss" ]] && rm -f -- "$old_gauss"
done
ln -s ../merge/trans.dat trans.dat
ln -s "$GAUSS_SOURCE" "$GAUSS_NAME"

printf '[STEP 1] proj_ra2ll.csh trans.dat vel.grd vel_ll.grd %s\n' "$FILTER_METERS"
proj_ra2ll.csh trans.dat vel.grd vel_ll.grd "$FILTER_METERS"
[[ -s vel_ll.grd ]] || die "proj_ra2ll.csh did not generate vel_ll.grd"

read -r VEL_LL_MIN VEL_LL_MAX < <(gmt grdinfo vel_ll.grd -C | awk '{print $6, $7; exit}')
DATA_ABS_MAX="$(awk -v lo="$VEL_LL_MIN" -v hi="$VEL_LL_MAX" 'BEGIN {
    if (lo<0) lo=-lo
    if (hi<0) hi=-hi
    printf "%.15g", (lo>hi ? lo : hi)
}')"
if [[ "$CPT_ABS_REQUEST" == "auto" ]]; then
    CPT_ABS_MAX="$(awk -v x="$DATA_ABS_MAX" -v step="$CPT_STEP" 'BEGIN {
        rounded=int(x+0.5)
        if (rounded<step) rounded=step
        printf "%.15g", rounded
    }')"
    CPT_MODE="auto_rounded"
else
    CPT_ABS_MAX="$CPT_ABS_REQUEST"
    CPT_MODE="manual"
fi
CPT_MIN="$(awk -v x="$CPT_ABS_MAX" 'BEGIN{printf "%.15g",-x}')"
CPT_MAX="$CPT_ABS_MAX"

if [[ "$CPT_TICK_REQUEST" == "auto" ]]; then
    CPT_TICK="$(awk -v maximum="$CPT_ABS_MAX" 'BEGIN {
        raw=(2*maximum)/4
        power=int(log(raw)/log(10))
        if (raw<1) power--
        base=10^power
        normalized=raw/base
        if (normalized<1.5) nice=1
        else if (normalized<3.5) nice=2
        else if (normalized<7.5) nice=5
        else nice=10
        printf "%.15g", nice*base
    }')"
else
    CPT_TICK="$CPT_TICK_REQUEST"
fi

printf '[STEP 2] Create jet CPT: data=%s/%s, CPT=%s/%s/%s (%s), tick=%s\n' \
    "$VEL_LL_MIN" "$VEL_LL_MAX" "$CPT_MIN" "$CPT_MAX" "$CPT_STEP" "$CPT_MODE" "$CPT_TICK"
gmt makecpt -Cjet -T"${CPT_MIN}/${CPT_MAX}/${CPT_STEP}" -Z -D > vel_ll.cpt
[[ -s vel_ll.cpt ]] || die "vel_ll.cpt was not generated"

printf '%s\n' '[STEP 3] Plot geographic velocity PDF and PNG'
gmt begin vel_ll pdf,png
    gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 10p FONT_LABEL 11p FONT_TITLE 13p COLOR_NAN gray
    gmt grdimage vel_ll.grd -JM15c -Cvel_ll.cpt -Baf -BWSen+t"SBAS velocity"
    gmt colorbar -Cvel_ll.cpt -DJBC+w10c/0.3c+h+o0c/1.0c \
        -Bxa"${CPT_TICK}"+l"LOS velocity (mm/yr)"
gmt end
[[ -s vel_ll.pdf && -s vel_ll.png ]] ||
    die "GMT did not generate vel_ll.pdf and vel_ll.png"
cp -f -- vel_ll.png vel_ll_map.png

printf '%s\n' '[STEP 4] Generate Google Earth KML and overlay PNG'
grd2kml.csh vel_ll vel_ll.cpt
[[ -s vel_ll.kml ]] || die "grd2kml.csh did not generate vel_ll.kml"
[[ -s vel_ll.png ]] || die "grd2kml.csh did not generate the overlay vel_ll.png"

printf '%s\n' '[STEP 5] Package doc.kml and vel_ll.png as vel_ll.kmz'
KMZ_TMP="$(mktemp -d .run4.4_kmz.XXXXXX)"
cleanup_all() {
    rm -rf -- "$KMZ_TMP"
    cleanup_filter_table
}
trap cleanup_all EXIT INT TERM
cp -f -- vel_ll.kml "$KMZ_TMP/doc.kml"
cp -f -- vel_ll.png "$KMZ_TMP/vel_ll.png"
(
    cd "$KMZ_TMP"
    zip -q ../vel_ll.kmz doc.kml vel_ll.png
)
[[ -s vel_ll.kmz ]] || die "failed to create vel_ll.kmz"
zip -T vel_ll.kmz >/dev/null || die "vel_ll.kmz failed ZIP integrity validation"
rm -rf -- "$KMZ_TMP"
trap cleanup_filter_table EXIT INT TERM

{
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'available_filters=%s\n' "$AVAILABLE_FILTERS"
    printf 'filter_request=%s\n' "$FILTER_REQUEST"
    printf 'filter_mode=%s\n' "$FILTER_MODE"
    printf 'filter_meters=%s\n' "$FILTER_METERS"
    printf 'gauss_source=%s\n' "$GAUSS_SOURCE"
    printf 'velocity_data_range=%s/%s\n' "$VEL_LL_MIN" "$VEL_LL_MAX"
    printf 'velocity_data_abs_max=%s\n' "$DATA_ABS_MAX"
    printf 'cpt_mode=%s\n' "$CPT_MODE"
    printf 'cpt_range=%s/%s/%s\n' "$CPT_MIN" "$CPT_MAX" "$CPT_STEP"
    printf 'cpt_tick=%s\n' "$CPT_TICK"
    printf 'velocity_grid=%s/%s/vel_ll.grd\n' "$ROOT" "$SBAS_DIR"
    printf 'map_png=%s/%s/vel_ll_map.png\n' "$ROOT" "$SBAS_DIR"
    printf 'overlay_png=%s/%s/vel_ll.png\n' "$ROOT" "$SBAS_DIR"
    printf 'kml=%s/%s/vel_ll.kml\n' "$ROOT" "$SBAS_DIR"
    printf 'kmz=%s/%s/vel_ll.kmz\n' "$ROOT" "$SBAS_DIR"
} > run4.4_complete

printf '%s\n' '========================================================================'
printf '[SUCCESS] Geographic velocity: %s/%s/vel_ll.grd\n' "$ROOT" "$SBAS_DIR"
printf '[SUCCESS] GMT map: %s/%s/vel_ll.pdf and vel_ll_map.png\n' "$ROOT" "$SBAS_DIR"
printf '[SUCCESS] Google Earth overlay: %s/%s/vel_ll.kml and vel_ll.png\n' "$ROOT" "$SBAS_DIR"
printf '[SUCCESS] Google Earth KMZ: %s/%s/vel_ll.kmz\n' "$ROOT" "$SBAS_DIR"
printf '[KMZ] Contains doc.kml and vel_ll.png\n'
printf '%s\n' '========================================================================'
