#!/usr/bin/env python3
"""Run 6.6: refit GNSS LOS displacement grids and compare with Run 6.4 velocity."""

from __future__ import annotations

import argparse
import calendar
from concurrent.futures import ProcessPoolExecutor, as_completed
import datetime as dt
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import numpy as np

TAG_RE = re.compile(r"gnss_LOS_(\d{4})(\d{3})\.grd$")


def die(message: str):
    raise SystemExit(f"[ERROR] {message}")


def tag_date(path: Path) -> tuple[dt.date, str]:
    match = TAG_RE.fullmatch(path.name)
    if not match:
        die(f"invalid time-series name: {path.name}")
    year, ddd = map(int, match.groups())
    maximum = 365 if calendar.isleap(year) else 364
    if not 0 <= ddd <= maximum:
        die(f"invalid zero-based day of year: {year:04d}{ddd:03d}")
    return dt.date(year, 1, 1) + dt.timedelta(days=ddd), f"{year:04d}{ddd:03d}"


def metadata(path: Path):
    result = subprocess.run(
        ["gmt", "grdinfo", str(path), "-C"], text=True, capture_output=True
    )
    if result.returncode:
        die(f"GMT cannot read {path}: {result.stderr.strip()}")
    fields = result.stdout.strip().splitlines()[-1].split()[-12:]
    return tuple(fields[0:4] + fields[6:11])


def read_block(path: str, y0: int, y1: int):
    import xarray as xr

    with xr.open_dataset(path, decode_times=False) as dataset:
        names = [name for name, var in dataset.data_vars.items() if var.ndim == 2]
        if not names:
            raise RuntimeError(f"no 2-D grid variable in {path}")
        array = dataset["z" if "z" in names else names[0]]
        if "y" in array.dims and "x" in array.dims:
            array = array.transpose("y", "x")
        return np.asarray(array.isel({array.dims[0]: slice(y0, y1)}).values, dtype=np.float64)


def worker(y0: int, y1: int, files: list[str], times: np.ndarray):
    sums = None
    for path, time in zip(files, times):
        values = read_block(path, y0, y1)
        if sums is None:
            shape = values.shape
            sums = [np.zeros(shape, dtype=np.float64) for _ in range(5)]
        valid = np.isfinite(values)
        clean = np.where(valid, values, 0.0)
        sums[0] += valid
        sums[1] += time * valid
        sums[2] += time * time * valid
        sums[3] += clean
        sums[4] += time * clean
    count, st, stt, sy, sty = sums
    denominator = count * stt - st * st
    with np.errstate(divide="ignore", invalid="ignore"):
        velocity = (count * sty - st * sy) / denominator * 365.0
    velocity[(count < 2) | (denominator == 0) | ~np.isfinite(velocity)] = np.nan
    return y0, y1, velocity.astype(np.float32)


def write_like(template: Path, output: Path, values: np.ndarray):
    import xarray as xr

    with xr.open_dataset(template, decode_times=False) as dataset:
        names = [name for name, var in dataset.data_vars.items() if var.ndim == 2]
        array = dataset["z" if "z" in names else names[0]]
        if "y" in array.dims and "x" in array.dims:
            array = array.transpose("y", "x")
        coords = {dim: np.asarray(dataset[dim].values) for dim in array.dims}
        result = xr.Dataset(
            {"z": (array.dims, values, {"long_name": "refitted GNSS LOS velocity", "units": "mm/yr"})},
            coords=coords,
        )
        result.to_netcdf(output)
        result.close()
    refreshed = output.with_suffix(".refresh.grd")
    subprocess.run(
        ["gmt", "grdmath", output.name, "1", "MUL", "=", refreshed.name],
        cwd=output.parent,
        check=True,
    )
    refreshed.replace(output)


