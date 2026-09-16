#!/usr/bin/env bash
# Run 5.4: project the deseasoned SBAS velocity from radar to geographic coordinates.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 22, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

SBAS_DIR="sbas_demcorr_pin"
DESEASON_DIR="${SBAS_DIR}/disp_deseason"
FILTER_METERS=400
GAUSS_NAME="gauss_${FILTER_METERS}"
CPT_MIN="${VEL_DESEASON_CPT_MIN:--10}"
CPT_MAX="${VEL_DESEASON_CPT_MAX:-10}"
CPT_STEP="${VEL_DESEASON_CPT_STEP:-1}"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 5.4: project the deseasoned velocity to geographic coordinates

Check only (no files are created or modified):
  ./run5.4_proj_vel_deseason_to_ll.sh

Formal run with the fixed 400 m spatial filter:
  ./run5.4_proj_vel_deseason_to_ll.sh 1

Input:
  sbas_demcorr_pin/disp_deseason/vel_deseason.grd
  merge/trans.dat
  F1/intf_all/<first_pair>/gauss_400

Output:
  sbas_demcorr_pin/disp_deseason/vel_deseason_ll.grd
  sbas_demcorr_pin/disp_deseason/vel_deseason_ll.cpt
  sbas_demcorr_pin/disp_deseason/vel_deseason_ll.pdf
  sbas_demcorr_pin/disp_deseason/run5.4_complete

