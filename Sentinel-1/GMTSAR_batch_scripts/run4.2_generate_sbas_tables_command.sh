#!/usr/bin/env bash
# Run 4.2: generate SBAS tables and the sbas_parallel command.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 12, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

SBAS_DIR="sbas_demcorr_pin"
MERGE_DIR="merge"
UNWRAP_NAME="unwrap_dem_correct_pin_up.grd"
CORR_NAME="corr.grd"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 4.2: generate GMTSAR SBAS tables and command

Check only (processing NOT started):
  ./run4.2_generate_sbas_tables_command.sh

Formal run with recommended defaults:
  ./run4.2_generate_sbas_tables_command.sh 1

Formal run with explicit incidence angle and smoothing:
  ./run4.2_generate_sbas_tables_command.sh 1 38 1.0

Arguments:
  1    = formal preparation mode
  38   = incidence angle in degrees (default: 38)
  1.0  = SBAS spatial smoothing parameter (default: 1.0)

Required Run 4.1 outputs:
  sbas_demcorr_pin/intflist_new
  sbas_demcorr_pin/intf.in
  sbas_demcorr_pin/baseline_table.dat

Run 4.2 outputs:
  sbas_demcorr_pin/intf.tab
  sbas_demcorr_pin/scene.tab
  sbas_demcorr_pin/supermaster.PRM
  sbas_demcorr_pin/prep_sbas.log
  sbas_demcorr_pin/range_check.log
  sbas_demcorr_pin/run_sbas_parallel.sh
  sbas_demcorr_pin/run4.2_complete

