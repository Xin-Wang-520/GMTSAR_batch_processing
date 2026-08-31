#!/usr/bin/env python3
"""Run 6.3: project horizontal GNSS east/north velocity onto InSAR LOS."""

from __future__ import annotations

import argparse
import datetime as dt
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np


DEFAULT_DIR = "GNSS2LOS_correction"
DEFAULT_TRACKS = {"ascending": 350.0, "descending": 190.0}
DEFAULT_LOOK = 40.0


def die(message: str) -> "None":
    raise SystemExit(f"[ERROR] {message}")


def read_grid(path: Path):
    try:
        import xarray as xr
    except ImportError:
        xr = None

    if xr is not None:
        try:
            ds = xr.open_dataset(path, decode_times=False)
            candidates = [name for name, var in ds.data_vars.items() if var.ndim == 2]
            if not candidates:
                ds.close()
                die(f"no two-dimensional grid variable found in {path}")
            zname = "z" if "z" in candidates else candidates[0]
            da = ds[zname]
            data = np.asarray(da.values, dtype=np.float64)
            dims = tuple(da.dims)
            coords = {name: np.asarray(ds[name].values) for name in dims}
            global_attrs = dict(ds.attrs)
            variable_attrs = dict(da.attrs)
            ds.close()
            return data, dims, coords, global_attrs, variable_attrs
        except Exception as exc:
            xarray_error = exc
    else:
        xarray_error = "xarray is not installed"

    try:
        from netCDF4 import Dataset
    except ImportError:
        die(
            "cannot read GMT grids: install either netCDF4 or xarray; "
            f"xarray result: {xarray_error}"
        )

    try:
        with Dataset(path, "r") as ds:
            candidates = [name for name, var in ds.variables.items() if var.ndim == 2]
            if not candidates:
                die(f"no two-dimensional grid variable found in {path}")
            zname = "z" if "z" in candidates else candidates[0]
            var = ds.variables[zname]
            raw = var[:]
            data = np.ma.filled(raw, np.nan).astype(np.float64)
            dims = tuple(var.dimensions)
            coords = {name: np.asarray(ds.variables[name][:]) for name in dims}
            global_attrs = {name: ds.getncattr(name) for name in ds.ncattrs()}
            variable_attrs = {name: var.getncattr(name) for name in var.ncattrs()}
    except Exception as exc:
        die(f"cannot open {path} with xarray or netCDF4: {xarray_error}; {exc}")
    return data, dims, coords, global_attrs, variable_attrs


def finite_range(data: np.ndarray, label: str) -> tuple[float, float]:
    finite = data[np.isfinite(data)]
    if finite.size == 0:
        die(f"{label} contains no finite value")
    return float(finite.min()), float(finite.max())


