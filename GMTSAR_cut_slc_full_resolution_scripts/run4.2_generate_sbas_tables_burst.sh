#!/usr/bin/env bash
# Run 4.2: generate GMTSAR SBAS tables and command for one burst stack.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 4.2: generate burst SBAS tables and command

Usage:
  ./run4.2_generate_sbas_tables_burst.sh
  ./run4.2_generate_sbas_tables_burst.sh 1
  ./run4.2_generate_sbas_tables_burst.sh 1 38 1.0

No arguments:
  Check Run 4.1 inputs and preview the calculated SBAS parameters.
  prep_sbas.csh and sbas_parallel are not run.

Mode 1:
  Generate intf.tab, scene.tab and run_sbas_parallel.sh.
  sbas_parallel itself is not started.

Optional values:
  INCIDENCE  incidence angle in degrees; default 38
  SMOOTH     SBAS spatial smoothing; default 1.0

Inputs:
  sbas_burst/intflist_new
  sbas_burst/intf.in
  sbas_burst/baseline_table.dat
  sbas_burst/supermaster.PRM
  sbas_burst/supermaster.LED
  burst/intf_all/<pair>/unwrap.grd
  burst/intf_all/<pair>/corr.grd

Outputs:
  sbas_burst/intf.tab
  sbas_burst/scene.tab
  sbas_burst/prep_sbas.log
  sbas_burst/range_check.log
  sbas_burst/run_sbas_parallel.sh
  sbas_burst/run4.2_complete

