#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 24, 2026
#
# Run 3.9: generate a radar-coordinate land mask in merge/.

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

MERGE_DIR="merge"
TRANS_MIN_BYTES=$((20 * 1024 * 1024))

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./run3.9_make_landmask_ra.sh
  ./run3.9_make_landmask_ra.sh 1

No arguments:
  Print this guide and check dem.grd, trans.dat and the template phasefilt.grd.
  No files are created, removed or modified.

Mode 1 - generate the radar-coordinate land mask:
  ./run3.9_make_landmask_ra.sh 1

Processing:
  1. Check merge/dem.grd and require merge/trans.dat > 20 MiB.
  2. Select the first sorted merge/20*/phasefilt.grd as the template.
  3. Read the template radar-coordinate region.
  4. Run landmask.csh in merge/.
  5. Resample landmask_ra.grd using -R<template_grid>; GMT copies the
     template region, increments and grid registration.
  6. Confirm the output region, increments, dimensions and registration
     match the template exactly.
  7. Plot landmask_ra.pdf in radar coordinates with gray background/sea
     and red land pixels.

Outputs:
  merge/landmask_ra.grd
  merge/landmask_ra.pdf
EOF
}

require_track_root() {
    local root track
    root="$(pwd -P)"
    track="$(basename -- "${root}")"
    [[ "${track}" =~ ^T[0-9]+$ ]] ||
        die "run this script in a T-number track directory (current: ${root})"
    [[ -d "${MERGE_DIR}" ]] || die "cannot find ${MERGE_DIR}/"
}

find_template() {
    find "${MERGE_DIR}" -mindepth 2 -maxdepth 2 -type f \
        -path "${MERGE_DIR}/20*/phasefilt.grd" -print | sort | sed -n '1p'
}

grid_signature() {
    local grid="$1"
    gmt grdinfo "${grid}" -C | awk '{
        # west east south north x_inc y_inc n_columns n_rows registration
        print $2, $3, $4, $5, $8, $9, $10, $11, $12
    }'
}

check_inputs() {
    local trans_size trans_mib phase_count

    [[ -s "${MERGE_DIR}/dem.grd" ]] ||
        die "missing, broken or empty: ${MERGE_DIR}/dem.grd"
    [[ -s "${MERGE_DIR}/trans.dat" ]] ||
        die "missing, broken or empty: ${MERGE_DIR}/trans.dat"

    trans_size="$(wc -c < "${MERGE_DIR}/trans.dat" | awk '{print $1}')"
    [[ "${trans_size}" =~ ^[0-9]+$ ]] || die "failed to determine trans.dat size"
    (( trans_size > TRANS_MIN_BYTES )) ||
        die "${MERGE_DIR}/trans.dat is not larger than 20 MiB (${trans_size} bytes)"

    TEMPLATE="$(find_template)"
    [[ -n "${TEMPLATE}" && -s "${TEMPLATE}" ]] ||
        die "cannot find a non-empty ${MERGE_DIR}/20*/phasefilt.grd template"

    phase_count="$(find "${MERGE_DIR}" -mindepth 2 -maxdepth 2 -type f \
        -path "${MERGE_DIR}/20*/phasefilt.grd" | wc -l | awk '{print $1}')"
    trans_mib="$(awk -v bytes="${trans_size}" 'BEGIN {printf "%.2f", bytes / 1024 / 1024}')"
    TEMPLATE_SIGNATURE="$(grid_signature "${TEMPLATE}")"
    [[ -n "${TEMPLATE_SIGNATURE}" ]] || die "failed to read template grid information"

    printf '%s\n' '========================================'
    printf '%s\n' 'Run 3.9 input check'
    printf 'Track root             : %s\n' "${ROOT_DIR}"
    printf 'DEM                    : %s/%s\n' "${ROOT_DIR}" "${MERGE_DIR}/dem.grd"
    printf 'trans.dat              : %s MiB (> 20 MiB)\n' "${trans_mib}"
    printf 'phasefilt.grd files    : %s\n' "${phase_count}"
    printf 'Template               : %s/%s\n' "${ROOT_DIR}" "${TEMPLATE}"
    printf 'Template grid signature: %s\n' "${TEMPLATE_SIGNATURE}"
    printf '%s\n' '========================================'
}

if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    usage
    exit 0
fi

