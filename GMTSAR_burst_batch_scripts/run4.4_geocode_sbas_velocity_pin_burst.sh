#!/usr/bin/env bash
# Run 4.4: geocode the burst SBAS velocity grid and create PDF/KML products.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

FILTER_METERS="${SBAS_FILTER_METERS:-400}"
CPT_MIN="${VEL_CPT_MIN:-}"
CPT_MAX="${VEL_CPT_MAX:-}"
CPT_STEP="${VEL_CPT_STEP:-}"
TRANS_MIN_BYTES="${BURST_TRANS_MIN_BYTES:-1048576}"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 4.4: geocode burst SBAS velocity and create PDF/KML

Usage:
  ./run4.4_geocode_sbas_velocity_pin_burst.sh
  ./run4.4_geocode_sbas_velocity_pin_burst.sh 1

No arguments:
  Check the SBAS velocity, burst projection table and spatial filter.
  No output is created or modified.

Mode 1:
  Project sbas_burst_pin/vel.grd to geographic coordinates and create PDF/KML.

Default settings:
  Spatial filter: 400 m
  Color range  : automatically read from the generated vel_ll.grd

Optional environment variables:
  SBAS_FILTER_METERS=400
  VEL_CPT_MIN=-200 VEL_CPT_MAX=200 VEL_CPT_STEP=10
  If VEL_CPT_MIN and VEL_CPT_MAX are omitted, the actual grid range is used.
  BURST_TRANS_MIN_BYTES=1048576

Inputs:
  sbas_burst_pin/vel.grd
  burst/topo/trans.dat
  burst/intf_all/<pair>/gauss_400

Outputs in sbas_burst_pin/:
  vel_ll.grd
  vel_ll.cpt
  vel_ll.pdf
  vel_ll KML/KMZ image products
  run4.4_complete
