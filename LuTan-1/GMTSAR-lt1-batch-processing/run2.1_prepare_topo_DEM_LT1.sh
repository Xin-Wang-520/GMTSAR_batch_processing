#!/usr/bin/env bash
# Run 2.1: derive the full LT-1 product footprint from meta.xml and prepare DEM.
# Formal mode is selected by positional argument 1; preview only records bounds.
set -euo pipefail

usage() {
    cat <<'HELP'
Run 2.1: prepare DEM from the complete LT-1 XML footprint

Usage:
  run2.1_prepare_topo_DEM_LT1.sh [1] [options]

Options:
  1                 Formal mode; download/create topo/dem.grd.
  --data-dir DIR    LT-1 data directory (default: data).
  --margin-deg N    Padding on every side in degrees (default: 0.30).
  --resolution N    make_dem mode: 1=SRTM-1s, 2=SRTM-3s (default: 1).
  --topo-dir DIR    DEM directory (default: topo).
HELP
}

die() { echo "[ERROR] $*" >&2; exit 1; }

formal=0
data_dir="data"
margin_deg=0.30
resolution=1
topo_dir="topo"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        1) formal=1; shift ;;
        --data-dir) [[ $# -ge 2 ]] || die "--data-dir requires a directory"; data_dir="$2"; shift 2 ;;
        --margin-deg) [[ $# -ge 2 ]] || die "--margin-deg requires a value"; margin_deg="$2"; shift 2 ;;
        --resolution) [[ $# -ge 2 ]] || die "--resolution requires 1 or 2"; resolution="$2"; shift 2 ;;
        --topo-dir) [[ $# -ge 2 ]] || die "--topo-dir requires a directory"; topo_dir="$2"; shift 2 ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ "$margin_deg" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--margin-deg must be non-negative"
[[ "$resolution" = 1 || "$resolution" = 2 ]] || die "--resolution must be 1 or 2"
command -v python3 >/dev/null 2>&1 || die "python3 was not found in PATH"
command -v make_dem.csh >/dev/null 2>&1 || die "make_dem.csh was not found in PATH"

root_dir="$(pwd -P)"
data_path="$root_dir/$data_dir"
topo_path="$root_dir/$topo_dir"
mkdir -p "$topo_path"
dem_path="$topo_path/dem.grd"
region_file="$topo_path/dem_region.txt"
[[ -d "$data_path" ]] || die "data directory not found: $data_path"

bounds_info="$(python3 - "$data_path" "$margin_deg" <<'PY'
import sys
import math
import xml.etree.ElementTree as ET
from pathlib import Path

data = Path(sys.argv[1])
margin = float(sys.argv[2])
xml_files = sorted(data.rglob("*.meta.xml"))
if not xml_files:
    print("no *.meta.xml files found", file=sys.stderr)
    raise SystemExit(1)

latitudes = []
longitudes = []
for path in xml_files:
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as exc:
        print(f"cannot parse {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
    scene_info = next((e for e in root.iter() if e.tag.rsplit('}', 1)[-1] == 'sceneInfo'), None)
    if scene_info is None:
        print(f"sceneInfo not found: {path}", file=sys.stderr)
        raise SystemExit(1)
    corners = [e for e in scene_info.iter() if e.tag.rsplit('}', 1)[-1] == 'sceneCornerCoord']
    if not corners:
        print(f"sceneCornerCoord not found: {path}", file=sys.stderr)
        raise SystemExit(1)
    for corner in corners:
        values = {child.tag.rsplit('}', 1)[-1]: child.text for child in corner}
        try:
            latitudes.append(float(values['lat']))
            longitudes.append(float(values['lon']))
        except (KeyError, TypeError, ValueError):
            print(f"invalid corner coordinate: {path}", file=sys.stderr)
            raise SystemExit(1)

raw_west, raw_east = min(longitudes), max(longitudes)
raw_south, raw_north = min(latitudes), max(latitudes)
# Expand first, then discard digits after the first decimal place (truncate,
# do not round).  The 0.3-degree margin remains on the order of 0.2-0.4
# degrees after truncation for this LT-1 area.
west = max(-180.0, math.trunc((raw_west - margin) * 10.0) / 10.0)
east = min(180.0, math.trunc((raw_east + margin) * 10.0) / 10.0)
south = max(-90.0, math.trunc((raw_south - margin) * 10.0) / 10.0)
north = min(90.0, math.trunc((raw_north + margin) * 10.0) / 10.0)
print(f"{len(xml_files)}|{raw_west:.8f}|{raw_east:.8f}|{raw_south:.8f}|{raw_north:.8f}|{west:.1f}|{east:.1f}|{south:.1f}|{north:.1f}")
PY
)" || die "failed to read LT-1 meta.xml footprint"
IFS='|' read -r xml_count raw_west raw_east raw_south raw_north west east south north <<< "$bounds_info"

printf '%s\n' \
    "data_dir=$data_path" \
    "meta_xml_count=$xml_count" \
    "margin_degrees=$margin_deg" \
    "raw_west=$raw_west" \
    "raw_east=$raw_east" \
    "raw_south=$raw_south" \
    "raw_north=$raw_north" \
    "west=$west" \
    "east=$east" \
    "south=$south" \
    "north=$north" \
    "make_dem_command=make_dem.csh $west $east $south $north $resolution" > "$region_file"

echo "========================================================================"
echo "LT-1 Run 2.1 Prepare DEM from complete XML footprint"
echo "Mode:       $([[ "$formal" -eq 1 ]] && echo FORMAL || echo PREVIEW)"
echo "Data:       $data_path"
echo "meta.xml:   $xml_count"
echo "Raw range:  $raw_west/$raw_east/$raw_south/$raw_north"
echo "DEM region: $west/$east/$south/$north"
echo "DEM output: $dem_path"
echo "Resolution: $resolution (1=SRTM-1s, 2=SRTM-3s)"
echo "========================================================================"

if [[ "$formal" -eq 0 ]]; then
    echo "[PREVIEW] Region saved to $region_file; DEM was not downloaded."
    echo "[NEXT]    $0 1 --margin-deg $margin_deg --resolution $resolution"
    exit 0
fi

[[ ! -e "$dem_path" ]] || die "DEM already exists: $dem_path; move it before rerunning"
log_file="$topo_path/run2.1_make_dem.log"
echo "[START] make_dem.csh $west $east $south $north $resolution"
if ! (cd "$topo_path" && make_dem.csh "$west" "$east" "$south" "$north" "$resolution" > "$log_file" 2>&1); then
    cat "$log_file" >&2
    die "make_dem.csh failed; inspect $log_file"
fi
cat "$log_file"
[[ -s "$dem_path" ]] || die "make_dem.csh finished but $dem_path is missing or empty"
echo "[SUCCESS] DEM created: $dem_path"
echo "[NEXT]    ./run2.2_geo_to_radar_region_LT1.sh --master 20250423 --roi roi.lonlat"
