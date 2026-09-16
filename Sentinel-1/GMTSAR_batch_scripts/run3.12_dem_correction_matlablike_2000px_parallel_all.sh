#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export LANG=C

# ============================================================
# run3.12_dem_correction_matlablike_2000px_parallel_all.sh
#
# Batch MATLAB-like Python DEM correction, fixed window = 2000 px
#
# 强制重跑版本：
#   即使已有 unwrap_dem_correct.grd，也会删除旧结果并重新生成。
#
# Method:
#   unwrap = p1 * DEM + p2
#
# MATLAB-like steps:
#   1. block regression
#   2. put p1/p2 at block centers
#   3. nearest interpolation to full-resolution grid
#   4. full-resolution Gaussian smoothing
#        sigma = 2000 / 3
#        truncate = 1.5
#   5. model = DEM * p1_smooth + p2_smooth
#   6. unwrap_dem_correct.grd = unwrap - model
#
# Run in merge / merge_small / merge_esd directory.
#
# Usage:
#   chmod +x run3.12_dem_correction_matlablike_2000px_parallel_all.sh
#
#   # 跑全部 20*_* 干涉对
#   ./run3.12_dem_correction_matlablike_2000px_parallel_all.sh 8 4
#
#   # 指定列表跑
#   ./run3.12_dem_correction_matlablike_2000px_parallel_all.sh 8 4 intflist
#
# Arguments:
#   $1 : OUTER_JOBS, 并行干涉对数量，默认 8
#   $2 : INNER_JOBS, 每个干涉对内部并行核数，默认 4
#   $3 : optional IFG list file
#
# Required inside each IFG directory:
#   unwrap.grd
#   tmp_dem_ra.grd
#
# Output kept inside each IFG directory:
#   unwrap_dem_correct.grd
#   unwrap_dem_correction.png
#   dem_correction.log
#
# Intermediate file generated then removed:
#   unwrap_dem_model_2000px.grd
#
# Batch output in current directory:
#   batch_dem_correction_matlablike_2000px.log
#   batch_dem_correction_matlablike_2000px_runlist.txt
#   batch_dem_correction_matlablike_2000px_done.txt
#   batch_dem_correction_matlablike_2000px_failed.txt
# ============================================================

OUTER_JOBS="${1:-8}"
INNER_JOBS="${2:-4}"
LIST_FILE="${3:-}"

# Modified by Xin Wang, USTC, Hefei, 2026-08-10.
ROOT="$(pwd -P)"
if [[ ! -d merge ]]; then
    echo "[ERR] Run this script in a track directory containing merge/."
    exit 1
