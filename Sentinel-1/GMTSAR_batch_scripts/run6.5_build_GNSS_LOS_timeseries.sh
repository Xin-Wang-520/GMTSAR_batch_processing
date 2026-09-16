#!/usr/bin/env bash
# Run 6.5: build GNSS LOS displacement grids at all InSAR epochs.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 24, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

OUT_DIR="GNSS2LOS_correction"
DISP_DIR="sbas_demcorr_pin/disp_deseason"
DEFAULT_JOBS=5

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 6.5: build GNSS LOS cumulative-displacement grids

Check only:
  ./run6.5_build_GNSS_LOS_timeseries.sh

Formal run with 5 parallel jobs:
  ./run6.5_build_GNSS_LOS_timeseries.sh 1

Formal run with a selected number of jobs:
  ./run6.5_build_GNSS_LOS_timeseries.sh 1 10

Date convention:
  YYYY000 = January 1
  date = January 1 + DDD days
  elapsed_years = actual elapsed days / 365.0
USAGE
}

MODE="${1:-}"
JOBS="${2:-$DEFAULT_JOBS}"
(( $# <= 2 )) || { usage; die "too many arguments"; }
[[ -z "$MODE" || "$MODE" == "1" ]] || { usage; die "use no argument or mode 1"; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "parallel jobs must be a positive integer"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] || die "run in a T-number track root: $ROOT"
OUT_DIR="$ROOT/$OUT_DIR"
DISP_DIR="$ROOT/$DISP_DIR"
VEL_GRID="$OUT_DIR/GNSS_to_LOS_ra.grd"

for command in gmt python3; do
    command -v "$command" >/dev/null 2>&1 || die "$command not found in PATH"
done
[[ -s "$VEL_GRID" ]] || die "missing Run 6.4 radar velocity: $VEL_GRID"
[[ -s "$OUT_DIR/run6.4_complete" ]] || die "missing Run 6.4 marker"
[[ -d "$DISP_DIR" ]] || die "missing displacement directory: $DISP_DIR"

MANIFEST="$(mktemp /tmp/run6.5_epochs.XXXXXX)"
trap 'rm -f "$MANIFEST"' EXIT INT TERM
python3 - "$DISP_DIR" > "$MANIFEST" <<'PY'
import calendar
import datetime as dt
import pathlib
import re
import sys

folder = pathlib.Path(sys.argv[1])
pattern = re.compile(r"disp_(\d{4})(\d{3})\.grd$")
items = []
for path in sorted(folder.glob("disp_*.grd")):
    match = pattern.fullmatch(path.name)
    if not match:
        continue
    year, ddd = map(int, match.groups())
    maximum = 365 if calendar.isleap(year) else 364
    if not 0 <= ddd <= maximum:
        raise SystemExit(f"invalid zero-based day of year: {year:04d}{ddd:03d}")
    date = dt.date(year, 1, 1) + dt.timedelta(days=ddd)
    items.append((date, f"{year:04d}{ddd:03d}", path.resolve()))
if not items:
    raise SystemExit("no valid disp_YYYYDDD.grd found")
items.sort()
first = items[0][0]
for date, tag, path in items:
    days = (date - first).days
    print(tag, date.isoformat(), days, f"{days / 365.0:.12f}", path, sep="\t")
PY

EPOCHS="$(wc -l < "$MANIFEST" | awk '{print $1}')"
FIRST_LINE="$(head -n 1 "$MANIFEST")"
LAST_LINE="$(tail -n 1 "$MANIFEST")"

echo "========================================"
echo "Run 6.5: build GNSS LOS displacement time series"
echo "Run mode          : $([[ $MODE == 1 ]] && echo FORMAL || echo 'CHECK ONLY')"
echo "Track root        : $ROOT"
echo "GNSS LOS velocity : $VEL_GRID"
echo "InSAR epochs      : $EPOCHS"
echo "First epoch       : $(cut -f1-4 <<< "$FIRST_LINE")"
echo "Last epoch        : $(cut -f1-4 <<< "$LAST_LINE")"
echo "Date convention   : YYYY000 = January 1"
echo "Year conversion   : actual elapsed days / 365.0"
echo "Parallel jobs     : $JOBS"
echo "Output directory  : $OUT_DIR/GNSS_LOS_timeseries"
echo "========================================"

if [[ -z "$MODE" ]]; then
    usage
    echo "[CHECK ONLY] No displacement grid was created or modified."
    echo "[NEXT] ./run6.5_build_GNSS_LOS_timeseries.sh 1"
    exit 0
fi

STAGE="$OUT_DIR/.run6.5_timeseries.$$"
mkdir -p "$STAGE"
WORKER="$STAGE/run_one.sh"
cat > "$WORKER" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
tag="$1"
dt_years="$2"
velocity="$3"
stage="$4"
tmp="$stage/.gnss_LOS_${tag}.$$.grd"
out="$stage/gnss_LOS_${tag}.grd"
gmt grdmath "$velocity" "$dt_years" MUL = "$tmp"
gmt grdinfo "$tmp" -C >/dev/null
mv -f "$tmp" "$out"
echo "[OK] $tag dt=$dt_years yr"
WORKER
chmod +x "$WORKER"

JOBS_FILE="$STAGE/jobs.txt"
while IFS=$'\t' read -r tag date days years source; do
    printf '%q %q %q %q %q\n' "$WORKER" "$tag" "$years" "$VEL_GRID" "$STAGE" >> "$JOBS_FILE"
done < "$MANIFEST"

echo "[RUN] Generate $EPOCHS grids with up to $JOBS parallel jobs"
if command -v parallel >/dev/null 2>&1; then
    parallel -j "$JOBS" --halt soon,fail=1 < "$JOBS_FILE"
else
    xargs -I{} -P "$JOBS" bash -c '{}' < "$JOBS_FILE"
fi

GENERATED="$(find "$STAGE" -maxdepth 1 -type f -name 'gnss_LOS_*.grd' | wc -l | awk '{print $1}')"
[[ "$GENERATED" == "$EPOCHS" ]] || die "generated $GENERATED/$EPOCHS grids"
rm -f "$WORKER" "$JOBS_FILE"

FINAL="$OUT_DIR/GNSS_LOS_timeseries"
rm -rf "$FINAL"
mv "$STAGE" "$FINAL"
cat > "$OUT_DIR/run6.5_complete" <<EOF
Run 6.5 completed successfully
track=$TRACK
epochs=$EPOCHS
first=$(cut -f1 <<< "$FIRST_LINE")
last=$(cut -f1 <<< "$LAST_LINE")
output=$FINAL
completed=$(date '+%Y-%m-%d %H:%M:%S %z')
EOF

echo "========================================"
echo "[DONE] Run 6.5 completed successfully: $GENERATED grids"
echo "Output: $FINAL/gnss_LOS_YYYYDDD.grd"
echo "[NEXT] ./run6.6_validate_GNSS_LOS_timeseries.py"
echo "========================================"