Optional PDF color-range environment variables:
  VEL_DESEASON_CPT_MIN=-10
  VEL_DESEASON_CPT_MAX=10
  VEL_DESEASON_CPT_STEP=1
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
(( $# <= 1 )) || die "expected no arguments, or mode 1"
[[ $# -eq 0 || "$1" == "1" ]] || die "MODE must be 1"

for value_name in CPT_MIN CPT_MAX CPT_STEP; do
    value="${!value_name}"
    awk -v x="$value" 'BEGIN { exit !(x ~ /^[-+]?[0-9]*\.?[0-9]+$/) }' ||
        die "$value_name must be numeric (current: $value)"
done
awk -v lo="$CPT_MIN" -v hi="$CPT_MAX" -v step="$CPT_STEP" \
    'BEGIN { exit !(lo < hi && step > 0) }' ||
    die "color range must satisfy MIN < MAX and STEP > 0"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number track root (current: $ROOT)"

[[ -d "$DESEASON_DIR" ]] || die "cannot find: $DESEASON_DIR/"
[[ -s "$DESEASON_DIR/vel_deseason.grd" ]] ||
    die "missing or empty: $DESEASON_DIR/vel_deseason.grd; finish Run 5.3 first"
[[ -s "$DESEASON_DIR/run5.3_complete" ]] ||
    die "missing or empty Run 5.3 completion marker: $DESEASON_DIR/run5.3_complete"
[[ -s "merge/trans.dat" ]] || die "missing or empty: merge/trans.dat"

TRANS_BYTES="$(wc -c < merge/trans.dat | tr -d ' ')"
(( TRANS_BYTES >= 20 * 1024 * 1024 )) ||
    die "merge/trans.dat is smaller than 20 MiB ($TRANS_BYTES bytes); it may be a preview placeholder"

for command_name in proj_ra2ll.csh gmt; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "$command_name not found in PATH"
done

FIRST_INTF_DIR="$(find F1/intf_all -mindepth 1 -maxdepth 1 -type d \
    -name '20*_20*' -print 2>/dev/null | sort | sed -n '1p')"
[[ -n "$FIRST_INTF_DIR" ]] ||
    die "cannot find F1/intf_all/20*_20* interferogram directories"
GAUSS_SOURCE="$ROOT/$FIRST_INTF_DIR/$GAUSS_NAME"
[[ -s "$GAUSS_SOURCE" ]] ||
    die "missing or empty 400 m filter file: $GAUSS_SOURCE"

OUTPUT="$DESEASON_DIR/vel_deseason_ll.grd"
echo "========================================"
echo "Run 5.4: project deseasoned velocity to geographic coordinates"
echo "Mode                : $([[ $# -eq 0 ]] && echo 'CHECK ONLY' || echo 'FORMAL')"
echo "Track root          : $ROOT"
echo "Radar velocity      : $DESEASON_DIR/vel_deseason.grd"
echo "Projection table    : merge/trans.dat ($(awk -v b="$TRANS_BYTES" 'BEGIN{printf "%.1f MiB", b/1048576}'))"
echo "Spatial filter      : $FILTER_METERS m"
echo "Filter source       : $GAUSS_SOURCE"
echo "Geographic velocity : $OUTPUT"
echo "PDF color range     : $CPT_MIN / $CPT_MAX / $CPT_STEP mm/yr"
echo "========================================"

if (( $# == 0 )); then
    usage
    echo "[CHECK ONLY] No links, geographic grid, CPT, PDF or completion marker was created."
    exit 0
fi

cd "$DESEASON_DIR"
TEMP_OUTPUT=".run5.4_vel_deseason_ll.$$.grd"
cleanup() {
    rm -f "$TEMP_OUTPUT"
}
trap cleanup EXIT INT TERM

rm -f trans.dat "$GAUSS_NAME" vel_deseason_ll.cpt vel_deseason_ll.pdf run5.4_complete
ln -s ../../merge/trans.dat trans.dat
ln -s "$GAUSS_SOURCE" "$GAUSS_NAME"

echo "[STEP 1] Project vel_deseason.grd with the ${FILTER_METERS} m spatial filter"
echo "[RUN] proj_ra2ll.csh trans.dat vel_deseason.grd $TEMP_OUTPUT $FILTER_METERS"
proj_ra2ll.csh trans.dat vel_deseason.grd "$TEMP_OUTPUT" "$FILTER_METERS"
[[ -s "$TEMP_OUTPUT" ]] || die "proj_ra2ll.csh did not generate a non-empty output"

echo "[STEP 2] Validate and install vel_deseason_ll.grd"
gmt grdinfo "$TEMP_OUTPUT" -C >/dev/null || die "GMT cannot read the projected grid"
mv -f "$TEMP_OUTPUT" vel_deseason_ll.grd

echo "[STEP 3] Create the velocity color palette"
gmt makecpt -Cjet -T"${CPT_MIN}/${CPT_MAX}/${CPT_STEP}" -Z -D > vel_deseason_ll.cpt
[[ -s vel_deseason_ll.cpt ]] || die "vel_deseason_ll.cpt was not generated"

echo "[STEP 4] Plot the geographic deseasoned velocity"
gmt begin vel_deseason_ll pdf
    gmt set \
        MAP_FRAME_TYPE plain \
        FONT_ANNOT_PRIMARY 10p \
        FONT_LABEL 11p \
        FONT_TITLE 13p \
        COLOR_NAN gray
    gmt grdimage vel_deseason_ll.grd \
        -JM15c \
        -Cvel_deseason_ll.cpt \
        -Baf \
        -BWSen+t"Deseasoned SBAS velocity"
    gmt colorbar \
        -DJBC+w10c/0.3c+h+o0c/1.0c \
        -Cvel_deseason_ll.cpt \
        -Bxa2f1+l"Velocity (mm/yr)"
gmt end
[[ -s vel_deseason_ll.pdf ]] || die "vel_deseason_ll.pdf was not generated"

{
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'input=%s\n' "$(pwd -P)/vel_deseason.grd"
    printf 'output=%s\n' "$(pwd -P)/vel_deseason_ll.grd"
    printf 'trans_source=%s\n' "$ROOT/merge/trans.dat"
    printf 'filter_meters=%s\n' "$FILTER_METERS"
    printf 'gauss_source=%s\n' "$GAUSS_SOURCE"
    printf 'cpt_range=%s/%s/%s\n' "$CPT_MIN" "$CPT_MAX" "$CPT_STEP"
    printf 'pdf=%s\n' "$(pwd -P)/vel_deseason_ll.pdf"
} > run5.4_complete

echo "========================================"
echo "[DONE] Run 5.4 completed"
echo "Geographic velocity : $(pwd -P)/vel_deseason_ll.grd"
echo "Color palette       : $(pwd -P)/vel_deseason_ll.cpt"
echo "PDF map             : $(pwd -P)/vel_deseason_ll.pdf"
echo "Completion marker   : $(pwd -P)/run5.4_complete"
echo "========================================"