fi
if [[ $# -eq 0 ]]; then
    echo "Run 3.12 alternative: MATLAB-like 2000px local DEM correction"
    echo "Processing NOT started. Recommended: ./run3.12_dem_correction_matlablike_2000px_parallel_all.sh 8 4"
    echo "Use this only when the default global model leaves spatially varying residuals."
    exit 0
fi
[[ $# -ge 2 && $# -le 3 ]] || { echo "[ERR] Expected: OUTER_JOBS INNER_JOBS [LIST_FILE]"; exit 1; }
cd merge

WINDOW_SIZE=2000

RUN_LIST="batch_dem_correction_matlablike_2000px_runlist.txt"
DONE_LIST="batch_dem_correction_matlablike_2000px_done.txt"
FAILED_LIST="batch_dem_correction_matlablike_2000px_failed.txt"
BATCH_LOG="batch_dem_correction_matlablike_2000px.log"

echo "========================================"
echo "Batch MATLAB-like Python DEM correction"
echo "FORCE RERUN MODE"
echo "Current dir : $(pwd -P)"
echo "Window size : ${WINDOW_SIZE}px"
echo "Outer jobs  : ${OUTER_JOBS}"
echo "Inner jobs  : ${INNER_JOBS}"
echo "List file   : ${LIST_FILE:-ALL 20*_* directories}"
echo "========================================"

rm -f "$RUN_LIST" "$DONE_LIST" "$FAILED_LIST" "$BATCH_LOG"

# ============================================================
# Build run list
# ============================================================

if [[ -n "$LIST_FILE" ]]; then
    if [[ ! -f "$LIST_FILE" ]]; then
        echo "ERROR: 找不到列表文件: $LIST_FILE"
        exit 1
    fi

    awk 'NF>0 && $1 !~ /^#/{print $1}' "$LIST_FILE" > "$RUN_LIST"
else
    find . -maxdepth 1 -mindepth 1 -type d -name '20*_*' \
        | sed 's#^\./##' \
        | sort > "$RUN_LIST"
fi

N_TOTAL=$(wc -l < "$RUN_LIST" | awk '{print $1}')

if [[ "$N_TOTAL" -eq 0 ]]; then
    echo "ERROR: 没有找到需要处理的干涉对"
    exit 1
fi

echo "Total IFGs: ${N_TOTAL}"
echo "Run list  : ${RUN_LIST}"

# ============================================================
# Worker function
# ============================================================

run_one_ifg() {
    local IFG_DIR="$1"
    local JOBS="$2"

    local WINDOW_SIZE=2000

    local UNWRAP_FILE="unwrap.grd"
    local DEM_FILE="tmp_dem_ra.grd"

    local OUT_CORRECT="unwrap_dem_correct.grd"
    local OUT_MODEL="unwrap_dem_model_2000px.grd"

    local OUT_LOG="dem_correction.log"
    local OUT_FIG="unwrap_dem_correction.png"

    echo
    echo "----------------------------------------"
    echo "START ${IFG_DIR}"
    echo "TIME  $(date '+%F %T')"
    echo "INNER_JOBS ${JOBS}"
    echo "----------------------------------------"

    if [[ ! -d "$IFG_DIR" ]]; then
        echo "FAIL ${IFG_DIR}: directory not found"
        echo "$IFG_DIR" >> batch_dem_correction_matlablike_2000px_failed.txt
        return 0
    fi

    if [[ ! -f "${IFG_DIR}/${UNWRAP_FILE}" ]]; then
        echo "FAIL ${IFG_DIR}: missing ${UNWRAP_FILE}"
        echo "$IFG_DIR" >> batch_dem_correction_matlablike_2000px_failed.txt
        return 0
    fi

    if [[ ! -f "${IFG_DIR}/${DEM_FILE}" ]]; then
        echo "FAIL ${IFG_DIR}: missing ${DEM_FILE}"
        echo "$IFG_DIR" >> batch_dem_correction_matlablike_2000px_failed.txt
        return 0
    fi

    # ========================================================
    # FORCE RERUN
    # ========================================================
    echo "FORCE RERUN ${IFG_DIR}: remove old DEM correction results"

    rm -f \
      "${IFG_DIR}/${OUT_CORRECT}" \
      "${IFG_DIR}/${OUT_MODEL}" \
      "${IFG_DIR}/${OUT_FIG}" \
      "${IFG_DIR}/${OUT_LOG}" \
      "${IFG_DIR}/tmp_refresh_${OUT_CORRECT}" \
      "${IFG_DIR}/tmp_refresh_${OUT_MODEL}" \
      "${IFG_DIR}/tmp_refresh_*.grd"

    (
        cd "$IFG_DIR"

        export OMP_NUM_THREADS=1
        export OPENBLAS_NUM_THREADS=1
        export MKL_NUM_THREADS=1
        export NUMEXPR_NUM_THREADS=1

        WINDOW_SIZE="$WINDOW_SIZE" \
        JOBS="$JOBS" \
        UNWRAP_FILE="$UNWRAP_FILE" \
        DEM_FILE="$DEM_FILE" \
        OUT_CORRECT="$OUT_CORRECT" \
        OUT_MODEL="$OUT_MODEL" \
        OUT_FIG="$OUT_FIG" \
        python3 - <<'PY' > "$OUT_LOG" 2>&1

import os
import math
import subprocess
from concurrent.futures import ProcessPoolExecutor, as_completed

import numpy as np
import xarray as xr
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy.ndimage import gaussian_filter, distance_transform_edt


# ============================================================
# Parameters
# ============================================================

UNWRAP_FILE = os.environ["UNWRAP_FILE"]
DEM_FILE = os.environ["DEM_FILE"]

OUT_CORRECT = os.environ["OUT_CORRECT"]
OUT_MODEL = os.environ["OUT_MODEL"]
OUT_FIG = os.environ["OUT_FIG"]

WINDOW_SIZE = int(os.environ.get("WINDOW_SIZE", "2000"))
JOBS = int(os.environ.get("JOBS", "4"))

MIN_PIXELS = 100

MAX_STAT_SAMPLES = 1000000
MAX_PLOT_PIXELS = 2500

PLOT_VMIN = -10
PLOT_VMAX = 10


# ============================================================
# Global arrays for multiprocessing
# ============================================================

G_DEM = None
G_UNWRAP = None


def init_worker(dem, unwrap):
    global G_DEM, G_UNWRAP
    G_DEM = dem
    G_UNWRAP = unwrap


# ============================================================
# Basic I/O functions
# ============================================================

def run_cmd(cmd):
    print("[RUN]", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def refresh_grd_inplace(grdfile, tmpfile):
    run_cmd(["gmt", "grdmath", grdfile, "1", "MUL", "=", tmpfile])
    run_cmd(["mv", tmpfile, grdfile])


def read_grd(path):
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


def write_grd_like(template_file, out_file, z_out):
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
        coords={
            "y": ds["y"].values,
            "x": ds["x"].values,
        },
        name=var,
        attrs=da.attrs,
    )

    out_ds = out_da.to_dataset()
    out_ds.attrs = ds.attrs
    out_ds.to_netcdf(out_file)

    ds.close()
    out_ds.close()


def print_stats(name, arr, max_samples=MAX_STAT_SAMPLES):
    finite = np.isfinite(arr)
    n_valid = int(np.sum(finite))

    if n_valid == 0:
        print(f"{name}: no valid pixels", flush=True)
        return

    v = arr[finite]

    if v.size > max_samples:
        step = max(1, v.size // max_samples)
        v_stat = v[::step]
    else:
        v_stat = v

    print(f"{name}:", flush=True)
    print(f"  valid        = {n_valid}", flush=True)
    print(f"  stat_samples = {v_stat.size}", flush=True)
    print(f"  min          = {np.nanmin(v_stat):.6f}", flush=True)
    print(f"  max          = {np.nanmax(v_stat):.6f}", flush=True)
    print(f"  mean         = {np.nanmean(v_stat):.6f}", flush=True)
    print(f"  median       = {np.nanmedian(v_stat):.6f}", flush=True)
    print(f"  std          = {np.nanstd(v_stat):.6f}", flush=True)
    print(f"  p02          = {np.nanpercentile(v_stat, 2):.6f}", flush=True)
    print(f"  p98          = {np.nanpercentile(v_stat, 98):.6f}", flush=True)


def make_plot_data(arr, max_pixels=MAX_PLOT_PIXELS):
    ny, nx = arr.shape
    step = max(1, int(math.ceil(max(ny, nx) / max_pixels)))
    return arr[::step, ::step], step


# ============================================================
# Block regression
# ============================================================

def fit_one_block(task):
    ib, jb, row_start, row_end, col_start, col_end = task

    dem_block = G_DEM[row_start:row_end, col_start:col_end]
    unwrap_block = G_UNWRAP[row_start:row_end, col_start:col_end]

    dd = dem_block.reshape(-1)
    vv = unwrap_block.reshape(-1)

    mask = np.isfinite(dd) & np.isfinite(vv)

    dd = dd[mask]
    vv = vv[mask]

    valid_count = vv.size

    if valid_count < MIN_PIXELS:
        return ib, jb, np.nan, np.nan, valid_count

    A = np.column_stack([
        dd,
        np.ones_like(dd)
    ])

    try:
        P, *_ = np.linalg.lstsq(A, vv, rcond=None)
    except np.linalg.LinAlgError:
        return ib, jb, np.nan, np.nan, valid_count

    p1 = float(P[0])
    p2 = float(P[1])

    return ib, jb, p1, p2, int(valid_count)


def run_block_regression(dem, unwrap, block_size):
    ny, nx = unwrap.shape

    n_block_y = math.ceil(ny / block_size)
    n_block_x = math.ceil(nx / block_size)

    tasks = []

    # MATLAB style:
    # colStart outer loop, rowStart inner loop
    for jb in range(n_block_x):
        col_start = jb * block_size
        col_end = min((jb + 1) * block_size, nx)

        for ib in range(n_block_y):
            row_start = ib * block_size
            row_end = min((ib + 1) * block_size, ny)

            tasks.append((
                ib, jb,
                row_start, row_end,
                col_start, col_end
            ))

    P1_block = np.full((n_block_y, n_block_x), np.nan, dtype=np.float64)
    P2_block = np.full((n_block_y, n_block_x), np.nan, dtype=np.float64)
    N_block = np.zeros((n_block_y, n_block_x), dtype=np.int64)

    print("========================================", flush=True)
    print("Block regression", flush=True)
    print("========================================", flush=True)
    print(f"Grid size   : ny={ny}, nx={nx}", flush=True)
    print(f"Block size  : {block_size}", flush=True)
    print(f"Block grid  : {n_block_y} x {n_block_x}", flush=True)
    print(f"Total blocks: {len(tasks)}", flush=True)
    print(f"Jobs        : {JOBS}", flush=True)

    done = 0

    with ProcessPoolExecutor(
        max_workers=JOBS,
        initializer=init_worker,
        initargs=(dem, unwrap)
    ) as executor:

        futures = [executor.submit(fit_one_block, t) for t in tasks]

        for fut in as_completed(futures):
            ib, jb, p1, p2, valid_count = fut.result()

            P1_block[ib, jb] = p1
            P2_block[ib, jb] = p2
            N_block[ib, jb] = valid_count

            done += 1

            if done % 20 == 0 or done == len(tasks):
                print(f"  finished blocks: {done}/{len(tasks)}", flush=True)

    valid_blocks = np.isfinite(P1_block) & np.isfinite(P2_block)
    n_valid = int(np.sum(valid_blocks))

    print(f"Valid blocks: {n_valid} / {valid_blocks.size}", flush=True)

    if n_valid < 3:
        raise ValueError("Too few valid blocks")

    return P1_block, P2_block, N_block, valid_blocks


# ============================================================
# MATLAB-like nearest gridding
# ============================================================

def nearest_fill_full_from_centers(P_block, valid_blocks, ny, nx, block_size):
    center_grid = np.full((ny, nx), np.nan, dtype=np.float64)

    n_block_y, n_block_x = P_block.shape

    for ib in range(n_block_y):
        row_start = ib * block_size
        row_end = min((ib + 1) * block_size, ny)

        cy = int(round((row_start + row_end - 1) / 2.0))

        for jb in range(n_block_x):
            if not valid_blocks[ib, jb]:
                continue

            col_start = jb * block_size
            col_end = min((jb + 1) * block_size, nx)

            cx = int(round((col_start + col_end - 1) / 2.0))

            center_grid[cy, cx] = P_block[ib, jb]

    valid = np.isfinite(center_grid)

    if np.sum(valid) < 3:
        raise ValueError("Too few valid centers for nearest interpolation")

    invalid = ~valid

    _, indices = distance_transform_edt(
        invalid,
        return_distances=True,
        return_indices=True
    )

    full_grid = center_grid[tuple(indices)]

    return full_grid


# ============================================================
# Main processing
# ============================================================

print("========================================", flush=True)
print("Loading input grids", flush=True)
print("========================================", flush=True)

x_coord, y_coord, dem = read_grd(DEM_FILE)
_, _, unwrap = read_grd(UNWRAP_FILE)

if dem.shape != unwrap.shape:
    raise ValueError(f"DEM shape {dem.shape} != unwrap shape {unwrap.shape}")

ny, nx = unwrap.shape

print(f"DEM shape    : {dem.shape}", flush=True)
print(f"Unwrap shape : {unwrap.shape}", flush=True)
print(f"Window size  : {WINDOW_SIZE}", flush=True)

print_stats("Original unwrap", unwrap)
print_stats("DEM", dem)

P1_block, P2_block, N_block, valid_blocks = run_block_regression(
    dem,
    unwrap,
    WINDOW_SIZE
)

print()
print("========================================", flush=True)
print("Nearest gridding to full resolution", flush=True)
print("========================================", flush=True)

P1_grid = nearest_fill_full_from_centers(
    P1_block,
    valid_blocks,
    ny,
    nx,
    WINDOW_SIZE
)

P2_grid = nearest_fill_full_from_centers(
    P2_block,
    valid_blocks,
    ny,
    nx,
    WINDOW_SIZE
)

print_stats("P1 nearest full-grid", P1_grid)
print_stats("P2 nearest full-grid", P2_grid)

print()
print("========================================", flush=True)
print("Full-resolution Gaussian smoothing", flush=True)
print("========================================", flush=True)

sigma = WINDOW_SIZE / 3.0
truncate = 1.5

print(f"Gaussian sigma    = {sigma}", flush=True)
print(f"Gaussian truncate = {truncate}", flush=True)

P1_smooth = gaussian_filter(
    P1_grid,
    sigma=sigma,
    mode="nearest",
    truncate=truncate
)

P2_smooth = gaussian_filter(
    P2_grid,
    sigma=sigma,
    mode="nearest",
    truncate=truncate
)

print_stats("P1 smooth", P1_smooth)
print_stats("P2 smooth", P2_smooth)

print()
print("========================================", flush=True)
print("Build DEM model and corrected unwrap", flush=True)
print("========================================", flush=True)

model = dem * P1_smooth + P2_smooth
model[~np.isfinite(unwrap)] = np.nan

corrected = unwrap - model
corrected[~np.isfinite(unwrap)] = np.nan

print_stats("DEM model", model)
print_stats("Corrected unwrap", corrected)

print()
print("========================================", flush=True)
print("Writing output grids", flush=True)
print("========================================", flush=True)

write_grd_like(UNWRAP_FILE, OUT_MODEL, model)
write_grd_like(UNWRAP_FILE, OUT_CORRECT, corrected)

for f in [OUT_MODEL, OUT_CORRECT]:
    refresh_grd_inplace(f, f"tmp_refresh_{f}")

print("Output grids:", flush=True)
print(f"  {OUT_MODEL}", flush=True)
print(f"  {OUT_CORRECT}", flush=True)

print()
print("========================================", flush=True)
print("Plotting", flush=True)
print("========================================", flush=True)

unwrap_p, step = make_plot_data(unwrap)

extent = [
    x_coord.min(),
    x_coord.max(),
    y_coord.min(),
    y_coord.max(),
]

fig, axes = plt.subplots(1, 3, figsize=(18, 5))

plot_items = [
    ("Original unwrap", unwrap, PLOT_VMIN, PLOT_VMAX),
    ("DEM correction model", model, PLOT_VMIN, PLOT_VMAX),
    ("Corrected unwrap", corrected, PLOT_VMIN, PLOT_VMAX),
]

for ax, (title, data, vmin, vmax) in zip(axes.ravel(), plot_items):
    im = ax.imshow(
        data[::step, ::step],
        origin="lower",
        cmap="jet",
        vmin=vmin,
        vmax=vmax,
        extent=extent,
        aspect="auto"
    )

    ax.set_title(title)
    ax.set_xlabel("Range")
    ax.set_ylabel("Azimuth")

    plt.colorbar(
        im,
        ax=ax,
        fraction=0.046,
        pad=0.04,
        extend="both"
    )

fig.suptitle(
    f"MATLAB-like Python DEM correction, block = {WINDOW_SIZE}px",
    fontsize=16,
    y=0.995
)

plt.tight_layout(rect=[0, 0, 1, 0.95])
plt.savefig(OUT_FIG, dpi=300, bbox_inches="tight")
plt.close(fig)

print(f"Figure: {OUT_FIG}", flush=True)

print()
print("========================================", flush=True)
print("All done", flush=True)
print("========================================", flush=True)

PY

        # 删除中间模型，只保留最终 corrected、图和 log
        rm -f \
          "${OUT_MODEL}" \
          tmp_refresh_*.grd
    )

    if [[ -f "${IFG_DIR}/${OUT_CORRECT}" ]]; then
        echo "DONE ${IFG_DIR}"
        echo "$IFG_DIR" >> batch_dem_correction_matlablike_2000px_done.txt
    else
        echo "FAIL ${IFG_DIR}: output ${OUT_CORRECT} not generated"
        echo "$IFG_DIR" >> batch_dem_correction_matlablike_2000px_failed.txt
    fi

    echo "END ${IFG_DIR}"
    echo "TIME $(date '+%F %T')"
}

export -f run_one_ifg

# ============================================================
# Run parallel
# ============================================================

echo
echo "========================================"
echo "Start parallel processing"
echo "Outer jobs : ${OUTER_JOBS}"
echo "Inner jobs : ${INNER_JOBS}"
echo "========================================"

cat "$RUN_LIST" | parallel -j "$OUTER_JOBS" --line-buffer run_one_ifg {} "$INNER_JOBS" \
    2>&1 | tee "$BATCH_LOG"

# ============================================================
# Summary
# ============================================================

echo
echo "========================================"
echo "Batch finished"
echo "Total IFGs : ${N_TOTAL}"
echo "Done list  : ${DONE_LIST}"
echo "Failed list: ${FAILED_LIST}"
echo "Batch log  : ${BATCH_LOG}"
echo "========================================"

N_DONE=0
N_FAIL=0

[[ -f "$DONE_LIST" ]] && N_DONE=$(wc -l < "$DONE_LIST" | awk '{print $1}')
[[ -f "$FAILED_LIST" ]] && N_FAIL=$(wc -l < "$FAILED_LIST" | awk '{print $1}')

echo "DONE  : ${N_DONE}"
echo "FAILED: ${N_FAIL}"

if [[ "$N_FAIL" -gt 0 ]]; then
    echo
    echo "Failed IFGs:"
    cat "$FAILED_LIST"
fi
