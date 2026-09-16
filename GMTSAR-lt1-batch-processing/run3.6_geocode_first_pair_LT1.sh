#!/usr/bin/env bash
# Geocode the earliest interferogram's wrapped filtered phase and export KMZ.
# Run from Ascending/ or Descending/. No arguments prints help.
# Preview: ./run3.6_geocode_first_pair_LT1.sh
# Formal:  ./run3.6_geocode_first_pair_LT1.sh 1
# Select:  ./run3.6_geocode_first_pair_LT1.sh 1 --pair 2025000_2025028
# The wavelength argument controls geographic sampling: 100 / 4 = 25 meters.
set -euo pipefail
die() { echo "[ERROR] $*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Run 3.6: geocode the first LT-1 interferogram and export KMZ

Usage:
  ./run3.6_geocode_first_pair_LT1.sh
  ./run3.6_geocode_first_pair_LT1.sh 1
  ./run3.6_geocode_first_pair_LT1.sh [1] [--pair YYYYDDD_YYYYDDD] [--wavelength 100]

Default: preview the earliest date-named directory in intf_all/.
Add 1 for formal execution. --pair selects a specific directory instead.
Inputs: topo/trans.dat, intf_all/PAIR/phasefilt.grd and phase.cpt.
Commands in an isolated temporary directory inside the selected pair:
  proj_ra2ll.csh trans.dat phasefilt.grd phasefilt_ll.grd 100
  grd2kml.csh phasefilt_ll phase.cpt
  zip -j phasefilt_ll.kmz phasefilt_ll.kml phasefilt_ll.png

Results are placed in intf_all/PAIR/ (same-named outputs are replaced).
The temporary directory is removed. The original radar grids are unchanged.
This exports wrapped phase, not unwrapped displacement.
HELP
}

formal=0
pair=""
wavelength=100
while [[ $# -gt 0 ]]; do
    case "$1" in
        1) formal=1; shift ;;
        --pair) [[ $# -ge 2 ]] || die "--pair requires a directory name"; pair="$2"; shift 2 ;;
        --wavelength) [[ $# -ge 2 ]] || die "--wavelength requires a number"; wavelength="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done
[[ "$wavelength" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid wavelength: $wavelength"
awk -v value="$wavelength" 'BEGIN {exit !(value>0)}' || die "wavelength must be positive"
root_dir="$(pwd -P)"
[[ -d "$root_dir/intf_all" ]] || die "intf_all/ not found; run from Ascending/ or Descending/"
if [[ -z "$pair" ]]; then
    # Zero-padded GMT year/day IDs sort chronologically. Do not silently skip
    # a failed earliest pair: report missing inputs so the user can inspect it.
    pair="$(
        for directory in "$root_dir"/intf_all/*; do
            [[ -d "$directory" ]] || continue
            name="${directory##*/}"
            if [[ "$name" =~ ^[0-9]{7}_[0-9]{7}$ || "$name" =~ ^[0-9]{8}_[0-9]{8}$ ]]; then
                printf '%s\n' "$name"
            fi
        done | LC_ALL=C sort | sed -n '1p'
    )"
fi
[[ "$pair" =~ ^[0-9]{7}_[0-9]{7}$ || "$pair" =~ ^[0-9]{8}_[0-9]{8}$ ]] || die "no valid pair selected: $pair"
pair_dir="$root_dir/intf_all/$pair"
[[ -d "$pair_dir" ]] || die "pair directory not found: $pair_dir"
for input in "$root_dir/topo/trans.dat" "$pair_dir/phasefilt.grd" "$pair_dir/phase.cpt"; do
    [[ -s "$input" ]] || die "missing or empty input: $input"
done
if [[ -e "$pair_dir/trans.dat" && ! -L "$pair_dir/trans.dat" ]]; then
    die "existing trans.dat is not a symbolic link: $pair_dir/trans.dat"
fi
echo "========================================================================"
echo "Run 3.6: wrapped phase geocoding and KMZ"
echo "Mode:       $([[ $formal -eq 1 ]] && echo FORMAL || echo PREVIEW)"
echo "Pair:       $pair"
echo "Lookup:     $root_dir/topo/trans.dat"
echo "Input:      $pair_dir/phasefilt.grd"
echo "Wavelength: $wavelength (geographic sampling approximately $(awk -v w="$wavelength" 'BEGIN {print w/4}') m)"
echo "Output:     $pair_dir/phasefilt_ll.{grd,png,kml,kmz}"
echo "Command:    proj_ra2ll.csh trans.dat phasefilt.grd phasefilt_ll.grd $wavelength"
echo "Command:    grd2kml.csh phasefilt_ll phase.cpt"
echo "========================================================================"
if [[ $formal -eq 0 ]]; then
    echo "[PREVIEW] No files were modified."
    echo "[NEXT] $0 1 --pair $pair --wavelength $wavelength"
    exit 0
fi
for command_name in proj_ra2ll.csh grd2kml.csh gmt zip; do
    command -v "$command_name" >/dev/null 2>&1 || die "$command_name was not found in PATH"
done

# A fresh workspace prevents reuse of stale raln/ralt lookup grids.
work_dir="$(mktemp -d "$pair_dir/run3.6_work.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ln -sfn ../../topo/trans.dat "$pair_dir/trans.dat"
ln -s "$root_dir/topo/trans.dat" "$work_dir/trans.dat"
ln -s "$pair_dir/phasefilt.grd" "$work_dir/phasefilt.grd"
ln -s "$pair_dir/phase.cpt" "$work_dir/phase.cpt"
log_file="$pair_dir/run3.6_geocode.log"
# Unlink a possible old log symlink before creating the new log.
rm -f -- "$log_file"
exec > >(tee "$log_file") 2>&1
cd "$work_dir"
echo "[START] Geocoding $pair"
proj_ra2ll.csh trans.dat phasefilt.grd phasefilt_ll.grd "$wavelength"
[[ -s phasefilt_ll.grd ]] || die "geocoding produced no phasefilt_ll.grd"
gmt grdinfo phasefilt_ll.grd >/dev/null
grd2kml.csh phasefilt_ll phase.cpt
[[ -s phasefilt_ll.kml && -s phasefilt_ll.png ]] || die "KML/PNG export failed; inspect $log_file"
zip -j phasefilt_ll.kmz phasefilt_ll.kml phasefilt_ll.png
zip -T phasefilt_ll.kmz
for suffix in grd png kml kmz; do
    mv -f "phasefilt_ll.$suffix" "$pair_dir/phasefilt_ll.$suffix"
done
echo "[SUCCESS] $pair_dir/phasefilt_ll.kmz"
echo "[LOG] $log_file"
