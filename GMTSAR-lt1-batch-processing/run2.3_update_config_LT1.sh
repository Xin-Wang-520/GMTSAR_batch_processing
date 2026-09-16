#!/usr/bin/env bash
# Run 2.3: update the LT-1 GMTSAR configuration for alignment/interferometry.
# Preview (no changes) is the default; positional argument 1 applies changes.
set -euo pipefail

usage() {
    cat <<'HELP'
Run 2.3: update config.LT1.txt

Usage:
  run2.3_update_config_LT1.sh [1] [--config FILE]

Changes applied in formal mode:
  proc_stage         = 2
  filter_wavelength  = 60
  dec_factor         = 1
  azimuth_dec        = 1
  range_dec          = 1

The old configuration is backed up under archive_run2.3/.
HELP
}

die() { echo "[ERROR] $*" >&2; exit 1; }

formal=0
config_file="config.LT1.txt"

# User settings: edit these values when a different processing configuration is needed.
TARGET_PROC_STAGE=2
TARGET_FILTER_WAVELENGTH=60
TARGET_DEC_FACTOR=1
# Single-look output in both range and azimuth. Odd values make filter.csh use
# one initial look, giving valid final filter factors idec=1 and jdec=1.
TARGET_RANGE_DEC=1
TARGET_AZIMUTH_DEC=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        1) formal=1; shift ;;
        --config) [[ $# -ge 2 ]] || die "--config requires a file"; config_file="$2"; shift 2 ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ -f "$config_file" ]] || die "configuration file not found: $config_file"

echo "========================================================================"
echo "LT-1 Run 2.3 Update GMTSAR configuration"
echo "Mode:   $([[ "$formal" -eq 1 ]] && echo FORMAL || echo PREVIEW)"
echo "Config: $config_file"
echo "Target values: proc_stage=$TARGET_PROC_STAGE, filter_wavelength=$TARGET_FILTER_WAVELENGTH, dec_factor=$TARGET_DEC_FACTOR, range_dec=$TARGET_RANGE_DEC, azimuth_dec=$TARGET_AZIMUTH_DEC"
echo "------------------------------------------------------------------------"
for key in proc_stage filter_wavelength dec_factor range_dec azimuth_dec; do
    value="$(awk -v key="$key" '$1==key && $2=="=" {v=$3} END {print v}' "$config_file")"
    if [[ -n "$value" ]]; then
        echo "$key = $value"
    else
        echo "$key = (missing; will be added in formal mode)"
    fi
done
echo "========================================================================"

if [[ "$formal" -eq 0 ]]; then
    echo "[PREVIEW] config.LT1.txt was not changed."
    echo "[NEXT]    $0 1 --config $config_file"
    exit 0
fi

root_dir="$(pwd -P)"
archive_dir="$root_dir/archive_run2.3"
mkdir -p "$archive_dir"
timestamp="$(date +%Y%m%dT%H%M%S)"
backup="$archive_dir/$(basename "$config_file").$timestamp.bak"
cp -p "$config_file" "$backup"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/run2.3_config.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

awk -v target_proc_stage="$TARGET_PROC_STAGE" \
    -v target_filter_wavelength="$TARGET_FILTER_WAVELENGTH" \
    -v target_dec_factor="$TARGET_DEC_FACTOR" \
    -v target_range_dec="$TARGET_RANGE_DEC" \
    -v target_azimuth_dec="$TARGET_AZIMUTH_DEC" '
    BEGIN {
        target["proc_stage"] = target_proc_stage
        target["filter_wavelength"] = target_filter_wavelength
        target["dec_factor"] = target_dec_factor
        target["range_dec"] = target_range_dec
        target["azimuth_dec"] = target_azimuth_dec
    }
    {
        key=$1
        if (key == "range_dec" || key == "azimuth_dec") next
        if (key == "dec_factor" && $2 == "=") {
            print "dec_factor = " target["dec_factor"]
            print "azimuth_dec = " target["azimuth_dec"]
            print "range_dec = " target["range_dec"]
            dec_block=1
            seen["dec_factor"]=1
            seen["azimuth_dec"]=1
            seen["range_dec"]=1
            next
        }
        if (key in target && $2 == "=") {
            print key " = " target[key]
            seen[key]=1
            next
        }
        print
    }
    END {
        if (!dec_block) {
            print "dec_factor = " target["dec_factor"]
            print "azimuth_dec = " target["azimuth_dec"]
            print "range_dec = " target["range_dec"]
            seen["dec_factor"]=1
            seen["azimuth_dec"]=1
            seen["range_dec"]=1
        }
        if (!("proc_stage" in seen)) print "proc_stage = " target["proc_stage"]
        if (!("filter_wavelength" in seen)) print "filter_wavelength = " target["filter_wavelength"]
    }
' "$config_file" > "$tmp_file"
mv "$tmp_file" "$config_file"

echo "[UPDATED] $config_file"
echo "[BACKUP]  $backup"
echo "[SUCCESS] proc_stage=$TARGET_PROC_STAGE, filter_wavelength=$TARGET_FILTER_WAVELENGTH, dec_factor=$TARGET_DEC_FACTOR, range_dec=$TARGET_RANGE_DEC, azimuth_dec=$TARGET_AZIMUTH_DEC"
echo "[NEXT] Run: batch_processing.csh LT1 <master_image> data.list 2 $(basename "$config_file")"
