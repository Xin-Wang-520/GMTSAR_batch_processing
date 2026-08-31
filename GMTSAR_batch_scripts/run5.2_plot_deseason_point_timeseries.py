#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Run 5.2: compare original, seasonal, and deseasoned displacement time series.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 22, 2026

import argparse
import datetime as dt
import re
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from netCDF4 import Dataset


TAG_RE = re.compile(r"disp_(\d{7})\.grd$")
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")

# Original T70 radar-coordinate check points.
DEFAULT_POINTS = [
    ("W", 10000.0, 16000.0),
    ("E", 58000.0, 16000.0),
    ("S", 34000.0, 5000.0),
    ("N", 34000.0, 28000.0),
    ("C", 34000.0, 16000.0),
]


def tag_to_datetime(tag):
    year = int(tag[:4])
    doy = int(tag[4:])
    date = dt.datetime(year, 1, 1) + dt.timedelta(days=doy)
    if doy < 0 or date.year != year:
        raise ValueError(f"无效的 GMTSAR 年内日编号: {tag}")
    # GMTSAR displacement names use zero-based day of year: 000 = January 1.
    return date


def collect_files(folder):
    result = {}
    for path in sorted(folder.glob("disp_*.grd")):
        match = TAG_RE.fullmatch(path.name)
        if match:
            tag = match.group(1)
            if tag in result:
                raise RuntimeError(f"重复时间标签：{tag}")
            result[tag] = path.resolve()
    return result


def find_grid_var(dataset):
    candidates = [name for name, var in dataset.variables.items() if var.ndim == 2]
    if not candidates:
        raise RuntimeError("No 2D grid variable found")
    return "z" if "z" in candidates else candidates[0]


def read_geometry(path):
    with Dataset(path, "r") as dataset:
        zname = find_grid_var(dataset)
        zvar = dataset.variables[zname]
        if len(zvar.dimensions) != 2:
            raise RuntimeError(f"二维变量结构异常：{path}")
        yname, xname = zvar.dimensions
        if xname not in dataset.variables or yname not in dataset.variables:
            raise RuntimeError(f"找不到坐标变量 {xname}/{yname}：{path}")
        x = np.asarray(dataset.variables[xname][:], dtype=np.float64)
        y = np.asarray(dataset.variables[yname][:], dtype=np.float64)
        shape = zvar.shape
    return zname, yname, xname, x, y, shape


def nearest_index(array, value):
    return int(np.nanargmin(np.abs(array - value)))


def scalar_to_float(value):
    if np.ma.isMaskedArray(value):
        if np.ma.is_masked(value):
            return np.nan
        return float(value.data)
    return float(value)


def validate_point_names(points):
    seen = set()
    for name, _, _ in points:
        if not SAFE_NAME_RE.fullmatch(name):
            raise ValueError(f"点名只能包含字母、数字、点、下划线或连字符：{name}")
        if name in seen:
            raise ValueError(f"点名重复：{name}")
        seen.add(name)


