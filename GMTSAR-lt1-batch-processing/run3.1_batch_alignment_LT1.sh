#!/usr/bin/env bash
# Run 3.1: crop every LT-1 raw SLC first, then align only the cropped stack.
# Preview is the default. Add positional argument 1 to run formally.
set -euo pipefail

die() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Run 3.1: LT-1 crop-first SLC alignment

Usage:
  run3.1_batch_alignment_LT1.sh --master YYYYMMDD
  run3.1_batch_alignment_LT1.sh 1 --master YYYYMMDD
  run3.1_batch_alignment_LT1.sh [1] --master YYYYMMDD [--input FILE] [--config FILE]

Examples:
  ./run3.1_batch_alignment_LT1.sh --master 20250423
  ./run3.1_batch_alignment_LT1.sh 1 --master 20250423

Method:
  1. Read region_cut from config.LT1.txt.
  2. Crop every raw/SCENE.PRM + raw/SCENE.SLC into a new SLC/ directory.
  3. Use only cropped PRM/SLC files in SLC/ for SAT_baseline, xcorr,
     fitoffset.csh and resamp.
  4. Keep every final PRM/SLC at the cropped master dimensions.

This does not call the LT1 generic raw-link block in p2p_processing.csh, so a
cropped master PRM cannot be overwritten by raw/MASTER.PRM. region_cut is not
applied a second time after alignment.

Formal mode deletes the previous SLC/ directory and overwrites the alignment
log before rebuilding from raw data. No backup is created.
HELP
}

formal=0
master_date=""
input_file="data.list"
config_file="config.LT1.txt"

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
raw_dir="$root_dir/raw"
slc_dir="$root_dir/SLC"

[[ -s "$input_file" ]] || die "input list not found or empty: $input_file"
[[ -f "$config_file" ]] || die "configuration file not found: $config_file"
[[ -d "$raw_dir" ]] || die "raw directory not found: $raw_dir"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/run3.1_lt1.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
scene_list="$tmp_dir/scenes.list"
awk 'NF && $1 !~ /^#/ {print $1}' "$input_file" > "$scene_list"
scene_count="$(wc -l < "$scene_list" | awk '{print $1}')"
[[ "$scene_count" -ge 2 ]] || die "at least two acquisitions are required"
first_record="$(head -n 1 "$scene_list")"
[[ "$first_record" == "$master_stem" ]] || die "first data.list record is '$first_record', expected '$master_stem'"

proc_stage="$(awk '$1=="proc_stage" && $2=="=" {print $3; exit}' "$config_file")"
region_cut="$(awk '$1=="region_cut" && $2=="=" {print $3; exit}' "$config_file")"
[[ "$proc_stage" == "2" ]] || die "config proc_stage is '${proc_stage:-MISSING}'; expected 2"
[[ "$region_cut" =~ ^[0-9]+/[0-9]+/[0-9]+/[0-9]+$ ]] || die "region_cut is missing or invalid: '${region_cut:-EMPTY}'"

IFS=/ read -r crop_x0 crop_x1 crop_y0 crop_y1 <<< "$region_cut"
(( crop_x0 >= 0 && crop_y0 >= 0 && crop_x1 > crop_x0 && crop_y1 > crop_y0 )) || die "invalid region_cut bounds: $region_cut"
expected_x=$((crop_x1 - crop_x0 + 1))
expected_y=$((crop_y1 - crop_y0 + 1))
expected_x=$((expected_x - expected_x % 4))
expected_y=$((expected_y - expected_y % 4))
(( expected_x > 0 && expected_y > 0 )) || die "region_cut produces an empty image"

for command_name in cut_slc SAT_baseline xcorr fitoffset.csh resamp; do
    command -v "$command_name" >/dev/null 2>&1 || die "$command_name was not found in PATH"
done

while IFS= read -r stem; do
    [[ "$stem" =~ ^LT1_[0-9]{8}$ ]] || die "invalid acquisition name in $input_file: $stem"
    for suffix in PRM SLC LED; do
        [[ -e "$raw_dir/${stem}.${suffix}" ]] || die "missing raw/${stem}.${suffix}"
    done
    raw_x="$(awk '$1=="num_rng_bins" && $2=="=" {printf "%d",$3; exit}' "$raw_dir/${stem}.PRM")"
    raw_y="$(awk '
        $1=="num_valid_az" && $2=="=" {valid=$3}
        $1=="num_patches" && $2=="=" {patches=$3}
        END {printf "%d",valid*patches}
    ' "$raw_dir/${stem}.PRM")"
    (( crop_x1 <= raw_x && crop_y1 <= raw_y )) || die "$stem raw size ${raw_x}x${raw_y} does not contain region_cut $region_cut"