def plot_three_panel(reference: Path, fitted: Path, difference: Path, pdf: Path):
    """Plot reference, refitted, and difference grids in one horizontal row."""
    plot_dir = pdf.parent / f".run6.6_plot.{os.getpid()}.three_panel"
    plot_dir.mkdir(parents=True)
    env = os.environ.copy()
    env.update(
        {
            "REFERENCE": str(reference.resolve()),
            "FITTED": str(fitted.resolve()),
            "DIFFERENCE": str(difference.resolve()),
        }
    )
    commands = r'''set -euo pipefail
gmt makecpt -Cjet -T-5/5/1 -Z -D > velocity.cpt
gmt makecpt -Cpolar -T-0.01/0.01/0.001 -Z -D > difference.cpt
REGION="$(gmt grdinfo "$REFERENCE" -C | awk 'NR==1{print $2"/"$3"/"$4"/"$5}')"
gmt set \
    MAP_FRAME_TYPE plain \
    FONT_ANNOT_PRIMARY 8p \
    FONT_LABEL 9p \
    FONT_TITLE 11p \
    COLOR_NAN gray

# Panel 1: Run 6.4 reference velocity
gmt grdimage "$REFERENCE" \
    -R"$REGION" -JX8c \
    -Cvelocity.cpt \
    -Baf -BWSen+t"Reference GNSS LOS velocity" \
    -K -X1.5c -Y4c > comparison.ps
gmt psscale \
    -R"$REGION" -JX8c \
    -DJBC+w6c/0.25c+h+o0c/0.8c \
    -Cvelocity.cpt \
    -Bxa5f1+l"Velocity (mm/yr)" \
    -O -K >> comparison.ps

# Panel 2: velocity refitted from Run 6.5 time series
gmt grdimage "$FITTED" \
    -R"$REGION" -JX8c \
    -Cvelocity.cpt \
    -Baf -BWSen+t"Refitted GNSS LOS velocity" \
    -O -K -X9c >> comparison.ps
gmt psscale \
    -R"$REGION" -JX8c \
    -DJBC+w6c/0.25c+h+o0c/0.8c \
    -Cvelocity.cpt \
    -Bxa5f1+l"Velocity (mm/yr)" \
    -O -K >> comparison.ps

# Panel 3: refitted minus reference
gmt grdimage "$DIFFERENCE" \
    -R"$REGION" -JX8c \
    -Cdifference.cpt \
    -Baf -BWSen+t"Refitted minus reference" \
    -O -K -X9c >> comparison.ps
gmt psscale \
    -R"$REGION" -JX8c \
    -DJBC+w6c/0.25c+h+o0c/0.8c \
    -Cdifference.cpt \
    -Bxa0.005f0.001+l"Difference (mm/yr)" \
    -O >> comparison.ps

gmt psconvert comparison.ps -Tf -A -FGNSS_LOS_validation_3panel
'''
    try:
        completed = subprocess.run(["bash", "-c", commands], cwd=plot_dir, env=env, text=True, capture_output=True)
        if completed.returncode:
            die(f"GMT plotting failed: {completed.stdout}\n{completed.stderr}")
        generated = plot_dir / "GNSS_LOS_validation_3panel.pdf"
        if not generated.is_file() or generated.stat().st_size == 0:
            die(f"GMT did not generate the three-panel PDF: {generated}")
        generated.replace(pdf)
    finally:
        shutil.rmtree(plot_dir, ignore_errors=True)


def parse_args():
    parser = argparse.ArgumentParser(description="Run 6.6: validate GNSS LOS displacement time series")
    parser.add_argument("mode", nargs="?", choices=("1",))
    parser.add_argument("--jobs", type=int, default=5)
    parser.add_argument("--block-rows", type=int, default=512)
    return parser.parse_args()