========================================
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
(( $# <= 1 )) || die "use no arguments for checking, or use mode 1"
if (( $# == 1 )); then
    [[ "$1" == 1 ]] || die "MODE must be 1"
fi

[[ "$FILTER_METERS" =~ ^[1-9][0-9]*$ ]] ||
    die "SBAS_FILTER_METERS must be a positive integer"
[[ "$TRANS_MIN_BYTES" =~ ^[1-9][0-9]*$ ]] ||
    die "BURST_TRANS_MIN_BYTES must be a positive integer"
if [[ -n "$CPT_MIN" || -n "$CPT_MAX" ]]; then
    [[ -n "$CPT_MIN" && -n "$CPT_MAX" ]] ||
        die "VEL_CPT_MIN and VEL_CPT_MAX must be set together"
    for value_name in CPT_MIN CPT_MAX; do
        value="${!value_name}"
        awk -v x="$value" 'BEGIN {exit !(x ~ /^[-+]?[0-9]*[.]?[0-9]+$/)}' ||
            die "$value_name must be numeric: $value"
    done
    awk -v low="$CPT_MIN" -v high="$CPT_MAX" 'BEGIN {exit !(low < high)}' ||
        die "color range must satisfy MIN < MAX"
    CPT_MODE='fixed by environment'
else
    CPT_MODE='automatic from vel_ll.grd'
fi
if [[ -n "$CPT_STEP" ]]; then
    awk -v x="$CPT_STEP" \
        'BEGIN {exit !(x ~ /^[+]?[0-9]*[.]?[0-9]+$/ && x > 0)}' ||
        die "VEL_CPT_STEP must be positive: $CPT_STEP"
fi

for command_name in awk basename cp date find gmt grd2kml.csh head ln mkdir mv \
                    proj_ra2ll.csh sort tr wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT)"

BURST_DIR="$ROOT/burst"
PAIR_ROOT="$BURST_DIR/intf_all"
TOPO_DIR="$BURST_DIR/topo"
SBAS_DIR="$ROOT/sbas_burst_pin"
INTFLIST="$SBAS_DIR/intflist_new"
RUN42_COMPLETE="$SBAS_DIR/run4.2_complete"
RUN43_PID="$SBAS_DIR/run4.3_sbas_parallel.pid"
VELOCITY="$SBAS_DIR/vel.grd"
TRANS_SOURCE="$TOPO_DIR/trans.dat"
GAUSS_NAME="gauss_${FILTER_METERS}"

for file in "$INTFLIST" "$RUN42_COMPLETE" "$VELOCITY" "$TRANS_SOURCE"; do
    [[ -s "$file" ]] || die "missing or empty: $file"
done
RUN42_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$RUN42_COMPLETE")"
[[ "$RUN42_STATUS" == COMPLETE ]] || die "Run 4.2 status is not COMPLETE"

if [[ -s "$RUN43_PID" ]]; then
    RUN43_PROCESS="$(tr -d '[:space:]' < "$RUN43_PID")"
    if [[ "$RUN43_PROCESS" =~ ^[1-9][0-9]*$ ]] && kill -0 "$RUN43_PROCESS" 2>/dev/null; then
        die "Run 4.3 is still running (PID $RUN43_PROCESS); wait for SBAS to finish"
    fi
fi

TRANS_BYTES="$(wc -c < "$TRANS_SOURCE" | tr -d ' ')"
(( TRANS_BYTES >= TRANS_MIN_BYTES )) ||
    die "$TRANS_SOURCE is smaller than $TRANS_MIN_BYTES bytes ($TRANS_BYTES bytes)"

GAUSS_SOURCE=''
while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    candidate="$PAIR_ROOT/$pair/$GAUSS_NAME"
    if [[ -s "$candidate" ]]; then
        GAUSS_SOURCE="$candidate"
        break
    fi
done < "$INTFLIST"
[[ -n "$GAUSS_SOURCE" ]] ||
    die "cannot find a non-empty $GAUSS_NAME in finalized burst pair directories"

read -r _ _ _ _ _ RADAR_Z_MIN RADAR_Z_MAX _ <<< "$(gmt grdinfo "$VELOCITY" -C)"
[[ -n "$RADAR_Z_MIN" && -n "$RADAR_Z_MAX" ]] ||
    die "failed to read the value range from $VELOCITY"
if [[ "$CPT_MODE" == automatic* ]]; then
    COLOR_DESCRIPTION="automatic from vel_ll.grd (radar preview: ${RADAR_Z_MIN}/${RADAR_Z_MAX})"
else
    COLOR_DESCRIPTION="${CPT_MIN}/${CPT_MAX}/${CPT_STEP:-auto} mm/yr"
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 4.4 burst velocity geocoding input check'
printf 'Track root          : %s\n' "$ROOT"
printf 'SBAS directory      : %s\n' "$SBAS_DIR"
printf 'Radar velocity      : %s\n' "$VELOCITY"
printf 'Projection table    : %s (%s bytes)\n' "$TRANS_SOURCE" "$TRANS_BYTES"
printf 'Spatial filter      : %s m\n' "$FILTER_METERS"
printf 'Filter source       : %s\n' "$GAUSS_SOURCE"
printf 'Color range         : %s\n' "$COLOR_DESCRIPTION"
printf 'Geographic velocity : %s/vel_ll.grd\n' "$SBAS_DIR"
printf '%s\n' '========================================'

if (( $# == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] No links, grids, CPT, PDF or KML files were created.'
    printf '%s\n' '[NEXT] ./run4.4_geocode_sbas_velocity_pin_burst.sh 1'
    exit 0
fi

cd "$SBAS_DIR"
STAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_DIR="run4.4_backup_$STAMP"
backup_count=0
for name in trans.dat "$GAUSS_NAME" vel_ll.grd vel_ll.cpt vel_ll.pdf \
            vel_ll.kml vel_ll.kmz vel_ll.png vel_ll.legend.png vel_ll \
            run4.4_complete; do
    if [[ -e "$name" || -L "$name" ]]; then
        mkdir -p "$BACKUP_DIR"
        mv -- "$name" "$BACKUP_DIR/"
        backup_count=$((backup_count + 1))
    fi
done
(( backup_count == 0 )) ||
    printf '[BACKUP] Previous Run 4.4 products: %s/%s\n' "$(pwd -P)" "$BACKUP_DIR"

ln -s "$TRANS_SOURCE" trans.dat
ln -s "$GAUSS_SOURCE" "$GAUSS_NAME"

printf '[STEP 1] Project vel.grd with the %s m spatial filter\n' "$FILTER_METERS"
proj_ra2ll.csh trans.dat vel.grd vel_ll.grd "$FILTER_METERS"
[[ -s vel_ll.grd ]] || die "vel_ll.grd was not generated"

if [[ "$CPT_MODE" == automatic* ]]; then
    read -r _ _ _ _ _ CPT_MIN CPT_MAX _ <<< "$(gmt grdinfo vel_ll.grd -C)"
    [[ -n "$CPT_MIN" && -n "$CPT_MAX" ]] ||
        die "failed to read the actual range from vel_ll.grd"
fi
awk -v low="$CPT_MIN" -v high="$CPT_MAX" 'BEGIN {exit !(low < high)}' ||
    die "invalid vel_ll.grd value range: $CPT_MIN/$CPT_MAX"
if [[ -z "$CPT_STEP" ]]; then
    CPT_STEP="$(awk -v low="$CPT_MIN" -v high="$CPT_MAX" \
        'BEGIN {printf "%.12g", (high-low)/20.0}')"
fi

printf '%s\n' '[STEP 2] Create the velocity color palette'
printf 'Actual CPT range: %s/%s/%s mm/yr\n' "$CPT_MIN" "$CPT_MAX" "$CPT_STEP"
gmt makecpt -Cjet -T"${CPT_MIN}/${CPT_MAX}/${CPT_STEP}" -Z -D > vel_ll.cpt
[[ -s vel_ll.cpt ]] || die "vel_ll.cpt was not generated"

printf '%s\n' '[STEP 3] Plot the geographic velocity PDF'
gmt begin vel_ll pdf
    gmt set \
        MAP_FRAME_TYPE plain \
        FONT_ANNOT_PRIMARY 10p \
        FONT_LABEL 11p \
        FONT_TITLE 13p \
        COLOR_NAN gray
    gmt grdimage vel_ll.grd \
        -JM15c \
        -Cvel_ll.cpt \
        -Baf \
        -BWSen+t"Burst SBAS velocity"
    gmt colorbar \
        -DJBC+w10c/0.3c+h+o0c/1.0c \
        -Cvel_ll.cpt \
        -Baf+l"Velocity (mm/yr)"
gmt end
[[ -s vel_ll.pdf ]] || die "vel_ll.pdf was not generated"

printf '%s\n' '[STEP 4] Generate KML/KMZ products'
grd2kml.csh vel_ll vel_ll.cpt
KML_COUNT="$(find . -maxdepth 2 \( -type f -o -type l \) \
    \( -name 'vel_ll*.kml' -o -name 'vel_ll*.kmz' \) | wc -l | tr -d ' ')"
(( KML_COUNT > 0 )) ||
    die "grd2kml.csh completed but no vel_ll KML/KMZ was found"

{
    printf 'status=COMPLETE\n'
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'velocity_source=%s\n' "$VELOCITY"
    printf 'trans_source=%s\n' "$TRANS_SOURCE"
    printf 'filter_meters=%s\n' "$FILTER_METERS"
    printf 'gauss_source=%s\n' "$GAUSS_SOURCE"
    printf 'cpt_mode=%s\n' "$CPT_MODE"
    printf 'cpt_range=%s/%s/%s\n' "$CPT_MIN" "$CPT_MAX" "$CPT_STEP"
    printf 'velocity_ll=%s/vel_ll.grd\n' "$(pwd -P)"
    printf 'pdf=%s/vel_ll.pdf\n' "$(pwd -P)"
    printf 'kml_files=%s\n' "$KML_COUNT"
} > run4.4_complete

printf '%s\n' '========================================'
printf '%s\n' '[DONE] Run 4.4 burst velocity geocoding completed.'
printf 'Velocity grid : %s/vel_ll.grd\n' "$(pwd -P)"
printf 'Color palette : %s/vel_ll.cpt\n' "$(pwd -P)"
printf 'PDF map       : %s/vel_ll.pdf\n' "$(pwd -P)"
printf 'KML/KMZ files : %s\n' "$KML_COUNT"
find . -maxdepth 2 \( -type f -o -type l \) \
    \( -name 'vel_ll*.kml' -o -name 'vel_ll*.kmz' \) -print | sort
printf '%s\n' '========================================'
