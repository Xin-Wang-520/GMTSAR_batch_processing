#!/usr/bin/env python3
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 21, 2026

"""Independent Python/Cython reproduction of GMT surface's numerical solver.

This program does not invoke ``gmt surface``.  It reproduces the finite-
difference coefficients, Briggs off-node constraints, natural boundaries,
row-major SOR, planar detrending, RMS normalization, and multigrid sequence.
The current test requires an explicit working region so that it follows the
same internal domain selected by GMT for the reference result.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path
import subprocess
import sys
import time

import numpy as np


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import pyximport

pyximport.install(
    setup_args={"include_dirs": np.get_include()},
    language_level=3,
    build_dir=str(ROOT / ".pyxbld"),
    inplace=False,
)
import gmt_surface_exact_core as clone_core


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Reproduce GMT surface without calling gmt surface."
    )
    parser.add_argument("input", type=Path, help="Binary float64 x/y/z input")
    parser.add_argument("output", type=Path, help="Pixel-registered output grid")
    parser.add_argument(
        "--region", nargs=4, type=float, required=True, metavar=("W", "E", "S", "N")
    )
    parser.add_argument(
        "--work-region",
        nargs=4,
        type=float,
        required=True,
        metavar=("W", "E", "S", "N"),
        help="Expanded pixel region used internally by GMT",
    )
    parser.add_argument(
        "--increment", nargs=2, type=float, required=True, metavar=("DX", "DY")
    )
    parser.add_argument("--tension", type=float, default=0.1)
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--relaxation", type=float, default=1.4)
    return parser.parse_args()


def load_binary_xyz(path: Path) -> np.ndarray:
    raw = np.fromfile(path, dtype=np.float64)
    if raw.size % 3:
        raise ValueError(f"Invalid three-column float64 file: {path}")
    data = raw.reshape(-1, 3)
    # Keep the input doubles here.  GMT assigns the node index while reading
    # the double record, then stores xyz as float for sorting and solving.
    return data[np.all(np.isfinite(data), axis=1)]


def prime_factors(value: int) -> list[int]:
    factors: list[int] = []
    divisor = 2
    while divisor * divisor <= value:
        while value % divisor == 0:
            factors.append(divisor)
            value //= divisor
        divisor += 1
    if value > 1:
        factors.append(value)
    return factors


def select_nearest_per_node(
    data: np.ndarray,
    nx: int,
    ny: int,
    xlo: float,
    ylo: float,
    yhi: float,
    inc_x: float,
    inc_y: float,
    compare_xlo: float | None = None,
    compare_yhi: float | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    if compare_xlo is None:
        compare_xlo = xlo
    if compare_yhi is None:
        compare_yhi = yhi
    # Node indices are computed from the original float64 input values.
    index_x = data[:, 0].astype(np.float64, copy=False)
    index_y = data[:, 1].astype(np.float64, copy=False)
    cols = np.floor((index_x - xlo) / inc_x + 0.5).astype(np.int64)
    rows = ny - 1 - np.floor(
        (index_y - ylo) / inc_y + 0.5
    ).astype(np.int64)
    inside = (cols >= 0) & (cols < nx) & (rows >= 0) & (rows < ny)
    indices = np.flatnonzero(inside)
    rows = rows[inside]
    cols = cols[inside]
    # GMT 6.x retains the pre-pixel-shift domain in the qsort metadata.
    # Indices therefore use xlo/ylo/yhi, while the nearest-point comparison
    # uses compare_xlo/compare_yhi.  Reproducing this detail is necessary for
    # bit-level agreement with existing surface grids.
    node_x = compare_xlo + cols * inc_x
    node_y = compare_yhi - rows * inc_y
    # GMT's SURFACE_DATA structure stores xyz as gmt_grdfloat.  Use those
    # float32 coordinates for the nearest-point comparison after indexing.
    stored_x = data[indices, 0].astype(np.float32).astype(np.float64)
    stored_y = data[indices, 1].astype(np.float32).astype(np.float64)
    distance2 = (stored_x - node_x) ** 2 + (stored_y - node_y) ** 2
    flat = rows * nx + cols
    order = np.lexsort((distance2, flat))
    flat_sorted = flat[order]
    first = np.r_[True, flat_sorted[1:] != flat_sorted[:-1]]
    chosen = indices[order[first]]
    chosen_rows = rows[order[first]]
    chosen_cols = cols[order[first]]
    return chosen, chosen_rows, chosen_cols, flat_sorted[first]


def remove_plane_and_normalize(
    data: np.ndarray, xlo: float, ylo: float, dx: float, dy: float
) -> tuple[np.ndarray, tuple[float, float, float], float]:
    normalized = np.ascontiguousarray(data.copy(), dtype=np.float32)
    intercept, slope_x, slope_y, rms = clone_core.detrend_normalize(
        normalized, xlo, ylo, dx, dy
    )
    return normalized, (intercept, slope_x, slope_y), rms


def briggs_coefficients(xx: float, yy: float, z: float, tension: float) -> np.ndarray:
    alpha2 = 1.0
    loose = 1.0 - tension
    inv_sum1 = 1.0 / (1.0 + xx + yy)
    inv_delta = inv_sum1 / (xx + yy)
    xx2, yy2 = xx * xx, yy * yy
    b = np.empty(6, dtype=np.float32)
    b[0] = (xx2 + 2.0 * xx * yy + xx - yy2 - yy) * inv_delta
    b[1] = 2.0 * (yy - xx + 1.0) * inv_sum1
    b[2] = 2.0 * (xx - yy + 1.0) * inv_sum1
    b[3] = (-xx2 + 2.0 * xx * yy - xx + yy2 + yy) * inv_delta
    b4 = 4.0 * inv_delta
    # In GMT these are gmt_grdfloat expressions.  Keep the C evaluation
    # order instead of allowing Python's b4/z doubles to promote the sum.
    b4f = np.float32(b4)
    bsum = np.float32(b[0] + b[1])
    bsum = np.float32(bsum + b[2])
    bsum = np.float32(bsum + b[3])
    b[5] = np.float32(bsum + b4f)
    b[4] = np.float32(float(b4) * float(np.float32(z)))
    a0_const_1 = 2.0 * loose * 2.0
    a0_const_2 = 2.0 - tension + 2.0 * loose * alpha2
    b[5] = 1.0 / (a0_const_1 + a0_const_2 * float(b[5]))
    return b


def make_constraints(
    data: np.ndarray,
    nx: int,
    ny: int,
    xlo: float,
    ylo: float,
    yhi: float,
    inc_x: float,
    inc_y: float,
    stride: int,
    plane: tuple[float, float, float],
    rms: float,
    tension: float,
    grid: np.ndarray,
    compare_xlo: float,
    compare_yhi: float,
    status: np.ndarray | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    chosen, rows, cols, _ = select_nearest_per_node(
        data, nx, ny, xlo, ylo, yhi, inc_x, inc_y,
        compare_xlo, compare_yhi,
    )
    if status is None:
        status = np.zeros((ny, nx), dtype=np.uint8)
    briggs = np.zeros((ny, nx, 6), dtype=np.float32)
    _, slope_x, slope_y = plane
    clone_core.set_constraints(
        data,
        np.ascontiguousarray(chosen, dtype=np.int64),
        np.ascontiguousarray(rows, dtype=np.int64),
        np.ascontiguousarray(cols, dtype=np.int64),
        status,
        briggs,
        grid,
        xlo,
        yhi,
        inc_x,
        inc_y,
        stride,
        slope_x,
        slope_y,
        rms,
        tension,
    )
    return status, briggs


def fill_in_forecast_inplace(
    storage: np.ndarray,
    status_storage: np.ndarray,
    previous_nx: int,
    previous_ny: int,
    current_nx: int,
    current_ny: int,
    previous_stride: int,
    current_stride: int,
) -> None:
    """Reproduce GMT 6.5's in-place multigrid expansion exactly."""
    previous_mx = previous_nx + 4
    current_mx = current_nx + 4
    expand = previous_stride // current_stride

    def node(row: int, col: int, mx: int) -> int:
        return (row + 2) * mx + col + 2

    # Move the old active nodes backward so source values are not overwritten.
    for previous_row in range(previous_ny - 1, -1, -1):
        row = previous_row * expand
        for previous_col in range(previous_nx - 1, -1, -1):
            col = previous_col * expand
            storage[node(row, col, current_mx)] = storage[
                node(previous_row, previous_col, previous_mx)
            ]

    fractions = np.arange(expand, dtype=np.float64) / float(previous_stride)
    for previous_row in range(1, previous_ny):
        row = previous_row * expand
        for previous_col in range(previous_nx - 1):
            col = previous_col * expand
            i00 = node(row, col, current_mx)
            i01 = i00 - expand * current_mx
            i10 = i00 + expand
            i11 = i01 + expand
            c0 = float(storage[i00])
            sx = float(storage[i10]) - c0
            sy = float(storage[i01]) - c0
            sxy = float(np.float32(storage[i11] - storage[i10])) - sy
            first = 1
            for j in range(expand):
                base = c0 + sy * fractions[j]
                slope = sx + sxy * fractions[j]
                index_new = i00 - j * current_mx + first
                for i in range(first, expand):
                    storage[index_new] = np.float32(base + fractions[i] * slope)
                    status_storage[index_new] = 0
                    index_new += 1
                first = 0
            status_storage[i00] = 5

    # East edge.
    i00 = node(0, current_nx - 1, current_mx)
    for previous_row in range(1, previous_ny):
        i01 = i00
        i00 += expand * current_mx
        sy = float(np.float32(storage[i01] - storage[i00]))
        index_new = i00 - current_mx
        for j in range(1, expand):
            storage[index_new] = np.float32(float(storage[i00]) + fractions[j] * sy)
            status_storage[index_new] = 0
            index_new -= current_mx
        status_storage[i00] = 5

    # North edge.
    i10 = node(0, 0, current_mx)
    for previous_col in range(previous_nx - 1):
        i00 = i10
        i10 = i00 + expand
        sx = float(np.float32(storage[i10] - storage[i00]))
        index_new = i00 + 1
        for i in range(1, expand):
            storage[index_new] = np.float32(float(storage[i00]) + fractions[i] * sx)
            status_storage[index_new] = 0
            index_new += 1
        status_storage[i00] = 5
    status_storage[node(0, current_nx - 1, current_mx)] = 5