def main():
    args = parse_args()
    root = Path.cwd().resolve()
    if not (root.name.startswith("T") and root.name[1:].isdigit()):
        die(f"run in a T-number track root: {root}")
    if args.jobs < 1 or args.block_rows < 1:
        die("--jobs and --block-rows must be positive")
    out_dir = root / "GNSS2LOS_correction"
    ts_dir = out_dir / "GNSS_LOS_timeseries"
    reference = out_dir / "GNSS_to_LOS_ra.grd"
    marker = out_dir / "run6.5_complete"
    for path in (reference, marker):
        if not path.is_file() or path.stat().st_size == 0:
            die(f"missing required input: {path}")
    files = sorted(ts_dir.glob("gnss_LOS_*.grd"))
    if len(files) < 2:
        die(f"need at least two time-series grids in {ts_dir}")
    dated = sorted((tag_date(path)[0], path) for path in files)
    dates = [item[0] for item in dated]
    files = [item[1] for item in dated]
    times = np.array([(date - dates[0]).days for date in dates], dtype=np.float64)
    first_meta = metadata(files[0])
    last_meta = metadata(files[-1])
    ref_meta = metadata(reference)
    if first_meta != last_meta or first_meta != ref_meta:
        die("first/last time-series grids and reference velocity have different geometry")

    print("========================================")
    print("Run 6.6: validate GNSS LOS displacement time series")
    print(f"Run mode          : {'FORMAL' if args.mode == '1' else 'CHECK ONLY'}")
    print(f"Track root        : {root}")
    print(f"Reference velocity: {reference}")
    print(f"Time-series grids : {len(files)}")
    print(f"First date        : {dates[0]} ({files[0].name})")
    print(f"Last date         : {dates[-1]} ({files[-1].name})")
    print("Date convention   : YYYY000 = January 1")
    print("Velocity scaling  : fitted mm/day x 365.0")
    print(f"Parallel workers  : {args.jobs}")
    print(f"Block rows        : {args.block_rows}")
    print("========================================")
    if args.mode is None:
        print("Formal run:")
        print("  ./run6.6_validate_GNSS_LOS_timeseries.py 1")
        print("[CHECK ONLY] Full grids were not loaded and no output was created.")
        return 0

    validation = out_dir / "GNSS_LOS_validation"
    validation.mkdir(exist_ok=True)
    temp_fit = validation / f".GNSS_to_LOS_ra_refit.{os.getpid()}.grd"
    fit_grid = validation / "GNSS_to_LOS_ra_refit.grd"
    diff_grid = validation / "GNSS_to_LOS_ra_difference.grd"

    newest_input = max(reference.stat().st_mtime, marker.stat().st_mtime)
    resume_ready = all(
        path.is_file() and path.stat().st_size > 0 and path.stat().st_mtime >= newest_input
        for path in (fit_grid, diff_grid)
    )
    if resume_ready:
        try:
            resume_ready = metadata(fit_grid) == ref_meta and metadata(diff_grid) == ref_meta
        except SystemExit:
            resume_ready = False

    if resume_ready:
        print("[RESUME] Valid refitted and difference grids already exist.")
        print("[RESUME] Skip the completed pixel-wise fitting and regenerate plots only.")
    else:
        try:
            import xarray as xr
        except ImportError:
            die("formal mode requires Python xarray (and a NetCDF backend)")
        with xr.open_dataset(files[0], decode_times=False) as dataset:
            names = [name for name, var in dataset.data_vars.items() if var.ndim == 2]
            array = dataset["z" if "z" in names else names[0]]
            if "y" in array.dims and "x" in array.dims:
                array = array.transpose("y", "x")
            ny, nx = array.shape

        blocks = [(y0, min(ny, y0 + args.block_rows)) for y0 in range(0, ny, args.block_rows)]
        fitted = np.full((ny, nx), np.nan, dtype=np.float32)
        file_strings = [str(path) for path in files]
        with ProcessPoolExecutor(max_workers=args.jobs) as executor:
            futures = [executor.submit(worker, y0, y1, file_strings, times) for y0, y1 in blocks]
            for number, future in enumerate(as_completed(futures), 1):
                y0, y1, values = future.result()
                fitted[y0:y1] = values
                print(f"[FIT] {number}/{len(blocks)} blocks completed (rows {y0}:{y1})", flush=True)

        write_like(files[0], temp_fit, fitted)
        temp_fit.replace(fit_grid)
        subprocess.run(
            ["gmt", "grdmath", fit_grid.name, str(reference), "SUB", "=", diff_grid.name],
            cwd=validation,
            check=True,
        )

    comparison_pdf = validation / "GNSS_LOS_validation_3panel.pdf"
    plot_three_panel(reference, fit_grid, diff_grid, comparison_pdf)
    (validation / "run6.6_complete").write_text(
        f"Run 6.6 completed successfully\nepochs={len(files)}\ncompleted={dt.datetime.now().isoformat()}\n"
    )
    print("========================================")
    print("[DONE] Run 6.6 validation completed.")
    print(f"Refitted velocity: {fit_grid}")
    print(f"Difference grid  : {diff_grid}")
    print(f"Three-panel plot : {comparison_pdf}")
    print("========================================")
    return 0


if __name__ == "__main__":
    sys.exit(main())