def read_grid_metadata(path: Path) -> dict[str, float | int]:
    """Read only the GMT grid header; do not load the 2-D pixel array."""
    if shutil.which("gmt") is None:
        die("gmt not found in PATH")
    result = subprocess.run(
        ["gmt", "grdinfo", str(path), "-C"],
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        die(f"GMT cannot read grid metadata for {path}: {detail}")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        die(f"gmt grdinfo returned no metadata for {path}")
    fields = lines[-1].split()
    if len(fields) < 13:
        die(f"unexpected gmt grdinfo -C output for {path}: {lines[-1]}")
    values = fields[-12:]
    try:
        return {
            "xmin": float(values[0]),
            "xmax": float(values[1]),
            "ymin": float(values[2]),
            "ymax": float(values[3]),
            "zmin": float(values[4]),
            "zmax": float(values[5]),
            "xinc": float(values[6]),
            "yinc": float(values[7]),
            "nx": int(values[8]),
            "ny": int(values[9]),
            "registration": int(values[10]),
        }
    except (ValueError, IndexError) as exc:
        die(f"cannot parse gmt grdinfo metadata for {path}: {exc}")


def same_grid_geometry(first: dict, second: dict) -> bool:
    for key in ("xmin", "xmax", "ymin", "ymax", "xinc", "yinc"):
        if not math.isclose(first[key], second[key], rel_tol=1e-10, abs_tol=1e-12):
            return False
    return all(
        first[key] == second[key]
        for key in ("nx", "ny", "registration")
    )


def projection_coefficients(track: float, look: float) -> tuple[float, float]:
    track_rad = math.radians(track)
    look_rad = math.radians(look)
    proj_e = -math.sin(look_rad) * math.cos(track_rad)
    proj_n = math.sin(look_rad) * math.sin(track_rad)
    return proj_e, proj_n


def write_grid(
    path: Path,
    los: np.ndarray,
    dims,
    coords,
    global_attrs,
    variable_attrs,
    track: float,
    look: float,
) -> None:
    attrs = dict(variable_attrs)
    attrs.pop("actual_range", None)
    attrs.pop("_FillValue", None)
    attrs["long_name"] = "GNSS horizontal velocity projected onto InSAR LOS"
    attrs["units"] = "mm/yr"
    attrs["track_azimuth_degrees"] = track
    attrs["look_angle_degrees"] = look

    try:
        from netCDF4 import Dataset
    except ImportError:
        Dataset = None

    if Dataset is not None:
        with Dataset(path, "w", format="NETCDF4_CLASSIC") as out:
            for dim in dims:
                out.createDimension(dim, len(coords[dim]))
                coordinate = out.createVariable(dim, "f8", (dim,))
                coordinate[:] = coords[dim]
            grid = out.createVariable("z", "f4", dims, fill_value=np.float32(np.nan))
            grid[:] = los.astype(np.float32)
            for name, value in attrs.items():
                try:
                    grid.setncattr(name, value)
                except (TypeError, ValueError):
                    pass
            for name, value in global_attrs.items():
                if name == "actual_range":
                    continue
                try:
                    out.setncattr(name, value)
                except (TypeError, ValueError):
                    pass
            out.title = "GNSS horizontal velocity projected to InSAR LOS"
            out.remark = f"track={track} degrees; look={look} degrees"
        return

    try:
        import xarray as xr
    except ImportError:
        die("cannot write GMT grid: install either netCDF4 or xarray")
    out = xr.Dataset(
        data_vars={"z": (dims, los.astype(np.float32), attrs)},
        coords={name: (name, coords[name]) for name in dims},
        attrs={
            **{k: v for k, v in global_attrs.items() if k != "actual_range"},
            "title": "GNSS horizontal velocity projected to InSAR LOS",
            "remark": f"track={track} degrees; look={look} degrees",
        },
    )
    encoding = {"z": {"dtype": "float32", "_FillValue": np.float32(np.nan)}}
    try:
        out.to_netcdf(path, format="NETCDF4_CLASSIC", encoding=encoding)
    except ValueError:
        out.to_netcdf(path, encoding=encoding)
    finally:
        out.close()


def plot_grid_with_gmt(
    grid_path: Path,
    pdf_path: Path,
    orbit: str,
    track: float,
    look: float,
) -> None:
    if shutil.which("gmt") is None:
        die("gmt not found in PATH; cannot plot GNSS_to_LOS.pdf")
    work_dir = pdf_path.parent
    plot_dir = work_dir / f".run6.3_plot.{os.getpid()}"
    plot_dir.mkdir(exist_ok=False)
    env = os.environ.copy()
    env.update(
        {
            "GRID": str(grid_path.resolve()),
            "CPT": "GNSS_to_LOS.cpt",
            "PS": "GNSS_to_LOS.ps",
            "OUT_BASE": "GNSS_to_LOS",
            "PLOT_TITLE": (
                f"GNSS to LOS velocity ({orbit}, "
                f"track={track:g} deg, look={look:g} deg)"
            ),
        }
    )
    commands = r'''
set -euo pipefail
gmt makecpt -Cjet -T-5/5/1 -Z -D > "$CPT"
REGION="$(gmt grdinfo "$GRID" -C | awk 'NR==1{print $2"/"$3"/"$4"/"$5}')"
gmt set \
    MAP_FRAME_TYPE plain \
    FONT_ANNOT_PRIMARY 10p \
    FONT_LABEL 11p \
    FONT_TITLE 13p \
    COLOR_NAN gray
gmt grdimage "$GRID" \
    -JM15c \
    -C"$CPT" \
    -Baf \
    -BWSen+t"$PLOT_TITLE" \
    -P -K > "$PS"
gmt psscale \
    -R"$REGION" -JM15c \
    -DJBC+w10c/0.3c+h+o0c/1.0c \
    -C"$CPT" \
    -Bxa5f1+l"LOS velocity (mm/yr)" \
    -O >> "$PS"
gmt psconvert "$PS" -Tf -A -F"$OUT_BASE"
'''
    try:
        result = subprocess.run(
            ["bash", "-c", commands],
            cwd=plot_dir,
            env=env,
            check=False,
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            detail = "\n".join(
                part for part in (result.stdout.strip(), result.stderr.strip()) if part
            )
            die(f"GMT LOS plotting failed: {detail}")
        generated_pdf = plot_dir / "GNSS_to_LOS.pdf"
        if not generated_pdf.is_file() or generated_pdf.stat().st_size == 0:
            die(f"GMT did not generate the expected PDF: {generated_pdf}")
        generated_pdf.replace(pdf_path)
    finally:
        shutil.rmtree(plot_dir, ignore_errors=True)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run 6.3: project GNSS east/north grids onto InSAR LOS",
        formatter_class=argparse.RawTextHelpFormatter,
        epilog=(
            "Check only:\n"
            "  ./run6.3_project_GNSS_to_LOS.py\n\n"
            "Formal ascending run (default track=350°, look=40°):\n"
            "  ./run6.3_project_GNSS_to_LOS.py 1 ascending\n\n"
            "Formal descending run (default track=190°, look=40°):\n"
            "  ./run6.3_project_GNSS_to_LOS.py 1 descending\n\n"
            "Override the default heading when a precise value is available:\n"
            "  ./run6.3_project_GNSS_to_LOS.py 1 descending --track 193 --look 40"
        ),
    )
    parser.add_argument("mode", nargs="?", choices=("1",), help="1 starts the formal calculation")
    parser.add_argument(
        "orbit",
        nargs="?",
        choices=("ascending", "descending"),
        help="orbit direction; required for a formal run",
    )
    parser.add_argument(
        "--track",
        type=float,
        default=None,
        help="override satellite heading clockwise from north",
    )
    parser.add_argument("--look", type=float, default=DEFAULT_LOOK, help="look/incidence angle from vertical (default: 40°)")
    parser.add_argument("--output-dir", default=DEFAULT_DIR, help=f"working/output directory (default: {DEFAULT_DIR})")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path.cwd().resolve()
    if not (root.name.startswith("T") and root.name[1:].isdigit()):
        die(f"run this script in a T-number track root (current: {root})")
    if args.mode == "1" and args.orbit is None:
        die(
            "formal mode requires an orbit direction: use '1 ascending' or "
            "'1 descending'"
        )
    orbit = args.orbit
    if orbit is None:
        lowered_parts = [part.lower() for part in root.parts]
        if "descending" in lowered_parts:
            orbit = "descending"
        elif "ascending" in lowered_parts:
            orbit = "ascending"
        else:
            orbit = "descending"
    track = args.track if args.track is not None else DEFAULT_TRACKS[orbit]
    if not np.isfinite(track):
        die("--track must be finite")
    if not np.isfinite(args.look) or not (0.0 < args.look < 90.0):
        die("--look must be between 0 and 90 degrees")

    out_dir = Path(args.output_dir)
    if not out_dir.is_absolute():
        out_dir = root / out_dir
    east_path = out_dir / "GNSS_E.grd"
    north_path = out_dir / "GNSS_N.grd"
    marker_62 = out_dir / "run6.2_complete"

    for path in (east_path, north_path, marker_62):
        if not path.is_file() or path.stat().st_size == 0:
            die(f"required Run 6.2 input is missing or empty: {path}")

    proj_e, proj_n = projection_coefficients(track, args.look)

    if args.mode is None:
        east_meta = read_grid_metadata(east_path)
        north_meta = read_grid_metadata(north_path)
        if not same_grid_geometry(east_meta, north_meta):
            die("GNSS_E.grd and GNSS_N.grd have different grid geometry")

        print("========================================")
        print("Run 6.3: project horizontal GNSS velocity to LOS")
        print("Run mode          : CHECK ONLY (metadata only)")
        print(f"Track root        : {root}")
        print(f"East grid         : {east_path}")
        print(f"North grid        : {north_path}")
        print(f"Grid size         : {east_meta['nx']} x {east_meta['ny']}")
        print(
            "Grid region       : "
            f"{east_meta['xmin']} / {east_meta['xmax']} / "
            f"{east_meta['ymin']} / {east_meta['ymax']}"
        )
        print(
            "Grid increment    : "
            f"{east_meta['xinc']} / {east_meta['yinc']}"
        )
        print(
            "Registration      : "
            f"{east_meta['registration']} (0=gridline, 1=pixel)"
        )
        print(
            "East header range : "
            f"{east_meta['zmin']:.6f} / {east_meta['zmax']:.6f} mm/yr"
        )
        print(
            "North header range: "
            f"{north_meta['zmin']:.6f} / {north_meta['zmax']:.6f} mm/yr"
        )
        print(f"Detected direction: {orbit}")
        print(f"Check track       : {track:g} degrees")
        print(f"Look angle        : {args.look:g} degrees")
        print("Plot color range  : -5 / 5 / 1 mm/yr (GMT jet)")
        print(f"East coefficient  : {proj_e:.8f}")
        print(f"North coefficient : {proj_n:.8f}")
        print("Formula           : LOS = east_coefficient * E + north_coefficient * N")
        print(f"Output directory  : {out_dir}")
        print("========================================")
        print("Run 6.3 command guide (processing NOT started)")
        print("")
        print("Choose the orbit direction for the formal run:")
        print("  Ascending : ./run6.3_project_GNSS_to_LOS.py 1 ascending")
        print("              default track=350 degrees, look=40 degrees")
        print("  Descending: ./run6.3_project_GNSS_to_LOS.py 1 descending")
        print("              default track=190 degrees, look=40 degrees")
        print("")
        print("For the current descending track, use:")
        print("  ./run6.3_project_GNSS_to_LOS.py 1 descending")
        print("")
        print("Override the heading/look angle when precise values are available:")
        print("  ./run6.3_project_GNSS_to_LOS.py 1 descending --track 193 --look 40")
        print("[CHECK ONLY] Pixel arrays were not loaded and no file was created or modified.")
        return 0

    east, dims_e, coords_e, attrs_e, var_attrs_e = read_grid(east_path)
    north, dims_n, coords_n, _, _ = read_grid(north_path)
    if dims_e != dims_n or east.shape != north.shape:
        die(f"east/north grid geometry differs: {dims_e} {east.shape} vs {dims_n} {north.shape}")
    for dim in dims_e:
        if not np.array_equal(coords_e[dim], coords_n[dim]):
            die(f"east/north coordinate differs along dimension {dim}")

    e_range = finite_range(east, "GNSS_E.grd")
    n_range = finite_range(north, "GNSS_N.grd")

    print("========================================")
    print("Run 6.3: project horizontal GNSS velocity to LOS")
    print("Run mode          : FORMAL")
    print(f"Track root        : {root}")
    print(f"East grid         : {east_path}")
    print(f"North grid        : {north_path}")
    print(f"Grid shape        : {east.shape}")
    print(f"East range        : {e_range[0]:.6f} / {e_range[1]:.6f} mm/yr")
    print(f"North range       : {n_range[0]:.6f} / {n_range[1]:.6f} mm/yr")
    print(f"Orbit direction   : {orbit}")
    print(f"Track azimuth     : {track:g} degrees")
    print(f"Look angle        : {args.look:g} degrees")
    print("Plot color range  : -5 / 5 / 1 mm/yr (GMT jet)")
    print(f"East coefficient  : {proj_e:.8f}")
    print(f"North coefficient : {proj_n:.8f}")
    print("Formula           : LOS = east_coefficient * E + north_coefficient * N")
    print(f"Output directory  : {out_dir}")
    print("========================================")

    valid = np.isfinite(east) & np.isfinite(north)
    los = np.full(east.shape, np.nan, dtype=np.float64)
    los[valid] = proj_e * east[valid] + proj_n * north[valid]
    los_range = finite_range(los, "projected LOS grid")
    print(f"[RESULT] LOS range: {los_range[0]:.6f} / {los_range[1]:.6f} mm/yr")

    tmp_grid = out_dir / f".run6.3_GNSS_to_LOS.{os.getpid()}.grd"
    tmp_pdf = out_dir / f".run6.3_GNSS_to_LOS.{os.getpid()}.pdf"
    final_grid = out_dir / "GNSS_to_LOS.grd"
    final_pdf = out_dir / "GNSS_to_LOS.pdf"
    try:
        write_grid(tmp_grid, los, dims_e, coords_e, attrs_e, var_attrs_e, track, args.look)
        plot_grid_with_gmt(tmp_grid, tmp_pdf, orbit, track, args.look)
        tmp_grid.replace(final_grid)
        tmp_pdf.replace(final_pdf)
    finally:
        tmp_grid.unlink(missing_ok=True)
        tmp_pdf.unlink(missing_ok=True)

    marker = out_dir / "run6.3_complete"
    marker.write_text(
        "Run 6.3 completed successfully\n"
        f"orbit={orbit}\n"
        f"track={track}\n"
        f"look={args.look}\n"
        f"east_coefficient={proj_e:.12g}\n"
        f"north_coefficient={proj_n:.12g}\n"
        f"grid={final_grid}\n"
        f"plot={final_pdf}\n"
        f"completed={dt.datetime.now().astimezone().isoformat(timespec='seconds')}\n",
        encoding="utf-8",
    )

    print("========================================")
    print("[DONE] Run 6.3 completed successfully.")
    print(f"LOS grid : {final_grid}")
    print(f"LOS plot : {final_pdf}")
    print(f"Marker   : {marker}")
    print("========================================")
    return 0


if __name__ == "__main__":
    sys.exit(main())
