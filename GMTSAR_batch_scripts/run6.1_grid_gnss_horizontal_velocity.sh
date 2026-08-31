#!/usr/bin/env bash
# Run 6.1: grid horizontal GNSS velocities for later InSAR LOS correction.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 23, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

GNSS_FILE="2024_HMF_GPS_ITRF_Panda_Eric_unique.txt"
OUT_DIR="GNSS2LOS_correction"
REGION="70/100/24/37.5"
INCREMENT="2m"
CPT_MIN="${GNSS_CPT_MIN:--20}"
CPT_MAX="${GNSS_CPT_MAX:-20}"
CPT_STEP="${GNSS_CPT_STEP:-1}"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 6.1: grid GNSS east/north horizontal velocities

Check only (no files are created or modified):
  ./run6.1_grid_gnss_horizontal_velocity.sh

Formal run with the default HMF region and 2-minute grid spacing:
  ./run6.1_grid_gnss_horizontal_velocity.sh 1

Options:
  --gnss-file FILE      GNSS text table (default: 2024_HMF_GPS_ITRF_Panda_Eric_unique.txt)
  --region W/E/S/N      geographic region (default: 70/100/24/37.5)
  --increment INC       grid spacing accepted by GMT (default: 2m)
  --output-dir DIR      output directory (default: GNSS2LOS_correction)
  -h, --help            show this help

Required input columns after the header:
  longitude latitude east_mm north_mm east_error north_error [...]

Outputs:
  GNSS2LOS_correction/GNSS_E_HMF.grd         east velocity, mm/yr
  GNSS2LOS_correction/GNSS_N_HMF.grd         north velocity, mm/yr
  GNSS2LOS_correction/GNSS_HMF.cpt
  GNSS2LOS_correction/GNSS_E_HMF.pdf
  GNSS2LOS_correction/GNSS_N_HMF.pdf
  GNSS2LOS_correction/gnss_stations_used.txt six columns passed to gpsgridder
  GNSS2LOS_correction/run6.1_gpsgridder.log
  GNSS2LOS_correction/run6.1_complete

Optional GMT color-range environment variables:
  GNSS_CPT_MIN=-20 GNSS_CPT_MAX=20 GNSS_CPT_STEP=1
USAGE
}

