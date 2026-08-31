#!/usr/bin/env bash
# Run 6.9: geocode GNSS-corrected and removed-correction velocity grids.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 24, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

DEFAULT_FILTER=400
CPT_MIN="${VEL_CPT_MIN:--5}"
CPT_MAX="${VEL_CPT_MAX:-5}"
CPT_STEP="${VEL_CPT_STEP:-1}"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 6.9: project GNSS-corrected velocity products to geographic coordinates

Check only:
  ./run6.9_geocode_GNSS_corrected_velocity.sh

Formal run with the recommended 400 m spatial filter:
  ./run6.9_geocode_GNSS_corrected_velocity.sh 1

Formal run with another filter distance:
  ./run6.9_geocode_GNSS_corrected_velocity.sh 1 600

Outputs:
  GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km_ll.grd
  GNSS2LOS_correction/GNSS_corrected_displacement/vel_diff_smooth80km_full_ll.grd
  GNSS2LOS_correction/GNSS_corrected_displacement/GNSS_corrected_velocity_ll.cpt
  GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km_ll.pdf
  GNSS2LOS_correction/GNSS_corrected_displacement/vel_diff_smooth80km_full_ll.pdf
  KML product for the GNSS-corrected geographic velocity only
USAGE
}

MODE="${1:-}"
FILTER="${2:-$DEFAULT_FILTER}"
(( $# <= 2 )) || { usage; die "too many arguments"; }
[[ -z "$MODE" || "$MODE" == "1" ]] || { usage; die "use no argument or mode 1"; }
[[ "$FILTER" =~ ^[1-9][0-9]*$ ]] || die "filter distance must be a positive integer in meters"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] || die "run in a T-number track root: $ROOT"

RUN6_DIR="$ROOT/GNSS2LOS_correction"
TARGET="$RUN6_DIR/GNSS_corrected_displacement"
TRANS="$ROOT/sbas_demcorr_pin/trans.dat"
[[ -s "$TRANS" ]] || TRANS="$ROOT/merge/trans.dat"
IN1="$TARGET/vel_gnssref_5km_80km.grd"
IN2="$TARGET/vel_diff_smooth80km_full.grd"
OUT1="$TARGET/vel_gnssref_5km_80km_ll.grd"
OUT2="$TARGET/vel_diff_smooth80km_full_ll.grd"
PDF1="$TARGET/vel_gnssref_5km_80km_ll.pdf"
PDF2="$TARGET/vel_diff_smooth80km_full_ll.pdf"
OLD_PDF="$TARGET/GNSS_corrected_velocity_ll_2panel.pdf"
CPT="$TARGET/GNSS_corrected_velocity_ll.cpt"
BASE1="$(basename "${OUT1%.grd}")"
BASE2="$(basename "${OUT2%.grd}")"

for command in gmt proj_ra2ll.csh grd2kml.csh; do
    command -v "$command" >/dev/null 2>&1 || die "$command not found in PATH"
done
[[ -d "$TARGET" ]] || die "missing Run 6.7 output directory: $TARGET"
[[ -s "$RUN6_DIR/run6.8_complete" ]] || die "missing Run 6.8 completion marker"
[[ -s "$TRANS" ]] || die "missing non-empty trans.dat in sbas_demcorr_pin/ or merge/"
[[ -s "$IN1" ]] || die "missing corrected velocity: $IN1"
[[ -s "$IN2" ]] || die "missing correction velocity: $IN2"

GAUSS=""
if [[ -s "$ROOT/sbas_demcorr_pin/gauss_$FILTER" ]]; then
    GAUSS="$ROOT/sbas_demcorr_pin/gauss_$FILTER"
else
    FIRST_INTF="$(find "$ROOT/F1/intf_all" -mindepth 1 -maxdepth 1 -type d -name '20*_20*' -print 2>/dev/null | sort | head -n 1)"
    if [[ -n "$FIRST_INTF" && -s "$FIRST_INTF/gauss_$FILTER" ]]; then
        GAUSS="$FIRST_INTF/gauss_$FILTER"
    fi
fi
[[ -n "$GAUSS" ]] || die "cannot find gauss_$FILTER in sbas_demcorr_pin/ or the first F1 interferogram"

TRANS_BYTES="$(wc -c < "$TRANS" | tr -d ' ')"
echo "========================================"
echo "Run 6.9: geocode GNSS-corrected velocity"
echo "Run mode             : $([[ $MODE == 1 ]] && echo FORMAL || echo 'CHECK ONLY')"
echo "Track root           : $ROOT"
echo "Radar velocity       : $IN1"
echo "Correction velocity  : $IN2"
echo "Projection table     : $TRANS ($(awk -v b="$TRANS_BYTES" 'BEGIN{printf "%.1f MiB",b/1048576}'))"
echo "Spatial filter       : $FILTER m"
echo "Filter file          : $GAUSS"
echo "Plot color range     : $CPT_MIN / $CPT_MAX / $CPT_STEP mm/yr"
echo "Output directory     : $TARGET"
echo "========================================"

if [[ -z "$MODE" ]]; then
    usage
    echo "[CHECK ONLY] Inputs are ready; no links, grids or plots were created."
    echo "[NEXT] ./run6.9_geocode_GNSS_corrected_velocity.sh 1"
    exit 0
fi

TMP="$TARGET/.run6.9_tmp.$$"
mkdir -p "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
ln -s "$TRANS" "$TMP/trans.dat"
ln -s "$GAUSS" "$TMP/gauss_$FILTER"
ln -s "$IN1" "$TMP/$(basename "$IN1")"
ln -s "$IN2" "$TMP/$(basename "$IN2")"
echo "[STEP 1] Project corrected velocity to longitude/latitude"
(
    cd "$TMP"
    proj_ra2ll.csh trans.dat "$(basename "$IN1")" "$(basename "$OUT1")" "$FILTER"
)
[[ -s "$TMP/$(basename "$OUT1")" ]] || die "corrected geographic velocity was not generated"

echo "[STEP 2] Project removed long-wavelength correction to longitude/latitude"
(
    cd "$TMP"
    proj_ra2ll.csh trans.dat "$(basename "$IN2")" "$(basename "$OUT2")" "$FILTER"
)
[[ -s "$TMP/$(basename "$OUT2")" ]] || die "geographic correction velocity was not generated"

echo "[STEP 3] Plot two separate geographic velocity PDFs"
(
    cd "$TMP"
    gmt makecpt -Cjet -T"${CPT_MIN}/${CPT_MAX}/${CPT_STEP}" -Z -D > velocity.cpt
    REGION="$(gmt grdinfo "$(basename "$OUT1")" -C | awk 'NR==1{print $2"/"$3"/"$4"/"$5}')"
    gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 9p FONT_LABEL 10p \
        FONT_TITLE 11p COLOR_NAN gray

    gmt grdimage "$(basename "$OUT1")" -R"$REGION" -JM10c -Cvelocity.cpt \
        -Baf -BWSen+t"GNSS-corrected InSAR velocity" -K -X2c -Y4c > corrected.ps
    gmt psscale -R"$REGION" -JM10c -DJBC+w7c/0.25c+h+o0c/0.9c \
        -Cvelocity.cpt -Bxa5f1+l"Velocity (mm/yr)" -O >> corrected.ps
    gmt psconvert corrected.ps -Tf -A -F"$BASE1"

    gmt grdimage "$(basename "$OUT2")" -R"$REGION" -JM10c -Cvelocity.cpt \
        -Baf -BWSen+t"Removed long-wavelength correction" -K -X2c -Y4c > correction.ps
    gmt psscale -R"$REGION" -JM10c -DJBC+w7c/0.25c+h+o0c/0.9c \
        -Cvelocity.cpt -Bxa5f1+l"Velocity (mm/yr)" -O >> correction.ps
    gmt psconvert correction.ps -Tf -A -F"$BASE2"
)
[[ -s "$TMP/${BASE1}.pdf" ]] || die "GNSS-corrected velocity PDF was not generated"
[[ -s "$TMP/${BASE2}.pdf" ]] || die "correction velocity PDF was not generated"

mv -f "$TMP/$(basename "$OUT1")" "$OUT1"
mv -f "$TMP/$(basename "$OUT2")" "$OUT2"
mv -f "$TMP/${BASE1}.pdf" "$PDF1"
mv -f "$TMP/${BASE2}.pdf" "$PDF2"
rm -f "$OLD_PDF"
gmt makecpt -Cjet -T"${CPT_MIN}/${CPT_MAX}/${CPT_STEP}" -Z -D > "$CPT"
[[ -s "$CPT" ]] || die "KML color palette was not generated"

echo "[STEP 4] Generate KML for the GNSS-corrected velocity"
(
    cd "$TARGET"
    rm -rf "${BASE1}.kml" "${BASE1}.kmz" "${BASE1}.png" \
        "${BASE1}.legend.png" "$BASE1"
    # Remove KML products made for the correction field by an older Run 6.9.
    rm -rf "${BASE2}.kml" "${BASE2}.kmz" "${BASE2}.png" \
        "${BASE2}.legend.png" "$BASE2"
    grd2kml.csh "$BASE1" "$(basename "$CPT")"
)

KML_COUNT="$(find "$TARGET" -maxdepth 2 \( -type f -o -type l \) \
    \( -name "${BASE1}*.kml" -o -name "${BASE1}*.kmz" \) \
    | wc -l | tr -d ' ')"
(( KML_COUNT >= 1 )) || die "grd2kml.csh finished but no KML/KMZ product was found"

cat > "$RUN6_DIR/run6.9_complete" <<EOF
Run 6.9 completed successfully
track=$TRACK
filter_meters=$FILTER
corrected_velocity_ll=$OUT1
correction_velocity_ll=$OUT2
corrected_velocity_pdf=$PDF1
correction_velocity_pdf=$PDF2
kml_files=$KML_COUNT
completed=$(date '+%Y-%m-%d %H:%M:%S %z')
EOF

echo "========================================"
echo "[DONE] Run 6.9 completed successfully."
echo "Corrected velocity : $OUT1"
echo "Correction velocity: $OUT2"
echo "Corrected PDF      : $PDF1"
echo "Correction PDF     : $PDF2"
echo "Color palette      : $CPT"
echo "KML/KMZ files      : $KML_COUNT"
find "$TARGET" -maxdepth 2 \( -type f -o -type l \) \
    \( -name "${BASE1}*.kml" -o -name "${BASE1}*.kmz" \) \
    -print | sort
echo "========================================"
