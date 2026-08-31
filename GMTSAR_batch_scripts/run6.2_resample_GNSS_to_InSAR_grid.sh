#!/usr/bin/env bash
# Run 6.2: resample and mask GNSS east/north grids to the InSAR velocity grid.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 23, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

OUT_DIR="GNSS2LOS_correction"
INSAR_GRID="sbas_demcorr_pin/vel_ll.grd"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 6.2: resample GNSS horizontal velocities to the InSAR geographic grid

Check only (no files are created or modified):
  ./run6.2_resample_GNSS_to_InSAR_grid.sh

Formal run:
  ./run6.2_resample_GNSS_to_InSAR_grid.sh 1

Inputs:
  GNSS2LOS_correction/GNSS_E_HMF.grd
  GNSS2LOS_correction/GNSS_N_HMF.grd
  sbas_demcorr_pin/vel_ll.grd

Outputs:
  GNSS2LOS_correction/GNSS_E.grd
  GNSS2LOS_correction/GNSS_N.grd
  GNSS2LOS_correction/GNSS_E.pdf
  GNSS2LOS_correction/GNSS_N.pdf
  GNSS2LOS_correction/run6.2_complete

The finite-data footprint of vel_ll.grd is used as the InSAR mask.
USAGE
}

RUN_FORMAL=0
if (( $# == 0 )); then
    RUN_FORMAL=0
elif (( $# == 1 )) && [[ "$1" == "1" ]]; then
    RUN_FORMAL=1
else
    usage
    die "use no argument for checking, or 1 for the formal run"
fi

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number track root (current: $ROOT)"

OUT_DIR="$ROOT/$OUT_DIR"
INSAR_GRID="$ROOT/$INSAR_GRID"
E_SOURCE="$OUT_DIR/GNSS_E_HMF.grd"
N_SOURCE="$OUT_DIR/GNSS_N_HMF.grd"

command -v gmt >/dev/null 2>&1 || die "gmt not found in PATH"
[[ -s "$E_SOURCE" ]] || die "east GNSS grid is missing or empty: $E_SOURCE"
[[ -s "$N_SOURCE" ]] || die "north GNSS grid is missing or empty: $N_SOURCE"
[[ -s "$INSAR_GRID" ]] || die "InSAR geographic velocity grid is missing or empty: $INSAR_GRID"

for grid in "$E_SOURCE" "$N_SOURCE" "$INSAR_GRID"; do
    gmt grdinfo "$grid" -C >/dev/null || die "GMT cannot read: $grid"
done

INC_OPT="$(gmt grdinfo "$INSAR_GRID" -I | awk 'NR==1{print $1}')"
[[ "$INC_OPT" == -I* ]] || die "failed to read grid increment from $INSAR_GRID"

read -r _ XMIN XMAX YMIN YMAX _ _ XINC YINC NX NY REGISTRATION _ \
    <<< "$(gmt grdinfo "$INSAR_GRID" -C | awk 'NR==1{print}')"

echo "========================================"
echo "Run 6.2: resample GNSS to the InSAR grid"
echo "Run mode          : $([[ $RUN_FORMAL -eq 1 ]] && echo FORMAL || echo 'CHECK ONLY')"
echo "Track root        : $ROOT"
echo "East source       : $E_SOURCE"
echo "North source      : $N_SOURCE"
echo "InSAR template    : $INSAR_GRID"
echo "Template region   : $XMIN / $XMAX / $YMIN / $YMAX"
echo "Template increment: $XINC / $YINC"
echo "Template size     : $NX x $NY"
echo "Registration      : $REGISTRATION (0=gridline, 1=pixel)"
echo "Output directory  : $OUT_DIR"
echo "========================================"

if (( RUN_FORMAL == 0 )); then
    usage
    echo "[CHECK ONLY] No output or temporary file was created."
    echo "[NEXT] Formal run:"
    echo "  ./run6.2_resample_GNSS_to_InSAR_grid.sh 1"
    exit 0
fi

mkdir -p "$OUT_DIR"
TMP_DIR="$OUT_DIR/.run6.2_tmp.$$"
mkdir "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

REG_OPT=""
[[ "$REGISTRATION" == "1" ]] && REG_OPT="-r"

echo "[STEP 1] Resample east and north GNSS grids to the vel_ll.grd geometry"
gmt grdsample "$E_SOURCE" -R"${XMIN}/${XMAX}/${YMIN}/${YMAX}" "$INC_OPT" $REG_OPT \
    -G"$TMP_DIR/GNSS_E_resampled.grd"
gmt grdsample "$N_SOURCE" -R"${XMIN}/${XMAX}/${YMIN}/${YMAX}" "$INC_OPT" $REG_OPT \
    -G"$TMP_DIR/GNSS_N_resampled.grd"

echo "[STEP 2] Apply the finite-data footprint of vel_ll.grd"
gmt grdmath "$INSAR_GRID" ISFINITE 0 NAN = "$TMP_DIR/insar_valid_mask.grd"
gmt grdmath "$TMP_DIR/GNSS_E_resampled.grd" "$TMP_DIR/insar_valid_mask.grd" MUL \
    = "$TMP_DIR/GNSS_E.grd"
gmt grdmath "$TMP_DIR/GNSS_N_resampled.grd" "$TMP_DIR/insar_valid_mask.grd" MUL \
    = "$TMP_DIR/GNSS_N.grd"

for component in E N; do
    GRID="$TMP_DIR/GNSS_${component}.grd"
    gmt grdinfo "$GRID" -C >/dev/null || die "GMT cannot read generated grid: $GRID"
    read -r _ _ _ _ _ _ _ _ _ OUT_NX OUT_NY OUT_REG _ \
        <<< "$(gmt grdinfo "$GRID" -C | awk 'NR==1{print}')"
    [[ "$OUT_NX" == "$NX" && "$OUT_NY" == "$NY" && "$OUT_REG" == "$REGISTRATION" ]] ||
        die "GNSS_${component}.grd geometry does not match vel_ll.grd"
done

echo "[STEP 3] Plot the resampled and masked east/north grids"
for component in E N; do
    GRID="GNSS_${component}.grd"
    if [[ "$component" == "E" ]]; then
        TITLE="GNSS East velocity on InSAR grid"
    else
        TITLE="GNSS North velocity on InSAR grid"
    fi
    (
        cd "$TMP_DIR"
        export GMT_USERDIR="$TMP_DIR/.gmt"
        mkdir -p "$GMT_USERDIR"
        gmt grd2cpt "$GRID" -Cjet -E21 -Z > "GNSS_${component}.cpt"
        gmt begin "GNSS_${component}" pdf
            gmt set \
                MAP_FRAME_TYPE plain \
                FONT_ANNOT_PRIMARY 10p \
                FONT_LABEL 11p \
                FONT_TITLE 13p \
                COLOR_NAN gray
            gmt grdimage "$GRID" \
                -JM15c \
                -C"GNSS_${component}.cpt" \
                -Baf \
                -BWSen+t"$TITLE"
            gmt colorbar \
                -DJBC+w10c/0.3c+h+o0c/1.0c \
                -C"GNSS_${component}.cpt" \
                -Baf+l"Velocity (mm/yr)"
        gmt end
    )
done

echo "[STEP 4] Install verified outputs"
mv -f "$TMP_DIR/GNSS_E.grd" "$OUT_DIR/GNSS_E.grd"
mv -f "$TMP_DIR/GNSS_N.grd" "$OUT_DIR/GNSS_N.grd"
mv -f "$TMP_DIR/GNSS_E.pdf" "$OUT_DIR/GNSS_E.pdf"
mv -f "$TMP_DIR/GNSS_N.pdf" "$OUT_DIR/GNSS_N.pdf"

cat > "$OUT_DIR/run6.2_complete" <<EOF
Run 6.2 completed successfully
track=$TRACK
template=$INSAR_GRID
east=$OUT_DIR/GNSS_E.grd
north=$OUT_DIR/GNSS_N.grd
completed=$(date '+%Y-%m-%d %H:%M:%S %z')
EOF

echo "========================================"
echo "[DONE] Run 6.2 completed successfully."
echo "Outputs:"
echo "  $OUT_DIR/GNSS_E.grd"
echo "  $OUT_DIR/GNSS_N.grd"
echo "  $OUT_DIR/GNSS_E.pdf"
echo "  $OUT_DIR/GNSS_N.pdf"
echo "  $OUT_DIR/run6.2_complete"
echo "[NEXT] ./run6.3_project_GNSS_to_LOS.py"
echo "========================================"
