#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 24, 2026
#
# Run 3.9: generate a radar-coordinate land mask in intf_all/.

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

MERGE_DIR="intf_all"


die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./run3.9_make_landmask_ra_LT1.sh
  ./run3.9_make_landmask_ra_LT1.sh 1

No arguments:
  Print this guide and check dem.grd, trans.dat and the template phasefilt.grd.
  No files are created, removed or modified.

Mode 1 - generate the radar-coordinate land mask:
  ./run3.9_make_landmask_ra_LT1.sh 1

Processing:
  1. Check topo/dem.grd and topo/trans.dat.
  2. Select the first sorted intf_all/20*/phasefilt.grd as the template.
  3. Read the template radar-coordinate region.
  4. Run landmask.csh once using the full phase region and inspect its bounds.
  5. If the first or third generated bound is not the template zero bound,
     rerun landmask.csh with the corresponding input bound changed to -4.
  6. Resample landmask_ra.grd using -R<template_grid>; GMT copies the
     template region, increments and grid registration.
  7. Confirm the output region, increments, dimensions and registration
     match the template exactly.
  8. Plot landmask_ra.pdf in radar coordinates with gray background/sea
     and red land pixels.

Outputs:
  intf_all/landmask_ra.grd
  intf_all/landmask_ra.pdf
EOF
}

require_track_root() {
    local root track
    root="$(pwd -P)"
    track="$(basename -- "${root}")"
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

    [[ -s "topo/dem.grd" ]] ||
        die "missing, broken or empty: topo/dem.grd"
    [[ -s "topo/trans.dat" ]] ||
        die "missing, broken or empty: topo/trans.dat"

    trans_size="$(wc -c < "topo/trans.dat" | awk '{print $1}')"
    [[ "${trans_size}" =~ ^[0-9]+$ ]] || die "failed to determine trans.dat size"

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
    printf 'DEM                    : %s/%s\n' "${ROOT_DIR}" "topo/dem.grd"
    printf 'trans.dat              : %s MiB \n' "${trans_mib}"
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
    printf '%s\n' '  ./run3.9_make_landmask_ra_LT1.sh 1'
    printf '%s\n' '========================================'
    exit 0
fi

command -v landmask.csh >/dev/null 2>&1 || die "landmask.csh was not found in PATH"

# Generate the full-size mask in a private workspace; never use the Run 3.7 ROI.
TEMPLATE_REL="${TEMPLATE#${MERGE_DIR}/}"
WORK_DIR="$(mktemp -d "${ROOT_DIR}/intf_all/run3.9_work.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT
ln -s "${ROOT_DIR}/topo/dem.grd" "$WORK_DIR/dem.grd"
ln -s "${ROOT_DIR}/topo/trans.dat" "$WORK_DIR/trans.dat"
TEMPLATE_REL="${ROOT_DIR}/${TEMPLATE}"
cd "$WORK_DIR"

REGION="$(gmt grdinfo "${TEMPLATE_REL}" -C | awk '{print $2 "/" $3 "/" $4 "/" $5}')"
[[ "${REGION}" == */*/*/* ]] || die "failed to read region from ${TEMPLATE_REL}"
read -r TEMPLATE_W TEMPLATE_E TEMPLATE_S TEMPLATE_N < <(
    gmt grdinfo "${TEMPLATE_REL}" -C | awk '{print $2, $3, $4, $5; exit}'
)

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

printf '%s\n' '[STEP 3] Inspect generated landmask_ra.grd bounds'
read -r LAND_W LAND_E LAND_S LAND_N < <(
    gmt grdinfo landmask_ra.grd -C | awk '{print $2, $3, $4, $5; exit}'
)
printf 'Template bounds          : %s/%s/%s/%s\n' \
    "${TEMPLATE_W}" "${TEMPLATE_E}" "${TEMPLATE_S}" "${TEMPLATE_N}"
printf 'Generated bounds         : %s/%s/%s/%s\n' \
    "${LAND_W}" "${LAND_E}" "${LAND_S}" "${LAND_N}"

# landmask.csh may return a pixel-registered grid whose first or third bound is
# 0.x rather than the template zero bound. Detect either mismatch explicitly,
# change only the corresponding input lower bound from 0 to -4, and generate
# it again before the final template resampling.
RETRY_W="${TEMPLATE_W}"
RETRY_S="${TEMPLATE_S}"
NEED_RETRY=0
if awk -v got="${LAND_W}" -v want="${TEMPLATE_W}" \
    'BEGIN {exit !(got != want)}'; then
    RETRY_W="$(awk -v value="${TEMPLATE_W}" 'BEGIN {printf "%.12g", value-4}')"
    NEED_RETRY=1
fi
if awk -v got="${LAND_S}" -v want="${TEMPLATE_S}" \
    'BEGIN {exit !(got != want)}'; then
    RETRY_S="$(awk -v value="${TEMPLATE_S}" 'BEGIN {printf "%.12g", value-4}')"
    NEED_RETRY=1
fi

if (( NEED_RETRY == 1 )); then
    RETRY_REGION="${RETRY_W}/${TEMPLATE_E}/${RETRY_S}/${TEMPLATE_N}"
    printf '%s\n' '[RETRY] Generated first and/or third bound is not the template zero bound.'
    printf '[RETRY] Regenerating with expanded region: %s\n' "${RETRY_REGION}"
    rm -f -- landmask.grd landmask_ra.grd landmask_ra.xyz tmp.grd \
        llr lla llr.grd lla.grd
    landmask.csh "${RETRY_REGION}"
    [[ -s landmask_ra.grd ]] || \
        die "landmask.csh retry did not generate a non-empty landmask_ra.grd"
    read -r LAND_W LAND_E LAND_S LAND_N < <(
        gmt grdinfo landmask_ra.grd -C | awk '{print $2, $3, $4, $5; exit}'
    )
    printf 'Regenerated bounds       : %s/%s/%s/%s\n' \
        "${LAND_W}" "${LAND_E}" "${LAND_S}" "${LAND_N}"
fi

awk -v w="${LAND_W}" -v e="${LAND_E}" -v s="${LAND_S}" -v n="${LAND_N}" \
    -v tw="${TEMPLATE_W}" -v te="${TEMPLATE_E}" \
    -v ts="${TEMPLATE_S}" -v tn="${TEMPLATE_N}" \
    'BEGIN {exit !((w <= tw+1e-9) && (e >= te-1e-9) &&
                    (s <= ts+1e-9) && (n >= tn-1e-9))}' || \
    die "generated landmask_ra.grd still does not cover the complete template region"

