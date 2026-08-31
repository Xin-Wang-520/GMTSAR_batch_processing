#!/usr/bin/env bash
# Run 3.10: adapt the former Run 3.12 global DEM correction to one burst stack.
# Original unwrap.grd files are preserved.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

JOBS="${1:-16}"
MODEL_TYPE="${2:-6}"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'EOF'
========================================
Run 3.10: burst global DEM correction

Usage:
  ./run3.10_dem_correction_parallel_all_in_one.sh
  ./run3.10_dem_correction_parallel_all_in_one.sh 16 6

No arguments only show this preview. Processing is not started.

JOBS        number of interferograms processed concurrently
MODEL_TYPE  4, 6 or 9; former Run 3.12 recommended value: 6

Inputs:
  burst/topo/topo_ra.grd
  burst/intf_all/<pair>/unwrap.grd
  burst/intf_all/<pair>/corr.grd

Outputs in burst/intf_all/<pair>/:
  unwrap_dem_correct.grd
  unwrap_dem_correction.png
  dem_correction.log

Shared cropped DEM:
  burst/intf_all/dem_ra.grd

No merge/ directory is used and unwrap.grd is not overwritten.
========================================
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then usage; exit 0; fi
if (( $# == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] DEM correction was not started.'
    printf '%s\n' '[NEXT] ./run3.10_dem_correction_parallel_all_in_one.sh 16 6'
    exit 0
fi
(( $# == 2 )) || die "expected: JOBS MODEL_TYPE"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
[[ "$MODEL_TYPE" =~ ^(4|6|9)$ ]] || die "MODEL_TYPE must be 4, 6 or 9"

for cmd in awk basename find gmt mktemp mv python3 rm sort wc xargs; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT)"

PAIR_ROOT="$ROOT/burst/intf_all"
DEM_SOURCE="$ROOT/burst/topo/topo_ra.grd"
SHARED_DEM="$PAIR_ROOT/dem_ra.grd"
[[ -d "$PAIR_ROOT" ]] || die "missing $PAIR_ROOT"
[[ -s "$DEM_SOURCE" ]] || die "missing or empty: $DEM_SOURCE"

mapfile -t DIRS < <(
    find "$PAIR_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*_*' \
        -printf '%f\n' | sort
)
(( ${#DIRS[@]} > 0 )) || die "no pair directories in $PAIR_ROOT"

MISSING="$PAIR_ROOT/run3.10_missing_inputs.tsv"
: > "$MISSING"
for pair in "${DIRS[@]}"; do
    [[ -s "$PAIR_ROOT/$pair/unwrap.grd" ]] ||
        printf '%s\tmissing_or_empty_unwrap.grd\n' "$pair" >> "$MISSING"
    [[ -s "$PAIR_ROOT/$pair/corr.grd" ]] ||
        printf '%s\tmissing_or_empty_corr.grd\n' "$pair" >> "$MISSING"
done
if [[ -s "$MISSING" ]]; then
    sed -n '1,21p' "$MISSING" >&2
    die "incomplete inputs; see $MISSING"
fi
rm -f -- "$MISSING"

grid_signature() {
    gmt grdinfo "$1" -C | awk '{print $2,$3,$4,$5,$8,$9,$10,$11,$12}'
}

TEMPLATE_CORR="$PAIR_ROOT/${DIRS[0]}/corr.grd"
TEMPLATE_UNWRAP="$PAIR_ROOT/${DIRS[0]}/unwrap.grd"
TEMPLATE_SIG="$(grid_signature "$TEMPLATE_CORR")"
UNWRAP_SIG="$(grid_signature "$TEMPLATE_UNWRAP")"
[[ -n "$TEMPLATE_SIG" ]] || die "cannot read $TEMPLATE_CORR"
[[ "$TEMPLATE_SIG" == "$UNWRAP_SIG" ]] ||
    die "template corr.grd and unwrap.grd geometry differ; run Run 3.9 first"

if [[ -s "$SHARED_DEM" ]] && [[ "$(grid_signature "$SHARED_DEM")" == "$TEMPLATE_SIG" ]]; then
    printf '[DEM] Reuse %s\n' "$SHARED_DEM"
else
    REVISED_DEM="$PAIR_ROOT/.run3.10_topo_ra_revise.$$.grd"
    TMP_DEM="$PAIR_ROOT/.run3.10_dem_ra.$$.grd"
    trap 'rm -f -- "${REVISED_DEM:-}" "${TMP_DEM:-}"' EXIT INT TERM

    printf '%s\n' '[DEM 1/2] Flip burst/topo/topo_ra.grd in the up/down direction'
    printf 'Command: gmt grdmath %s FLIPUD = %s\n' "$DEM_SOURCE" "$REVISED_DEM"
    gmt grdmath "$DEM_SOURCE" FLIPUD = "$REVISED_DEM"
    [[ -s "$REVISED_DEM" ]] || die "GMT did not create $REVISED_DEM"

    printf '%s\n' '[DEM 2/2] Resample revised DEM to the corr.grd geometry'
    printf 'Command: gmt grdsample %s -R%s -G%s\n' "$REVISED_DEM" "$TEMPLATE_CORR" "$TMP_DEM"
    gmt grdsample "$REVISED_DEM" -R"$TEMPLATE_CORR" -G"$TMP_DEM"
    [[ -s "$TMP_DEM" ]] || die "GMT did not create $TMP_DEM"
    [[ "$(grid_signature "$TMP_DEM")" == "$TEMPLATE_SIG" ]] ||
        die "resampled DEM geometry does not match corr.grd/unwrap.grd"
    mv -f -- "$TMP_DEM" "$SHARED_DEM"
    rm -f -- "$REVISED_DEM"
    trap - EXIT INT TERM
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.10: burst global DEM correction'
printf 'Track root       : %s\n' "$ROOT"
printf 'Interferograms   : %s\n' "${#DIRS[@]}"
printf 'Parallel jobs    : %s\n' "$JOBS"
printf 'Model type       : %s\n' "$MODEL_TYPE"
printf 'Radar DEM        : %s\n' "$SHARED_DEM"
printf 'Output           : burst/intf_all/<pair>/unwrap_dem_correct.grd\n'
printf '%s\n' '========================================'

run_one() {
    local pair="$1"
    printf '==== Processing %s ====\n' "$pair"
    (
        cd "$PAIR_ROOT/$pair"
        MODEL_TYPE="$MODEL_TYPE" python3 - <<'PY' > dem_correction.log 2>&1
import os
import subprocess
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import xarray as xr

DEM_FILE = "../dem_ra.grd"
UNWRAP_FILE = "unwrap.grd"
OUT_GRD = "unwrap_dem_correct.grd"
OUT_FIG = "unwrap_dem_correction.png"
MODEL_TYPE = int(os.environ.get("MODEL_TYPE", "6"))

def read_grd(path):
    with xr.open_dataset(path) as ds:
        var = list(ds.data_vars)[0]
        da = ds[var]
        da = da.transpose("y", "x") if "y" in da.dims and "x" in da.dims else da.transpose(*da.dims[-2:])
        return ds["x"].values.astype(float), ds["y"].values.astype(float), da.values.astype(float)

def write_like(template, output, values):
    with xr.open_dataset(template) as ds:
        var = list(ds.data_vars)[0]
        source = ds[var]
        source = source.transpose("y", "x") if "y" in source.dims and "x" in source.dims else source.transpose(*source.dims[-2:])
        out = xr.DataArray(
            values.astype(np.float32), dims=("y", "x"),
            coords={"y": ds["y"].values, "x": ds["x"].values},
            name=var, attrs=source.attrs,
        ).to_dataset()
        out.attrs = ds.attrs
        out.to_netcdf(output)
        out.close()

def design(d, x, y, kind):
    if kind == 4:
        return np.column_stack((d, np.ones_like(d), x, y))
    if kind == 6:
        return np.column_stack((d*x, d*y, d, np.ones_like(d), x, y))
    if kind == 9:
        return np.column_stack((d*x, d*y, d*x*y/1000, d*x*x/1000, d*y*y/1000, d, np.ones_like(d), x, y))
    raise ValueError("MODEL_TYPE must be 4, 6 or 9")

def model(p, d, x, y, kind):
    if kind == 4:
        return p[0]*d + p[1] + p[2]*x + p[3]*y
    if kind == 6:
        return p[0]*d*x + p[1]*d*y + p[2]*d + p[3] + p[4]*x + p[5]*y
    return (p[0]*d*x + p[1]*d*y + p[2]*d*x*y/1000 + p[3]*d*x*x/1000
            + p[4]*d*y*y/1000 + p[5]*d + p[6] + p[7]*x + p[8]*y)

xcoord, ycoord, dem = read_grd(DEM_FILE)
_, _, unwrap = read_grd(UNWRAP_FILE)
if dem.shape != unwrap.shape:
    raise ValueError(f"DEM shape {dem.shape} != unwrap shape {unwrap.shape}")

ny, nx = unwrap.shape
xidx, yidx = np.meshgrid(np.arange(1, nx+1, dtype=float), np.arange(1, ny+1, dtype=float))
valid = np.isfinite(unwrap) & np.isfinite(dem)
if np.count_nonzero(valid) < 100:
    raise ValueError("fewer than 100 valid DEM/unwrap pixels")

g = design(dem[valid], xidx[valid], yidx[valid], MODEL_TYPE)
p = np.linalg.pinv(g) @ unwrap[valid]
print(f"MODEL_TYPE = {MODEL_TYPE}")
for i, value in enumerate(p, 1): print(f"P{i} = {value:.6e}")

fitted = model(p, dem, xidx, yidx, MODEL_TYPE)
corrected = unwrap - fitted
corrected[~np.isfinite(unwrap)] = np.nan
tmp = OUT_GRD + ".tmp"
write_like(UNWRAP_FILE, tmp, corrected)
subprocess.run(["gmt", "grdmath", tmp, "1", "MUL", "=", OUT_GRD], check=True)
os.remove(tmp)

extent = [xcoord.min(), xcoord.max(), ycoord.min(), ycoord.max()]
fig, axes = plt.subplots(1, 3, figsize=(15, 5))
for ax, grid, title in zip(axes, (unwrap, fitted, corrected),
                           ("Original unwrap", f"Model ({MODEL_TYPE}p)", "DEM corrected")):
    image = ax.imshow(grid, origin="lower", cmap="jet", vmin=-10, vmax=10,
                      extent=extent, aspect="auto")
    ax.set_title(title); ax.set_xlabel("Range"); ax.set_ylabel("Azimuth")
    plt.colorbar(image, ax=ax, fraction=0.046, pad=0.04, extend="both")
plt.tight_layout()
plt.savefig(OUT_FIG, dpi=300, bbox_inches="tight")
plt.close(fig)
print(f"Saved: {OUT_GRD}")
print(f"Saved: {OUT_FIG}")
PY
        [[ -s unwrap_dem_correct.grd && -s unwrap_dem_correction.png ]]
    )
}
export -f run_one
export PAIR_ROOT MODEL_TYPE

RUN_LIST="$PAIR_ROOT/run3.10_runlist.txt"
FAILED="$PAIR_ROOT/run3.10_failed_pairs.txt"
printf '%s\n' "${DIRS[@]}" > "$RUN_LIST"
: > "$FAILED"
xargs -I{} -P "$JOBS" bash -lc 'run_one "$1" || printf "%s\n" "$1" >> "$2"' _ {} "$FAILED" < "$RUN_LIST"

OUTPUTS="$(find "$PAIR_ROOT" -mindepth 2 -maxdepth 2 -type f -name unwrap_dem_correct.grd -size +0c | wc -l | awk '{print $1}')"
FAILURES="$(wc -l < "$FAILED" | awk '{print $1}')"
if (( FAILURES > 0 || OUTPUTS != ${#DIRS[@]} )); then
    die "incomplete: outputs=$OUTPUTS/${#DIRS[@]}, failures=$FAILURES; see $FAILED"
fi
rm -f -- "$FAILED"

printf '%s\n' '========================================'
printf '[DONE] Corrected interferograms: %s/%s\n' "$OUTPUTS" "${#DIRS[@]}"
printf '%s\n' 'Original unwrap.grd files were not modified.'
printf '%s\n' '========================================'
