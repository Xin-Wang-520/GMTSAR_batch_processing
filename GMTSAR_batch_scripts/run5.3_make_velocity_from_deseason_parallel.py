#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Run 5.3: estimate linear velocity from deseasoned SBAS displacement grids.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 22, 2026

import argparse
import datetime as dt
import fcntl
import math
import os
import re
import shutil
import subprocess
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from netCDF4 import Dataset


TAG_RE = re.compile(r"disp_(\d{7})\.grd$")


def tag_to_date(tag):
    year = int(tag[:4])
    doy = int(tag[4:])
    date = dt.date(year, 1, 1) + dt.timedelta(days=doy)
    if doy < 0 or date.year != year:
        raise ValueError(f"invalid GMTSAR zero-based day of year: {tag}")
    # GMTSAR displacement names use zero-based day of year: 000 = January 1.
    return date


def collect_files(folder):
    items = []
    seen = set()
    for path in sorted(folder.glob("disp_*.grd")):
        match = TAG_RE.fullmatch(path.name)
        if not match:
            continue
        tag = match.group(1)
        if tag in seen:
            raise RuntimeError(f"duplicate epoch: {tag}")
        seen.add(tag)
        items.append((tag_to_date(tag), tag, path.resolve()))
    items.sort(key=lambda item: item[0])
    return items


def find_grid_var(dataset):
    candidates = [name for name, var in dataset.variables.items() if var.ndim == 2]
    if not candidates:
        raise RuntimeError("No 2D grid variable found")
    return "z" if "z" in candidates else candidates[0]


def read_geometry(path):
    with Dataset(path, "r") as dataset:
        zname = find_grid_var(dataset)
        variable = dataset.variables[zname]
        if len(variable.dimensions) != 2:
            raise RuntimeError(f"grid variable is not two-dimensional: {path}")
        yname, xname = variable.dimensions
        if yname not in dataset.variables or xname not in dataset.variables:
            raise RuntimeError(f"coordinate variables are missing: {path}")
        y = np.asarray(dataset.variables[yname][:], dtype=np.float64)
        x = np.asarray(dataset.variables[xname][:], dtype=np.float64)
        shape = tuple(variable.shape)
    return zname, yname, xname, y, x, shape


def read_block(variable, y0, y1):
    values = variable[y0:y1, :]
    if np.ma.isMaskedArray(values):
        values = values.filled(np.nan)
    return np.asarray(values, dtype=np.float64)


def fit_block(y0, y1, file_names, times_days, zname, expected_shape, minimum_observations):
    count = sum_t = sum_t2 = sum_y = sum_ty = None

    for file_name, time_days in zip(file_names, times_days):
        with Dataset(file_name, "r") as dataset:
            variable = dataset.variables[zname]
            if tuple(variable.shape) != tuple(expected_shape):
                raise RuntimeError(f"grid shape mismatch: {file_name}")
            values = read_block(variable, y0, y1)

        if count is None:
            block_shape = values.shape
            count = np.zeros(block_shape, dtype=np.float64)
            sum_t = np.zeros(block_shape, dtype=np.float64)
            sum_t2 = np.zeros(block_shape, dtype=np.float64)
            sum_y = np.zeros(block_shape, dtype=np.float64)
            sum_ty = np.zeros(block_shape, dtype=np.float64)

        valid = np.isfinite(values)
        valid_float = valid.astype(np.float64)
        safe_values = np.where(valid, values, 0.0)
        count += valid_float
        sum_t += time_days * valid_float
        sum_t2 += time_days * time_days * valid_float
        sum_y += safe_values
        sum_ty += time_days * safe_values

    denominator = count * sum_t2 - sum_t * sum_t
    with np.errstate(divide="ignore", invalid="ignore"):
        slope_mm_per_day = (count * sum_ty - sum_t * sum_y) / denominator
        velocity = slope_mm_per_day * 365.0

    bad = (
        (count < minimum_observations)
        | (~np.isfinite(velocity))
        | (~np.isfinite(denominator))
        | (denominator == 0)
    )
    velocity[bad] = np.nan
    return y0, y1, velocity.astype(np.float32)


def create_output_like(template_path, output_path, zname, long_name, units, remark):
    source = Dataset(template_path, "r")
    source_z = source.variables[zname]
    output = Dataset(output_path, "w", format="NETCDF4")

    for dimension_name, dimension in source.dimensions.items():
        output.createDimension(dimension_name, len(dimension))

    for attribute in source.ncattrs():
        output.setncattr(attribute, source.getncattr(attribute))

    for coordinate_name in source_z.dimensions:
        source_coordinate = source.variables[coordinate_name]
        fill_value = (
            source_coordinate.getncattr("_FillValue")
            if "_FillValue" in source_coordinate.ncattrs() else None
        )
        if fill_value is None:
            output_coordinate = output.createVariable(
                coordinate_name, source_coordinate.dtype, source_coordinate.dimensions
            )
        else:
            output_coordinate = output.createVariable(
                coordinate_name, source_coordinate.dtype, source_coordinate.dimensions,
                fill_value=fill_value
            )
        output_coordinate[:] = source_coordinate[:]
        for attribute in source_coordinate.ncattrs():
            if attribute != "_FillValue":
                output_coordinate.setncattr(attribute, source_coordinate.getncattr(attribute))

    output_z = output.createVariable(
        zname, "f4", source_z.dimensions, fill_value=np.float32(np.nan),
        zlib=True, complevel=3, shuffle=True
    )
    for attribute in source_z.ncattrs():
        if attribute not in {"_FillValue", "scale_factor", "add_offset", "long_name", "units"}:
            output_z.setncattr(attribute, source_z.getncattr(attribute))
    output_z.setncattr("long_name", long_name)
    output_z.setncattr("units", units)
    output.setncattr("Remark", remark)
    source.close()
    return output