def main():
    parser = argparse.ArgumentParser(
        description="Run 5.2：绘制原始、季节项和去季节位移三行时间序列"
    )
    parser.add_argument("mode", nargs="?", choices=["1"], help="省略为检查；1 为正式绘图")
    parser.add_argument(
        "--point", action="append", nargs=3, metavar=("NAME", "X", "Y"),
        help="自定义雷达坐标点，可重复使用；一旦提供则替代全部默认点"
    )
    parser.add_argument("--no-txt", action="store_true", help="不输出逐点时间序列文本")
    parser.add_argument("--dpi", type=int, default=200, help="PNG分辨率（默认：200）")
    args = parser.parse_args()

    if args.dpi < 72:
        parser.error("--dpi 不能小于72")

    if args.point:
        points = []
        for name, x_text, y_text in args.point:
            try:
                points.append((name, float(x_text), float(y_text)))
            except ValueError:
                parser.error(f"点 {name} 的 X/Y 必须是数值")
    else:
        points = list(DEFAULT_POINTS)
    try:
        validate_point_names(points)
    except ValueError as exc:
        parser.error(str(exc))

    root = Path.cwd().resolve()
    if not re.fullmatch(r"T\d+", root.name):
        raise SystemExit(f"[ERROR] 请在 T数字 轨道根目录运行（当前：{root}）")

    sbas_dir = root / "sbas_demcorr_pin"
    deseason_dir = sbas_dir / "disp_deseason"
    output_dir = deseason_dir / "run5.2_point_timeseries"
    marker = deseason_dir / "run5.1_complete"

    if not sbas_dir.is_dir():
        raise SystemExit(f"[ERROR] 找不到：{sbas_dir}")
    if not deseason_dir.is_dir():
        raise SystemExit(f"[ERROR] 找不到：{deseason_dir}；请先完成 Run 5.1")
    if not marker.is_file() or marker.stat().st_size == 0:
        raise SystemExit(f"[ERROR] 找不到有效完成标记：{marker}")

    original = collect_files(sbas_dir)
    deseasoned = collect_files(deseason_dir)
    if not original:
        raise SystemExit("[ERROR] 没有原始 disp_YYYYDDD.grd")
    if not deseasoned:
        raise SystemExit("[ERROR] 没有去季节 disp_YYYYDDD.grd")

    original_tags = set(original)
    deseasoned_tags = set(deseasoned)
    missing_deseasoned = sorted(original_tags - deseasoned_tags)
    extra_deseasoned = sorted(deseasoned_tags - original_tags)
    if missing_deseasoned or extra_deseasoned:
        raise SystemExit(
            "[ERROR] 原始与去季节历元不一致："
            f"missing={len(missing_deseasoned)}, extra={len(extra_deseasoned)}"
        )
    tags = sorted(original_tags)

    zname, yname, xname, x, y, shape = read_geometry(original[tags[0]])
    des_zname, des_yname, des_xname, des_x, des_y, des_shape = read_geometry(
        deseasoned[tags[0]]
    )
    if (des_zname != zname or des_yname != yname or des_xname != xname
            or des_shape != shape or not np.array_equal(des_x, x)
            or not np.array_equal(des_y, y)):
        raise SystemExit("[ERROR] 原始与去季节网格结构或坐标不一致")

    selected = []
    for name, requested_x, requested_y in points:
        ix = nearest_index(x, requested_x)
        iy = nearest_index(y, requested_y)
        selected.append((name, requested_x, requested_y, ix, iy, x[ix], y[iy]))

    existing_png = len(list(output_dir.glob("*_3rows.png"))) if output_dir.is_dir() else 0
    print("========================================")
    print("Run 5.2: plot seasonal-correction point time series")
    print(f"Mode              : {'FORMAL' if args.mode == '1' else 'CHECK ONLY'}")
    print(f"Track root        : {root}")
    print(f"Original grids    : {len(original)}")
    print(f"Deseasoned grids  : {len(deseasoned)}")
    print(f"First epoch       : {tags[0]}")
    print(f"Last epoch        : {tags[-1]}")
    print(f"Grid variable     : {zname}")
    print(f"Grid shape        : {shape}")
    print(f"X range           : {np.nanmin(x)} / {np.nanmax(x)} ({len(x)} nodes)")
    print(f"Y range           : {np.nanmin(y)} / {np.nanmax(y)} ({len(y)} nodes)")
    print(f"Points            : {len(selected)}")
    for name, rx, ry, ix, iy, actual_x, actual_y in selected:
        print(
            f"  {name}: requested=({rx:g}, {ry:g}), "
            f"actual=({actual_x:g}, {actual_y:g}), index=({ix}, {iy})"
        )
    print(f"Save TXT          : {'no' if args.no_txt else 'yes'}")
    print(f"PNG DPI           : {args.dpi}")
    print(f"Output directory  : {output_dir}")
    print(f"Existing PNG      : {existing_png}")
    print("========================================")

    if args.mode is None:
        print("[CHECK ONLY] No plot, text or directory was created.")
        print("[NEXT] Plot the default W/E/S/N/C points:")
        print("  ./run5.2_plot_deseason_point_timeseries.py 1")
        print("[OPTION] Plot custom radar-coordinate points:")
        print(
            "  ./run5.2_plot_deseason_point_timeseries.py 1 "
            "--point P1 34000 16000 --point P2 40000 12000"
        )
        return

    output_dir.mkdir(parents=True, exist_ok=True)
    for old in output_dir.glob("*_3rows.png"):
        old.unlink()
    for old in output_dir.glob("*_timeseries.txt"):
        old.unlink()
    completion = output_dir / "run5.2_complete"
    completion.unlink(missing_ok=True)

    npoints = len(selected)
    nepochs = len(tags)
    values_original = np.full((npoints, nepochs), np.nan, dtype=np.float64)
    values_deseasoned = np.full((npoints, nepochs), np.nan, dtype=np.float64)

    for epoch_index, tag in enumerate(tags):
        with Dataset(original[tag], "r") as dataset:
            variable = dataset.variables[zname]
            for point_index, item in enumerate(selected):
                values_original[point_index, epoch_index] = scalar_to_float(
                    variable[item[4], item[3]]
                )
        with Dataset(deseasoned[tag], "r") as dataset:
            variable = dataset.variables[zname]
            for point_index, item in enumerate(selected):
                values_deseasoned[point_index, epoch_index] = scalar_to_float(
                    variable[item[4], item[3]]
                )

    times = [tag_to_datetime(tag) for tag in tags]
    for point_index, item in enumerate(selected):
        name, _, _, _, _, actual_x, actual_y = item
        original_series = values_original[point_index]
        deseasoned_series = values_deseasoned[point_index]
        seasonal_series = original_series - deseasoned_series

        if not args.no_txt:
            txt_path = output_dir / f"{name}_timeseries.txt"
            with txt_path.open("w") as stream:
                stream.write("# name date tag x y orig_mm seasonal_mm deseasoned_mm\n")
                for date, tag, orig, seasonal, deseasoned_value in zip(
                    times, tags, original_series, seasonal_series, deseasoned_series
                ):
                    stream.write(
                        f"{name} {date:%Y-%m-%d} {tag} "
                        f"{actual_x:.3f} {actual_y:.3f} "
                        f"{orig:.6f} {seasonal:.6f} {deseasoned_value:.6f}\n"
                    )

        figure, axes = plt.subplots(3, 1, figsize=(10, 9), sharex=True)
        axes[0].plot(times, original_series, "o-", ms=3, lw=1)
        axes[0].set_ylabel("mm")
        axes[0].set_title(f"{name} - Original (x={actual_x:.1f}, y={actual_y:.1f})")
        axes[0].grid(True, alpha=0.3)

        axes[1].plot(times, seasonal_series, "o-", ms=3, lw=1)
        axes[1].set_ylabel("mm")
        axes[1].set_title("Seasonal component")
        axes[1].grid(True, alpha=0.3)

        axes[2].plot(times, deseasoned_series, "o-", ms=3, lw=1)
        axes[2].set_ylabel("mm")
        axes[2].set_title("Deseasoned")
        axes[2].set_xlabel("Time")
        axes[2].grid(True, alpha=0.3)

        figure.autofmt_xdate()
        figure.tight_layout()
        figure.savefig(output_dir / f"{name}_3rows.png", dpi=args.dpi)
        plt.close(figure)

    png_count = len(list(output_dir.glob("*_3rows.png")))
    txt_count = len(list(output_dir.glob("*_timeseries.txt")))
    if png_count != npoints:
        raise RuntimeError(f"PNG数量错误：{png_count}/{npoints}")
    if not args.no_txt and txt_count != npoints:
        raise RuntimeError(f"TXT数量错误：{txt_count}/{npoints}")

    completion.write_text(
        f"completed={dt.datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %z')}\n"
        f"track={root.name}\n"
        f"epochs={nepochs}\n"
        f"points={npoints}\n"
        f"png_files={png_count}\n"
        f"txt_files={txt_count}\n"
    )

    print("========================================")
    print("[DONE] Run 5.2 point time-series plots completed")
    print(f"PNG files : {png_count}")
    print(f"TXT files : {txt_count}")
    print(f"Output    : {output_dir}")
    print("========================================")


if __name__ == "__main__":
    main()