Run 4.2 only prepares the command; it does not run sbas_parallel.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
(( $# <= 3 )) || die "expected no arguments, or: 1 [INCIDENCE] [SMOOTH]"
[[ $# -eq 0 || "$1" == "1" ]] || die "MODE must be 1"
INCIDENCE="${2:-38}"
SMOOTH="${3:-1.0}"

awk -v x="$INCIDENCE" 'BEGIN {exit !(x ~ /^[0-9]+([.][0-9]+)?$/ && x > 0 && x < 90)}' ||
    die "INCIDENCE must be a number between 0 and 90 degrees"
awk -v x="$SMOOTH" 'BEGIN {exit !(x ~ /^[0-9]+([.][0-9]+)?$/ && x >= 0)}' ||
    die "SMOOTH must be a non-negative number"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] || die "run this script in a T-number track directory (current: $ROOT)"
[[ -d "$MERGE_DIR" ]] || die "cannot find $MERGE_DIR/"
[[ -d "$SBAS_DIR" ]] || die "cannot find $SBAS_DIR/; complete Run 4.1 first"

INTFLIST="$SBAS_DIR/intflist_new"
INTF_IN="$SBAS_DIR/intf.in"
BASELINE="$SBAS_DIR/baseline_table.dat"
for file in "$INTFLIST" "$INTF_IN" "$BASELINE"; do
    [[ -s "$file" ]] || die "missing or empty: $file"
done

command -v awk >/dev/null 2>&1 || die "awk not found"
command -v gmt >/dev/null 2>&1 || die "GMT not found"
command -v prep_sbas.csh >/dev/null 2>&1 || die "prep_sbas.csh not found in PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
if (( $# > 0 )); then
    command -v sbas_parallel >/dev/null 2>&1 || die "sbas_parallel not found in PATH"
fi

PAIR_COUNT="$(wc -l < "$INTFLIST" | tr -d ' ')"
INTF_COUNT="$(wc -l < "$INTF_IN" | tr -d ' ')"
BASELINE_COUNT="$(wc -l < "$BASELINE" | tr -d ' ')"
(( PAIR_COUNT > 0 )) || die "empty pair list"
[[ "$PAIR_COUNT" == "$INTF_COUNT" ]] ||
    die "intflist_new ($PAIR_COUNT) and intf.in ($INTF_COUNT) counts differ"

SELECTED_PAIR=""
MISSING_TEMPLATE="$(mktemp "${TMPDIR:-/tmp}/run4.2_template_missing.XXXXXX")"
trap 'rm -f -- "$MISSING_TEMPLATE"' EXIT INT TERM
: > "$MISSING_TEMPLATE"

while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    if [[ ! "$pair" =~ ^[0-9]{7}_[0-9]{7}$ ]]; then
        printf '%s\tinvalid_pair_name\n' "$pair" >> "$MISSING_TEMPLATE"
        continue
    fi
    pair_dir="$MERGE_DIR/$pair"
    missing=()
    [[ -s "$pair_dir/supermaster.PRM" ]] || missing+=("supermaster.PRM")
    [[ -s "$pair_dir/$UNWRAP_NAME" ]] || missing+=("$UNWRAP_NAME")
    [[ -s "$pair_dir/$CORR_NAME" ]] || missing+=("$CORR_NAME")
    if (( ${#missing[@]} == 0 )); then
        SELECTED_PAIR="$pair"
        break
    fi
    joined="$(IFS=,; printf '%s' "${missing[*]}")"
    printf '%s\t%s\n' "$pair" "$joined" >> "$MISSING_TEMPLATE"
done < "$INTFLIST"

[[ -n "$SELECTED_PAIR" ]] || {
    printf '[ERROR] No Run 4.1 pair can provide the PRM and template grid:\n' >&2
    cat "$MISSING_TEMPLATE" >&2
    exit 1
}

PRM_SOURCE="$MERGE_DIR/$SELECTED_PAIR/supermaster.PRM"
GRID_SOURCE="$MERGE_DIR/$SELECTED_PAIR/$UNWRAP_NAME"

read -r _ X_MIN X_MAX Y_MIN Y_MAX _ _ X_INC Y_INC NX NY REG _ \
    <<< "$(gmt grdinfo "$GRID_SOURCE" -C)"
for value in "$X_MIN" "$X_MAX" "$Y_MIN" "$Y_MAX" "$X_INC" "$Y_INC" "$NX" "$NY"; do
    [[ -n "$value" ]] || die "failed to read grid geometry from $GRID_SOURCE"
done

read_prm_value() {
    local key="$1" file="$2"
    awk -v k="$key" '$1==k {print $3; exit}' "$file"
}

WAVELENGTH="$(read_prm_value radar_wavelength "$PRM_SOURCE")"
RNG_SAMP_RATE="$(read_prm_value rng_samp_rate "$PRM_SOURCE")"
NEAR_RANGE="$(read_prm_value near_range "$PRM_SOURCE")"
if [[ -z "$WAVELENGTH" ]]; then
    WAVELENGTH="0.0554658"
    WAVELENGTH_SOURCE="Sentinel-1 fallback"
else
    WAVELENGTH_SOURCE="supermaster.PRM"
fi
[[ -n "$RNG_SAMP_RATE" ]] || die "cannot read rng_samp_rate from $PRM_SOURCE"
[[ -n "$NEAR_RANGE" ]] || die "cannot read near_range from $PRM_SOURCE"

for item in "$WAVELENGTH" "$RNG_SAMP_RATE" "$NEAR_RANGE" "$X_MIN" "$X_MAX"; do
    awk -v x="$item" 'BEGIN {exit !(x ~ /^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/)}' ||
        die "non-numeric PRM or grid parameter: $item"
done

RANGE="$(python3 - "$RNG_SAMP_RATE" "$NEAR_RANGE" "$X_MIN" "$X_MAX" <<'PY'
import math
import sys
rate, near, xmin, xmax = map(float, sys.argv[1:])
value = near + (3.0e8 / rate / 2.0) * (((xmin + xmax) / 2.0) / 2.0)
if not math.isfinite(value) or value <= 0:
    raise SystemExit("invalid calculated range")
print(round(value))
PY
)"

echo "========================================"
echo "Run 4.2 input check"
echo "Track root             : $ROOT"
echo "SBAS directory         : $SBAS_DIR"
echo "Interferogram pairs    : $PAIR_COUNT"
echo "Baseline scenes        : $BASELINE_COUNT"
echo "Template pair          : $SELECTED_PAIR"
echo "Template grid          : $GRID_SOURCE"
echo "Grid geometry          : $NX x $NY, x=$X_MIN/$X_MAX, y=$Y_MIN/$Y_MAX"
echo "Grid increments        : $X_INC/$Y_INC"
echo "radar_wavelength       : $WAVELENGTH ($WAVELENGTH_SOURCE)"
echo "rng_samp_rate          : $RNG_SAMP_RATE"
echo "near_range             : $NEAR_RANGE"
echo "Calculated center range: $RANGE m"
echo "Incidence angle        : $INCIDENCE degrees"
echo "Smoothing              : $SMOOTH"
echo "========================================"

if (( $# == 0 )); then
    usage
    echo "[CHECK ONLY] prep_sbas.csh and sbas_parallel were not run."
    exit 0
fi

cd "$SBAS_DIR"
STAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_DIR="run4.2_backup_$STAMP"
backup_count=0
for name in intf.tab scene.tab supermaster.PRM prep_sbas.log range_check.log run_sbas_parallel.sh run4.3_sbas_parallel.sh run4.2_complete; do
    if [[ -e "$name" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$name" "$BACKUP_DIR/"
        ((backup_count+=1))
    fi
done
(( backup_count > 0 )) && echo "[BACKUP] Previous Run 4.2 files: $(pwd -P)/$BACKUP_DIR"
if [[ -e run4.3_sbas_parallel.sh ]]; then
    rm -f -- run4.3_sbas_parallel.sh
    echo "[CLEANUP] Removed legacy generated command after backup: run4.3_sbas_parallel.sh"
fi

cp "../$PRM_SOURCE" supermaster.PRM
PREP_LOG="prep_sbas.log"
RANGE_LOG="range_check.log"
CMD_FILE="run_sbas_parallel.sh"

echo "[STEP 1] Run prep_sbas.csh"
prep_sbas.csh intf.in baseline_table.dat ../merge "$UNWRAP_NAME" "$CORR_NAME" |
    tee "$PREP_LOG"

[[ -s intf.tab ]] || die "prep_sbas.csh did not generate intf.tab"
[[ -s scene.tab ]] || die "prep_sbas.csh did not generate scene.tab"

SBAS_LINE="$(grep -E '^sbas[[:space:]]' "$PREP_LOG" | tail -n 1 || true)"
[[ -n "$SBAS_LINE" ]] || die "cannot find the generated sbas command in $PREP_LOG"

read -r _ _ _ N S XDIM YDIM _ <<< "$SBAS_LINE"
for value in "$N" "$S" "$XDIM" "$YDIM"; do
    [[ "$value" =~ ^[0-9]+$ ]] || die "invalid N/S/XDIM/YDIM parsed from prep_sbas.log"
done

cat > "$RANGE_LOG" <<EOF_RANGE
========== RANGE CALCULATION ==========
c              = 300000000.0
rng_samp_rate  = $RNG_SAMP_RATE
near_range     = $NEAR_RANGE
x_min          = $X_MIN
x_max          = $X_MAX
x_center       = $(python3 -c "print((float('$X_MIN')+float('$X_MAX'))/2.0)")
formula        = near_range + (c/rng_samp_rate/2) * (x_center/2)
range_round    = $RANGE
=======================================
EOF_RANGE

SBAS_CMD="sbas_parallel intf.tab scene.tab $N $S $XDIM $YDIM -smooth $SMOOTH -wavelength $WAVELENGTH -incidence $INCIDENCE -range $RANGE -rms -dem"

cat > "$CMD_FILE" <<EOF_CMD
#!/usr/bin/env bash
set -euo pipefail
cd "$(pwd -P)"
$SBAS_CMD
EOF_CMD
chmod +x "$CMD_FILE"

INTF_TAB_COUNT="$(wc -l < intf.tab | tr -d ' ')"
SCENE_TAB_COUNT="$(wc -l < scene.tab | tr -d ' ')"
[[ "$INTF_TAB_COUNT" == "$PAIR_COUNT" ]] ||
    die "intf.tab count ($INTF_TAB_COUNT) differs from Run 4.1 pairs ($PAIR_COUNT)"

{
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'pairs=%s\n' "$PAIR_COUNT"
    printf 'scenes=%s\n' "$SCENE_TAB_COUNT"
    printf 'template_pair=%s\n' "$SELECTED_PAIR"
    printf 'N=%s\nS=%s\nXDIM=%s\nYDIM=%s\n' "$N" "$S" "$XDIM" "$YDIM"
    printf 'wavelength=%s\nincidence=%s\nrange=%s\nsmooth=%s\n' "$WAVELENGTH" "$INCIDENCE" "$RANGE" "$SMOOTH"
    printf 'command=%s\n' "$SBAS_CMD"
} > run4.2_complete

echo "========================================"
echo "[DONE] Run 4.2 prepared the SBAS inputs and command."
echo "intf.tab       : $(pwd -P)/intf.tab ($INTF_TAB_COUNT)"
echo "scene.tab      : $(pwd -P)/scene.tab ($SCENE_TAB_COUNT)"
echo "supermaster.PRM: $(pwd -P)/supermaster.PRM"
echo "Range log      : $(pwd -P)/$RANGE_LOG"
echo "Command script : $(pwd -P)/$CMD_FILE"
echo "Prepared command:"
echo "  $SBAS_CMD"
echo "[INFO] sbas_parallel was NOT started."
echo "========================================"