def refresh_gmt_grid(source_path, destination_path):
    refreshed = source_path.with_name(source_path.name + ".gmt.grd")
    subprocess.run(
        ["gmt", "grdmath", str(source_path), "1", "MUL", "=", str(refreshed)],
        check=True
    )
    os.replace(refreshed, destination_path)
    source_path.unlink(missing_ok=True)


def plot_velocity(grid_path, output_path, maximum_plot_nodes=2000, dpi=300):
    with Dataset(grid_path, "r") as dataset:
        zname = find_grid_var(dataset)
        variable = dataset.variables[zname]
        yname, xname = variable.dimensions
        ny, nx = variable.shape
        y_step = max(1, math.ceil(ny / maximum_plot_nodes))
        x_step = max(1, math.ceil(nx / maximum_plot_nodes))
        values = variable[::y_step, ::x_step]
        if np.ma.isMaskedArray(values):
            values = values.filled(np.nan)
        values = np.asarray(values, dtype=np.float64)
        y = np.asarray(dataset.variables[yname][::y_step], dtype=np.float64)
        x = np.asarray(dataset.variables[xname][::x_step], dtype=np.float64)

    finite = np.isfinite(values)
    if not np.any(finite):
        raise RuntimeError("No finite values found in velocity grid")
    vmax = float(np.nanpercentile(np.abs(values[finite]), 98))
    if not np.isfinite(vmax) or vmax == 0:
        vmax = 1.0

    figure, axis = plt.subplots(figsize=(10, 8))
    image = axis.pcolormesh(
        x, y, values, shading="auto", cmap="seismic", vmin=-vmax, vmax=vmax
    )
    colorbar = figure.colorbar(image, ax=axis)
    colorbar.set_label("Velocity (mm/yr)")
    axis.set_title("Velocity from deseasoned time series")
    axis.set_xlabel("Range")
    axis.set_ylabel("Azimuth")
    figure.tight_layout()
    figure.savefig(output_path, dpi=dpi)
    plt.close(figure)
    return -vmax, vmax, x_step, y_step


