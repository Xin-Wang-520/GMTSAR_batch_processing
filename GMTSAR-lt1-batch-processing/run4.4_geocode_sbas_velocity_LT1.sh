#!/usr/bin/env bash
# Run 4.4: geocode LT-1 SBAS velocity and generate map/KML products.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

SBAS_DIR="sbas_detrend"
UNWRAP_NAME="unwrap_detrend_ref_pin.grd"
DEFAULT_FILTER_REQUEST="auto"
CPT_STEP="${VEL_CPT_STEP:-1}"
DEFAULT_CPT_ABS_MAX="${VEL_CPT_ABS_MAX:-auto}"
CPT_TICK_REQUEST="${VEL_CPT_TICK:-auto}"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Run 4.4: geocode LT-1 SBAS velocity

Usage:
  ./run4.4_geocode_sbas_velocity_LT1.sh
  ./run4.4_geocode_sbas_velocity_LT1.sh 1 [FILTER_METERS|auto] [CPT_ABS_MAX]

Defaults:
  geographic sampling filter = auto from gauss_<meters>
  velocity color range       = auto symmetric limits
  velocity color step        = 1 mm/yr

CPT_ABS_MAX:
  auto  Read the minimum and maximum of vel_ll.grd, take the larger absolute
        value, round it to the nearest integer, and use -M/+M as both ends.
  N     Manually use -N/+N as both ends; for example, 10 gives -10/+10.

Examples:
  ./run4.4_geocode_sbas_velocity_LT1.sh 1
  ./run4.4_geocode_sbas_velocity_LT1.sh 1 auto
  ./run4.4_geocode_sbas_velocity_LT1.sh 1 60
  ./run4.4_geocode_sbas_velocity_LT1.sh 1 60 10

Automatic filter selection:
  Read filter_wavelength from config.LT1.txt and match
  intf_all/<template_pair>/gauss_<filter_wavelength>. If the configuration
  does not provide a usable value, exactly one numeric gauss_* file must
  exist in that pair. Formal mode links the selected file into sbas_detrend/
  and reads the number after gauss_ as the proj_ra2ll.csh filter parameter.

Optional color environment variables:
  VEL_CPT_ABS_MAX=auto VEL_CPT_STEP=1 VEL_CPT_TICK=auto

The colorbar tick interval defaults to a sparse automatic 1/2/5 x 10^n value,
giving approximately five labeled major ticks. Set VEL_CPT_TICK manually only
when a different interval is needed.

Inputs:
  sbas_detrend/vel.grd
  topo/trans.dat
  intf_all/<template_pair>/gauss_<meters>