done < "$scene_list"

echo "========================================================================"
echo "LT-1 Run 3.1 crop-first SLC alignment"
echo "Mode:                $([[ "$formal" -eq 1 ]] && echo FORMAL || echo PREVIEW)"
echo "Working dir:         $root_dir"
echo "Master:              $master_stem"
echo "Input list:          $input_file"
echo "Acquisitions:        $scene_count"
echo "Config:              $config_file"
echo "proc_stage:          $proc_stage"
echo "region_cut:          $region_cut"
echo "Cropped dimensions:  ${expected_x} x ${expected_y}"
echo "Input source:        raw/ (cropped once before alignment)"
echo "Alignment workspace: SLC/ (cropped PRM/SLC only)"
echo "Core commands:       SAT_baseline -> xcorr -> fitoffset.csh -> resamp"
echo "========================================================================"

if [[ "$formal" -eq 1 ]]; then
    # Delete only the designated output directory, never a symlink target.
    [[ "$root_dir" != "/" && "$slc_dir" == "$root_dir/SLC" ]] || die "unsafe SLC output path: $slc_dir"
    [[ ! -L "$slc_dir" ]] || die "SLC output directory is a symbolic link: $slc_dir"
    if [[ -e "$slc_dir" ]]; then
        [[ -d "$slc_dir" ]] || die "SLC output path is not a directory: $slc_dir"
        rm -rf -- "$slc_dir"
        echo "[DELETE] Removed previous SLC directory: $slc_dir"
    fi
    mkdir -p "$slc_dir"
    log_file="$root_dir/run3.1_batch_alignment_${master_date}.log"
    rm -f -- "$log_file"
    : > "$log_file"
else
    echo "[PREVIEW] Formal mode deletes the previous SLC/ directory and overwrites the alignment log (no backup)."
    echo "[PREVIEW] Scene crop plan:"
fi

# Crop every raw scene before correlation. Some cut_slc versions return 1
# after a successful write, so the generated products are validated directly.
while IFS= read -r stem; do
    if [[ "$formal" -eq 0 ]]; then
        echo "  $stem -> SLC/${stem}.{PRM,SLC} (${expected_x}x${expected_y})"
        continue
    fi

    echo "[CROP] $stem -> ${expected_x}x${expected_y}" | tee -a "$log_file"
    set +e
    (
        cd "$raw_dir"
        cut_slc "${stem}.PRM" "$slc_dir/$stem" "$region_cut"
    ) 2>&1 | tee -a "$log_file"
    crop_status=${PIPESTATUS[0]}
    set -e
    if [[ "$crop_status" -ne 0 && "$crop_status" -ne 1 ]]; then
        die "cut_slc failed for $stem with status $crop_status"
    fi
    [[ -s "$slc_dir/${stem}.PRM" && -s "$slc_dir/${stem}.SLC" ]] || die "cut_slc did not generate PRM/SLC for $stem"

    xdim="$(awk '$1=="num_rng_bins" && $2=="=" {printf "%d",$3; exit}' "$slc_dir/${stem}.PRM")"
    ydim="$(awk '$1=="num_lines" && $2=="=" {printf "%d",$3; exit}' "$slc_dir/${stem}.PRM")"
    actual_bytes="$(wc -c < "$slc_dir/${stem}.SLC" | awk '{print $1}')"
    expected_bytes=$((xdim * ydim * 4))
    [[ "$xdim" -eq "$expected_x" && "$ydim" -eq "$expected_y" ]] || die "$stem crop is ${xdim}x${ydim}; expected ${expected_x}x${expected_y}"
    [[ "$actual_bytes" -eq "$expected_bytes" ]] || die "$stem cropped PRM/SLC mismatch: expected $expected_bytes bytes, found $actual_bytes"
    ln -s "../raw/${stem}.LED" "$slc_dir/${stem}.LED"
done < "$scene_list"

if [[ "$formal" -eq 0 ]]; then
    echo "[PREVIEW] No files were modified and no alignment was started."
    echo "[NEXT]    $0 1 --master $master_date --input $input_file --config $config_file"
    exit 0
fi

