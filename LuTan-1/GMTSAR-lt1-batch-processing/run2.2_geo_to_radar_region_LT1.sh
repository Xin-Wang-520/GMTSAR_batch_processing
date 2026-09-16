#!/usr/bin/env bash
# Run 2.2: convert a geographic ROI to an LT-1 radar-coordinate region_cut.
# ROI format: longitude latitude, one point per line. Elevation is sampled
# automatically from topo/dem.grd with GMT grdtrack.
# Preview leaves config.LT1.txt unchanged; formal mode updates it and saves a
# timestamped backup under archive_run2.2/.
set -euo pipefail

usage() {
    cat <<'HELP'
Run 2.2: geographic ROI -> LT-1 radar region_cut

Usage:
  run2.2_geo_to_radar_region_LT1.sh [1] --master DATE (--roi FILE | --upper-left LON LAT --lower-right LON LAT) [options]

Options:
  1                 Formal mode; update config.LT1.txt. Omit for preview.
  --master DATE     Master date, for example 20250423.
  --roi FILE        longitude latitude, one point per line.
  --upper-left      Upper-left corner: longitude latitude.
  --lower-right     Lower-right corner: longitude latitude.
  --margin PIXELS   Radar-pixel padding (default: 500).
  --config FILE     Config file (default: config.LT1.txt).
  --output FILE     Converted points (default: run2.2_roi.ratll).

Output columns in .ratll:
  range_pixel azimuth_pixel DEM_elevation_m latitude longitude
HELP
}

die() { echo "[ERROR] $*" >&2; exit 1; }