def expand_bilinear(
    previous: np.ndarray, factor: int, previous_stride: int
) -> np.ndarray:
    """Reproduce GMT's fill_in_forecast operation, including float32 writes."""
    old_ny, old_nx = previous.shape
    new_ny = (old_ny - 1) * factor + 1
    new_nx = (old_nx - 1) * factor + 1
    result = np.zeros((new_ny, new_nx), dtype=np.float32)
    result[::factor, ::factor] = previous
    fractions = np.arange(factor, dtype=np.float64) / float(previous_stride)

    for old_row in range(1, old_ny):
        lower = old_row * factor
        upper = (old_row - 1) * factor
        for old_col in range(old_nx - 1):
            left = old_col * factor
            c0 = float(previous[old_row, old_col])
            sx = float(previous[old_row, old_col + 1]) - c0
            sy = float(previous[old_row - 1, old_col]) - c0
            sxy = (
                float(previous[old_row - 1, old_col + 1])
                - float(previous[old_row, old_col + 1]) - sy
            )
            first = 1
            for j in range(factor):
                fy = fractions[j]
                base = c0 + sy * fy
                slope = sx + sxy * fy
                for i in range(first, factor):
                    result[lower - j, left + i] = np.float32(
                        base + fractions[i] * slope
                    )
                first = 0

    # Eastern boundary, interpolated upward from each lower coarse node.
    east = new_nx - 1
    for old_row in range(1, old_ny):
        lower = old_row * factor
        lower_value = float(previous[old_row, -1])
        sy = float(previous[old_row - 1, -1]) - lower_value
        for j in range(1, factor):
            result[lower - j, east] = np.float32(
                lower_value + fractions[j] * sy
            )

    # Northern boundary, interpolated rightward from each left coarse node.
    for old_col in range(old_nx - 1):
        left = old_col * factor
        left_value = float(previous[0, old_col])
        sx = float(previous[0, old_col + 1]) - left_value
        for i in range(1, factor):
            result[0, left + i] = np.float32(
                left_value + fractions[i] * sx
            )
    return result


