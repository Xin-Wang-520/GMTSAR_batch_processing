#!/usr/bin/env bash
# Run 1.2.4: Optionally resample LT-1 SLCs to common sampling parameters.
#
# Input:  raw/*.PRM and raw/*.SLC after Run 1.2.3.
# Preview: lists every scene's PRF/rng_samp_rate and reports the target maxima.
# Execute: backs up current PRM/SLC, then runs samp_slc.csh in isolated
#          per-scene workspaces and rewrites raw/*.PRM and raw/*.SLC.
# Backup: raw/archive_run1.2.4/ (old PRM/SLC and sampling logs).
# This step is optional and modifies large SLC files. Preview it first.
# Master: --master is required and must match Run 1.2.1.
#
# Examples:
#   ./run1.2.4_common_sampling_LT1.sh --master 20250716
#   ./run1.2.4_common_sampling_LT1.sh 1 --master 20250716
set -euo pipefail

if [[ $# -eq 0 ]]; then
    cat <<'HELP'
LT-1 Run 1.2.4: Resample all SLCs to common sampling parameters (optional)

Prerequisite:
  Complete Run 1.2.3 first.

What this step does:
  1. Reads PRF and rng_samp_rate from every raw/*.PRM.
  2. Selects the maximum PRF and maximum range sampling rate as targets.
  3. Backs up the current PRM/SLC to raw/archive_run1.2.4/.
  4. Runs samp_slc.csh in isolated workspaces, up to --jobs scenes in parallel.
  5. Rewrites raw/*.PRM and raw/*.SLC; therefore preview it first.

Preview every scene and target sampling parameters (no files changed):
  ./run1.2.4_common_sampling_LT1.sh --master 20250423

Execute:
  ./run1.2.4_common_sampling_LT1.sh 1 --master 20250423 --jobs 5
HELP
    exit 0
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${SCRIPT_DIR}/run1.2_preprocess_LT1.py" "$@" --step sample