formal=0
master_date=""
roi_file=""
ul_lon=""; ul_lat=""; lr_lon=""; lr_lat=""
margin=500
config_file="config.LT1.txt"
output_file="run2.2_roi.ratll"

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        1) formal=1; shift ;;
        --master) [[ $# -ge 2 ]] || die "--master requires a date"; master_date="$2"; shift 2 ;;
        --roi) [[ $# -ge 2 ]] || die "--roi requires a file"; roi_file="$2"; shift 2 ;;
        --upper-left|--ul) [[ $# -ge 3 ]] || die "$1 requires longitude and latitude"; ul_lon="$2"; ul_lat="$3"; shift 3 ;;
        --lower-right|--lr) [[ $# -ge 3 ]] || die "$1 requires longitude and latitude"; lr_lon="$2"; lr_lat="$3"; shift 3 ;;
        --margin) [[ $# -ge 2 ]] || die "--margin requires pixels"; margin="$2"; shift 2 ;;
        --config) [[ $# -ge 2 ]] || die "--config requires a file"; config_file="$2"; shift 2 ;;
        --output) [[ $# -ge 2 ]] || die "--output requires a file"; output_file="$2"; shift 2 ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ "$master_date" =~ ^[0-9]{8}$ ]] || die "--master must be YYYYMMDD"
if [[ -n "$roi_file" ]]; then
    [[ -f "$roi_file" ]] || die "ROI file not found: $roi_file"
    [[ -z "$ul_lon$ul_lat$lr_lon$lr_lat" ]] || die "use either --roi or corner options, not both"
else
    [[ -n "$ul_lon$ul_lat$lr_lon$lr_lat" ]] || die "provide --roi or both --upper-left and --lower-right"
    [[ -n "$ul_lon" && -n "$ul_lat" && -n "$lr_lon" && -n "$lr_lat" ]] || die "both corner options require longitude and latitude"
fi
[[ "$margin" =~ ^[0-9]+$ ]] || die "--margin must be a non-negative integer"
[[ -f "$config_file" ]] || die "configuration file not found: $config_file"
command -v SAT_llt2rat >/dev/null 2>&1 || die "SAT_llt2rat was not found in PATH"
if command -v grdtrack >/dev/null 2>&1; then
    GRDTRACK=(grdtrack)
elif command -v gmt >/dev/null 2>&1; then
    GRDTRACK=(gmt grdtrack)
else
    die "neither grdtrack nor gmt was found in PATH"
fi

root_dir="$(pwd -P)"
raw_dir="$root_dir/raw"
master_stem="LT1_${master_date}"
prm_file="$raw_dir/${master_stem}.PRM"
led_file="$raw_dir/${master_stem}.LED"
dem_file="$root_dir/topo/dem.grd"
[[ -s "$prm_file" ]] || die "missing master PRM: $prm_file; complete Run 1.2.2 first"
[[ -s "$led_file" ]] || die "missing master LED: $led_file; complete Run 1.2.2 first"
[[ -s "$dem_file" ]] || die "missing DEM: $dem_file; run Run 2.1 first"

num_rng_bins="$(awk '$1=="num_rng_bins" {v=$3} END {print v}' "$prm_file")"
num_lines="$(awk '$1=="num_lines" {v=$3} END {print v}' "$prm_file")"
[[ "$num_rng_bins" =~ ^[0-9]+$ ]] || die "cannot read num_rng_bins from $prm_file"
[[ "$num_lines" =~ ^[0-9]+$ ]] || die "cannot read num_lines from $prm_file"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/run2.2_lt1.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
normalized_lonlat="$tmp_dir/roi.lonlat"

if [[ -z "$roi_file" ]]; then
    # Convert upper-left/lower-right rectangle corners into four boundary points.
    input_roi="$tmp_dir/roi.corners"
    printf '%s %s\n%s %s\n%s %s\n%s %s\n' \
        "$ul_lon" "$ul_lat" "$ul_lon" "$lr_lat" \
        "$lr_lon" "$ul_lat" "$lr_lon" "$lr_lat" > "$input_roi"
    awk -v west="$ul_lon" -v north="$ul_lat" -v east="$lr_lon" -v south="$lr_lat" \
        'BEGIN { exit !(west < east && south < north) }' \
        || die "rectangle requires upper-left west/north and lower-right east/south"
else
    input_roi="$roi_file"
fi

awk '
    /^[[:space:]]*#/ || NF==0 { next }
    NF < 2 { printf("invalid ROI line %d\n", NR) > "/dev/stderr"; bad=1; next }
    {
        if ($1 !~ /^[-+]?[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$/ || $2 !~ /^[-+]?[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$/ || $1 < -180 || $1 > 180 || $2 < -90 || $2 > 90) {
            printf("invalid longitude/latitude on ROI line %d\n", NR) > "/dev/stderr"; bad=1; next
        }
        print $1, $2; count++
    }
    END { if (bad || count < 2) exit 1 }
' "$input_roi" > "$normalized_lonlat" || die "ROI must contain at least two valid lon/lat points"

input_count="$(wc -l < "$normalized_lonlat" | awk '{print $1}')"
dem_points="$tmp_dir/roi.with_dem"
"${GRDTRACK[@]}" "$normalized_lonlat" -G"$dem_file" > "$dem_points" || die "grdtrack failed for $input_roi"
dem_count="$(awk 'NF >= 3 && $3 !~ /^NaN$/ {n++} END {print n+0}' "$dem_points")"
[[ "$dem_count" -eq "$input_count" ]] || die "DEM has no elevation for $((input_count-dem_count)) ROI point(s)"

ratll_tmp="$tmp_dir/roi.ratll"
(cd "$raw_dir" && SAT_llt2rat "${master_stem}.PRM" 1 < "$dem_points" > "$ratll_tmp") || die "SAT_llt2rat failed"
output_count="$(awk 'NF >= 5 {n++} END {print n+0}' "$ratll_tmp")"
[[ "$output_count" -eq "$input_count" ]] || die "only $output_count/$input_count ROI points converted; check coverage/elevation"

raw_radar_region="$(awk '
    NF >= 2 {
        r=$1; a=$2
        if (!seen++) { rmin=rmax=r; amin=amax=a }
        else { if (r<rmin) rmin=r; if (r>rmax) rmax=r; if (a<amin) amin=a; if (a>amax) amax=a }
    }
    END {
        if (!seen) exit 1
        printf "%.3f/%.3f/%.3f/%.3f", rmin,rmax,amin,amax
    }
' "$ratll_tmp")" || die "cannot calculate the raw radar ROI bounds"

region_cut="$(awk -v margin="$margin" -v nr="$num_rng_bins" -v nl="$num_lines" '
    NF >= 2 {
        r=$1; a=$2
        if (!seen++) { rmin=rmax=r; amin=amax=a }
        else { if (r<rmin) rmin=r; if (r>rmax) rmax=r; if (a<amin) amin=a; if (a>amax) amax=a }
    }
    END {
        if (!seen) exit 1
        r0=int(rmin-margin); if (r0<0) r0=0
        r1=int(rmax+margin+0.999999); if (r1>nr) r1=nr
        a0=int(amin-margin); if (a0<0) a0=0
        a1=int(amax+margin+0.999999); if (a1>nl) a1=nl
        if (r1<=r0 || a1<=a0) exit 1
        printf "%d/%d/%d/%d", r0,r1,a0,a1
    }
' "$ratll_tmp")" || die "ROI is outside the master radar coverage"

if [[ "$output_file" = /* ]]; then
    output_path="$output_file"
else
    output_path="$root_dir/$output_file"
fi
cp "$ratll_tmp" "$output_path"
report_path="$root_dir/run2.2_region_report.txt"
printf '%s\n' \
    "master=$master_stem" \
    "full_radar_region=0/$num_rng_bins/0/$num_lines" \
    "raw_roi_radar_region=$raw_radar_region" \
    "padding_pixels=$margin" \
    "region_cut=$region_cut" \
    "ratll=$output_path" > "$report_path"

echo "========================================================================"
echo "LT-1 Run 2.2 Geographic ROI -> radar region_cut"
echo "Mode:           $([[ "$formal" -eq 1 ]] && echo FORMAL || echo PREVIEW)"
echo "Master PRM:     $prm_file"
echo "ROI points:     $input_count"
if [[ -z "$roi_file" ]]; then
    echo "Rectangle UL:   $ul_lon $ul_lat"
    echo "Rectangle LR:   $lr_lon $lr_lat"
fi
echo "DEM source:     $dem_file"
echo "Radar output:   $output_path"
echo "Full radar data: range 0..$num_rng_bins, azimuth 0..$num_lines"
echo "Full radar region: 0/$num_rng_bins/0/$num_lines"
echo "Raw radar ROI:  $raw_radar_region"
echo "Padding:        $margin pixels"
echo "region_cut:     $region_cut"
echo "Region report:  $report_path"
echo "========================================================================"

if [[ "$formal" -eq 0 ]]; then
    echo "[PREVIEW] config.LT1.txt was not changed."
    echo "[NEXT]    rerun with positional 1 to update the configuration."
    exit 0
fi

archive_dir="$root_dir/archive_run2.2"
mkdir -p "$archive_dir"
timestamp="$(date +%Y%m%dT%H%M%S)"
config_backup="$archive_dir/$(basename "$config_file").$timestamp.bak"
cp -p "$config_file" "$config_backup"
config_tmp="$tmp_dir/config.updated"
awk -v value="$region_cut" '
    BEGIN { replaced=0 }
    /^[[:space:]]*region_cut[[:space:]]*=/ && !replaced { print "region_cut = " value; replaced=1; next }
    { print }
    END { if (!replaced) print "region_cut = " value }
' "$config_file" > "$config_tmp"
mv "$config_tmp" "$config_file"

echo "[UPDATED] $config_file"
echo "[BACKUP]  $config_backup"
echo "[SUCCESS] region_cut = $region_cut"
echo "[NEXT]    batch_processing.csh LT1 $master_stem data.list 2 $(basename "$config_file")"
