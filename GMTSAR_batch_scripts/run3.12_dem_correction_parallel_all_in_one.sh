#!/usr/bin/env bash
set -euo pipefail

JOBS="${1:-16}"
MODEL_TYPE="${2:-6}"

# Modified by Xin Wang, USTC, Hefei, 2026-08-10.
ROOT="$(pwd -P)"
if [[ ! -d merge ]]; then
    echo "[ERR] Run this script in a track directory containing merge/."
    exit 1
fi
if [[ $# -eq 0 ]]; then
    echo "Run 3.12 default: global DEM correction (processing NOT started)"
    echo "Recommended: ./run3.12_dem_correction_parallel_all_in_one.sh 16 6"
    echo "  16 = parallel interferograms; reduce it if RAM is limited"
    echo "  6  = recommended global model; alternatives: 4 or 9"
    exit 0
fi
[[ $# -eq 2 ]] || { echo "[ERR] Expected: JOBS MODEL_TYPE"; exit 1; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "[ERR] JOBS must be positive."; exit 1; }
[[ "$MODEL_TYPE" =~ ^(4|6|9)$ ]] || { echo "[ERR] MODEL_TYPE must be 4, 6 or 9."; exit 1; }
cd merge

echo "========================================"
echo "Run 3.12: global DEM correction"
echo "Current directory: $(pwd -P)"
echo "JOBS       = $JOBS"
echo "MODEL_TYPE = $MODEL_TYPE"
echo "========================================"

mapfile -t DIRS < <(find . -maxdepth 1 -mindepth 1 -type d -name '20*_*' -printf '%f
' | sort)

if [[ ${#DIRS[@]} -eq 0 ]]; then
    echo "ERROR: 当前目录下没有找到 20*_* 子目录"
    exit 1
fi

echo
echo "[STEP 1] Found ${#DIRS[@]} interferogram directories"
printf '  %s
' "${DIRS[@]}"

echo
echo "[STEP 2] Checking required files in every directory ..."

VALID_DIRS=()
MISSING_DIRS=()

for d in "${DIRS[@]}"; do
    missing_list=()

    [[ -f "${d}/unwrap.grd" ]] || missing_list+=("unwrap.grd")
    [[ -e "${d}/tmp_dem_ra.grd" ]] || missing_list+=("tmp_dem_ra.grd")

    if [[ ${#missing_list[@]} -eq 0 ]]; then
        VALID_DIRS+=("$d")
    else
        MISSING_DIRS+=("$d")
        echo "---- $d"
        for f in "${missing_list[@]}"; do
            echo "  missing: $f"
        done
    fi
done

echo
echo "[STEP 3] Summary"
echo "Valid directories  : ${#VALID_DIRS[@]}"
echo "Missing directories: ${#MISSING_DIRS[@]}"

if [[ ${#VALID_DIRS[@]} -gt 0 ]]; then
    echo
    echo "Directories to process:"
    printf '  %s
' "${VALID_DIRS[@]}"
fi

if [[ ${#MISSING_DIRS[@]} -gt 0 ]]; then
    echo
    echo "Directories skipped due to missing files:"
    printf '  %s
' "${MISSING_DIRS[@]}"
fi

if [[ ${#VALID_DIRS[@]} -eq 0 ]]; then
    echo
    echo "No valid directories to process. Exit."
    exit 0
fi

echo
echo "[STEP 4] Start parallel processing ..."

run_one() {
    d="$1"
    echo "==== Processing $d ===="
    (
        cd "$d"

        MODEL_TYPE="$MODEL_TYPE" python3 - <<'PY' > dem_correction.log 2>&1
import os
import subprocess
import numpy as np
import xarray as xr
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

DEM_FILE = "tmp_dem_ra.grd"
UNWRAP_FILE = "unwrap.grd"
OUT_GRD = "unwrap_dem_correct.grd"
OUT_FIG = "unwrap_dem_correction.png"

MODEL_TYPE = int(os.environ.get("MODEL_TYPE", "6"))

def run_cmd(cmd):
    print("[RUN]", " ".join(cmd))
    subprocess.run(cmd, check=True)

def refresh_grd_inplace(grdfile, tmpfile):
    run_cmd(["gmt", "grdmath", grdfile, "1", "MUL", "=", tmpfile])
    run_cmd(["mv", tmpfile, grdfile])

def read_grd(path: str):
    ds = xr.open_dataset(path)
    var = list(ds.data_vars)[0]
    da = ds[var]

    if tuple(da.dims) != ("y", "x"):
        if "y" in da.dims and "x" in da.dims:
            da = da.transpose("y", "x")
        else:
            da = da.transpose(*da.dims[-2:])

    x = ds["x"].values.astype(np.float64)
    y = ds["y"].values.astype(np.float64)
    z = da.values.astype(np.float64)
    ds.close()
    return x, y, z

def write_grd_like(template_file: str, out_file: str, z_out: np.ndarray):
    ds = xr.open_dataset(template_file)
    var = list(ds.data_vars)[0]
    da = ds[var]

    if tuple(da.dims) != ("y", "x"):
        if "y" in da.dims and "x" in da.dims:
            da = da.transpose("y", "x")
        else:
            da = da.transpose(*da.dims[-2:])

    out_da = xr.DataArray(
        z_out.astype(np.float32),
        dims=("y", "x"),
        coords={"y": ds["y"].values, "x": ds["x"].values},
        name=var,
        attrs=da.attrs,
    )
    out_ds = out_da.to_dataset()
    out_ds.attrs = ds.attrs
    out_ds.to_netcdf(out_file)

    ds.close()
    out_ds.close()

def build_design_matrix(dd, xx, yy, model_type):
    if model_type == 4:
        return np.column_stack([
            dd,
            np.ones_like(dd),
            xx,
            yy
        ])
    elif model_type == 6:
        return np.column_stack([
            dd * xx,
            dd * yy,
            dd,
            np.ones_like(dd),
            xx,
            yy
        ])
    elif model_type == 9:
        return np.column_stack([
            dd * xx,
            dd * yy,
            dd * xx * yy / 1000.0,
            dd * xx * xx / 1000.0,
            dd * yy * yy / 1000.0,
            dd,
            np.ones_like(dd),
            xx,
            yy
        ])
    else:
        raise ValueError("MODEL_TYPE must be 4, 6, or 9")

def build_model_from_P(P, dem, x, y, model_type):
    if model_type == 4:
        return (
            P[0] * dem +
            P[1] +
            P[2] * x +
            P[3] * y
        )
    elif model_type == 6:
        return (
            P[0] * dem * x +
            P[1] * dem * y +
            P[2] * dem +
            P[3] +
            P[4] * x +
            P[5] * y
        )
    elif model_type == 9:
        return (
            P[0] * dem * x +
            P[1] * dem * y +
            P[2] * dem * x * y / 1000.0 +
            P[3] * dem * x * x / 1000.0 +
            P[4] * dem * y * y / 1000.0 +
            P[5] * dem +
            P[6] +
            P[7] * x +
            P[8] * y
        )
    else:
        raise ValueError("MODEL_TYPE must be 4, 6, or 9")

x_coord, y_coord, dem = read_grd(DEM_FILE)
_, _, vel = read_grd(UNWRAP_FILE)

if dem.shape != vel.shape:
    raise ValueError(f"DEM shape {dem.shape} != unwrap shape {vel.shape}")

ny, nx = vel.shape
x_idx, y_idx = np.meshgrid(
    np.arange(1, nx + 1, dtype=np.float64),
    np.arange(1, ny + 1, dtype=np.float64)
)

vv = vel.reshape(-1)
dd = dem.reshape(-1)
xx = x_idx.reshape(-1)
yy = y_idx.reshape(-1)

mask = np.isfinite(vv) & np.isfinite(dd) & np.isfinite(xx) & np.isfinite(yy)
vv = vv[mask]
dd = dd[mask]
xx = xx[mask]
yy = yy[mask]

print(f"===== MODEL_TYPE = {MODEL_TYPE} =====")
G = build_design_matrix(dd, xx, yy, MODEL_TYPE)
P = np.linalg.pinv(G) @ vv

print("Fitted parameters:")
for i, p in enumerate(P, start=1):
    print(f"P{i} = {p:.6e}")

model = build_model_from_P(P, dem, x_idx, y_idx, MODEL_TYPE)
out = vel - model

write_grd_like(UNWRAP_FILE, OUT_GRD, out)
refresh_grd_inplace(OUT_GRD, "tmp_out_refresh.grd")
print(f"Saved: {OUT_GRD}")

fig, axes = plt.subplots(1, 3, figsize=(15, 5))
extent = [x_coord.min(), x_coord.max(), y_coord.min(), y_coord.max()]
plot_vmin = -10
plot_vmax = 10

im = axes[0].imshow(
    vel, origin="lower", cmap="jet",
    vmin=plot_vmin, vmax=plot_vmax,
    extent=extent, aspect="auto"
)
axes[0].set_title("Original unwrap")
axes[0].set_xlabel("Range")
axes[0].set_ylabel("Azimuth")
plt.colorbar(im, ax=axes[0], fraction=0.046, pad=0.04, extend="both")

im = axes[1].imshow(
    model, origin="lower", cmap="jet",
    vmin=plot_vmin, vmax=plot_vmax,
    extent=extent, aspect="auto"
)
axes[1].set_title(f"Python model ({MODEL_TYPE}p)")
axes[1].set_xlabel("Range")
axes[1].set_ylabel("Azimuth")
plt.colorbar(im, ax=axes[1], fraction=0.046, pad=0.04, extend="both")

im = axes[2].imshow(
    out, origin="lower", cmap="jet",
    vmin=plot_vmin, vmax=plot_vmax,
    extent=extent, aspect="auto"
)
axes[2].set_title(f"Python corrected ({MODEL_TYPE}p)")
axes[2].set_xlabel("Range")
axes[2].set_ylabel("Azimuth")
plt.colorbar(im, ax=axes[2], fraction=0.046, pad=0.04, extend="both")

plt.tight_layout()
plt.savefig(OUT_FIG, dpi=300, bbox_inches="tight")
plt.close(fig)
print(f"Saved figure: {OUT_FIG}")
PY

        echo "[OK] $d"
    ) || echo "[FAIL] $d"
}
export -f run_one
export MODEL_TYPE

printf '%s
' "${VALID_DIRS[@]}" | \
xargs -I{} -P "$JOBS" bash -lc 'run_one "$@"' _ {}