def main():
    parser = argparse.ArgumentParser(
        description="Run 5.3: estimate linear velocity from deseasoned displacement grids"
    )
    parser.add_argument("mode", nargs="?", choices=["1"], help="omit for check; 1 for formal run")
    parser.add_argument("--jobs", type=int, default=20, help="parallel workers (default: 20)")
    parser.add_argument("--block-rows", type=int, default=512, help="rows per block (default: 512)")
    parser.add_argument(
        "--min-observations", type=int, default=2,
        help="minimum finite epochs required per pixel (default: 2)"
    )
    parser.add_argument("--dpi", type=int, default=300, help="PNG resolution (default: 300)")
    args = parser.parse_args()

    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    if args.block_rows < 1:
        parser.error("--block-rows must be at least 1")
    if args.min_observations < 2:
        parser.error("--min-observations must be at least 2")
    if args.dpi < 72:
        parser.error("--dpi must be at least 72")

    root = Path.cwd().resolve()
    if not re.fullmatch(r"T\d+", root.name):
        raise SystemExit(f"[ERROR] run this script in a T-number track root: {root}")
    sbas_dir = root / "sbas_demcorr_pin"
    input_dir = sbas_dir / "disp_deseason"
    run5_1_marker = input_dir / "run5.1_complete"
    if not input_dir.is_dir():
        raise SystemExit(f"[ERROR] directory not found: {input_dir}")
    if not run5_1_marker.is_file() or run5_1_marker.stat().st_size == 0:
        raise SystemExit(f"[ERROR] valid Run 5.1 marker not found: {run5_1_marker}")
    if shutil.which("gmt") is None:
        raise SystemExit("[ERROR] gmt is not available in PATH")

    items = collect_files(input_dir)
    if len(items) < 2:
        raise SystemExit("[ERROR] at least two deseasoned displacement grids are required")
    dates = [item[0] for item in items]
    tags = [item[1] for item in items]
    files = [item[2] for item in items]
    times_days = np.array([(date - dates[0]).days for date in dates], dtype=np.float64)

    zname, yname, xname, y, x, shape = read_geometry(files[0])
    last_geometry = read_geometry(files[-1])
    if (
        last_geometry[0:3] != (zname, yname, xname)
        or last_geometry[5] != shape
        or not np.array_equal(last_geometry[3], y)
        or not np.array_equal(last_geometry[4], x)
    ):
        raise SystemExit("[ERROR] first and last deseasoned grids have different geometry")

    ny, nx = shape
    blocks = [(y0, min(ny, y0 + args.block_rows)) for y0 in range(0, ny, args.block_rows)]
    output_velocity = input_dir / "vel_deseason.grd"
    output_figure = input_dir / "vel_deseason.png"
    completion = input_dir / "run5.3_complete"

    print("========================================")
    print("Run 5.3: velocity from deseasoned displacement stack")
    print(f"Mode                 : {'FORMAL' if args.mode == '1' else 'CHECK ONLY'}")
    print(f"Track root           : {root}")
    print(f"Input directory      : {input_dir}")
    print(f"Displacement grids   : {len(files)}")
    print(f"First epoch          : {tags[0]} ({dates[0]})")
    print(f"Last epoch           : {tags[-1]} ({dates[-1]})")
    print(f"Time span            : {times_days[-1]:.0f} days")
    print(f"Grid variable        : {zname}")
    print(f"Grid shape           : {ny} rows x {nx} columns")
    print(f"Parallel workers     : {args.jobs}")
    print(f"Rows per block       : {args.block_rows}")
    print(f"Processing blocks    : {len(blocks)}")
    print(f"Minimum observations : {args.min_observations}")
    print("Velocity conversion  : linear slope (mm/day) x 365.0")
    print(f"Velocity output      : {output_velocity}")
    print(f"Preview output       : {output_figure}")
    print("========================================")

    if args.mode is None:
        print("[CHECK ONLY] No velocity grid or plot was created.")
        print("[NEXT] Formal run with the default 20 workers:")
        print("  ./run5.3_make_velocity_from_deseason_parallel.py 1")
        print("[OPTION] Reduce parallel workers on a busy server:")
        print("  ./run5.3_make_velocity_from_deseason_parallel.py 1 --jobs 5")
        return

    lock_path = input_dir / ".run5.3.lock"
    lock_stream = lock_path.open("w")
    try:
        fcntl.flock(lock_stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("[ERROR] another Run 5.3 process is already running")

    completion.unlink(missing_ok=True)

    pid = os.getpid()
    temporary_velocity = input_dir / f".run5.3_vel.{pid}.grd"
    temporary_figure = input_dir / f".run5.3_vel.{pid}.png"
    temporary_paths = [temporary_velocity, temporary_figure]

    velocity_dataset = None
    try:
        velocity_dataset = create_output_like(
            files[0], temporary_velocity, zname,
            "linear velocity from deseasoned displacement", "mm/yr",
            "Run 5.3 linear velocity from Run 5.1 deseasoned displacement grids"
        )
        velocity_variable = velocity_dataset.variables[zname]

        completed_blocks = 0
        with ProcessPoolExecutor(max_workers=args.jobs) as executor:
            futures = [
                executor.submit(
                    fit_block, y0, y1, [str(path) for path in files], times_days,
                    zname, shape, args.min_observations
                )
                for y0, y1 in blocks
            ]
            for future in as_completed(futures):
                y0, y1, velocity_block = future.result()
                velocity_variable[y0:y1, :] = velocity_block
                completed_blocks += 1
                print(
                    f"[PROGRESS] {completed_blocks}/{len(blocks)} blocks "
                    f"(rows {y0}:{y1})", flush=True
                )

        velocity_dataset.close()
        velocity_dataset = None

        print("[INFO] Refreshing GMT grid headers...")
        refresh_gmt_grid(temporary_velocity, output_velocity)

        print("[INFO] Plotting a memory-limited velocity preview...")
        color_min, color_max, x_step, y_step = plot_velocity(
            output_velocity, temporary_figure, dpi=args.dpi
        )
        os.replace(temporary_figure, output_figure)

        completion.write_text(
            f"completed={dt.datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %z')}\n"
            f"track={root.name}\n"
            f"epochs={len(files)}\n"
            f"first_epoch={tags[0]}\n"
            f"last_epoch={tags[-1]}\n"
            f"jobs={args.jobs}\n"
            f"block_rows={args.block_rows}\n"
            f"minimum_observations={args.min_observations}\n"
            f"velocity_year_days=365.0\n"
            f"plot_color_range={color_min:.6f}/{color_max:.6f}\n"
            f"plot_decimation={x_step}/{y_step}\n"
        )

        print("========================================")
        print("[DONE] Run 5.3 completed")
        print(f"Velocity grid    : {output_velocity}")
        print(f"Velocity plot    : {output_figure}")
        print(f"Completion marker: {completion}")
        print(f"Plot color range : {color_min:.2f} / {color_max:.2f} mm/yr")
        print("========================================")
    finally:
        if velocity_dataset is not None:
            velocity_dataset.close()
        for temporary_path in temporary_paths:
            temporary_path.unlink(missing_ok=True)
        for temporary_path in input_dir.glob(f".run5.3_*.{pid}.grd.gmt.grd"):
            temporary_path.unlink(missing_ok=True)
        fcntl.flock(lock_stream.fileno(), fcntl.LOCK_UN)
        lock_stream.close()
        lock_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