(( $# <= 1 )) || die "use no arguments for checking, or use mode 1 to generate the mask"
if (( $# == 1 )); then
    [[ "$1" == '1' ]] || die "MODE must be 1"
fi

for command_name in awk basename find gmt head sed sort wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

require_track_root
ROOT_DIR="$(pwd -P)"
TEMPLATE=""
TEMPLATE_SIGNATURE=""
check_inputs

if (( $# == 0 )); then
    usage
    printf '%s\n' '========================================'
    printf '%s\n' '[CHECK ONLY] Inputs are ready; landmask processing was NOT started.'
    if [[ -s "${MERGE_DIR}/landmask_ra.grd" ]]; then
        printf 'Existing grid          : %s/%s\n' "${ROOT_DIR}" "${MERGE_DIR}/landmask_ra.grd"
    else
        printf '%s\n' 'Existing grid          : not found'
    fi
    if [[ -s "${MERGE_DIR}/landmask_ra.pdf" ]]; then
        printf 'Existing figure        : %s/%s\n' "${ROOT_DIR}" "${MERGE_DIR}/landmask_ra.pdf"
    else
        printf '%s\n' 'Existing figure        : not found'
    fi
    printf '%s\n' '[NEXT] Generate or replace landmask_ra.grd:'
    printf '%s\n' '  ./run3.9_make_landmask_ra.sh 1'
    printf '%s\n' '========================================'
    exit 0
fi

command -v landmask.csh >/dev/null 2>&1 || die "landmask.csh was not found in PATH"

# Convert the root-relative template path to a merge-relative path.
TEMPLATE_REL="${TEMPLATE#${MERGE_DIR}/}"
cd "${MERGE_DIR}"

REGION="$(gmt grdinfo "${TEMPLATE_REL}" -C | awk '{print $2 "/" $3 "/" $4 "/" $5}')"
[[ "${REGION}" == */*/*/* ]] || die "failed to read region from ${TEMPLATE_REL}"

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.9: make radar-coordinate land mask'
printf 'Working directory      : %s\n' "$(pwd -P)"
printf 'Template               : %s\n' "${TEMPLATE_REL}"
printf 'Radar region            : %s\n' "${REGION}"
printf 'landmask.csh            : %s\n' "$(command -v landmask.csh)"
printf '%s\n' '========================================'

printf '%s\n' '[STEP 1] Remove old land-mask products and temporary files'
rm -f -- landmask.grd landmask_ra.grd landmask_ra.xyz tmp.grd \
    tmp_landmask_ra.grd landmask_ra.cpt landmask_ra.ps landmask_ra.pdf

printf '%s\n' '[STEP 2] Generate landmask_ra.grd'
printf 'Command: landmask.csh %s\n' "${REGION}"
landmask.csh "${REGION}"
[[ -s landmask_ra.grd ]] || die "landmask.csh did not generate a non-empty landmask_ra.grd"

printf '%s\n' '[STEP 3] Match the phasefilt.grd template grid exactly'
printf 'Command: gmt grdsample landmask_ra.grd -R%s -Gtmp_landmask_ra.grd\n' \
    "${TEMPLATE_REL}"
gmt grdsample landmask_ra.grd -R"${TEMPLATE_REL}" -Gtmp_landmask_ra.grd
[[ -s tmp_landmask_ra.grd ]] || die "GMT did not generate tmp_landmask_ra.grd"
mv -f -- tmp_landmask_ra.grd landmask_ra.grd

printf '%s\n' '[STEP 4] Validate the final grid geometry'
OUTPUT_SIGNATURE="$(grid_signature landmask_ra.grd)"
[[ -n "${OUTPUT_SIGNATURE}" ]] || die "failed to read landmask_ra.grd information"
printf 'Template signature : %s\n' "${TEMPLATE_SIGNATURE}"
printf 'Output signature   : %s\n' "${OUTPUT_SIGNATURE}"
[[ "${OUTPUT_SIGNATURE}" == "${TEMPLATE_SIGNATURE}" ]] ||
    die "landmask_ra.grd geometry does not match ${TEMPLATE_REL}"

gmt grdinfo landmask_ra.grd

printf '%s\n' '[STEP 5] Plot landmask_ra.pdf (gray background/sea, red land)'
rm -f -- landmask_ra.cpt landmask_ra.ps landmask_ra.pdf \
    gmt.conf gmt.history .gmtcommands4
cat > landmask_ra.cpt <<'EOF_CPT'
0.0  160 160 160   0.5  160 160 160
0.5  255   0   0   1.0  255   0   0
B    160 160 160
F    255   0   0
N    160 160 160
EOF_CPT

gmt grdimage landmask_ra.grd \
    -JX6.5i \
    -Clandmask_ra.cpt \
    -Bxaf+lRange \
    -Byaf+lAzimuth \
    -BWSen+t"Radar-coordinate land mask" \
    -X1.2i -Y2.8i -P -K > landmask_ra.ps

gmt psscale \
    -Rlandmask_ra.grd -J \
    -DJBC+w5.0i/0.25i+h+o0i/0.35i \
    -Clandmask_ra.cpt \
    -Bxa0.5f0.5+l"Land mask" \
    -O >> landmask_ra.ps

gmt psconvert -Tf -P -A -Z landmask_ra.ps
[[ -s landmask_ra.pdf ]] || die "landmask_ra.pdf was not generated"
rm -f -- landmask_ra.cpt landmask_ra.ps gmt.conf gmt.history .gmtcommands4

printf '%s\n' '[STEP 6] Remove intermediate land-mask files'
rm -f -- landmask.grd landmask_ra.xyz tmp.grd tmp_landmask_ra.grd

printf '%s\n' '========================================'
printf '%s\n' '[DONE] Run 3.9 completed successfully.'
printf 'Grid     : %s/merge/landmask_ra.grd\n' "${ROOT_DIR}"
printf 'Figure   : %s/merge/landmask_ra.pdf\n' "${ROOT_DIR}"
printf 'Template : %s/%s\n' "${ROOT_DIR}" "${TEMPLATE}"
printf 'Region   : %s\n' "${REGION}"
printf '%s\n' '========================================'