# Align every freshly cropped secondary directly to the cropped master. The
# raw-link and post-alignment crop sections of p2p_processing.csh are bypassed.
while IFS= read -r aligned; do
    [[ "$aligned" != "$master_stem" ]] || continue
    echo "[ALIGN] $aligned -> $master_stem" | tee -a "$log_file"
    (
        cd "$slc_dir"
        cp "${aligned}.PRM" "${aligned}.PRM0"

        baseline_tmp=".$aligned.SAT_baseline.tmp"
        set +e
        SAT_baseline "${master_stem}.PRM" "${aligned}.PRM0" > "$baseline_tmp" 2>> "$log_file"
        baseline_status=$?
        set -e
        [[ "$baseline_status" -eq 0 ]] || exit "$baseline_status"
        cat "$baseline_tmp" >> "$log_file"
        cat "$baseline_tmp" >> "${aligned}.PRM"
        rm -f "$baseline_tmp"

        set +e
        xcorr "${master_stem}.PRM" "${aligned}.PRM" -xsearch 128 -ysearch 128 -nx 20 -ny 50 2>&1 | tee -a "$log_file"
        xcorr_status=${PIPESTATUS[0]}
        set -e
        [[ "$xcorr_status" -eq 0 && -s freq_xcorr.dat ]] || exit 20

        fit_tmp=".$aligned.fitoffset.tmp"
        set +e
        fitoffset.csh 3 3 freq_xcorr.dat 18 > "$fit_tmp" 2>> "$log_file"
        fit_status=$?
        set -e
        [[ "$fit_status" -eq 0 && -s "$fit_tmp" ]] || exit 21
        cat "$fit_tmp" >> "$log_file"
        cat "$fit_tmp" >> "${aligned}.PRM"
        rm -f "$fit_tmp"
        cp freq_xcorr.dat "xcorr_${master_stem}_${aligned}.dat0"

        set +e
        resamp "${master_stem}.PRM" "${aligned}.PRM" "${aligned}.PRMresamp" "${aligned}.SLCresamp" 4 2>&1 | tee -a "$log_file"
        resamp_status=${PIPESTATUS[0]}
        set -e
        [[ "$resamp_status" -eq 0 && -s "${aligned}.PRMresamp" && -s "${aligned}.SLCresamp" ]] || exit 22
        mv "${aligned}.PRMresamp" "${aligned}.PRM"
        mv "${aligned}.SLCresamp" "${aligned}.SLC"
    ) || die "alignment failed for $aligned; inspect $log_file"

    xdim="$(awk '$1=="num_rng_bins" && $2=="=" {printf "%d",$3; exit}' "$slc_dir/${aligned}.PRM")"
    ydim="$(awk '$1=="num_lines" && $2=="=" {printf "%d",$3; exit}' "$slc_dir/${aligned}.PRM")"
    actual_bytes="$(wc -c < "$slc_dir/${aligned}.SLC" | awk '{print $1}')"
    expected_bytes=$((expected_x * expected_y * 4))
    [[ "$xdim" -eq "$expected_x" && "$ydim" -eq "$expected_y" && "$actual_bytes" -eq "$expected_bytes" ]] || die "$aligned output failed cropped-geometry validation"
    echo "[DONE] $aligned ${xdim}x${ydim}" | tee -a "$log_file"
done < "$scene_list"

checked_count=0
while IFS= read -r stem; do
    prm="$slc_dir/${stem}.PRM"
    slc="$slc_dir/${stem}.SLC"
    [[ -s "$prm" && -s "$slc" && -e "$slc_dir/${stem}.LED" ]] || die "incomplete final products for $stem"
    xdim="$(awk '$1=="num_rng_bins" && $2=="=" {printf "%d",$3; exit}' "$prm")"
    ydim="$(awk '$1=="num_lines" && $2=="=" {printf "%d",$3; exit}' "$prm")"
    slc_name="$(awk '$1=="SLC_file" && $2=="=" {print $3; exit}' "$prm")"
    actual_bytes="$(wc -c < "$slc" | awk '{print $1}')"
    expected_bytes=$((expected_x * expected_y * 4))
    [[ "$xdim" -eq "$expected_x" && "$ydim" -eq "$expected_y" ]] || die "$stem final PRM is ${xdim}x${ydim}; expected ${expected_x}x${expected_y}"
    [[ "$actual_bytes" -eq "$expected_bytes" ]] || die "$stem final SLC has $actual_bytes bytes; expected $expected_bytes"
    [[ "$slc_name" == "${stem}.SLC" ]] || die "$stem PRM points to unexpected SLC_file '$slc_name'"
    checked_count=$((checked_count + 1))
done < "$scene_list"

echo "[SUCCESS] Run 3.1 aligned $checked_count cropped scenes at ${expected_x}x${expected_y}."
echo "[CHECK]   Every final PRM matches its SLC; raw PRM/SLC files were not linked into the alignment workspace."
echo "[NEXT]    ./run3.2_dem_ra_LT1.sh 1 --master $master_date"