printf '%s\n' '[STEP 4] Match the phasefilt.grd template grid exactly'
printf 'Command: gmt grdsample landmask_ra.grd -R%s -Gtmp_landmask_ra.grd\n' \
    "${TEMPLATE_REL}"
gmt grdsample landmask_ra.grd -R"${TEMPLATE_REL}" -nn -Gtmp_landmask_ra.grd
[[ -s tmp_landmask_ra.grd ]] || die "GMT did not generate tmp_landmask_ra.grd"
mv -f -- tmp_landmask_ra.grd landmask_ra.grd

printf '%s\n' '[STEP 5] Validate the final grid geometry'
OUTPUT_SIGNATURE="$(grid_signature landmask_ra.grd)"
[[ -n "${OUTPUT_SIGNATURE}" ]] || die "failed to read landmask_ra.grd information"
printf 'Template signature : %s\n' "${TEMPLATE_SIGNATURE}"
printf 'Output signature   : %s\n' "${OUTPUT_SIGNATURE}"
[[ "${OUTPUT_SIGNATURE}" == "${TEMPLATE_SIGNATURE}" ]] ||
    die "landmask_ra.grd geometry does not match ${TEMPLATE_REL}"

gmt grdinfo landmask_ra.grd

printf '%s\n' '[STEP 6] Plot landmask_ra.pdf (gray background/sea, red land)'
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

printf '%s\n' '[STEP 7] Remove intermediate land-mask files'
rm -f -- landmask.grd landmask_ra.xyz tmp.grd tmp_landmask_ra.grd

printf '%s\n' '========================================'
mv -f landmask_ra.grd landmask_ra.pdf "${ROOT_DIR}/intf_all/"
printf '%s\n' '[DONE] Run 3.9 completed successfully.'
printf 'Grid     : %s/intf_all/landmask_ra.grd\n' "${ROOT_DIR}"
printf 'Figure   : %s/intf_all/landmask_ra.pdf\n' "${ROOT_DIR}"
printf 'Template : %s/%s\n' "${ROOT_DIR}" "${TEMPLATE}"
printf 'Region   : %s\n' "${REGION}"
printf '%s\n' '========================================'
