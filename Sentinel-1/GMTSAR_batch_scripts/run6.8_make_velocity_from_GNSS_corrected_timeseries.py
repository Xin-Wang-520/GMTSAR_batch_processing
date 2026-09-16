#!/usr/bin/env python3
"""Run 6.8: fit velocity from GNSS-corrected displacement and correction grids."""

# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 24, 2026

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

import numpy as np

SERIES = {
    "corrected": {
        "regex": re.compile(r"disp_(\d{4})(\d{3})_gnssref_5km_80km\.grd$"),
        "glob": "disp_*_gnssref_5km_80km.grd",
        "output": "vel_gnssref_5km_80km.grd",
        "long_name": "velocity from GNSS-referenced deseasoned InSAR displacement",
    },
    "correction": {
        "regex": re.compile(r"diff_(\d{4})(\d{3})_smooth80km_full\.grd$"),
        "glob": "diff_*_smooth80km_full.grd",
        "output": "vel_diff_smooth80km_full.grd",
        "long_name": "velocity of the removed long-wavelength InSAR minus GNSS correction",
    },
}


def die(message: str):
    raise SystemExit(f"[ERROR] {message}")


def parse_date(path: Path, regex: re.Pattern[str]) -> tuple[dt.date, str]:
    match = regex.fullmatch(path.name)
    if not match:
        die(f"invalid time-series name: {path.name}")
    year, ddd = map(int, match.groups())
    maximum = 365 if calendar.isleap(year) else 364
    if not 0 <= ddd <= maximum:
        die(f"invalid zero-based day of year: {year:04d}{ddd:03d}")
    return dt.date(year, 1, 1) + dt.timedelta(days=ddd), f"{year:04d}{ddd:03d}"


def collect(folder: Path, config: dict) -> list[tuple[dt.date, Path]]:
    items = [
        (parse_date(path, config["regex"])[0], path)
        for path in sorted(folder.glob(config["glob"]))
    ]
    if len(items) < 2:
        die(f"fewer than two grids matching {folder / config['glob']}")
    return sorted(items)


def read_grid(path: str, y0: int | None = None, y1: int | None = None):
    import xarray as xr

    with xr.open_dataset(path, decode_times=False) as dataset:
        names = [name for name, var in dataset.data_vars.items() if var.ndim == 2]
        if not names:
            raise RuntimeError(f"no 2-D grid variable in {path}")
        array = dataset["z" if "z" in names else names[0]]
        if "y" in array.dims and "x" in array.dims:
            array = array.transpose("y", "x")
        if y0 is not None:
            array = array.isel({array.dims[0]: slice(y0, y1)})
        return np.asarray(array.values, dtype=np.float64)


def grid_geometry(path: Path):
    import xarray as xr

    with xr.open_dataset(path, decode_times=False) as dataset:
        names = [name for name, var in dataset.data_vars.items() if var.ndim == 2]
        if not names:
            die(f"no 2-D grid variable in {path}")
        array = dataset["z" if "z" in names else names[0]]
        if "y" in array.dims and "x" in array.dims:
            array = array.transpose("y", "x")
        ydim, xdim = array.dims
        return (
            tuple(array.shape),
            np.asarray(dataset[xdim].values),
            np.asarray(dataset[ydim].values),
            array.dims,
        )


def fit_block(y0: int, y1: int, files: list[str], times: np.ndarray):
    sums = None
    for path, time in zip(files, times):
        values = read_grid(path, y0, y1)
        if sums is None:
            sums = [np.zeros(values.shape, dtype=np.float64) for _ in range(5)]
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


