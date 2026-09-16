#!/usr/bin/env bash
# Run 4.2: generate LT-1 GMTSAR SBAS tables and the parallel command.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

SBAS_DIR="sbas_detrend"
INTF_DIR="intf_all"
UNWRAP_NAME="unwrap_detrend_ref_pin.grd"
CORR_NAME="corr_sbas.grd"
DEFAULT_INCIDENCE="38"
DEFAULT_SMOOTH="1.0"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Run 4.2: generate LT-1 SBAS tables and command

Usage:
  ./run4.2_generate_sbas_tables_command_LT1.sh
  ./run4.2_generate_sbas_tables_command_LT1.sh 1
  ./run4.2_generate_sbas_tables_command_LT1.sh 1 INCIDENCE SMOOTH

Defaults:
  incidence angle = 38 degrees
  SBAS smoothing  = 1.0

Example:
  ./run4.2_generate_sbas_tables_command_LT1.sh 1 38 1.0

This script:
  - automatically identifies the zero-baseline LT-1 master scene;
  - reads radar_wavelength, rng_samp_rate and near_range from its cropped PRM;
  - calculates center slant range for LT-1 range_dec=1;
  - runs prep_sbas.csh using unwrap_detrend_ref_pin.grd and corr_sbas.grd;
  - prepares, but does not start, the sbas_parallel command.

Outputs in sbas_detrend/:
  intf.tab
  scene.tab
  supermaster.PRM
  prep_sbas.log
  range_check.log
  run_sbas_parallel.sh
  run4.2_complete
EOF
}

grid_signature() {
    gmt grdinfo "$1" -C |
        awk '{print $2, $3, $4, $5, $8, $9, $10, $11, $12}'
}