def write_pixel_grid(
    grid: np.ndarray,
    output: Path,
    region: tuple[float, float, float, float],
    increment: tuple[float, float],
) -> None:
    raw = output.with_suffix(output.suffix + ".tmp.bin")
    grid.astype(np.float32).tofile(raw)
    try:
        subprocess.run(
            [
                "gmt", "xyz2grd", str(raw), "-ZTLf",
                f"-R{region[0]}/{region[1]}/{region[2]}/{region[3]}",
                f"-I{increment[0]}/{increment[1]}", "-r", f"-G{output}",
            ],
            check=True,
        )
    finally:
        raw.unlink(missing_ok=True)


def main() -> None:
    args = parse_args()
    started = time.perf_counter()
    region = tuple(args.region)
    work_region = tuple(args.work_region)
    dx, dy = args.increment

    # GMT represents a pixel grid internally as a node grid shifted by half a cell.
    xlo = work_region[0] + 0.5 * dx
    xhi = work_region[1] + 0.5 * dx
    ylo = work_region[2] + 0.5 * dy
    yhi = work_region[3] + 0.5 * dy
    final_nx = int(round((xhi - xlo) / dx)) + 1
    final_ny = int(round((yhi - ylo) / dy)) + 1

    original = load_binary_xyz(args.input)
    chosen, _, _, _ = select_nearest_per_node(
        original, final_nx, final_ny, xlo, ylo, yhi, dx, dy,
        work_region[0], work_region[3],
    )
    data = original[chosen].astype(np.float32)
    data, plane, rms = remove_plane_and_normalize(data, xlo, ylo, dx, dy)
    convergence = 1.0e-4 * rms

    stride = math.gcd(final_nx - 1, final_ny - 1)
    factors = prime_factors(stride)
    while (final_nx - 1) // stride + 1 < 4 or (final_ny - 1) // stride + 1 < 4:
        stride //= factors.pop()

    # GMT keeps all multigrid levels in the same final-size allocation.  This
    # is numerically observable because its status reset uses the final grid
    # layout while active levels use a smaller row stride.  Preserve that
    # layout for agreement with GMT 6.5.0.
    full_mx = final_nx + 4
    full_storage = np.zeros((final_ny + 4) * full_mx, dtype=np.float32)
    full_status = np.zeros_like(full_storage, dtype=np.uint8)
    previous_interior: np.ndarray | None = None
    previous_nx = previous_ny = 0
    previous_stride = stride
    total_iterations = 0
    level = 0
    while True:
        level += 1
        nx = (final_nx - 1) // stride + 1
        ny = (final_ny - 1) // stride + 1
        inc_x, inc_y = dx * stride, dy * stride
        active_size = (ny + 4) * (nx + 4)
        grid = full_storage[:active_size].reshape(ny + 4, nx + 4)
        active_status_padded = full_status[:active_size].reshape(ny + 4, nx + 4)
        node_status = active_status_padded[2:-2, 2:-2]
        if previous_interior is not None:
            factor = previous_stride // stride
            fill_in_forecast_inplace(
                full_storage, full_status,
                previous_nx, previous_ny, nx, ny,
                previous_stride, stride,
            )
            empty_briggs = np.zeros((ny, nx, 6), dtype=np.float32)
            count, change = clone_core.iterate_c_exact(
                grid, active_status_padded, empty_briggs, stride, rms, convergence,
                args.iterations, args.tension, args.tension, 1.0, args.relaxation,
            )
            total_iterations += count
            print(
                f"level={level} stride={stride} mode=I iterations={count} "
                f"max_change={change:.9f}"
            )

        # Match GMT 6.5's reset loop: it addresses the status allocation with
        # the final padded row width, even while a coarser active grid is used.
        for reset_row in range(final_ny):
            start = (reset_row + 2) * full_mx + 2
            full_status[start : start + final_nx] = 0

        status, briggs = make_constraints(
            data, nx, ny, xlo, ylo, yhi, inc_x, inc_y, stride,
            plane, rms, args.tension, grid, work_region[0], work_region[3],
            node_status,
        )
        count, change = clone_core.iterate_c_exact(
            grid, active_status_padded, briggs, stride, rms, convergence,
            args.iterations, args.tension, args.tension, 1.0, args.relaxation,
        )
        total_iterations += count
        print(
            f"level={level} stride={stride} mode=D iterations={count} "
            f"max_change={change:.9f}"
        )
        previous_interior = grid[2:-2, 2:-2].copy()
        previous_nx, previous_ny = nx, ny
        if stride == 1:
            break
        previous_stride = stride
        stride //= factors.pop()

    intercept, slope_x, slope_y = plane
    rows = np.arange(final_ny, dtype=np.float64)
    cols = np.arange(final_nx, dtype=np.float64)
    plane_grid = (
        intercept + slope_x * cols[np.newaxis, :]
        + slope_y * (final_ny - 1 - rows[:, np.newaxis])
    )
    restored = (
        previous_interior.astype(np.float64) * rms + plane_grid
    ).astype(np.float32)

    out_nx = int(round((region[1] - region[0]) / dx))
    out_ny = int(round((region[3] - region[2]) / dy))
    left = int(round((region[0] - xlo) / dx))
    # GMT's pixel-registration write step turns the northernmost internal
    # node into padding; skip that additional row when shrinking the adjusted
    # work region back to the requested output region.
    top = int(round((yhi - region[3]) / dy)) + 1
    output_grid = restored[top : top + out_ny, left : left + out_nx]
    if output_grid.shape != (out_ny, out_nx):
        raise RuntimeError(
            f"Crop failed: got {output_grid.shape}, expected {(out_ny, out_nx)}"
        )
    write_pixel_grid(output_grid, args.output, region, (dx, dy))

    elapsed = time.perf_counter() - started
    print(f"input_points={original.shape[0]}")
    print(f"usable_points={data.shape[0]}")
    print(f"work_grid={final_ny}x{final_nx}")
    print(f"output_grid={out_ny}x{out_nx}")
    print(f"plane={intercept:.12g},{slope_x:.12g},{slope_y:.12g}")
    print(f"z_rms={rms:.12g}")
    print(f"total_iterations={total_iterations}")
    print(f"total_seconds={elapsed:.6f}")
    print(f"output={args.output}")


if __name__ == "__main__":
    main()