Outputs in sbas_detrend/:
  vel_ll.grd
  vel_ll.cpt
  vel_ll.pdf / vel_ll.png
  vel_ll.kml
  vel_ll.kmz (doc.kml + vel_ll.png, ready for Google Earth)
  gauss_<meters> -> ../intf_all/<template_pair>/gauss_<meters>
  run4.4_complete
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
(( $# <= 3 )) || die "expected no arguments, or: 1 [FILTER_METERS|auto] [CPT_ABS_MAX]"
[[ $# -eq 0 || "$1" == "1" ]] || die "MODE must be 1"
FORMAL=0
(( $# == 0 )) || FORMAL=1
FILTER_REQUEST="${2:-$DEFAULT_FILTER_REQUEST}"
CPT_ABS_REQUEST="${3:-$DEFAULT_CPT_ABS_MAX}"

if [[ "${FILTER_REQUEST}" != "auto" ]]; then
    awk -v x="${FILTER_REQUEST}" 'BEGIN {
        exit !(x~/^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && x>0)
    }' || die "FILTER_METERS must be auto or a positive number"
fi
awk -v x="${CPT_STEP}" 'BEGIN {
    exit !(x~/^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && x>0)
}' || die "CPT_STEP must be positive"
if [[ "${CPT_ABS_REQUEST}" != "auto" ]]; then
    awk -v x="${CPT_ABS_REQUEST}" 'BEGIN {
        exit !(x~/^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && x>0)
    }' || die "CPT_ABS_MAX must be auto or a positive number"
fi
if [[ "${CPT_TICK_REQUEST}" != "auto" ]]; then
    awk -v x="${CPT_TICK_REQUEST}" 'BEGIN {
        exit !(x~/^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && x>0)
    }' || die "VEL_CPT_TICK must be auto or a positive number"
fi

for command_name in awk basename find gmt grd2kml.csh ln proj_ra2ll.csh sed wc zip; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

ROOT="$(pwd -P)"
TRACK="$(basename -- "${ROOT}")"
[[ "${TRACK}" == "Ascending" || "${TRACK}" == "Descending" ]] ||
    die "run this script in an LT-1 Ascending or Descending directory"
[[ -d "${SBAS_DIR}" ]] || die "cannot find ${SBAS_DIR}/"
[[ -s "${SBAS_DIR}/vel.grd" ]] ||
    die "missing or empty: ${SBAS_DIR}/vel.grd; confirm Run 4.3 completed"
[[ -s "${SBAS_DIR}/intflist_new" ]] ||
    die "missing or empty: ${SBAS_DIR}/intflist_new"
[[ -s "${SBAS_DIR}/run4.2_complete" ]] ||
    die "missing or empty: ${SBAS_DIR}/run4.2_complete"
SBAS_UNWRAP="$(awk -F= '$1=="unwrap_name"{print $2; exit}' "${SBAS_DIR}/run4.2_complete")"
[[ "${SBAS_UNWRAP}" == "${UNWRAP_NAME}" ]] ||
    die "Run 4.2 used ${SBAS_UNWRAP:-an unknown unwrap input}; rerun Run 4.1 through Run 4.3 with ${UNWRAP_NAME}"
[[ -s topo/trans.dat ]] || die "missing or empty: topo/trans.dat"

TRANS_BYTES="$(wc -c < topo/trans.dat | awk '{print $1}')"
(( TRANS_BYTES >= 1024 * 1024 )) ||
    die "topo/trans.dat is unexpectedly small (${TRANS_BYTES} bytes)"
grid_signature() {
    gmt grdinfo "$1" -C |
        awk '{print $2, $3, $4, $5, $8, $9, $10, $11, $12}'
}

TEMPLATE_PAIR="$(sed -n '1p' "${SBAS_DIR}/intflist_new")"
TEMPLATE_GRID="intf_all/${TEMPLATE_PAIR}/${UNWRAP_NAME}"
[[ -s "${TEMPLATE_GRID}" ]] || die "missing SBAS radar template: ${TEMPLATE_GRID}"
TEMPLATE_INTF_DIR="intf_all/${TEMPLATE_PAIR}"

# proj_ra2ll.csh expects gauss_<filter> in its working directory. Select the
# original filter from the SBAS template pair, then link it into sbas_detrend/.
# The suffix of that link is the authoritative proj_ra2ll.csh filter value.
GAUSS_CANDIDATES=()
while IFS= read -r candidate; do
    name="$(basename -- "${candidate}")"
    value="${name#gauss_}"
    if awk -v x="${value}" 'BEGIN {
        exit !(x~/^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && x>0)
    }'; then
        GAUSS_CANDIDATES+=("${candidate}")
    fi
done < <(find "${TEMPLATE_INTF_DIR}" -mindepth 1 -maxdepth 1 \
    \( -type f -o -type l \) -name 'gauss_*' -print | sort)
(( ${#GAUSS_CANDIDATES[@]} > 0 )) ||
    die "no numeric gauss_<meters> file found in ${TEMPLATE_INTF_DIR}"

CONFIG_FILTER="$(awk '$1=="filter_wavelength" && $2=="=" {print $3; exit}' config.LT1.txt 2>/dev/null || true)"
GAUSS_SOURCE=""
FILTER_MODE=""
if [[ "${FILTER_REQUEST}" != "auto" ]]; then
    for candidate in "${GAUSS_CANDIDATES[@]}"; do
        candidate_value="$(basename -- "${candidate}")"
        candidate_value="${candidate_value#gauss_}"
        awk -v a="${candidate_value}" -v b="${FILTER_REQUEST}" \
            'BEGIN {exit !(a+0==b+0)}' || continue
        GAUSS_SOURCE="${candidate}"
        break
    done
    [[ -n "${GAUSS_SOURCE}" ]] ||
        die "requested gauss_${FILTER_REQUEST} does not exist in ${TEMPLATE_INTF_DIR}"
    FILTER_MODE="manual"
elif [[ -n "${CONFIG_FILTER}" ]]; then
    for candidate in "${GAUSS_CANDIDATES[@]}"; do
        candidate_value="$(basename -- "${candidate}")"
        candidate_value="${candidate_value#gauss_}"
        awk -v a="${candidate_value}" -v b="${CONFIG_FILTER}" \
            'BEGIN {exit !(a+0==b+0)}' || continue
        GAUSS_SOURCE="${candidate}"
        break
    done
    if [[ -n "${GAUSS_SOURCE}" ]]; then
        FILTER_MODE="auto_config_filter_wavelength"
    fi
fi
if [[ -z "${GAUSS_SOURCE}" && ${#GAUSS_CANDIDATES[@]} -eq 1 ]]; then
    GAUSS_SOURCE="${GAUSS_CANDIDATES[0]}"
    FILTER_MODE="auto_single_gauss"
fi
if [[ -z "${GAUSS_SOURCE}" ]]; then
    printf '[ERROR] Multiple gauss_* filters exist in %s:\n' "${TEMPLATE_INTF_DIR}" >&2
    printf '  %s\n' "${GAUSS_CANDIDATES[@]}" >&2
    die "config.LT1.txt did not identify one of them; specify FILTER_METERS manually"
fi
GAUSS_NAME="$(basename -- "${GAUSS_SOURCE}")"
FILTER_METERS="${GAUSS_NAME#gauss_}"
[[ -s "${GAUSS_SOURCE}" ]] || die "selected Gaussian filter is empty: ${GAUSS_SOURCE}"

VEL_SIGNATURE="$(grid_signature "${SBAS_DIR}/vel.grd")"
TEMPLATE_SIGNATURE="$(grid_signature "${TEMPLATE_GRID}")"
[[ -n "${VEL_SIGNATURE}" ]] || die "cannot read sbas_detrend/vel.grd"
read -r VEL_W VEL_E VEL_S VEL_N VEL_DX VEL_DY VEL_NX VEL_NY VEL_REG <<< "${VEL_SIGNATURE}"
read -r TMP_W TMP_E TMP_S TMP_N TMP_DX TMP_DY TMP_NX TMP_NY TMP_REG <<< "${TEMPLATE_SIGNATURE}"
[[ "${VEL_NX}" == "${TMP_NX}" && "${VEL_NY}" == "${TMP_NY}" ]] ||
    die "vel.grd dimensions ${VEL_NX}x${VEL_NY} differ from SBAS template ${TMP_NX}x${TMP_NY}"
[[ "${VEL_REG}" == "${TMP_REG}" ]] ||
    die "vel.grd registration differs from the SBAS unwrap template"

printf '%s\n' '========================================================================'
printf '%s\n' 'LT-1 Run 4.4 geocode SBAS velocity'
printf 'Mode:                 %s\n' "$([[ "${FORMAL}" -eq 1 ]] && printf FORMAL || printf CHECK)"
printf 'Track:                %s\n' "${TRACK}"
printf 'Radar velocity input: %s/vel.grd\n' "${SBAS_DIR}"
printf 'Velocity grid:        %s\n' "${VEL_SIGNATURE}"
printf 'SBAS radar template:  %s\n' "${TEMPLATE_GRID}"
printf 'Phase input:          %s\n' "${UNWRAP_NAME}"
printf 'Template grid:        %s\n' "${TEMPLATE_SIGNATURE}"
printf 'Projection table:     topo/trans.dat (%.2f MiB)\n' "$(awk -v b="${TRANS_BYTES}" 'BEGIN {print b/1048576}')"
printf 'Gaussian source:      %s\n' "${GAUSS_SOURCE}"
printf 'SBAS filter link:     %s/%s\n' "${SBAS_DIR}" "${GAUSS_NAME}"
printf 'Filter selection:     %s\n' "${FILTER_MODE}"
printf 'Geographic sampling:  %s/4 = %s m nominal pixel spacing\n' "${FILTER_METERS}" "$(awk -v f="${FILTER_METERS}" 'BEGIN {print f/4}')"
if [[ "${CPT_ABS_REQUEST}" == "auto" ]]; then
    printf 'Color range:          auto: rounded symmetric limits from vel_ll.grd\n'
else
    printf 'Color range:          -%s/+%s mm/yr (manual)\n' \
        "${CPT_ABS_REQUEST}" "${CPT_ABS_REQUEST}"
fi
printf 'Color step:           %s mm/yr\n' "${CPT_STEP}"
printf '%s\n' '========================================================================'

if (( FORMAL == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] No geographic velocity product was created.'
    exit 0
fi

cd "${SBAS_DIR}"
rm -f -- trans.dat vel_ra.grd vel_ll.grd vel_ll.cpt \
    vel_ll.pdf vel_ll.png vel_ll.kml vel_ll.kmz \
    vel_ll.legend.png run4.4_complete
rm -rf -- vel_ll
for old_gauss in gauss_*; do
    [[ -L "${old_gauss}" ]] && rm -f -- "${old_gauss}"
done
ln -s ../topo/trans.dat trans.dat
ln -s "../${GAUSS_SOURCE}" "${GAUSS_NAME}"
[[ -s "${GAUSS_NAME}" ]] || die "failed to link ${SBAS_DIR}/${GAUSS_NAME}"

# Read the filter directly from the link name now present in sbas_detrend/.
FILTER_METERS="${GAUSS_NAME#gauss_}"

printf '%s\n' '[STEP 1] Verify vel.grd radar-coordinate header'
[[ "${VEL_SIGNATURE}" == "${TEMPLATE_SIGNATURE}" ]] ||
    die "vel.grd geometry differs from ${TEMPLATE_GRID}; refusing to geocode with a mismatched radar header"

printf '[STEP 2] proj_ra2ll.csh trans.dat vel.grd vel_ll.grd %s\n' "${FILTER_METERS}"
proj_ra2ll.csh trans.dat vel.grd vel_ll.grd "${FILTER_METERS}"
[[ -s vel_ll.grd ]] || die "proj_ra2ll.csh did not generate vel_ll.grd"

read -r VEL_LL_MIN VEL_LL_MAX < <(
    gmt grdinfo vel_ll.grd -C | awk '{print $6, $7; exit}'
)
DATA_ABS_MAX="$(awk -v lo="${VEL_LL_MIN}" -v hi="${VEL_LL_MAX}" 'BEGIN {
    if(lo<0)lo=-lo
    if(hi<0)hi=-hi
    printf "%.15g", (lo>hi ? lo : hi)
}')"
if [[ "${CPT_ABS_REQUEST}" == "auto" ]]; then
    CPT_ABS_MAX="$(awk -v x="${DATA_ABS_MAX}" -v step="${CPT_STEP}" 'BEGIN {
        rounded=int(x+0.5)
        if(rounded<step)rounded=step
        printf "%.15g", rounded
    }')"
    CPT_MODE="auto_rounded"
else
    CPT_ABS_MAX="${CPT_ABS_REQUEST}"
    CPT_MODE="manual"
fi
CPT_MIN="$(awk -v x="${CPT_ABS_MAX}" 'BEGIN{printf "%.15g",-x}')"
CPT_MAX="${CPT_ABS_MAX}"
if [[ "${CPT_TICK_REQUEST}" == "auto" ]]; then
    # Aim for roughly four intervals across the full symmetric color span,
    # then round the interval to a readable 1, 2, 5, or 10 x 10^n value.
    CPT_TICK="$(awk -v maximum="${CPT_ABS_MAX}" 'BEGIN {
        raw=(2*maximum)/4
        power=int(log(raw)/log(10))
        if(raw<1)power--
        base=10^power
        normalized=raw/base
        if(normalized<1.5)nice=1
        else if(normalized<3.5)nice=2
        else if(normalized<7.5)nice=5
        else nice=10
        printf "%.15g", nice*base
    }')"
else
    CPT_TICK="${CPT_TICK_REQUEST}"
fi

printf '[STEP 3] Create jet velocity palette: data=%s/%s, |max|=%s, CPT=%s/%s/%s (%s), tick=%s\n' \
    "${VEL_LL_MIN}" "${VEL_LL_MAX}" "${DATA_ABS_MAX}" \
    "${CPT_MIN}" "${CPT_MAX}" "${CPT_STEP}" "${CPT_MODE}" "${CPT_TICK}"
gmt makecpt -Cjet -T"${CPT_MIN}/${CPT_MAX}/${CPT_STEP}" -Z -D > vel_ll.cpt
[[ -s vel_ll.cpt ]] || die "failed to generate vel_ll.cpt"

printf '%s\n' '[STEP 4] Plot geographic velocity PDF and PNG'
gmt begin vel_ll pdf,png
    gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 10p FONT_LABEL 11p FONT_TITLE 13p COLOR_NAN gray
    gmt grdimage vel_ll.grd -JM15c -Cvel_ll.cpt -Baf -BWSen+t"LT-1 SBAS velocity"
    gmt colorbar -Cvel_ll.cpt -DJBC+w10c/0.3c+h+o0c/1.0c \
        -Bxa"${CPT_TICK}"+l"LOS velocity (mm/yr)"
gmt end
[[ -s vel_ll.pdf && -s vel_ll.png ]] ||
    die "GMT did not generate vel_ll.pdf and vel_ll.png"

printf '%s\n' '[STEP 5] Generate Google Earth KML and transparent overlay PNG'
grd2kml.csh vel_ll vel_ll.cpt
[[ -s vel_ll.kml ]] || die "grd2kml.csh did not generate vel_ll.kml"
[[ -s vel_ll.png ]] || die "grd2kml.csh did not generate the overlay vel_ll.png"

printf '%s\n' '[STEP 6] Package doc.kml and vel_ll.png as vel_ll.kmz'
KMZ_TMP="$(mktemp -d .run4.4_kmz.XXXXXX)"
cleanup_kmz() { rm -rf -- "${KMZ_TMP}"; }
trap cleanup_kmz EXIT INT TERM
cp -f -- vel_ll.kml "${KMZ_TMP}/doc.kml"
cp -f -- vel_ll.png "${KMZ_TMP}/vel_ll.png"
(
    cd "${KMZ_TMP}"
    zip -q ../vel_ll.kmz doc.kml vel_ll.png
)
[[ -s vel_ll.kmz ]] || die "failed to create vel_ll.kmz"
zip -T vel_ll.kmz >/dev/null || die "vel_ll.kmz failed ZIP integrity validation"
cleanup_kmz
trap - EXIT INT TERM

{
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\nfilter_meters=%s\n' "${TRACK}" "${FILTER_METERS}"
    printf 'filter_mode=%s\n' "${FILTER_MODE}"
    printf 'gauss_source=%s/%s\n' "${ROOT}" "${GAUSS_SOURCE}"
    printf 'gauss_link=%s/%s/%s\n' "${ROOT}" "${SBAS_DIR}" "${GAUSS_NAME}"
    printf 'nominal_pixel_meters=%s\n' "$(awk -v f="${FILTER_METERS}" 'BEGIN {print f/4}')"
    printf 'velocity_data_range=%s/%s\n' "${VEL_LL_MIN}" "${VEL_LL_MAX}"
    printf 'velocity_data_abs_max=%s\n' "${DATA_ABS_MAX}"
    printf 'cpt_mode=%s\n' "${CPT_MODE}"
    printf 'cpt_range=%s/%s/%s\n' "${CPT_MIN}" "${CPT_MAX}" "${CPT_STEP}"
    printf 'cpt_tick=%s\n' "${CPT_TICK}"
    printf 'velocity_grid=%s/%s/vel_ll.grd\n' "${ROOT}" "${SBAS_DIR}"
    printf 'radar_velocity_input=%s/%s/vel.grd\n' "${ROOT}" "${SBAS_DIR}"
    printf 'png=%s/%s/vel_ll.png\n' "${ROOT}" "${SBAS_DIR}"
    printf 'kml=%s/%s/vel_ll.kml\n' "${ROOT}" "${SBAS_DIR}"
    printf 'kmz=%s/%s/vel_ll.kmz\n' "${ROOT}" "${SBAS_DIR}"
} > run4.4_complete

printf '%s\n' '========================================================================'
printf '[SUCCESS] Geographic velocity: %s/%s/vel_ll.grd\n' "${ROOT}" "${SBAS_DIR}"
printf '[SUCCESS] Radar velocity input: %s/%s/vel.grd\n' "${ROOT}" "${SBAS_DIR}"
printf '[SUCCESS] Map: %s/%s/vel_ll.pdf and vel_ll.png\n' "${ROOT}" "${SBAS_DIR}"
printf '[SUCCESS] Google Earth KML: %s/%s/vel_ll.kml\n' "${ROOT}" "${SBAS_DIR}"
printf '[SUCCESS] Google Earth KMZ: %s/%s/vel_ll.kmz\n' "${ROOT}" "${SBAS_DIR}"
printf '[KMZ] Contains doc.kml and vel_ll.png\n'
printf '%s\n' '========================================================================'