read_prm_value() {
    local key="$1" file="$2"
    awk -v wanted="${key}" '$1==wanted {print $3; exit}' "${file}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
(( $# <= 3 )) || die "expected no arguments, or: 1 [INCIDENCE] [SMOOTH]"
[[ $# -eq 0 || "$1" == "1" ]] || die "MODE must be 1"
FORMAL=0
if (( $# > 0 )); then FORMAL=1; fi
INCIDENCE="${2:-$DEFAULT_INCIDENCE}"
SMOOTH="${3:-$DEFAULT_SMOOTH}"

awk -v x="${INCIDENCE}" 'BEGIN {exit !(x~/^[0-9]+([.][0-9]+)?$/ && x>0 && x<90)}' ||
    die "INCIDENCE must be between 0 and 90 degrees"
awk -v x="${SMOOTH}" 'BEGIN {exit !(x~/^[0-9]+([.][0-9]+)?$/ && x>=0)}' ||
    die "SMOOTH must be non-negative"

for command_name in awk gmt prep_sbas.csh python3 sed sort wc; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done
ROOT="$(pwd -P)"
TRACK="$(basename -- "${ROOT}")"
[[ "${TRACK}" == "Ascending" || "${TRACK}" == "Descending" ]] ||
    die "run this script in an LT-1 Ascending or Descending directory"
[[ -d "${SBAS_DIR}" ]] || die "cannot find ${SBAS_DIR}/; complete Run 4.1 first"
[[ -d "${INTF_DIR}" ]] || die "cannot find ${INTF_DIR}/"

INTFLIST="${SBAS_DIR}/intflist_new"
INTF_IN="${SBAS_DIR}/intf.in"
BASELINE="${SBAS_DIR}/baseline_table.dat"
MASTER_BASELINE="baseline_table.LT1.dat"
RUN41="${SBAS_DIR}/run4.1_complete"
for file in "${INTFLIST}" "${INTF_IN}" "${BASELINE}" "${RUN41}"; do
    [[ -s "${file}" ]] || die "missing or empty: ${file}"
done
RUN41_UNWRAP="$(awk -F= '$1=="unwrap_name"{print $2; exit}' "${RUN41}")"
[[ "${RUN41_UNWRAP}" == "${UNWRAP_NAME}" ]] ||
    die "Run 4.1 used ${RUN41_UNWRAP:-an unknown unwrap input}; rerun Run 4.1 with ${UNWRAP_NAME}"
[[ -s "${MASTER_BASELINE}" ]] ||
    die "missing or empty master baseline source: ${MASTER_BASELINE}"

PAIR_COUNT="$(wc -l < "${INTFLIST}" | awk '{print $1}')"
INTF_COUNT="$(wc -l < "${INTF_IN}" | awk '{print $1}')"
(( PAIR_COUNT > 0 )) || die "empty pair list"
[[ "${PAIR_COUNT}" == "${INTF_COUNT}" ]] ||
    die "intflist_new and intf.in counts differ"

MASTER_STEM="$(awk '$4==0 && $5==0 {print $1; count++}
    END {if(count!=1) exit 1}' "${MASTER_BASELINE}")" ||
    die "cannot identify one unique zero-baseline master in ${MASTER_BASELINE}"
[[ "${MASTER_STEM}" =~ ^LT1_[0-9]{8}$ ]] ||
    die "invalid LT-1 master name in baseline table: ${MASTER_STEM}"
PRM_SOURCE="SLC/${MASTER_STEM}.PRM"
[[ -s "${PRM_SOURCE}" ]] || die "missing cropped master PRM: ${PRM_SOURCE}"

TEMPLATE_PAIR="$(sed -n '1p' "${INTFLIST}")"
TEMPLATE_GRID="${INTF_DIR}/${TEMPLATE_PAIR}/${UNWRAP_NAME}"
TEMPLATE_CORR="${INTF_DIR}/${TEMPLATE_PAIR}/${CORR_NAME}"
[[ -s "${TEMPLATE_GRID}" ]] || die "missing template: ${TEMPLATE_GRID}"
[[ -s "${TEMPLATE_CORR}" ]] || die "missing template: ${TEMPLATE_CORR}"
TEMPLATE_SIGNATURE="$(grid_signature "${TEMPLATE_GRID}")"
[[ "$(grid_signature "${TEMPLATE_CORR}")" == "${TEMPLATE_SIGNATURE}" ]] ||
    die "template correlation and unwrap grids differ"

while IFS= read -r pair; do
    unwrap="${INTF_DIR}/${pair}/${UNWRAP_NAME}"
    corr="${INTF_DIR}/${pair}/${CORR_NAME}"
    [[ -s "${unwrap}" && -s "${corr}" ]] ||
        die "${pair}: missing ${UNWRAP_NAME} or ${CORR_NAME}; rerun Run 4.1"
    [[ "$(grid_signature "${unwrap}")" == "${TEMPLATE_SIGNATURE}" ]] ||
        die "${pair}: unwrap grid geometry differs from ${TEMPLATE_PAIR}"
    [[ "$(grid_signature "${corr}")" == "${TEMPLATE_SIGNATURE}" ]] ||
        die "${pair}: correlation grid geometry differs from ${TEMPLATE_PAIR}"
done < "${INTFLIST}"

read -r _ X_MIN X_MAX Y_MIN Y_MAX _ _ X_INC Y_INC NX NY REG _ <<< "$(gmt grdinfo "${TEMPLATE_GRID}" -C)"
[[ "${X_INC}" == "1" || "${X_INC}" == "1.0" ]] ||
    die "LT-1 center-range calculation expects range grid increment 1; found ${X_INC}"

RANGE_DEC="$(awk '$1=="range_dec" && $2=="=" {print $3; exit}' config.LT1.txt 2>/dev/null || true)"
[[ "${RANGE_DEC:-1}" == "1" ]] ||
    die "config.LT1.txt range_dec=${RANGE_DEC}; this LT-1 SBAS script expects range_dec=1"

WAVELENGTH="$(read_prm_value radar_wavelength "${PRM_SOURCE}")"
RNG_SAMP_RATE="$(read_prm_value rng_samp_rate "${PRM_SOURCE}")"
NEAR_RANGE="$(read_prm_value near_range "${PRM_SOURCE}")"
for label_value in "radar_wavelength:${WAVELENGTH}" "rng_samp_rate:${RNG_SAMP_RATE}" "near_range:${NEAR_RANGE}"; do
    label="${label_value%%:*}"
    value="${label_value#*:}"
    [[ -n "${value}" ]] || die "cannot read ${label} from ${PRM_SOURCE}"
    awk -v x="${value}" 'BEGIN {exit !(x~/^[-+]?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/)}' ||
        die "invalid ${label} in ${PRM_SOURCE}: ${value}"
done

RANGE="$(python3 - "${RNG_SAMP_RATE}" "${NEAR_RANGE}" "${X_MIN}" "${X_MAX}" <<'PY'
import math
import sys

sampling_rate, near_range, xmin, xmax = map(float, sys.argv[1:])
x_center = (xmin + xmax) / 2.0
slant_range = near_range + (299792458.0 / (2.0 * sampling_rate)) * x_center
if not math.isfinite(slant_range) or slant_range <= 0:
    raise SystemExit("invalid calculated center slant range")
print(round(slant_range))
PY
)"

printf '%s\n' '========================================================================'
printf '%s\n' 'LT-1 Run 4.2 generate SBAS tables and command'
printf 'Mode:                   %s\n' "$([[ "${FORMAL}" -eq 1 ]] && printf FORMAL || printf CHECK)"
printf 'Track:                  %s\n' "${TRACK}"
printf 'SBAS directory:         %s/\n' "${SBAS_DIR}"
printf 'Interferogram pairs:    %s\n' "${PAIR_COUNT}"
printf 'Master:                 %s\n' "${MASTER_STEM}"
printf 'Master PRM:             %s\n' "${PRM_SOURCE}"
printf 'Template pair:          %s\n' "${TEMPLATE_PAIR}"
printf 'Grid geometry:          %sx%s, x=%s/%s, y=%s/%s\n' "${NX}" "${NY}" "${X_MIN}" "${X_MAX}" "${Y_MIN}" "${Y_MAX}"
printf 'radar_wavelength:       %s m\n' "${WAVELENGTH}"
printf 'rng_samp_rate:          %s Hz\n' "${RNG_SAMP_RATE}"
printf 'near_range:             %s m\n' "${NEAR_RANGE}"
printf 'Center slant range:     %s m (LT-1 range_dec=1)\n' "${RANGE}"
printf 'Incidence angle:        %s degrees\n' "${INCIDENCE}"
printf 'SBAS smoothing:         %s\n' "${SMOOTH}"
printf '%s\n' '========================================================================'

if (( FORMAL == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] prep_sbas.csh and sbas_parallel were not run.'
    exit 0
fi

cd "${SBAS_DIR}"
rm -f -- intf.tab scene.tab supermaster.PRM prep_sbas.log range_check.log \
    run_sbas_parallel.sh run4.2_complete
cp -f -- "../${PRM_SOURCE}" supermaster.PRM

printf '%s\n' '[STEP 1] Run prep_sbas.csh'
set +e
prep_sbas.csh intf.in baseline_table.dat ../intf_all "${UNWRAP_NAME}" "${CORR_NAME}" |
    tee prep_sbas.log
PREP_STATUS="${PIPESTATUS[0]}"
set -e
(( PREP_STATUS == 0 )) || die "prep_sbas.csh failed with status ${PREP_STATUS}"
[[ -s intf.tab && -s scene.tab ]] ||
    die "prep_sbas.csh did not generate intf.tab and scene.tab"

SBAS_LINE="$(awk '/^sbas[[:space:]]/ {line=$0} END{print line}' prep_sbas.log)"
[[ -n "${SBAS_LINE}" ]] || die "cannot find generated sbas command in prep_sbas.log"
read -r _ _ _ N S XDIM YDIM _ <<< "${SBAS_LINE}"
for value in "${N}" "${S}" "${XDIM}" "${YDIM}"; do
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || die "invalid count parsed from prep_sbas.log"
done
[[ "${N}" == "${PAIR_COUNT}" ]] || die "prep_sbas pair count differs from Run 4.1"
[[ "${XDIM}" == "${NX}" && "${YDIM}" == "${NY}" ]] ||
    die "prep_sbas dimensions ${XDIM}x${YDIM} differ from grid ${NX}x${NY}"

SBAS_CMD="sbas_parallel intf.tab scene.tab ${N} ${S} ${XDIM} ${YDIM} -smooth ${SMOOTH} -wavelength ${WAVELENGTH} -incidence ${INCIDENCE} -range ${RANGE} -rms -dem"

cat > run_sbas_parallel.sh <<EOF_CMD
#!/usr/bin/env bash
set -euo pipefail
cd "$(pwd -P)"
${SBAS_CMD}
EOF_CMD
chmod +x run_sbas_parallel.sh

cat > range_check.log <<EOF_RANGE
c_m_per_s       = 299792458.0
rng_samp_rate   = ${RNG_SAMP_RATE}
near_range      = ${NEAR_RANGE}
x_min           = ${X_MIN}
x_max           = ${X_MAX}
x_center        = $(python3 -c "print((float('${X_MIN}')+float('${X_MAX}'))/2.0)")
range_dec       = 1
formula         = near_range + c/(2*rng_samp_rate)*x_center
center_range_m  = ${RANGE}
EOF_RANGE

{
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\nmaster=%s\n' "${TRACK}" "${MASTER_STEM}"
    printf 'pairs=%s\nscenes=%s\n' "${N}" "${S}"
    printf 'xdim=%s\nydim=%s\n' "${XDIM}" "${YDIM}"
    printf 'wavelength=%s\nincidence=%s\nrange=%s\nsmooth=%s\n' "${WAVELENGTH}" "${INCIDENCE}" "${RANGE}" "${SMOOTH}"
    printf 'unwrap_name=%s\ncorr_name=%s\n' "${UNWRAP_NAME}" "${CORR_NAME}"
    printf 'command=%s\n' "${SBAS_CMD}"
} > run4.2_complete

printf '%s\n' '========================================================================'
printf '[SUCCESS] intf.tab:            %s/intf.tab (%s)\n' "${SBAS_DIR}" "${N}"
printf '[SUCCESS] scene.tab:           %s/scene.tab (%s)\n' "${SBAS_DIR}" "${S}"
printf '[SUCCESS] Command script:      %s/run_sbas_parallel.sh\n' "${SBAS_DIR}"
printf '[COMMAND] %s\n' "${SBAS_CMD}"
printf '[INFO] sbas_parallel was not started.\n'
printf '[NEXT] ./run4.3_sbas_parallel_LT1.sh 1\n'
printf '%s\n' '========================================================================'
