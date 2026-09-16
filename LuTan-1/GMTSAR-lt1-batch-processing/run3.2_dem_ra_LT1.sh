#!/usr/bin/env bash
# Run 3.2: execute GMTSAR batch-processing step 3 (DEM back-geocoding).
# Preview is the default. Add positional argument 1 to run formally.
# The master date must be supplied explicitly with --master YYYYMMDD.
set -euo pipefail

usage() {
    cat <<'HELP'
Run 3.2: LT-1 DEM back-geocoding and topo_ra generation (step 3)

Usage:
  run3.2_dem_ra_LT1.sh --master YYYYMMDD
  run3.2_dem_ra_LT1.sh 1 --master YYYYMMDD
  run3.2_dem_ra_LT1.sh [1] --master YYYYMMDD [--input FILE] [--config FILE]

Examples:
  ./run3.2_dem_ra_LT1.sh --master 20250423
  ./run3.2_dem_ra_LT1.sh 1 --master 20250423

Equivalent direct GMTSAR command:
  batch_processing.csh LT1 LT1_20250423 data.list 3 config.LT1.txt

Required inputs:
  topo/dem.grd                 Geographic DEM made by Run 2.1
  SLC/LT1_YYYYMMDD.PRM         Cropped master PRM made by Run 3.1
  SLC/LT1_YYYYMMDD.SLC         Cropped master SLC made by Run 3.1
  raw/LT1_YYYYMMDD.LED         Master orbit made by Run 1.2.3

Main outputs:
  topo/topo_ra.grd             DEM in master radar coordinates
  topo/topo_shift.grd          Shift-corrected topo_ra when shift_topo=1
  SLC/amp-LT1_YYYYMMDD.grd     Master amplitude used by offset_topo

Before formal processing, existing files in topo/ other than dem.grd are
copied to archive_run3.2/TIMESTAMP/. GMTSAR then cleans the old topo products.
The proc_stage value in config.LT1.txt does not need to be changed: the step-3
batch command creates a temporary configuration with proc_stage=3.
HELP
}

die() { echo "[ERROR] $*" >&2; exit 1; }

formal=0
master_date=""
input_file="data.list"
config_file="config.LT1.txt"

