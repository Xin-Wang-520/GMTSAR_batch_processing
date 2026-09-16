#!/usr/bin/env bash
# Run 1.2.1: Prepare LT-1 inputs in raw/.
#
# Input:  data/LT1*/<product>.meta.xml and <product>.tiff.
# Output: raw/*.meta.xml and raw/*.tiff symlinks, data.list, config.LT1.txt.
# Naming: data.list uses LT1_YYYYMMDD; the selected master is its first line.
# Orbit:  meta.xml contains the product metadata orbit. This step does not
#         read or validate data/orbit/.
# Next:   Run 1.2.2 creates SLC/PRM/LED with the metadata orbit; Run 1.2.3
#         replaces the LED with the precise orbit.
# Master: --master YYYYMMDD or an exact product name is always required.
# Mode:   omit positional 1 for preview; add 1 to perform the changes.
#
# Examples:
#   ./run1.2.1_prepare_raw_LT1.sh --master 20250716
#   ./run1.2.1_prepare_raw_LT1.sh 1 --master 20250716
set -euo pipefail

if [[ $# -eq 0 ]]; then
    cat <<'HELP'
LT-1 Run 1.2.1: Prepare raw inputs

What this step does:
  1. Reads each .meta.xml and .tiff under data/LT1*/.
  2. Preserves the original .meta.xml and .tiff names under raw/.
  3. Creates data.list using LT1_YYYYMMDD, with the master on its first line.
  4. Creates config.LT1.txt if it does not already exist.

Orbit handling:
  meta.xml contains the product metadata orbit. This step does not read or
  validate data/orbit/. Run 1.2.3 applies the precise orbit later.

Run from an Ascending/ or Descending/ directory. --master is required.

Preview only (no files changed):
  ./run1.2.1_prepare_raw_LT1.sh --master 20250423

Execute:
  ./run1.2.1_prepare_raw_LT1.sh 1 --master 20250423
HELP
    exit 0
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${SCRIPT_DIR}/run1.2_preprocess_LT1.py" "$@" --step prepare
