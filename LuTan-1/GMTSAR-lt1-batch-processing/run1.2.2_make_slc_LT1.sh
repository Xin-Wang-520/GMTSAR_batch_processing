#!/usr/bin/env bash
# Run 1.2.2: Convert LT-1 TIFF products to GMTSAR SLC/PRM/LED files.
#
# Input:  raw/*.meta.xml and raw/*.tiff created by Run 1.2.1.
# Output: raw/LT1_YYYYMMDD.SLC, .PRM, .LED, and make_slc logs.
# Method: calls make_slc_lt1 with SLC_factor=10 and 5 parallel jobs by default.
# Orbit:  the generated LED still uses the orbit embedded in meta.xml.
#         Run 1.2.3 replaces it with the precise orbit.
# Master: --master is required and must match Run 1.2.1.
#
# Examples:
#   ./run1.2.2_make_slc_LT1.sh --master 20250716
#   ./run1.2.2_make_slc_LT1.sh 1 --master 20250716 --jobs 5
set -euo pipefail

if [[ $# -eq 0 ]]; then
    cat <<'HELP'
LT-1 Run 1.2.2: Create SLC/PRM/metadata LED files

Prerequisite:
  Complete Run 1.2.1 first. Its data.list must exist, and its first line must
  match the --master value supplied here.

What this step does:
  1. Calls make_slc_lt1 for every raw/*.meta.xml and raw/*.tiff pair.
  2. Creates raw/LT1_YYYYMMDD.SLC, .PRM, and .LED.
  3. Uses SLC_factor=10 and 5 parallel jobs by default.
  4. Keeps the metadata orbit at this stage; precise orbit is applied in 1.2.3.

Preview only (no files changed):
  ./run1.2.2_make_slc_LT1.sh --master 20250423 --jobs 5

Execute:
  ./run1.2.2_make_slc_LT1.sh 1 --master 20250423 --jobs 5

Optional initial scale factor:
  ./run1.2.2_make_slc_LT1.sh 1 --master 20250423 --jobs 5 --slc-factor 10
HELP
    exit 0
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${SCRIPT_DIR}/run1.2_preprocess_LT1.py" "$@" --step slc
