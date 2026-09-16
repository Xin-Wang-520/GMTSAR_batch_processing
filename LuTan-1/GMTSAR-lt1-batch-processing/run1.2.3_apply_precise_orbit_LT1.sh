#!/usr/bin/env bash
# Run 1.2.3: Apply LT-1 precise orbits to GMTSAR LED/PRM files.
#
# Input:  raw/*.PRM, raw/*.LED, and precise-orbit TXT files in data/orbit/.
# Formats: 13-column .scie.gps.txt and headered 18-column GpsData_GAS_C.
# Output: raw/*.LED.metadata backup, precise raw/*.LED, and updated raw/*.PRM.
# Method: matches satellite/date, extracts scene time +/-200 s, fills short
#         one-second sampling gaps, writes LED, and runs calc_dop_orb.
# Missing precise orbits automatically repair the metadata/coarse LED and are
# listed in run1.2.3_missing_precise_orbits.tsv. Use --require-precise-orbit
# when a missing orbit should stop execution.
# After a successful formal run, backups, logs, and completion markers are
# archived under raw/archive_run1.2.3/; active PRM/SLC/LED files stay in raw/.
# Master: --master is required and must match Run 1.2.1.
#
# Examples:
#   ./run1.2.3_apply_precise_orbit_LT1.sh --master 20250716
#   ./run1.2.3_apply_precise_orbit_LT1.sh 1 --master 20250716
set -euo pipefail

if [[ $# -eq 0 ]]; then
    cat <<'HELP'
LT-1 Run 1.2.3: Apply precise orbits

Prerequisite:
  Complete Run 1.2.2 first. Put precise-orbit TXT files in data/orbit/.

Supported orbit files:
  - 13-column *.scie.gps.txt
      YYYY MM DD hh mm ss flag X Y Z VX VY VZ
      The flag column is ignored; X/Y/Z and VX/VY/VZ are used.
  - 18-column *_GpsData_GAS_C_*.txt with comment headers

What this step does:
  1. Matches each orbit by satellite (LT1A/LT1B) and acquisition date.
  2. Saves the original metadata LED for repeatable reruns; after success it
     is archived under raw/archive_run1.2.3/.
  3. Converts either orbit format into GMTSAR LED format using ECEF/FIXED
     position and velocity, with GMTSAR's zero-based day-of-year.
  4. Repairs precise-orbit internal gaps with local two-point cubic Hermite
     interpolation and adds a 5-second boundary extension for calc_dop_orb.
     Missing metadata/coarse-orbit scenes use the LT_LED_repair.m
     high-order Hermite/spline method.
  5. Updates the PRM by running calc_dop_orb.
  6. Archives backups, logs, and markers under raw/archive_run1.2.3/.

Preview orbit matching (no files changed):
  ./run1.2.3_apply_precise_orbit_LT1.sh --master 20250423

Execute with 5 parallel jobs:
  ./run1.2.3_apply_precise_orbit_LT1.sh 1 --master 20250423 --jobs 5

Missing precise orbit behavior:
  By default, unmatched scenes repair their Run 1.2.2 metadata/coarse LED by
  one-second interpolation of internal gaps (matching LT_LED_repair.m), then are written to
  run1.2.3_missing_precise_orbits.tsv.
  To stop instead, add --require-precise-orbit.
HELP
    exit 0
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${SCRIPT_DIR}/run1.2_preprocess_LT1.py" "$@" --step orbit
