#!/usr/bin/env bash
# Run 6.4: project geographic GNSS LOS velocity to the InSAR radar grid.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 24, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

OUT_DIR="GNSS2LOS_correction"
DISP_DIR="sbas_demcorr_pin/disp_deseason"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 6.4: project geographic GNSS LOS velocity to the radar grid

Check only:
  ./run6.4_project_GNSS_LOS_to_radar.sh

Formal run:
  ./run6.4_project_GNSS_LOS_to_radar.sh 1

Inputs:
  GNSS2LOS_correction/GNSS_to_LOS.grd
  GNSS2LOS_correction/run6.3_complete
  sbas_demcorr_pin/trans.dat
  sbas_demcorr_pin/disp_deseason/disp_YYYYDDD.grd

Outputs:
  GNSS2LOS_correction/GNSS_to_LOS_ra.grd
  GNSS2LOS_correction/GNSS_to_LOS_ra.pdf
  GNSS2LOS_correction/run6.4_complete
USAGE
}

MODE="${1:-}"
(( $# <= 1 )) || { usage; die "too many arguments"; }
[[ -z "$MODE" || "$MODE" == "1" ]] || { usage; die "use no argument or mode 1"; }

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] || die "run in a T-number track root: $ROOT"

OUT_DIR="$ROOT/$OUT_DIR"
DISP_DIR="$ROOT/$DISP_DIR"
LL_GRID="$OUT_DIR/GNSS_to_LOS.grd"
TRANS="$ROOT/sbas_demcorr_pin/trans.dat"

for command in gmt proj_ll2ra.csh; do
    command -v "$command" >/dev/null 2>&1 || die "$command not found in PATH"
done
[[ -s "$LL_GRID" ]] || die "missing Run 6.3 LOS grid: $LL_GRID"
[[ -s "$OUT_DIR/run6.3_complete" ]] || die "missing Run 6.3 marker"
[[ -s "$TRANS" ]] || die "missing trans.dat: $TRANS"
[[ -d "$DISP_DIR" ]] || die "missing deseasoned displacement directory: $DISP_DIR"

REF_GRID="$(find "$DISP_DIR" -maxdepth 1 -type f \
    -name 'disp_[0-9][0-9][0-9][0-9][0-9][0-9][0-9].grd' -print | sort | head -n 1)"
[[ -n "$REF_GRID" ]] || die "no disp_YYYYDDD.grd found in $DISP_DIR"

gmt grdinfo "$LL_GRID" -C >/dev/null || die "GMT cannot read $LL_GRID"
gmt grdinfo "$REF_GRID" -C >/dev/null || die "GMT cannot read $REF_GRID"

read -r _ XMIN XMAX YMIN YMAX _ _ XINC YINC NX NY REG _ \
    <<< "$(gmt grdinfo "$REF_GRID" -C | awk 'NR==1{print}')"
INC_OPT="$(gmt grdinfo "$REF_GRID" -I | awk 'NR==1{print $1}')"
[[ "$INC_OPT" == -I* ]] || die "failed to read increment from $REF_GRID"
REG_OPT=""
[[ "$REG" == "1" ]] && REG_OPT="-r"

echo "========================================"
echo "Run 6.4: project GNSS LOS to radar coordinates"
echo "Run mode          : $([[ $MODE == 1 ]] && echo FORMAL || echo 'CHECK ONLY')"
echo "Track root        : $ROOT"
echo "Geographic LOS    : $LL_GRID"
echo "Projection table  : $TRANS"
echo "Radar template    : $REF_GRID"
echo "Template region   : $XMIN / $XMAX / $YMIN / $YMAX"
echo "Template increment: $XINC / $YINC"
echo "Template size     : $NX x $NY"
echo "Registration      : $REG (0=gridline, 1=pixel)"
echo "Output            : $OUT_DIR/GNSS_to_LOS_ra.grd"
echo "========================================"

if [[ -z "$MODE" ]]; then
    usage
    echo "[CHECK ONLY] No output was created or modified."
    echo "[NEXT] ./run6.4_project_GNSS_LOS_to_radar.sh 1"
    exit 0
fi

TMP="$OUT_DIR/.run6.4_tmp.$$"
mkdir -p "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

ln -s "$TRANS" "$TMP/trans.dat"
ln -s "$LL_GRID" "$TMP/GNSS_to_LOS.grd"

echo "[STEP 1] Initial geographic-to-radar projection"
(
    cd "$TMP"
    proj_ll2ra.csh trans.dat GNSS_to_LOS.grd GNSS_to_LOS_ra_initial.grd "$INC_OPT"
)
[[ -s "$TMP/GNSS_to_LOS_ra_initial.grd" ]] || die "proj_ll2ra.csh produced no grid"

echo "[STEP 2] Interpolate onto the exact deseasoned InSAR grid geometry"
gmt grd2xyz "$TMP/GNSS_to_LOS_ra_initial.grd" -s > "$TMP/GNSS_to_LOS_ra.xyz"
[[ -s "$TMP/GNSS_to_LOS_ra.xyz" ]] || die "no finite radar-coordinate points"
gmt surface "$TMP/GNSS_to_LOS_ra.xyz" \
    -R"${XMIN}/${XMAX}/${YMIN}/${YMAX}" "$INC_OPT" $REG_OPT \
    -T0.1 -G"$TMP/GNSS_to_LOS_ra.grd"

read -r _ _ _ _ _ _ _ _ _ OUT_NX OUT_NY OUT_REG _ \
    <<< "$(gmt grdinfo "$TMP/GNSS_to_LOS_ra.grd" -C | awk 'NR==1{print}')"
[[ "$OUT_NX" == "$NX" && "$OUT_NY" == "$NY" && "$OUT_REG" == "$REG" ]] ||
    die "generated radar grid geometry does not match $REF_GRID"

echo "[STEP 3] Plot radar-coordinate GNSS LOS velocity"
(
    cd "$TMP"
    gmt makecpt -Cjet -T-5/5/1 -Z -D > GNSS_to_LOS_ra.cpt
    gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 10p FONT_LABEL 11p \
        FONT_TITLE 13p COLOR_NAN gray
    gmt grdimage GNSS_to_LOS_ra.grd -JX15c \
        -CGNSS_to_LOS_ra.cpt -Baf -BWSen+t"GNSS LOS velocity in radar coordinates" \
        -P -K > GNSS_to_LOS_ra.ps
    gmt psscale -R"${XMIN}/${XMAX}/${YMIN}/${YMAX}" -JX15c \
        -DJBC+w10c/0.3c+h+o0c/1.0c -CGNSS_to_LOS_ra.cpt \
        -Bxa5f1+l"LOS velocity (mm/yr)" -O >> GNSS_to_LOS_ra.ps
    gmt psconvert GNSS_to_LOS_ra.ps -Tf -A -FGNSS_to_LOS_ra
)
[[ -s "$TMP/GNSS_to_LOS_ra.pdf" ]] || die "radar-coordinate PDF was not generated"

mv -f "$TMP/GNSS_to_LOS_ra.grd" "$OUT_DIR/GNSS_to_LOS_ra.grd"
mv -f "$TMP/GNSS_to_LOS_ra.pdf" "$OUT_DIR/GNSS_to_LOS_ra.pdf"
cat > "$OUT_DIR/run6.4_complete" <<EOF
Run 6.4 completed successfully
track=$TRACK
reference=$REF_GRID
output=$OUT_DIR/GNSS_to_LOS_ra.grd
completed=$(date '+%Y-%m-%d %H:%M:%S %z')
EOF

echo "========================================"
echo "[DONE] Run 6.4 completed successfully."
echo "Grid: $OUT_DIR/GNSS_to_LOS_ra.grd"
echo "Plot: $OUT_DIR/GNSS_to_LOS_ra.pdf"
echo "[NEXT] ./run6.5_build_GNSS_LOS_timeseries.sh"
echo "========================================"