# Show complete instructions when the script is run without arguments.
if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        1) formal=1; shift ;;
        --master)
            [[ $# -ge 2 ]] || die "--master requires YYYYMMDD"
            master_date="$2"
            shift 2
            ;;
        --input)
            [[ $# -ge 2 ]] || die "--input requires a file"
            input_file="$2"
            shift 2
            ;;
        --config)
            [[ $# -ge 2 ]] || die "--config requires a file"
            config_file="$2"
            shift 2
            ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ "$master_date" =~ ^[0-9]{8}$ ]] || die "--master must be YYYYMMDD"
master_stem="LT1_${master_date}"
root_dir="$(pwd -P)"
topo_dir="$root_dir/topo"
slc_dir="$root_dir/SLC"
raw_dir="$root_dir/raw"

[[ -f "$input_file" ]] || die "input list not found: $input_file"
[[ -f "$config_file" ]] || die "configuration file not found: $config_file"
[[ -f "$topo_dir/dem.grd" ]] || die "DEM not found: $topo_dir/dem.grd"
[[ -f "$slc_dir/${master_stem}.PRM" ]] || die "cropped master PRM not found: $slc_dir/${master_stem}.PRM"
[[ -e "$slc_dir/${master_stem}.SLC" ]] || die "cropped master SLC not found: $slc_dir/${master_stem}.SLC"
[[ -f "$raw_dir/${master_stem}.PRM" ]] || die "raw master PRM not found: $raw_dir/${master_stem}.PRM"
[[ -e "$raw_dir/${master_stem}.LED" ]] || die "master LED not found: $raw_dir/${master_stem}.LED"

first_record="$(awk 'NF && $1 !~ /^#/ {print $1; exit}' "$input_file")"
[[ "$first_record" == "$master_stem" ]] || die "first data.list record is '$first_record', expected '$master_stem'"

batch_cmd="$(command -v batch_processing.csh || true)"
[[ -n "$batch_cmd" ]] || die "batch_processing.csh was not found in PATH"
command -v dem2topo_ra.csh >/dev/null 2>&1 || die "dem2topo_ra.csh was not found in PATH"

config_value() {
    awk -v key="$1" '$1==key && $2=="=" {print $3; exit}' "$config_file"
}

proc_stage="$(config_value proc_stage)"
topo_phase="$(config_value topo_phase)"
topo_interp_mode="$(config_value topo_interp_mode)"
shift_topo="$(config_value shift_topo)"
region_cut="$(config_value region_cut)"
num_rng_bins="$(awk '$1=="num_rng_bins" {print $3; exit}' "$slc_dir/${master_stem}.PRM")"
num_lines="$(awk '$1=="num_lines" {print $3; exit}' "$slc_dir/${master_stem}.PRM")"

[[ "$topo_phase" == "1" ]] || die "topo_phase is '${topo_phase:-MISSING}'; set topo_phase = 1 to generate topo_ra"
[[ "$shift_topo" == "0" || "$shift_topo" == "1" ]] || die "shift_topo must be 0 or 1"

if [[ "$shift_topo" == "1" ]]; then
    command -v slc2amp.csh >/dev/null 2>&1 || die "slc2amp.csh was not found in PATH"
    command -v offset_topo >/dev/null 2>&1 || die "offset_topo was not found in PATH"
    command -v gmt >/dev/null 2>&1 || die "GMT was not found in PATH"
fi

echo "========================================================================"
echo "LT-1 Run 3.2 DEM back-geocoding (step 3)"
echo "Mode:               $([[ "$formal" -eq 1 ]] && echo FORMAL || echo PREVIEW)"
echo "Working dir:        $root_dir"
echo "Master:             $master_stem"
echo "Cropped master PRM: $slc_dir/${master_stem}.PRM"
echo "Cropped radar size: ${num_rng_bins:-UNKNOWN} x ${num_lines:-UNKNOWN}"
echo "Master orbit:       $raw_dir/${master_stem}.LED"
echo "DEM:                $topo_dir/dem.grd"
echo "Config:             $config_file"
echo "proc_stage:         ${proc_stage:-MISSING} (temporarily overridden to 3)"
echo "region_cut:         ${region_cut:-FULL IMAGE} (already applied by Run 3.1)"
echo "topo_phase:         $topo_phase"
echo "topo_interp_mode:   ${topo_interp_mode:-0}"
echo "shift_topo:         $shift_topo"
echo "Command:            batch_processing.csh LT1 $master_stem $input_file 3 $config_file"
echo "Expected topo:      $topo_dir/topo_ra.grd"
if [[ "$shift_topo" == "1" ]]; then
    echo "Expected shifted:   $topo_dir/topo_shift.grd"
fi
echo "========================================================================"

if [[ "$formal" -eq 0 ]]; then
    echo "[PREVIEW] No processing was started."
    echo "[NEXT]    $0 1 --master $master_date --input $input_file --config $config_file"
    exit 0
fi

# Preserve previous topo products because GMTSAR cleanup.csh deletes everything
# in topo/ except dem.grd before rebuilding topo_ra.
timestamp="$(date +%Y%m%dT%H%M%S)"
archive_dir="$root_dir/archive_run3.2/$timestamp"
archive_count=0
while IFS= read -r -d '' item; do
    mkdir -p "$archive_dir"
    cp -a "$item" "$archive_dir/"
    archive_count=$((archive_count + 1))
done < <(find "$topo_dir" -mindepth 1 -maxdepth 1 ! -name dem.grd -print0)

if [[ "$archive_count" -gt 0 ]]; then
    echo "[ARCHIVE] Copied $archive_count existing topo item(s) to $archive_dir"
else
    echo "[ARCHIVE] No previous topo products required backup."
fi

log_file="$root_dir/run3.2_dem_ra_${master_date}.log"
echo "[START]   step 3 back-geocoding; log: $log_file"
set +e
"$batch_cmd" LT1 "$master_stem" "$input_file" 3 "$config_file" 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
set -e

[[ "$status" -eq 0 ]] || die "batch_processing.csh exited with status $status; inspect $log_file"
[[ -s "$topo_dir/topo_ra.grd" ]] || die "topo_ra.grd was not generated; inspect $log_file"
if [[ "$shift_topo" == "1" ]]; then
    [[ -s "$topo_dir/topo_shift.grd" ]] || die "topo_shift.grd was not generated; inspect $log_file"
fi

echo "[SUCCESS] Run 3.2 generated $topo_dir/topo_ra.grd"
if [[ "$shift_topo" == "1" ]]; then
    echo "[SUCCESS] Shift-corrected topo: $topo_dir/topo_shift.grd"
fi
echo "[NEXT]    Prepare an interferogram-pair list before GMTSAR batch step 4."