The generated SBAS command retains the conventional -rms -dem options.
No merge/ directory is used.
========================================
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
(( $# <= 3 )) || die "usage: $0 [1 [INCIDENCE [SMOOTH]]]"
if (( $# > 0 )); then
    [[ "$1" == 1 ]] || die "MODE must be 1"
fi
INCIDENCE="${2:-38}"
SMOOTH="${3:-1.0}"

awk -v x="$INCIDENCE" \
    'BEGIN {exit !(x ~ /^[0-9]+([.][0-9]+)?$/ && x > 0 && x < 90)}' ||
    die "INCIDENCE must be between 0 and 90 degrees"
awk -v x="$SMOOTH" \
    'BEGIN {exit !(x ~ /^[0-9]+([.][0-9]+)?$/ && x >= 0)}' ||
    die "SMOOTH must be zero or positive"

for command_name in awk basename cp date grep gmt head mktemp mv sed sort tail tr uniq wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done
command -v prep_sbas.csh >/dev/null 2>&1 ||
    die "prep_sbas.csh not found in PATH"
if (( $# > 0 )); then
    command -v sbas_parallel >/dev/null 2>&1 ||
        die "sbas_parallel not found in PATH"
fi

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT)"

BURST_DIR="$ROOT/burst"
PAIR_ROOT="$BURST_DIR/intf_all"
SBAS_DIR="$ROOT/sbas_burst"
RUN41_COMPLETE="$SBAS_DIR/run4.1_complete"
INTFLIST="$SBAS_DIR/intflist_new"
INTF_IN="$SBAS_DIR/intf.in"
BASELINE="$SBAS_DIR/baseline_table.dat"
SUPERMASTER_PRM="$SBAS_DIR/supermaster.PRM"
SUPERMASTER_LED="$SBAS_DIR/supermaster.LED"
UNWRAP_NAME="unwrap.grd"
CORR_NAME="corr.grd"

[[ -d "$PAIR_ROOT" ]] || die "missing $PAIR_ROOT"
[[ -d "$SBAS_DIR" ]] || die "missing $SBAS_DIR; complete Run 4.1 first"
for file in "$RUN41_COMPLETE" "$INTFLIST" "$INTF_IN" "$BASELINE" \
            "$SUPERMASTER_PRM" "$SUPERMASTER_LED"; do
    [[ -s "$file" ]] || die "missing or empty: $file"
done
RUN41_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$RUN41_COMPLETE")"
[[ "$RUN41_STATUS" == COMPLETE ]] || die "Run 4.1 status is not COMPLETE"

PAIR_COUNT="$(wc -l < "$INTFLIST" | tr -d ' ')"
INTF_COUNT="$(wc -l < "$INTF_IN" | tr -d ' ')"
BASELINE_COUNT="$(wc -l < "$BASELINE" | tr -d ' ')"
[[ "$PAIR_COUNT" =~ ^[1-9][0-9]*$ ]] || die "empty or invalid intflist_new"
[[ "$PAIR_COUNT" -eq "$INTF_COUNT" ]] ||
    die "intflist_new=$PAIR_COUNT but intf.in=$INTF_COUNT"
[[ "$BASELINE_COUNT" =~ ^[1-9][0-9]*$ ]] || die "empty baseline_table.dat"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run4.2-burst.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT INT TERM
MISSING="$TMP/missing.tsv"
printf 'pair\tmissing_or_empty_files\n' > "$MISSING"
SELECTED_PAIR=''

while IFS= read -r pair; do
    [[ "$pair" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] || {
        printf '%s\tinvalid_pair_name\n' "$pair" >> "$MISSING"
        continue
    }
    pair_dir="$PAIR_ROOT/$pair"
    missing=()
    [[ -s "$pair_dir/$UNWRAP_NAME" ]] || missing+=("$UNWRAP_NAME")
    [[ -s "$pair_dir/$CORR_NAME" ]] || missing+=("$CORR_NAME")
    if (( ${#missing[@]} > 0 )); then
        joined="$(IFS=,; printf '%s' "${missing[*]}")"
        printf '%s\t%s\n' "$pair" "$joined" >> "$MISSING"
    elif [[ -z "$SELECTED_PAIR" ]]; then
        SELECTED_PAIR="$pair"
    fi
done < "$INTFLIST"

MISSING_COUNT="$(( $(wc -l < "$MISSING" | tr -d ' ') - 1 ))"
if (( MISSING_COUNT > 0 )); then
    printf '[ERROR] %s SBAS pair inputs are incomplete:\n' "$MISSING_COUNT" >&2
    sed -n '1,21p' "$MISSING" >&2
    (( MISSING_COUNT <= 20 )) || printf '%s\n' '[INFO] Only the first 20 are shown.' >&2
    exit 1
fi
[[ -n "$SELECTED_PAIR" ]] || die "no complete pair is available as a grid template"

GRID_SOURCE="$PAIR_ROOT/$SELECTED_PAIR/$UNWRAP_NAME"
read -r _ X_MIN X_MAX Y_MIN Y_MAX _ _ X_INC Y_INC NX NY REG _ \
    <<< "$(gmt grdinfo "$GRID_SOURCE" -C)"
for value in "$X_MIN" "$X_MAX" "$Y_MIN" "$Y_MAX" "$X_INC" "$Y_INC" "$NX" "$NY"; do
    [[ -n "$value" ]] || die "failed to read grid geometry from $GRID_SOURCE"
done

read_prm_value() {
    local key="$1" file="$2"
    awk -v key="$key" '$1==key {print $3; exit}' "$file"
}

WAVELENGTH="$(read_prm_value radar_wavelength "$SUPERMASTER_PRM")"
RNG_SAMP_RATE="$(read_prm_value rng_samp_rate "$SUPERMASTER_PRM")"
NEAR_RANGE="$(read_prm_value near_range "$SUPERMASTER_PRM")"
if [[ -z "$WAVELENGTH" ]]; then
    WAVELENGTH='0.0554658'
    WAVELENGTH_SOURCE='Sentinel-1 fallback'
else
    WAVELENGTH_SOURCE='sbas_burst/supermaster.PRM'
fi
[[ -n "$RNG_SAMP_RATE" ]] || die "cannot read rng_samp_rate from $SUPERMASTER_PRM"
[[ -n "$NEAR_RANGE" ]] || die "cannot read near_range from $SUPERMASTER_PRM"

for item in "$WAVELENGTH" "$RNG_SAMP_RATE" "$NEAR_RANGE" "$X_MIN" "$X_MAX"; do
    awk -v x="$item" \
        'BEGIN {exit !(x ~ /^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/)}' ||
        die "non-numeric PRM or grid value: $item"
done

X_CENTER="$(awk -v xmin="$X_MIN" -v xmax="$X_MAX" \
    'BEGIN {printf "%.10g", (xmin+xmax)/2.0}')"
RANGE="$(awk -v rate="$RNG_SAMP_RATE" -v near="$NEAR_RANGE" -v x="$X_CENTER" \
    'BEGIN {
        value=near+(300000000.0/rate/2.0)*(x/2.0)
        if (value <= 0) exit 1
        printf "%.0f", value
    }')" || die "failed to calculate center slant range"

printf '%s\n' '========================================'
printf '%s\n' 'Run 4.2 burst SBAS input check'
printf 'Track root             : %s\n' "$ROOT"
printf 'SBAS directory         : %s\n' "$SBAS_DIR"
printf 'Interferogram pairs    : %s\n' "$PAIR_COUNT"
printf 'Baseline scenes        : %s\n' "$BASELINE_COUNT"
printf 'Pair file check        : all unwrap.grd/corr.grd exist and are non-empty\n'
printf 'All-pair geometry check: skipped\n'
printf 'Template pair          : %s\n' "$SELECTED_PAIR"
printf 'Template grid          : %s\n' "$GRID_SOURCE"
printf 'Grid geometry          : %s x %s, x=%s/%s, y=%s/%s\n' \
    "$NX" "$NY" "$X_MIN" "$X_MAX" "$Y_MIN" "$Y_MAX"
printf 'Grid increments        : %s/%s; registration=%s\n' "$X_INC" "$Y_INC" "$REG"
printf 'radar_wavelength       : %s (%s)\n' "$WAVELENGTH" "$WAVELENGTH_SOURCE"
printf 'rng_samp_rate          : %s\n' "$RNG_SAMP_RATE"
printf 'near_range             : %s\n' "$NEAR_RANGE"
printf 'Calculated center range: %s m\n' "$RANGE"
printf 'Incidence angle        : %s degrees\n' "$INCIDENCE"
printf 'Smoothing              : %s\n' "$SMOOTH"
printf 'SBAS internal DEM term : enabled (-dem)\n'
printf '%s\n' '========================================'

if (( $# == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] prep_sbas.csh and sbas_parallel were not run.'
    printf '%s\n' '[NEXT] ./run4.2_generate_sbas_tables_burst.sh 1'
    exit 0
fi

cd "$SBAS_DIR"
STAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_DIR="run4.2_backup_$STAMP"
backup_count=0
for name in intf.tab scene.tab prep_sbas.log range_check.log run_sbas_parallel.sh run4.2_complete; do
    if [[ -e "$name" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$name" "$BACKUP_DIR/"
        backup_count=$((backup_count + 1))
    fi
done
(( backup_count == 0 )) || printf '[BACKUP] Previous Run 4.2 files: %s/%s\n' "$(pwd -P)" "$BACKUP_DIR"

PREP_LOG='prep_sbas.log'
RANGE_LOG='range_check.log'
CMD_FILE='run_sbas_parallel.sh'

printf '%s\n' '[STEP 1] Run prep_sbas.csh for burst/intf_all'
set +e
prep_sbas.csh intf.in baseline_table.dat ../burst/intf_all "$UNWRAP_NAME" "$CORR_NAME" \
    2>&1 | tee "$PREP_LOG"
PREP_STATUS=${PIPESTATUS[0]}
set -e
(( PREP_STATUS == 0 )) || die "prep_sbas.csh failed with status $PREP_STATUS"

[[ -s intf.tab ]] || die "prep_sbas.csh did not generate intf.tab"
[[ -s scene.tab ]] || die "prep_sbas.csh did not generate scene.tab"
SBAS_LINE="$(grep -E '^sbas[[:space:]]' "$PREP_LOG" | tail -n 1 || true)"
[[ -n "$SBAS_LINE" ]] || die "cannot find the generated sbas command in $PREP_LOG"

read -r _ _ _ N S XDIM YDIM _ <<< "$SBAS_LINE"
for value in "$N" "$S" "$XDIM" "$YDIM"; do
    [[ "$value" =~ ^[0-9]+$ ]] ||
        die "invalid N/S/XDIM/YDIM parsed from prep_sbas.log: $SBAS_LINE"
done

cat > "$RANGE_LOG" <<EOF_RANGE
========== RANGE CALCULATION ==========
c              = 300000000.0
rng_samp_rate  = $RNG_SAMP_RATE
near_range     = $NEAR_RANGE
x_min          = $X_MIN
x_max          = $X_MAX
x_center       = $X_CENTER
formula        = near_range + (c/rng_samp_rate/2) * (x_center/2)
range_round    = $RANGE
=======================================
EOF_RANGE

SBAS_CMD="sbas_parallel intf.tab scene.tab $N $S $XDIM $YDIM -smooth $SMOOTH -wavelength $WAVELENGTH -incidence $INCIDENCE -range $RANGE -rms -dem"
cat > "$CMD_FILE" <<EOF_COMMAND
#!/usr/bin/env bash
set -euo pipefail
cd "$(pwd -P)"
$SBAS_CMD
EOF_COMMAND
chmod +x "$CMD_FILE"

INTF_TAB_COUNT="$(wc -l < intf.tab | tr -d ' ')"
SCENE_TAB_COUNT="$(wc -l < scene.tab | tr -d ' ')"
[[ "$INTF_TAB_COUNT" -eq "$PAIR_COUNT" ]] ||
    die "intf.tab=$INTF_TAB_COUNT but Run 4.1 pairs=$PAIR_COUNT"
[[ "$SCENE_TAB_COUNT" -eq "$BASELINE_COUNT" ]] ||
    die "scene.tab=$SCENE_TAB_COUNT but baseline scenes=$BASELINE_COUNT"

{
    printf 'status=COMPLETE\n'
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'pairs=%s\n' "$PAIR_COUNT"
    printf 'scenes=%s\n' "$SCENE_TAB_COUNT"
    printf 'pair_root=%s\n' "$PAIR_ROOT"
    printf 'unwrap_name=%s\n' "$UNWRAP_NAME"
    printf 'corr_name=%s\n' "$CORR_NAME"
    printf 'template_pair=%s\n' "$SELECTED_PAIR"
    printf 'N=%s\nS=%s\nXDIM=%s\nYDIM=%s\n' "$N" "$S" "$XDIM" "$YDIM"
    printf 'wavelength=%s\nincidence=%s\nrange=%s\nsmooth=%s\n' \
        "$WAVELENGTH" "$INCIDENCE" "$RANGE" "$SMOOTH"
    printf 'internal_dem_term=enabled\n'
    printf 'command=%s\n' "$SBAS_CMD"
} > run4.2_complete

printf '%s\n' '========================================'
printf '%s\n' '[DONE] Run 4.2 prepared burst SBAS tables and command.'
printf 'intf.tab       : %s/intf.tab (%s)\n' "$(pwd -P)" "$INTF_TAB_COUNT"
printf 'scene.tab      : %s/scene.tab (%s)\n' "$(pwd -P)" "$SCENE_TAB_COUNT"
printf 'Supermaster PRM: %s/supermaster.PRM\n' "$(pwd -P)"
printf 'Supermaster LED: %s/supermaster.LED\n' "$(pwd -P)"
printf 'Range log      : %s/%s\n' "$(pwd -P)" "$RANGE_LOG"
printf 'Command script : %s/%s\n' "$(pwd -P)" "$CMD_FILE"
printf 'Prepared command:\n  %s\n' "$SBAS_CMD"
printf '%s\n' '[INFO] sbas_parallel was NOT started.'
printf '%s\n' '[NEXT] Inspect intf.tab, scene.tab and run_sbas_parallel.sh.'
printf '%s\n' '========================================'
