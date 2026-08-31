#!/usr/bin/env bash
# Run 6.7: reference deseasoned InSAR displacement to the GNSS LOS time series.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 24, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

DEFAULT_JOBS=5
FILTER_KM="${FILTER_KM:-5}"
SMOOTH_PIX="${SMOOTH_PIX:-17}"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 6.7: GNSS-reference the deseasoned InSAR displacement time series

Check only:
  ./run6.7_correct_displacement_with_GNSS.sh

Formal run with 5 parallel jobs:
  ./run6.7_correct_displacement_with_GNSS.sh 1

Formal run with a selected number of jobs:
  ./run6.7_correct_displacement_with_GNSS.sh 1 10

Algorithm:
  difference = InSAR displacement - GNSS LOS displacement
  correction = approximately 80 km smoothed long-wavelength difference
  corrected  = InSAR displacement - correction

Optional environment settings:
  FILTER_KM=5 SMOOTH_PIX=17 ./run6.7_correct_displacement_with_GNSS.sh 1 5
USAGE
}

MODE="${1:-}"
JOBS="${2:-$DEFAULT_JOBS}"
(( $# <= 2 )) || { usage; die "too many arguments"; }
[[ -z "$MODE" || "$MODE" == "1" ]] || { usage; die "use no argument or mode 1"; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "parallel jobs must be a positive integer"
awk -v x="$FILTER_KM" 'BEGIN{exit !(x+0>0)}' || die "FILTER_KM must be positive"
[[ "$SMOOTH_PIX" =~ ^[1-9][0-9]*$ ]] || die "SMOOTH_PIX must be a positive integer"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] || die "run in a T-number track root: $ROOT"

DISP_DIR="$ROOT/sbas_demcorr_pin/disp_deseason"
GNSS_DIR="$ROOT/GNSS2LOS_correction/GNSS_LOS_timeseries"
PRM="$ROOT/sbas_demcorr_pin/supermaster.PRM"
OUT_DIR="$ROOT/GNSS2LOS_correction/GNSS_corrected_displacement"
RUN6_DIR="$ROOT/GNSS2LOS_correction"

for command in gmt awk python3; do
    command -v "$command" >/dev/null 2>&1 || die "$command not found in PATH"
done
[[ -d "$DISP_DIR" ]] || die "missing deseasoned displacement directory: $DISP_DIR"
[[ -d "$GNSS_DIR" ]] || die "missing GNSS LOS time-series directory: $GNSS_DIR"
[[ -s "$PRM" ]] || die "missing supermaster PRM: $PRM"
[[ -s "$RUN6_DIR/run6.5_complete" ]] || die "missing Run 6.5 completion marker"

MANIFEST="$(mktemp /tmp/run6.7_manifest.XXXXXX)"
trap 'rm -f "$MANIFEST"' EXIT INT TERM
python3 - "$DISP_DIR" "$GNSS_DIR" > "$MANIFEST" <<'PY'
from pathlib import Path
import re
import sys

disp_dir, gnss_dir = map(Path, sys.argv[1:])
disp_re = re.compile(r"disp_(\d{7})\.grd$")
gnss_re = re.compile(r"gnss_LOS_(\d{7})\.grd$")

def collect(folder, regex):
    result = {}
    for path in sorted(folder.glob("*.grd")):
        match = regex.fullmatch(path.name)
        if match:
            result[match.group(1)] = path.resolve()
    return result

disp = collect(disp_dir, disp_re)
gnss = collect(gnss_dir, gnss_re)
if len(disp) < 2:
    raise SystemExit("[ERROR] fewer than two deseasoned InSAR displacement grids")
missing_gnss = sorted(set(disp) - set(gnss))
extra_gnss = sorted(set(gnss) - set(disp))
if missing_gnss or extra_gnss:
    if missing_gnss:
        print("[ERROR] InSAR epochs missing from GNSS time series: " + ", ".join(missing_gnss[:20]), file=sys.stderr)
    if extra_gnss:
        print("[ERROR] GNSS epochs absent from InSAR time series: " + ", ".join(extra_gnss[:20]), file=sys.stderr)
    raise SystemExit(1)
for tag in sorted(disp):
    print(tag, disp[tag], gnss[tag], sep="\t")
PY

EPOCHS="$(wc -l < "$MANIFEST" | awk '{print $1}')"
[[ "$EPOCHS" -ge 2 ]] || die "invalid empty epoch manifest"
REF_DISP="$(awk -F '\t' 'NR==1{print $2}' "$MANIFEST")"

read -r _ _ _ _ _ _ _ XINC YINC NX NY REG _ \
    <<< "$(gmt grdinfo "$REF_DISP" -C | awk 'NR==1{print}')"
[[ "$XINC" != "0" && "$YINC" != "0" ]] || die "invalid grid increments in $REF_DISP"

RNG_RATE="$(awk '$1=="rng_samp_rate"{print $3; exit}' "$PRM")"
SC_VEL="$(awk '$1=="SC_vel"{print $3; exit}' "$PRM")"
PRF="$(awk '$1=="PRF"{print $3; exit}' "$PRM")"
[[ -n "$RNG_RATE" && -n "$SC_VEL" && -n "$PRF" ]] || die "failed to read rng_samp_rate, SC_vel or PRF from $PRM"

read -r RNG_PIXEL_M AZ_PIXEL_M DX_M DY_M COARSE_NX COARSE_NY COARSE_DX_M COARSE_DY_M <<< "$(
awk -v rate="$RNG_RATE" -v vel="$SC_VEL" -v prf="$PRF" \
    -v xi="$XINC" -v yi="$YINC" -v nx="$NX" -v ny="$NY" -v reg="$REG" -v km="$FILTER_KM" 'BEGIN {
    rpx=1.556*299792458.0/rate/2.0;
    apx=vel/prf;
    dx=xi*rpx; dy=yi*apx; target=km*1000.0;
    sx=int(target/dx+0.5); sy=int(target/dy+0.5);
    if (sx<1) sx=1; if (sy<1) sy=1;
    if (reg==1) {
        cnx=int(nx/sx+0.5); cny=int(ny/sy+0.5);
        if (cnx<2) cnx=2; if (cny<2) cny=2;
        cdx=nx*dx/cnx; cdy=ny*dy/cny;
    } else {
        cnx=int((nx-1)/sx+0.5)+1; cny=int((ny-1)/sy+0.5)+1;
        if (cnx<2) cnx=2; if (cny<2) cny=2;
        cdx=(nx-1)*dx/(cnx-1); cdy=(ny-1)*dy/(cny-1);
    }
    printf "%.6f %.6f %.6f %.6f %d %d %.3f %.3f", rpx,apx,dx,dy,cnx,cny,cdx,cdy
}')"
COARSE_SPEC="${COARSE_NX}+n/${COARSE_NY}+n"

echo "========================================"
echo "Run 6.7: GNSS-reference deseasoned InSAR displacement"
echo "Run mode             : $([[ $MODE == 1 ]] && echo FORMAL || echo 'CHECK ONLY')"
echo "Track root           : $ROOT"
echo "InSAR directory      : $DISP_DIR"
echo "GNSS time series     : $GNSS_DIR"
echo "Matched epochs       : $EPOCHS"
echo "Reference grid       : $REF_DISP"
echo "Reference size       : $NX x $NY (registration=$REG)"
echo "Radar pixel size     : range=$RNG_PIXEL_M m, azimuth=$AZ_PIXEL_M m"
echo "Input grid spacing   : range=$DX_M m, azimuth=$DY_M m"
echo "Coarse target        : approximately $FILTER_KM km"
echo "Coarse grid size     : $COARSE_NX x $COARSE_NY"
echo "Actual coarse spacing: range=$COARSE_DX_M m, azimuth=$COARSE_DY_M m"
echo "Smoothing width      : $SMOOTH_PIX coarse-grid pixels (approximately 80 km)"
echo "Parallel jobs        : $JOBS"
echo "Output directory     : $OUT_DIR"
echo "========================================"

if [[ -z "$MODE" ]]; then
    usage
    echo "[CHECK ONLY] Epoch matching and required inputs are valid."
    echo "[CHECK ONLY] No output was created or modified."
    echo "[NEXT] ./run6.7_correct_displacement_with_GNSS.sh 1"
    exit 0
fi

mkdir -p "$OUT_DIR"
WORKROOT="$OUT_DIR/.run6.7_work"
mkdir -p "$WORKROOT"
WORKER="$WORKROOT/run_one.sh"
cat > "$WORKER" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
tag="$1"; disp="$2"; gnss="$3"; outdir="$4"; workroot="$5"; coarse_spec="$6"; smooth_pix="$7"
out="$outdir/disp_${tag}_gnssref_5km_80km.grd"
corr="$outdir/diff_${tag}_smooth80km_full.grd"
if [[ -s "$out" && -s "$corr" && "$out" -nt "$disp" && "$out" -nt "$gnss" && "$corr" -nt "$disp" && "$corr" -nt "$gnss" ]]; then
    gmt grdinfo "$out" -C >/dev/null 2>&1 && gmt grdinfo "$corr" -C >/dev/null 2>&1 && {
        disp_done_geometry="$(gmt grdinfo "$disp" -Cn | awk 'NR==1{print $1,$2,$3,$4,$7,$8,$9,$10,$11}')"
        out_done_geometry="$(gmt grdinfo "$out" -Cn | awk 'NR==1{print $1,$2,$3,$4,$7,$8,$9,$10,$11}')"
        corr_done_geometry="$(gmt grdinfo "$corr" -Cn | awk 'NR==1{print $1,$2,$3,$4,$7,$8,$9,$10,$11}')"
        if [[ "$disp_done_geometry" == "$out_done_geometry" && "$disp_done_geometry" == "$corr_done_geometry" ]]; then
            echo "[SKIP] $tag already complete"; exit 0
        fi
    }
fi
work="$workroot/$tag"
rm -rf "$work"; mkdir -p "$work"
trap 'rm -rf "$work"' EXIT INT TERM
cd "$work"
ln -s "$disp" disp.grd
ln -s "$gnss" gnss.grd
gmt grdmath disp.grd gnss.grd SUB = diff.grd
read -r xmin xmax ymin ymax _ _ _ _ _ _ reg _ <<< "$(gmt grdinfo disp.grd -Cn | awk 'NR==1{print}')"
region="${xmin}/${xmax}/${ymin}/${ymax}"
if [[ "$reg" == "1" ]]; then
    gmt grdsample diff.grd -R"$region" -I"$coarse_spec" -rp -Gdiff_coarse.grd
else
    gmt grdsample diff.grd -R"$region" -I"$coarse_spec" -rg -Gdiff_coarse.grd
fi
gmt grdfilter diff_coarse.grd -Dp -Fg"$smooth_pix" -Gdiff_smooth.grd
full_inc="$(gmt grdinfo disp.grd -I | awk 'NR==1{print $1}')"
if [[ "$reg" == "1" ]]; then
    gmt grdsample diff_smooth.grd -R"$region" "$full_inc" -rp -Gcorrection_resampled.grd
else
    gmt grdsample diff_smooth.grd -R"$region" "$full_inc" -rg -Gcorrection_resampled.grd
fi
input_geometry="$(gmt grdinfo disp.grd -Cn | awk 'NR==1{print $1,$2,$3,$4,$7,$8,$9,$10,$11}')"
resampled_geometry="$(gmt grdinfo correction_resampled.grd -Cn | awk 'NR==1{print $1,$2,$3,$4,$7,$8,$9,$10,$11}')"
if [[ "$resampled_geometry" == "$input_geometry" ]]; then
    mv correction_resampled.grd correction_full.grd
else
    echo "[ALIGN] $tag resampled edge differs from the InSAR template; restore the exact template region"
    echo "[ALIGN] uncovered outer-edge cells use zero correction"
    gmt grdcut correction_resampled.grd -R"$region" -N0 -Gcorrection_full.grd
fi
output_geometry="$(gmt grdinfo correction_full.grd -Cn | awk 'NR==1{print $1,$2,$3,$4,$7,$8,$9,$10,$11}')"
[[ "$input_geometry" == "$output_geometry" ]] || {
    echo "[ERROR] $tag correction grid geometry differs from InSAR input" >&2
    echo "[ERROR] input : $input_geometry" >&2
    echo "[ERROR] output: $output_geometry" >&2
    exit 1
}
gmt grdmath disp.grd correction_full.grd SUB = corrected.grd
gmt grdinfo correction_full.grd -C >/dev/null
gmt grdinfo corrected.grd -C >/dev/null
mv -f correction_full.grd "$corr"
mv -f corrected.grd "$out"
echo "[OK] $tag"
WORKER
chmod +x "$WORKER"

JOBS_FILE="$WORKROOT/jobs.txt"
ARGS_FILE="$WORKROOT/jobs.args0"
: > "$JOBS_FILE"
: > "$ARGS_FILE"
while IFS=$'\t' read -r tag disp gnss; do
    printf '%q %q %q %q %q %q %q %q\n' \
        "$WORKER" "$tag" "$disp" "$gnss" "$OUT_DIR" "$WORKROOT" "$COARSE_SPEC" "$SMOOTH_PIX" >> "$JOBS_FILE"
    printf '%s\0' "$tag" "$disp" "$gnss" "$OUT_DIR" "$WORKROOT" "$COARSE_SPEC" "$SMOOTH_PIX" >> "$ARGS_FILE"
done < "$MANIFEST"

echo "[RUN] Correct $EPOCHS epochs with up to $JOBS parallel jobs"
if command -v parallel >/dev/null 2>&1; then
    parallel -j "$JOBS" --halt soon,fail=1 < "$JOBS_FILE"
else
    xargs -0 -n 7 -P "$JOBS" "$WORKER" < "$ARGS_FILE"
fi

N_CORRECTED="$(find "$OUT_DIR" -maxdepth 1 -type f -name 'disp_*_gnssref_5km_80km.grd' | wc -l | awk '{print $1}')"
N_CORRECTION="$(find "$OUT_DIR" -maxdepth 1 -type f -name 'diff_*_smooth80km_full.grd' | wc -l | awk '{print $1}')"
[[ "$N_CORRECTED" == "$EPOCHS" && "$N_CORRECTION" == "$EPOCHS" ]] || \
    die "output count mismatch: corrected=$N_CORRECTED, correction=$N_CORRECTION, expected=$EPOCHS"
rm -rf "$WORKROOT"
cat > "$RUN6_DIR/run6.7_complete" <<EOF
Run 6.7 completed successfully
track=$TRACK
epochs=$EPOCHS
filter_km=$FILTER_KM
smooth_pixels=$SMOOTH_PIX
output=$OUT_DIR
completed=$(date '+%Y-%m-%d %H:%M:%S %z')
EOF

echo "========================================"
echo "[DONE] Run 6.7 completed successfully: $EPOCHS epochs"
echo "Corrected displacement: $OUT_DIR/disp_YYYYDDD_gnssref_5km_80km.grd"
echo "Long-wave correction  : $OUT_DIR/diff_YYYYDDD_smooth80km_full.grd"
echo "[NEXT] ./run6.8_make_velocity_from_GNSS_corrected_timeseries.py"
echo "========================================"