def write_like(template: Path, output: Path, values: np.ndarray, long_name: str):
    import xarray as xr

    with xr.open_dataset(template, decode_times=False) as dataset:
        names = [name for name, var in dataset.data_vars.items() if var.ndim == 2]
        array = dataset["z" if "z" in names else names[0]]
        if "y" in array.dims and "x" in array.dims:
            array = array.transpose("y", "x")
        coords = {dim: np.asarray(dataset[dim].values) for dim in array.dims}
        result = xr.Dataset(
            {"z": (array.dims, values, {"long_name": long_name, "units": "mm/yr"})},
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


def fit_series(label: str, items, output: Path, jobs: int, block_rows: int, long_name: str):
    dates = [item[0] for item in items]
    files = [item[1] for item in items]
    times = np.asarray([(date - dates[0]).days for date in dates], dtype=np.float64)
    shape, _, _, _ = grid_geometry(files[0])
    last_shape, _, _, _ = grid_geometry(files[-1])
    if shape != last_shape:
        die(f"{label}: first and last grid shapes differ")
    ny, nx = shape
    blocks = [(y0, min(y0 + block_rows, ny)) for y0 in range(0, ny, block_rows)]
    velocity = np.full((ny, nx), np.nan, dtype=np.float32)
    print(f"[FIT] {label}: {len(files)} epochs, {ny}x{nx}, {len(blocks)} blocks")
    file_names = [str(path) for path in files]
    if jobs == 1:
        for number, (start, stop) in enumerate(blocks, 1):
            y0, y1, block = fit_block(start, stop, file_names, times)
            velocity[y0:y1] = block
            print(f"[FIT] {label}: {number}/{len(blocks)} blocks completed (rows {y0}:{y1})", flush=True)
    else:
        with ProcessPoolExecutor(max_workers=jobs) as executor:
            futures = [
                executor.submit(fit_block, y0, y1, file_names, times)
                for y0, y1 in blocks
            ]
            for number, future in enumerate(as_completed(futures), 1):
                y0, y1, block = future.result()
                velocity[y0:y1] = block
                print(f"[FIT] {label}: {number}/{len(blocks)} blocks completed (rows {y0}:{y1})", flush=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp.grd")
    write_like(files[0], temporary, velocity, long_name)
    temporary.replace(output)


def plot_six_panel(
    original: Path,
    deseasoned: Path,
    gnss: Path,
    corrected: Path,
    correction: Path,
    pdf: Path,
):
    """Plot the complete velocity-correction workflow in a two-by-three layout."""
    plot_dir = pdf.parent / f".run6.8_plot.{os.getpid()}"
    plot_dir.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env.update(
        {
            "ORIGINAL": str(original.resolve()),
            "DESEASONED": str(deseasoned.resolve()),
            "GNSS": str(gnss.resolve()),
            "CORRECTED": str(corrected.resolve()),
            "CORRECTION": str(correction.resolve()),
        }
    )
    commands = r'''set -euo pipefail
gmt makecpt -Cjet -T-5/5/1 -Z -D > velocity.cpt
gmt makecpt -Cpolar -T-5/5/1 -Z -D > correction.cpt
gmt makecpt -Cpolar -T-0.01/0.01/0.001 -Z -D > residual.cpt
gmt grdmath "$DESEASONED" "$CORRECTED" SUB "$CORRECTION" SUB = closure_residual.grd
REGION="$(gmt grdinfo "$ORIGINAL" -C | awk 'NR==1{print $2"/"$3"/"$4"/"$5}')"
gmt set PS_MEDIA A3 MAP_FRAME_TYPE plain MAP_TITLE_OFFSET 8p \
    FONT_ANNOT_PRIMARY 8p FONT_LABEL 9p FONT_TITLE 10p COLOR_NAN gray

# Top-left: original SBAS velocity before seasonal correction
gmt grdimage "$ORIGINAL" -R"$REGION" -JX8c/10c -Cvelocity.cpt \
    -Baf -BWSen+t"Original SBAS velocity" -K -X1.5c -Y16.5c > velocity.ps
gmt psscale -R"$REGION" -JX8c/10c -DJBC+w6c/0.25c+h+o0c/0.8c \
    -Cvelocity.cpt -Bxa5f1+l"Velocity (mm/yr)" -O -K >> velocity.ps

# Top-middle: velocity after seasonal correction
gmt grdimage "$DESEASONED" -R"$REGION" -JX8c/10c -Cvelocity.cpt \
    -Baf -BWSen+t"Deseasoned InSAR velocity" -O -K -X10c >> velocity.ps
gmt psscale -R"$REGION" -JX8c/10c -DJBC+w6c/0.25c+h+o0c/0.8c \
    -Cvelocity.cpt -Bxa5f1+l"Velocity (mm/yr)" -O -K >> velocity.ps

# Top-right: GNSS LOS velocity on the radar grid
gmt grdimage "$GNSS" -R"$REGION" -JX8c/10c -Cvelocity.cpt \
    -Baf -BWSen+t"GNSS LOS velocity" -O -K -X10c >> velocity.ps
gmt psscale -R"$REGION" -JX8c/10c -DJBC+w6c/0.25c+h+o0c/0.8c \
    -Cvelocity.cpt -Bxa5f1+l"Velocity (mm/yr)" -O -K >> velocity.ps

# Bottom-left: final GNSS-corrected InSAR velocity
gmt grdimage "$CORRECTED" -R"$REGION" -JX8c/10c -Cvelocity.cpt \
    -Baf -BWSen+t"GNSS-corrected InSAR velocity" -O -K -X-20c -Y-14c >> velocity.ps
gmt psscale -R"$REGION" -JX8c/10c -DJBC+w6c/0.25c+h+o0c/0.8c \
    -Cvelocity.cpt -Bxa5f1+l"Velocity (mm/yr)" -O -K >> velocity.ps

# Bottom-middle: velocity of the removed long-wavelength correction
gmt grdimage "$CORRECTION" -R"$REGION" -JX8c/10c -Ccorrection.cpt \
    -Baf -BWSen+t"Removed long-wavelength velocity" -O -K -X10c >> velocity.ps
gmt psscale -R"$REGION" -JX8c/10c -DJBC+w6c/0.25c+h+o0c/0.8c \
    -Ccorrection.cpt -Bxa5f1+l"Correction (mm/yr)" -O -K >> velocity.ps

# Bottom-right: deseasoned - corrected - correction; should be close to zero
gmt grdimage closure_residual.grd -R"$REGION" -JX8c/10c -Cresidual.cpt \
    -Baf -BWSen+t"Closure residual" -O -K -X10c >> velocity.ps
gmt psscale -R"$REGION" -JX8c/10c -DJBC+w6c/0.25c+h+o0c/0.8c \
    -Cresidual.cpt -Bxa0.005f0.001+l"Residual (mm/yr)" -O >> velocity.ps
gmt psconvert velocity.ps -Tf -A -FGNSS_corrected_velocity_6panel
'''
    try:
        completed = subprocess.run(
            ["bash", "-c", commands], cwd=plot_dir, env=env, text=True, capture_output=True
        )
        if completed.returncode:
            die(f"GMT plotting failed:\n{completed.stdout}\n{completed.stderr}")
        generated = plot_dir / "GNSS_corrected_velocity_6panel.pdf"
        if not generated.is_file() or generated.stat().st_size == 0:
            die("GMT did not generate the Run 6.8 six-panel PDF")
        generated.replace(pdf)
    finally:
        shutil.rmtree(plot_dir, ignore_errors=True)


def parse_args():
    parser = argparse.ArgumentParser(description="Run 6.8: fit GNSS-corrected InSAR velocity")
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
    if shutil.which("gmt") is None:
        die("gmt not found in PATH")
    try:
        import xarray  # noqa: F401
    except ImportError:
        die("Python xarray and a NetCDF backend are required")

    run6_dir = root / "GNSS2LOS_correction"
    input_dir = run6_dir / "GNSS_corrected_displacement"
    original_velocity = root / "sbas_demcorr_pin" / "vel.grd"
    before_velocity = root / "sbas_demcorr_pin" / "disp_deseason" / "vel_deseason.grd"
    gnss_velocity = run6_dir / "GNSS_to_LOS_ra.grd"
    marker = run6_dir / "run6.7_complete"
    if not marker.is_file() or marker.stat().st_size == 0:
        die(f"missing Run 6.7 completion marker: {marker}")
    if not input_dir.is_dir():
        die(f"missing Run 6.7 output directory: {input_dir}")
    if not original_velocity.is_file() or original_velocity.stat().st_size == 0:
        die(f"missing original SBAS velocity: {original_velocity}")
    if not before_velocity.is_file() or before_velocity.stat().st_size == 0:
        die(f"missing Run 5.3 deseasoned velocity: {before_velocity}")
    if not gnss_velocity.is_file() or gnss_velocity.stat().st_size == 0:
        die(f"missing Run 6.4 GNSS LOS radar velocity: {gnss_velocity}")

    collected = {name: collect(input_dir, config) for name, config in SERIES.items()}
    corrected_tags = [parse_date(path, SERIES["corrected"]["regex"])[1] for _, path in collected["corrected"]]
    correction_tags = [parse_date(path, SERIES["correction"]["regex"])[1] for _, path in collected["correction"]]
    if corrected_tags != correction_tags:
        die("corrected-displacement and correction series contain different epochs")
    series_shape, series_x, series_y, _ = grid_geometry(collected["corrected"][0][1])
    for label, path in (
        ("original SBAS velocity", original_velocity),
        ("Run 5.3 deseasoned velocity", before_velocity),
        ("Run 6.4 GNSS LOS radar velocity", gnss_velocity),
    ):
        shape, x, y, _ = grid_geometry(path)
        if (
            shape != series_shape
            or not np.allclose(x, series_x, rtol=0.0, atol=1e-9)
            or not np.allclose(y, series_y, rtol=0.0, atol=1e-9)
        ):
            die(f"{label} and Run 6.7 displacement grids have different geometry")

    print("========================================")
    print("Run 6.8: fit velocity from GNSS-corrected time series")
    print(f"Run mode          : {'FORMAL' if args.mode == '1' else 'CHECK ONLY'}")
    print(f"Track root        : {root}")
    print(f"Input directory   : {input_dir}")
    print(f"Original velocity : {original_velocity}")
    print(f"Deseasoned velocity: {before_velocity}")
    print(f"GNSS LOS velocity : {gnss_velocity}")
    print(f"Matched epochs    : {len(corrected_tags)}")
    print(f"First date        : {collected['corrected'][0][0]} ({corrected_tags[0]})")
    print(f"Last date         : {collected['corrected'][-1][0]} ({corrected_tags[-1]})")
    print("Date convention   : YYYY000 = January 1")
    print("Velocity scaling  : fitted mm/day x 365.0")
    print(f"Parallel workers  : {args.jobs}")
    print(f"Block rows        : {args.block_rows}")
    print("========================================")
    if args.mode is None:
        print("Formal run:")
        print("  ./run6.8_make_velocity_from_GNSS_corrected_timeseries.py 1")
        print("Adjust workers if needed:")
        print("  ./run6.8_make_velocity_from_GNSS_corrected_timeseries.py 1 --jobs 10")
        print("[CHECK ONLY] No velocity grid or plot was created.")
        return 0

    outputs = {
        name: input_dir / config["output"] for name, config in SERIES.items()
    }
    newest_input = max(marker.stat().st_mtime, *(path.stat().st_mtime for _, path in collected["corrected"]), *(path.stat().st_mtime for _, path in collected["correction"]))
    for name, config in SERIES.items():
        output = outputs[name]
        if output.is_file() and output.stat().st_size > 0 and output.stat().st_mtime >= newest_input:
            try:
                subprocess.run(["gmt", "grdinfo", str(output), "-C"], check=True, capture_output=True)
                print(f"[RESUME] Keep valid existing velocity: {output.name}")
                continue
            except subprocess.CalledProcessError:
                pass
        fit_series(name, collected[name], output, args.jobs, args.block_rows, config["long_name"])

    pdf = input_dir / "GNSS_corrected_velocity_6panel.pdf"
    plot_six_panel(
        original_velocity,
        before_velocity,
        gnss_velocity,
        outputs["corrected"],
        outputs["correction"],
        pdf,
    )
    (run6_dir / "run6.8_complete").write_text(
        "Run 6.8 completed successfully\n"
        f"track={root.name}\n"
        f"epochs={len(corrected_tags)}\n"
        f"original_velocity={original_velocity}\n"
        f"deseasoned_velocity={before_velocity}\n"
        f"gnss_velocity={gnss_velocity}\n"
        f"corrected_velocity={outputs['corrected']}\n"
        f"correction_velocity={outputs['correction']}\n",
        encoding="utf-8",
    )
    print("========================================")
    print("[DONE] Run 6.8 completed successfully.")
    print(f"Corrected velocity : {outputs['corrected']}")
    print(f"Correction velocity: {outputs['correction']}")
    print(f"Plot               : {pdf}")
    print("[NEXT] ./run6.9_geocode_GNSS_corrected_velocity.sh")
    print("========================================")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