RUN_FORMAL=0
while (( $# > 0 )); do
    case "$1" in
        1)
            (( RUN_FORMAL == 0 )) || die "formal mode 1 was specified more than once"
            RUN_FORMAL=1
            shift
            ;;
        --gnss-file)
            (( $# >= 2 )) || die "--gnss-file requires a path"
            GNSS_FILE="$2"
            shift 2
            ;;
        --region)
            (( $# >= 2 )) || die "--region requires W/E/S/N"
            REGION="$2"
            shift 2
            ;;
        --increment)
            (( $# >= 2 )) || die "--increment requires a GMT increment"
            INCREMENT="$2"
            shift 2
            ;;
        --output-dir)
            (( $# >= 2 )) || die "--output-dir requires a directory"
            OUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

for value_name in CPT_MIN CPT_MAX CPT_STEP; do
    value="${!value_name}"
    awk -v x="$value" 'BEGIN {exit !(x ~ /^[-+]?[0-9]*\.?[0-9]+$/)}' ||
        die "$value_name must be numeric (current: $value)"
done
awk -v lo="$CPT_MIN" -v hi="$CPT_MAX" -v step="$CPT_STEP" \
    'BEGIN {exit !(lo < hi && step > 0)}' ||
    die "color range must satisfy MIN < MAX and STEP > 0"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number track root (current: $ROOT)"

if [[ "$GNSS_FILE" != /* ]]; then
    GNSS_FILE="$ROOT/$GNSS_FILE"
fi
if [[ "$OUT_DIR" != /* ]]; then
    OUT_DIR="$ROOT/$OUT_DIR"
fi

[[ -s "$GNSS_FILE" ]] || die "GNSS table is missing or empty: $GNSS_FILE"
command -v gmt >/dev/null 2>&1 || die "gmt not found in PATH"

awk '
    NR == 1 { next }
    /^[[:space:]]*$/ { next }
    {
        if (NF < 6) {
            printf "[ERROR] line %d has fewer than 6 columns\n", NR > "/dev/stderr"
            bad = 1
            next
        }
        for (i = 1; i <= 6; i++) {
            if ($i !~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) {
                printf "[ERROR] line %d column %d is not numeric: %s\n", NR, i, $i > "/dev/stderr"
                bad = 1
            }
        }
    }
    END { exit bad }
' "$GNSS_FILE" || die "invalid GNSS table"

STATION_COUNT="$(awk 'NR >= 2 && NF >= 6 {n++} END {print n+0}' "$GNSS_FILE")"
(( STATION_COUNT >= 3 )) || die "at least 3 valid GNSS stations are required"

IFS=/ read -r WEST EAST SOUTH NORTH EXTRA <<< "$REGION"
[[ -z "${EXTRA:-}" && -n "${WEST:-}" && -n "${EAST:-}" && -n "${SOUTH:-}" && -n "${NORTH:-}" ]] ||
    die "--region must have W/E/S/N format"
for value in "$WEST" "$EAST" "$SOUTH" "$NORTH"; do
    awk -v x="$value" 'BEGIN {exit !(x ~ /^[-+]?[0-9]*\.?[0-9]+$/)}' ||
        die "region values must be numeric: $REGION"
done
awk -v w="$WEST" -v e="$EAST" -v s="$SOUTH" -v n="$NORTH" \
    'BEGIN {exit !(w < e && s < n)}' || die "region must satisfy W < E and S < N"

EXISTING_E="no"
EXISTING_N="no"
[[ -s "$OUT_DIR/GNSS_E_HMF.grd" ]] && EXISTING_E="yes"
[[ -s "$OUT_DIR/GNSS_N_HMF.grd" ]] && EXISTING_N="yes"

echo "========================================"
echo "Run 6.1: grid horizontal GNSS velocities"
echo "Run mode          : $([[ $RUN_FORMAL -eq 1 ]] && echo FORMAL || echo 'CHECK ONLY')"
echo "Track root        : $ROOT"
echo "GNSS table        : $GNSS_FILE"
echo "GNSS stations     : $STATION_COUNT"
echo "Input columns     : lon lat east north east_error north_error"
echo "Region            : $REGION"
echo "Increment         : $INCREMENT"
echo "Registration      : pixel (-r)"
echo "Coordinates       : geographic (-fg)"
echo "Solver            : gpsgridder -W -Cn100%"
echo "Plot color range  : $CPT_MIN / $CPT_MAX / $CPT_STEP mm/yr"
echo "Output directory  : $OUT_DIR"
echo "Existing east grid: $EXISTING_E"
echo "Existing north grid: $EXISTING_N"
echo "========================================"

if (( RUN_FORMAL == 0 )); then
    usage
    echo "[CHECK ONLY] No directory, station table, grid, log, lock or marker was created."
    echo "[NEXT] Formal run:"
    echo "  ./run6.1_grid_gnss_horizontal_velocity.sh 1"
    exit 0
fi

mkdir -p "$OUT_DIR"
LOCK_FILE="$OUT_DIR/.run6.1.lock"
LOCK_DIR=""
if command -v flock >/dev/null 2>&1; then
    exec 9> "$LOCK_FILE"
    flock -n 9 || die "another Run 6.1 process is already running"
else
    LOCK_DIR="$OUT_DIR/.run6.1.lock.d"
    mkdir "$LOCK_DIR" 2>/dev/null || die "another Run 6.1 process may be running"
    trap 'rmdir -- "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

TMP_DIR="$OUT_DIR/.run6.1_tmp.$$"
mkdir "$TMP_DIR"
cleanup() {
    rm -rf "$TMP_DIR"
    [[ -z "$LOCK_DIR" ]] || rmdir -- "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

STATIONS_TMP="$TMP_DIR/gnss_stations_used.txt"
LOG_TMP="$TMP_DIR/run6.1_gpsgridder.log"
awk 'NR >= 2 && NF >= 6 {print $1, $2, $3, $4, $5, $6}' \
    "$GNSS_FILE" > "$STATIONS_TMP"
[[ "$(wc -l < "$STATIONS_TMP" | awk '{print $1}')" -eq "$STATION_COUNT" ]] ||
    die "station count changed while preparing input"

echo "[RUN] gmt gpsgridder -R$REGION -I$INCREMENT -fg -W -r -Cn100% -Ggps_%s.grd -V"
set +e
gmt gpsgridder "$STATIONS_TMP" \
    -R"$REGION" -I"$INCREMENT" -fg -W -r -Cn100% \
    -G"$TMP_DIR/gps_%s.grd" -V > "$LOG_TMP" 2>&1
GPS_STATUS=$?
set -e
cat "$LOG_TMP"
(( GPS_STATUS == 0 )) || die "gmt gpsgridder exited with status $GPS_STATUS"

for component in u v; do
    grid="$TMP_DIR/gps_${component}.grd"
    [[ -s "$grid" ]] || die "gpsgridder did not generate: $grid"
    gmt grdinfo "$grid" -C >/dev/null || die "GMT cannot read: $grid"
done

echo "[STEP 2] Rename gpsgridder components to the final GNSS names"
mv -f "$TMP_DIR/gps_u.grd" "$TMP_DIR/GNSS_E_HMF.grd"
mv -f "$TMP_DIR/gps_v.grd" "$TMP_DIR/GNSS_N_HMF.grd"
gmt grdinfo "$TMP_DIR/GNSS_E_HMF.grd" -C >/dev/null ||
    die "GMT cannot read renamed east grid"
gmt grdinfo "$TMP_DIR/GNSS_N_HMF.grd" -C >/dev/null ||
    die "GMT cannot read renamed north grid"

echo "[STEP 3] Plot GNSS east/north velocity grids with GMT"
(
    cd "$TMP_DIR"
    gmt makecpt -Cjet -T"${CPT_MIN}/${CPT_MAX}/${CPT_STEP}" -Z -D > GNSS_HMF.cpt

    gmt begin GNSS_E_HMF pdf
        gmt set \
            MAP_FRAME_TYPE plain \
            FONT_ANNOT_PRIMARY 10p \
            FONT_LABEL 11p \
            FONT_TITLE 13p \
            COLOR_NAN gray
        gmt grdimage GNSS_E_HMF.grd \
            -R"$REGION" -JM15c \
            -CGNSS_HMF.cpt \
            -Baf \
            -BWSen+t"GNSS_E_HMF Velocity (mm/yr)"
        gmt colorbar \
            -DJBC+w10c/0.3c+h+o0c/1.0c \
            -CGNSS_HMF.cpt \
            -Bxa10f5+l"Velocity (mm/yr)"
    gmt end

    gmt begin GNSS_N_HMF pdf
        gmt set \
            MAP_FRAME_TYPE plain \
            FONT_ANNOT_PRIMARY 10p \
            FONT_LABEL 11p \
            FONT_TITLE 13p \
            COLOR_NAN gray
        gmt grdimage GNSS_N_HMF.grd \
            -R"$REGION" -JM15c \
            -CGNSS_HMF.cpt \
            -Baf \
            -BWSen+t"GNSS_N_HMF Velocity (mm/yr)"
        gmt colorbar \
            -DJBC+w10c/0.3c+h+o0c/1.0c \
            -CGNSS_HMF.cpt \
            -Bxa10f5+l"Velocity (mm/yr)"
    gmt end
)

for product in GNSS_HMF.cpt GNSS_E_HMF.pdf GNSS_N_HMF.pdf; do
    [[ -s "$TMP_DIR/$product" ]] || die "GMT did not generate: $product"
done

mv -f "$TMP_DIR/GNSS_E_HMF.grd" "$OUT_DIR/GNSS_E_HMF.grd"
mv -f "$TMP_DIR/GNSS_N_HMF.grd" "$OUT_DIR/GNSS_N_HMF.grd"
mv -f "$TMP_DIR/GNSS_HMF.cpt" "$OUT_DIR/GNSS_HMF.cpt"
mv -f "$TMP_DIR/GNSS_E_HMF.pdf" "$OUT_DIR/GNSS_E_HMF.pdf"
mv -f "$TMP_DIR/GNSS_N_HMF.pdf" "$OUT_DIR/GNSS_N_HMF.pdf"
mv -f "$STATIONS_TMP" "$OUT_DIR/gnss_stations_used.txt"
mv -f "$LOG_TMP" "$OUT_DIR/run6.1_gpsgridder.log"

# Remove output names used by the earlier Run 6.1 draft, if present.
rm -f "$OUT_DIR/gps_u.grd" "$OUT_DIR/gps_v.grd"

{
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'gnss_file=%s\n' "$GNSS_FILE"
    printf 'stations=%s\n' "$STATION_COUNT"
    printf 'region=%s\n' "$REGION"
    printf 'increment=%s\n' "$INCREMENT"
    printf 'east_grid=%s\n' "$OUT_DIR/GNSS_E_HMF.grd"
    printf 'north_grid=%s\n' "$OUT_DIR/GNSS_N_HMF.grd"
    printf 'cpt_range=%s/%s/%s\n' "$CPT_MIN" "$CPT_MAX" "$CPT_STEP"
    printf 'east_pdf=%s\n' "$OUT_DIR/GNSS_E_HMF.pdf"
    printf 'north_pdf=%s\n' "$OUT_DIR/GNSS_N_HMF.pdf"
} > "$OUT_DIR/run6.1_complete"

echo "========================================"
echo "[DONE] Run 6.1 completed"
echo "East velocity grid  : $OUT_DIR/GNSS_E_HMF.grd"
echo "North velocity grid : $OUT_DIR/GNSS_N_HMF.grd"
echo "East velocity PDF   : $OUT_DIR/GNSS_E_HMF.pdf"
echo "North velocity PDF  : $OUT_DIR/GNSS_N_HMF.pdf"
echo "Color palette       : $OUT_DIR/GNSS_HMF.cpt"
echo "Stations used       : $OUT_DIR/gnss_stations_used.txt"
echo "Log                 : $OUT_DIR/run6.1_gpsgridder.log"
echo "Completion marker   : $OUT_DIR/run6.1_complete"
echo "========================================"
