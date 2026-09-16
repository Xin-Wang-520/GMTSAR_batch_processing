#!/usr/bin/env bash
# Convert one longitude/latitude point to GMTSAR radar coordinates.
# Default point: Luosixing landslide (118.774 E, 30.010 N).

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACK_ROOT="${TRACK_ROOT:-$SCRIPT_DIR}"
TOPO_DIR="$TRACK_ROOT/burst/topo"

LON="${1:-118.774}"
LAT="${2:-30.010}"
DEM="$TOPO_DIR/dem.grd"

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

if (( $# > 2 )); then
    echo "Usage: ./geo_to_radar_burst.sh [LONGITUDE LATITUDE]"
    echo "Example: ./geo_to_radar_burst.sh 118.774 30.010"
    exit 1
fi

command -v gmt >/dev/null 2>&1 || die "gmt not found"
command -v SAT_llt2rat >/dev/null 2>&1 || die "SAT_llt2rat not found"
[[ -s "$DEM" ]] || die "DEM not found or empty: $DEM"

shopt -s nullglob
PRM_FILES=("$TOPO_DIR"/S1_*_ALL_F*.PRM)
shopt -u nullglob
(( ${#PRM_FILES[@]} > 0 )) ||
    die "no S1_*_ALL_F*.PRM found in $TOPO_DIR"
(( ${#PRM_FILES[@]} == 1 )) ||
    die "more than one master PRM found in $TOPO_DIR"

PRM="${PRM_FILES[0]}"

ELEVATION="$(
    printf '%s %s\n' "$LON" "$LAT" |
        gmt grdtrack -G"$DEM" -fg |
        awk 'NF >= 3 && $3 != "NaN" {print $3; exit}'
)"
[[ -n "$ELEVATION" ]] ||
    die "point is outside dem.grd or its elevation is NaN"

RADAR="$(
    cd "$TOPO_DIR"
    printf '%s %s %s\n' "$LON" "$LAT" "$ELEVATION" |
        SAT_llt2rat "$(basename "$PRM")" 1 |
        awk 'NF >= 2 && $1 ~ /^[-+0-9.]/ && $2 ~ /^[-+0-9.]/ {print $1, $2; exit}'
)"
[[ -n "$RADAR" ]] || die "SAT_llt2rat returned no valid coordinate"

read -r RANGE AZIMUTH <<< "$RADAR"

echo "longitude = $LON"
echo "latitude  = $LAT"
echo "elevation = $ELEVATION m"
echo "range     = $RANGE"
echo "azimuth   = $AZIMUTH"
echo "region point format: $RANGE/$RANGE/$AZIMUTH/$AZIMUTH"
