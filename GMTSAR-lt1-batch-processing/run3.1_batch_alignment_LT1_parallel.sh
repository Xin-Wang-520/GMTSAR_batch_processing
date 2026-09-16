#!/usr/bin/env bash
# Run 3.1: crop every LT-1 raw SLC first, then align secondaries in parallel.
# Preview is the default. Add positional argument 1 to run formally.
set -euo pipefail

die() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Run 3.1: LT-1 parallel crop-first SLC alignment

Usage:
  run3.1_batch_alignment_LT1_parallel.sh --master YYYYMMDD
  run3.1_batch_alignment_LT1_parallel.sh 1 --master YYYYMMDD
  run3.1_batch_alignment_LT1_parallel.sh [1] --master YYYYMMDD [--input FILE] [--config FILE] [--jobs N]

Examples:
  ./run3.1_batch_alignment_LT1_parallel.sh --master 20250423
  ./run3.1_batch_alignment_LT1_parallel.sh 1 --master 20250423 --jobs 4

Default parallel jobs: 4. Cropping is sequential; secondary alignment is parallel.
Each secondary has an isolated working directory and a separate log.
Stop any other alignment/interferometry run using SLC/ before formal mode.

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
jobs=4

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
        --jobs)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--jobs requires a positive integer"
            jobs="$2"
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
awk 'seen[$0]++ {exit 1}' "$scene_list" || die "duplicate acquisitions in $input_file"
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

for command_name in cut_slc SAT_baseline xcorr fitoffset.csh resamp xargs; do
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
echo "LT-1 Run 3.1 parallel crop-first SLC alignment"
echo "Mode:                $([[ "$formal" -eq 1 ]] && echo FORMAL || echo PREVIEW)"
echo "Working dir:         $root_dir"
echo "Master:              $master_stem"
echo "Input list:          $input_file"
echo "Acquisitions:        $scene_count"
echo "Config:              $config_file"
echo "proc_stage:          $proc_stage"
echo "region_cut:          $region_cut"
echo "Cropped dimensions:  ${expected_x} x ${expected_y}"
echo "Parallel jobs:       $jobs"
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
    log_file="$root_dir/run3.1_parallel_alignment_${master_date}.log"
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
    echo "[NEXT]    $0 1 --master $master_date --input $input_file --config $config_file --jobs $jobs"
    exit 0
fi

# Each worker reads the same immutable cropped master, but has private PRMs,
# correlation data, fitoffset temporary files and resampling outputs.
log_dir="$(mktemp -d "$root_dir/run3.1_parallel_logs.XXXXXX")"
work_root="$(mktemp -d "$slc_dir/run3.1_parallel.XXXXXX")"
echo "[LOGS] $log_dir" | tee -a "$log_file"
exec 3>&1

align_one() {
    set -euo pipefail
    aligned="$1"
    job_dir="$work_root/$aligned"
    mkdir "$job_dir"
    # The worker shell is launched independently, so errexit remains active.
    # Always remove this worker's temporary files; diagnostic logs stay outside.
    trap 'rc=$?; if [[ $rc -ne 0 ]]; then echo "[FAILED] $aligned (log: $log_dir/$aligned.log)" >&3; fi; cd "$root_dir"; rm -rf -- "$job_dir"' EXIT
    exec > "$log_dir/$aligned.log" 2>&1
    cd "$job_dir"
    for stem in "$master_stem" "$aligned"; do
        cp "$slc_dir/$stem.PRM" "$stem.PRM"
        ln -s "$slc_dir/$stem.SLC" "$stem.SLC"
        ln -s "$slc_dir/$stem.LED" "$stem.LED"
    done
    cp "$aligned.PRM" "$aligned.PRM0"
    echo "[BASELINE] $aligned -> $master_stem"
    SAT_baseline "$master_stem.PRM" "$aligned.PRM0" > baseline.params
    cat baseline.params >> "$aligned.PRM"
    echo "[XCORR] $aligned"
    xcorr "$master_stem.PRM" "$aligned.PRM" -xsearch 128 -ysearch 128 -nx 20 -ny 50
    [[ -s freq_xcorr.dat ]] || exit 20
    fitoffset.csh 3 3 freq_xcorr.dat 18 > fit.params
    # Reject a nominally successful fit that did not emit all eight fields.
    awk '
        $2=="=" && $3 ~ /^[-+]?[0-9]*[.]?[0-9]+([eE][-+]?[0-9]+)?$/ {
            if ($1 ~ /^(rshift|ashift|sub_int_r|sub_int_a|stretch_r|stretch_a|a_stretch_r|a_stretch_a)$/) seen[$1]=1
        }
        END {for (k in seen) n++; exit(n!=8)}
    ' fit.params || exit 21
    cat fit.params >> "$aligned.PRM"
    echo "[RESAMP] $aligned"
    resamp "$master_stem.PRM" "$aligned.PRM" "$aligned.PRMresamp" "$aligned.SLCresamp" 4
    [[ -s "$aligned.PRMresamp" && -s "$aligned.SLCresamp" ]] || exit 22
    xdim="$(awk '$1=="num_rng_bins" {print $3; exit}' "$aligned.PRMresamp")"
    ydim="$(awk '$1=="num_lines" {print $3; exit}' "$aligned.PRMresamp")"
    actual_bytes="$(wc -c < "$aligned.SLCresamp" | awk '{print $1}')"
    [[ "$xdim" -eq "$expected_x" && "$ydim" -eq "$expected_y" && "$actual_bytes" -eq $((expected_x*expected_y*4)) ]] || exit 23
    cp "$aligned.PRM0" "$slc_dir/$aligned.PRM0"
    cp freq_xcorr.dat "$slc_dir/xcorr_${master_stem}_${aligned}.dat0"
    mv "$aligned.SLCresamp" "$slc_dir/$aligned.SLC"
    mv "$aligned.PRMresamp" "$slc_dir/$aligned.PRM"
    touch "$log_dir/$aligned.done"
    echo "[DONE] $aligned"
    echo "[DONE] $aligned" >&3
}
export -f align_one
export root_dir slc_dir master_stem expected_x expected_y work_root log_dir
echo "[START] Aligning $((scene_count-1)) secondaries with $jobs parallel jobs" | tee -a "$log_file"
set +e
awk -v master="$master_stem" '$0!=master' "$scene_list" |
    xargs -n 1 -P "$jobs" bash -c 'align_one "$1"' _
parallel_status=${PIPESTATUS[1]}
set -e
rm -rf -- "$work_root"
failed=0
while IFS= read -r stem; do
    [[ "$stem" != "$master_stem" ]] || continue
    if [[ -f "$log_dir/$stem.done" ]]; then
        echo "[DONE] $stem" >> "$log_file"
    else
        echo "[FAILED] $stem (log: $log_dir/$stem.log)" | tee -a "$log_file"
        failed=$((failed+1))
    fi
done < "$scene_list"
[[ "$parallel_status" -eq 0 && "$failed" -eq 0 ]] || die "$failed alignment(s) incomplete; see $log_dir"

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
