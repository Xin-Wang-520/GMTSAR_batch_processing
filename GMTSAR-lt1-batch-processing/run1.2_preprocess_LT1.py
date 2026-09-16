#!/usr/bin/env python3
"""Prepare LT-1 SLC products and precise GMTSAR LED files.

Run this program from an Ascending/ or Descending/ directory containing data/.
No arguments performs a read-only preview. Positional mode ``1`` performs work.
"""

from __future__ import annotations

import argparse
import bisect
import concurrent.futures
import datetime as dt
import fcntl
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


MARKER = ".run1.2.3_precise_orbit_complete.json"
# Precise GPS orbits use local two-point Hermite interpolation.  Metadata/coarse
# LEDs keep the MATLAB-style high-order Hermite + spline repair below.
ORBIT_REPAIR_METHOD = "precise_adjacent_hermite_v3"
AUX_ARCHIVE_DIRNAME = "archive_run1.2.3"
SAMPLE_ARCHIVE_DIRNAME = "archive_run1.2.4"
AUXILIARY_SUFFIXES = (
    ".LED.metadata",
    ".PRM.make_slc",
    ".make_slc.log",
    ".calc_dop_orb.log",
    MARKER,
)
PRODUCT_RE = re.compile(r"^(LT1[AB])_.*_(\d{8})_SLC_[^_]+_S2A_.*$")
SCALE_RE = re.compile(r"closer\s+to\s+([-+0-9.eE]+)", re.IGNORECASE)


@dataclass(frozen=True)
class Scene:
    stem: str
    satellite: str
    date: str
    directory: Path
    metadata: Path
    raster: Path
    orbit: Path | None

    @property
    def output_stem(self) -> str:
        """Short GMTSAR name requested for PRM/SLC/LED and data.list."""
        return f"LT1_{self.date}"


@dataclass(frozen=True)
class OrbitPoint:
    time: dt.datetime
    position: tuple[float, float, float]
    velocity: tuple[float, float, float]


def die(message: str) -> "None":
    raise RuntimeError(message)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="""LT-1 Run 1.2：生成 raw 输入、SLC/PRM 与精密轨道 LED。

目录结构：
  Ascending/                         # 或 Descending/
  ├── run1.2_preprocess_LT1.py
  ├── data/
  │   ├── orbit/                 # 精密轨道 txt文件
  │   └── LT1A_MONO_.../         # Run 1.1 解压产品
  └── raw/                            # 本脚本生成

运行（--master 必填）：
  ./run1.2_preprocess_LT1.py --master 20250716             # 只读预览
  ./run1.2_preprocess_LT1.py 1 --master 20250716           # 正式处理
  ./run1.2_preprocess_LT1.py 1 --master 20250716 --jobs 5  # 指定并行数

默认不运行 samp_slc.csh。需要统一 PRF/距离采样率时，先预览后显式加：
  ./run1.2_preprocess_LT1.py 1 --master 20250716 --common-sampling

分步入口：
  ./run1.2.1_prepare_raw_LT1.sh [1] --master YYYYMMDD
  ./run1.2.2_make_slc_LT1.sh [1] --master YYYYMMDD
  ./run1.2.3_apply_precise_orbit_LT1.sh [1] --master YYYYMMDD
  ./run1.2.4_common_sampling_LT1.sh [1] --master YYYYMMDD
""",
    )
    parser.add_argument("mode", nargs="?", choices=["1"], help="1=正式执行；不填=预览")
    parser.add_argument("--jobs", type=int, default=5, help="独立景处理并行数（默认 5）")
    parser.add_argument("--slc-factor", type=float, default=10.0, help="初始 SLC_factor（默认 10）")
    parser.add_argument(
        "--master",
        required=True,
        help="必填：用户指定的主影像日期 YYYYMMDD 或完整产品名",
    )
    parser.add_argument(
        "--common-sampling",
        action="store_true",
        help="对全部 SLC 运行 samp_slc.csh，统一到最大 PRF 和最大距离采样率",
    )
    parser.add_argument(
        "--allow-missing-orbit",
        action="store_true",
        help="兼容旧命令：允许缺少精密轨道的景保留 meta.xml 内置轨道",
    )
    parser.add_argument(
        "--require-precise-orbit",
        action="store_true",
        help="发现精密轨道缺失时停止（默认自动使用粗轨道 LED）",
    )
    parser.add_argument("--force", action="store_true", help="备份后重新生成已有的 raw 产品")
    parser.add_argument(
        "--step",
        choices=["all", "prepare", "slc", "orbit", "sample"],
        default="all",
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs 必须是正整数")
    if not math.isfinite(args.slc_factor) or args.slc_factor <= 0:
        parser.error("--slc-factor 必须是大于 0 的有限数")
    return args


def orbit_looks_like_gps(path: Path, satellite: str, date: str) -> bool:
    if not path.name.startswith(satellite) or date not in path.name:
        return False
    # LT-1 精密轨道有两种实际格式：
    #   *.scie.gps.txt          13 列
    #   *_GpsData_GAS_C_*.txt  5 行 # 头 + 18 列
    # 扫描第一条有效数据，不把注释头误判为数据。
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for raw_line in stream:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) not in {13, 18}:
                return False
            try:
                values = [float(value) for value in fields]
            except ValueError:
                return False
            row_date = f"{int(values[0]):04d}{int(values[1]):02d}{int(values[2]):02d}"
            return row_date == date
    return False


def select_orbit(orbit_dir: Path, satellite: str, date: str) -> Path | None:
    matches = [
        path
        for path in sorted(orbit_dir.glob(f"{satellite}*.txt"))
        if orbit_looks_like_gps(path, satellite, date)
    ]
    if not matches:
        return None
    exact = [path for path in matches if path.name.endswith(".scie.gps.txt")]
    chosen = exact if exact else matches
    if len(chosen) != 1:
        names = ", ".join(path.name for path in chosen)
        die(f"{satellite} {date} 匹配到多个精密轨道：{names}")
    return chosen[0]


def discover_scenes(
    data_dir: Path,
    orbit_dir: Path,
    match_precise_orbits: bool,
) -> list[Scene]:
    scenes: list[Scene] = []
    for directory in sorted(data_dir.glob("LT1*")):
        if not directory.is_dir():
            continue
        match = PRODUCT_RE.match(directory.name)
        if not match:
            continue
        satellite, date = match.groups()
        metadata = directory / f"{directory.name}.meta.xml"
        raster = directory / f"{directory.name}.tiff"
        if not metadata.is_file() or metadata.stat().st_size == 0:
            die(f"缺少元数据：{metadata}")
        if not raster.is_file() or raster.stat().st_size == 0:
            die(f"缺少 SLC TIFF：{raster}")
        scenes.append(
            Scene(
                stem=directory.name,
                satellite=satellite,
                date=date,
                directory=directory,
                metadata=metadata,
                raster=raster,
                orbit=(
                    select_orbit(orbit_dir, satellite, date)
                    if match_precise_orbits
                    else None
                ),
            )
        )
    if not scenes:
        die(f"{data_dir} 中没有发现完整的 LT-1 解压产品")
    scenes = sorted(scenes, key=lambda item: (item.date, item.satellite, item.stem))
    names: dict[str, list[str]] = {}
    for scene in scenes:
        names.setdefault(scene.output_stem, []).append(scene.stem)
    duplicates = {name: stems for name, stems in names.items() if len(stems) > 1}
    if duplicates:
        details = "; ".join(f"{name}: {', '.join(stems)}" for name, stems in duplicates.items())
        die(f"输出名 LT1_YYYYMMDD 发生冲突，同日存在多景数据：{details}")
    return scenes


def raw_outputs(raw_dir: Path, stem: str) -> tuple[Path, Path, Path]:
    return raw_dir / f"{stem}.PRM", raw_dir / f"{stem}.SLC", raw_dir / f"{stem}.LED"


def auxiliary_path(raw_dir: Path, stem: str, suffix: str) -> Path:
    """Locate a backup/log/marker in raw or its post-processing archive."""
    direct = raw_dir / f"{stem}{suffix}"
    archived = raw_dir / AUX_ARCHIVE_DIRNAME / f"{stem}{suffix}"
    return direct if direct.exists() else archived


def select_master(scenes: list[Scene], requested: str | None) -> Scene:
    if requested is None:
        die("必须使用 --master 指定主影像")
    matches = [scene for scene in scenes if scene.stem == requested or scene.date == requested]
    if not matches:
        die(f"找不到指定主影像：{requested}")
    if len(matches) > 1:
        names = ", ".join(scene.stem for scene in matches)
        die(f"主影像条件 {requested} 匹配多景，请使用完整产品名：{names}")
    return matches[0]


def scene_is_complete(raw_dir: Path, scene: Scene) -> bool:
    prm, slc, led = raw_outputs(raw_dir, scene.output_stem)
    marker = auxiliary_path(raw_dir, scene.output_stem, MARKER)
    if not all(path.is_file() and path.stat().st_size > 0 for path in (prm, slc, led, marker)):
        return False
    # If a precise orbit is added later, do not keep silently reusing an older
    # metadata-orbit result. Likewise, fall back to metadata if a precise file
    # is removed between runs.
    try:
        marker_data = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    expected = "precise" if scene.orbit is not None else "metadata_repaired"
    if marker_data.get("orbit_source") != expected:
        return False
    return marker_data.get("orbit_repair_method") == ORBIT_REPAIR_METHOD


def inputs_are_ready(raw_dir: Path, scene: Scene) -> bool:
    metadata = raw_dir / f"{scene.stem}.meta.xml"
    tiff = raw_dir / f"{scene.stem}.tiff"
    return (
        metadata.is_symlink()
        and metadata.exists()
        and tiff.is_symlink()
        and tiff.exists()
    )


def slc_is_ready(raw_dir: Path, scene: Scene) -> bool:
    return all(
        path.is_file() and path.stat().st_size > 0
        for path in raw_outputs(raw_dir, scene.output_stem)
    )


def ensure_link(link: Path, target: Path) -> None:
    relative = os.path.relpath(target, link.parent)
    if link.is_symlink() and os.readlink(link) == relative:
        return
    if link.exists() or link.is_symlink():
        die(f"不会覆盖已有 raw 输入：{link}")
    temp = link.with_name(f".{link.name}.tmp.{os.getpid()}")
    temp.symlink_to(relative)
    temp.replace(link)


def backup_existing(raw_dir: Path, scene: Scene) -> None:
    stamp = dt.datetime.now().strftime("%Y%m%dT%H%M%S")
    backup_dir = raw_dir / "run1.2_backup" / f"{scene.output_stem}.{stamp}"
    candidates = [
        raw_dir / f"{scene.output_stem}{suffix}"
        for suffix in (
            ".PRM",
            ".SLC",
            ".LED",
            ".LED.metadata",
            ".make_slc.log",
            ".calc_dop_orb.log",
            ".PRM.make_slc",
            MARKER,
        )
    ]
    existing = [path for path in candidates if path.exists() or path.is_symlink()]
    if not existing:
        return
    backup_dir.mkdir(parents=True, exist_ok=False)
    for path in existing:
        shutil.move(str(path), backup_dir / path.name)


def run_make_slc(raw_dir: Path, scene: Scene, initial_factor: float) -> float:
    log_path = raw_dir / f"{scene.output_stem}.make_slc.log"
    factor = initial_factor
    for attempt in range(2):
        command = [
            "make_slc_lt1",
            f"{scene.stem}.meta.xml",
            f"{scene.stem}.tiff",
            scene.output_stem,
            f"{factor:.12g}",
        ]
        process = subprocess.Popen(
            command,
            cwd=raw_dir,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
        )
        suggested: float | None = None
        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"$ {' '.join(command)}\n")
            log.flush()
            if process.stdout is None:
                process.terminate()
                die(f"无法读取 make_slc_lt1 输出：{scene.output_stem}")
            for line in process.stdout:
                log.write(line)
                log.flush()
                if attempt != 0:
                    continue
                recommendation = SCALE_RE.search(line)
                if recommendation is None:
                    continue
                candidate = float(recommendation.group(1))
                if (
                    math.isfinite(candidate)
                    and candidate > 0
                    and not math.isclose(candidate, factor, rel_tol=0.01)
                ):
                    suggested = candidate
                    if process.poll() is None:
                        process.terminate()
                    break

        if suggested is not None:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            if process.stdout is not None:
                process.stdout.close()
            message = (
                f"[AUTO-RETRY] {scene.output_stem}: stopped first pass; "
                f"SLC_factor {factor:.12g} -> {suggested:.12g}"
            )
            print(message, flush=True)
            with log_path.open("a", encoding="utf-8") as log:
                log.write(f"{message}\n")
            factor = suggested
            continue

        returncode = process.wait()
        if process.stdout is not None:
            process.stdout.close()
        if returncode != 0:
            die(f"make_slc_lt1 失败：{scene.output_stem}，见 {log_path}")
        break
    prm, slc, led = raw_outputs(raw_dir, scene.output_stem)
    for path in (prm, slc, led):
        if not path.is_file() or path.stat().st_size == 0:
            die(f"make_slc_lt1 未生成完整文件：{path}")
    return factor


def parse_gps_orbit(path: Path) -> list[OrbitPoint]:
    points: list[OrbitPoint] = []
    column_count: int | None = None
    with path.open("r", encoding="utf-8", errors="strict") as stream:
        for number, raw_line in enumerate(stream, 1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) not in {13, 18}:
                die(f"{path}:{number} 应为 13 或 18 列，实际为 {len(fields)} 列")
            if column_count is None:
                column_count = len(fields)
            elif len(fields) != column_count:
                die(
                    f"{path}:{number} 轨道列数不一致："
                    f"前面为 {column_count} 列，本行为 {len(fields)} 列"
                )
            try:
                year, month, day, hour, minute = (int(fields[index]) for index in range(5))
                second = float(fields[5])
                if column_count == 13:
                    # scie.gps: 第7列是标志，第8–13列是位置/速度。
                    position = tuple(float(value) for value in fields[7:10])
                    velocity = tuple(float(value) for value in fields[10:13])
                else:
                    # GpsData_GAS_C: 第7–12列为 FIXED/ECEF 位置/速度，
                    # 第13–18列为 INERTIAL。GMTSAR LED 需要地球固连坐标。
                    position = tuple(float(value) for value in fields[6:9])
                    velocity = tuple(float(value) for value in fields[9:12])
                whole_second = int(math.floor(second))
                microsecond = int(round((second - whole_second) * 1_000_000))
                if microsecond == 1_000_000:
                    whole_second += 1
                    microsecond = 0
                timestamp = dt.datetime(
                    year, month, day, hour, minute, whole_second, microsecond, tzinfo=dt.timezone.utc
                )
            except (ValueError, OverflowError) as error:
                die(f"{path}:{number} 无法解析：{error}")
            points.append(OrbitPoint(timestamp, position, velocity))
    if len(points) < 2:
        die(f"精密轨道点少于2个：{path}")
    points.sort(key=lambda point: point.time)
    for previous, current in zip(points, points[1:]):
        if current.time <= previous.time:
            die(f"精密轨道时间重复或倒序：{path}")
    return points


def parse_led_orbit(path: Path) -> list[OrbitPoint]:
    """Read a GMTSAR LED and return its state vectors as UTC orbit points."""
    rows = [line.split() for line in path.read_text(encoding="ascii", errors="strict").splitlines() if line.strip()]
    if len(rows) < 3 or len(rows[0]) < 4:
        die(f"粗轨道 LED 格式无效：{path}")
    try:
        expected_count = int(rows[0][0])
        points: list[OrbitPoint] = []
        for number, fields in enumerate(rows[1:], 2):
            if len(fields) < 9:
                die(f"{path}:{number} 粗轨道记录少于9列")
            year = int(fields[0])
            day_index = int(fields[1])
            seconds = float(fields[2])
            if not 0 <= day_index <= 365 or not 0 <= seconds < 86401:
                die(f"{path}:{number} 粗轨道日期或秒数无效")
            timestamp = (
                dt.datetime(year, 1, 1, tzinfo=dt.timezone.utc)
                + dt.timedelta(days=day_index, seconds=seconds)
            )
            position = tuple(float(value) for value in fields[3:6])
            velocity = tuple(float(value) for value in fields[6:9])
            points.append(OrbitPoint(timestamp, position, velocity))
    except (ValueError, OverflowError) as error:
        die(f"{path} 粗轨道 LED 无法解析：{error}")
    if len(points) != expected_count:
        die(f"{path} 粗轨道记录数不一致：头部 {expected_count}，实际 {len(points)}")
    if len(points) < 2:
        die(f"粗轨道 LED 少于2个状态向量：{path}")
    points.sort(key=lambda point: point.time)
    for previous, current in zip(points, points[1:]):
        if current.time <= previous.time:
            die(f"粗轨道 LED 时间重复或倒序：{path}")
    return points


def hermite_high_order(x: list[float], y: list[float], derivative: list[float], x0: float) -> float:
    """Evaluate the same osculating Hermite polynomial used by LT_LED_repair.m."""
    if not (len(x) == len(y) == len(derivative)) or len(x) < 2:
        die("Hermite 插值输入点数量不一致")
    result = 0.0
    for i, xi in enumerate(x):
        basis = 1.0
        coefficient = 0.0
        for j, xj in enumerate(x):
            if i == j:
                continue
            difference = xi - xj
            if difference == 0.0:
                die("Hermite 插值存在重复时间点")
            basis *= ((x0 - xj) / difference) ** 2
            coefficient += 1.0 / difference
        result += basis * ((xi - x0) * (2.0 * coefficient * y[i] - derivative[i]) + y[i])
    return result


def spline_value(x: list[float], y: list[float], x0: float) -> float:
    """Evaluate a cubic not-a-knot spline, matching MATLAB interp1(...,'spline')."""
    n = len(x)
    if n != len(y) or n < 2:
        die("spline 插值输入点数量不一致")
    if n == 2:
        return y[0] + (y[1] - y[0]) * (x0 - x[0]) / (x[1] - x[0])
    if n == 3:
        # MATLAB's spline remains well-defined for three knots; the
        # not-a-knot solution reduces to the unique quadratic here.
        result = 0.0
        for i in range(3):
            term = y[i]
            for j in range(3):
                if i != j:
                    term *= (x0 - x[j]) / (x[i] - x[j])
            result += term
        return result
    h = [x[i + 1] - x[i] for i in range(n - 1)]
    if any(value <= 0.0 for value in h):
        die("spline 插值时间点必须严格递增")

    # Solve for the knot second derivatives with not-a-knot end conditions.
    matrix = [[0.0 for _ in range(n)] for _ in range(n)]
    rhs = [0.0 for _ in range(n)]
    matrix[0][0] = -h[1]
    matrix[0][1] = h[0] + h[1]
    matrix[0][2] = -h[0]
    matrix[-1][-3] = -h[-1]
    matrix[-1][-2] = h[-2] + h[-1]
    matrix[-1][-1] = -h[-2]
    for i in range(1, n - 1):
        matrix[i][i - 1] = h[i - 1]
        matrix[i][i] = 2.0 * (h[i - 1] + h[i])
        matrix[i][i + 1] = h[i]
        rhs[i] = 6.0 * (
            (y[i + 1] - y[i]) / h[i] - (y[i] - y[i - 1]) / h[i - 1]
        )

    # Small dense Gaussian elimination is sufficient for the 10-point window.
    for pivot in range(n):
        pivot_row = max(range(pivot, n), key=lambda row: abs(matrix[row][pivot]))
        if abs(matrix[pivot_row][pivot]) < 1e-15:
            die("spline 插值方程组奇异")
        if pivot_row != pivot:
            matrix[pivot], matrix[pivot_row] = matrix[pivot_row], matrix[pivot]
            rhs[pivot], rhs[pivot_row] = rhs[pivot_row], rhs[pivot]
        scale = matrix[pivot][pivot]
        for column in range(pivot, n):
            matrix[pivot][column] /= scale
        rhs[pivot] /= scale
        for row in range(n):
            if row == pivot:
                continue
            factor = matrix[row][pivot]
            if factor == 0.0:
                continue
            for column in range(pivot, n):
                matrix[row][column] -= factor * matrix[pivot][column]
            rhs[row] -= factor * rhs[pivot]

    interval = min(n - 2, max(0, bisect.bisect_right(x, x0) - 1))
    left, right = x[interval], x[interval + 1]
    width = right - left
    left_weight = (right - x0) / width
    right_weight = (x0 - left) / width
    return (
        rhs[interval] * (right - x0) ** 3 / (6.0 * width)
        + rhs[interval + 1] * (x0 - left) ** 3 / (6.0 * width)
        + (y[interval] - rhs[interval] * width**2 / 6.0) * left_weight
        + (y[interval + 1] - rhs[interval + 1] * width**2 / 6.0) * right_weight
    )


def repair_led_matlab_style(
    points: list[OrbitPoint], window_points: int = 10, max_gap_seconds: int = 20
) -> list[OrbitPoint]:
    """Repair an LED using LT_LED_repair.m's Hermite/spline method."""
    repaired: list[OrbitPoint] = [points[0]]
    half_window = round((window_points + 1) / 2)
    for right_index, right in enumerate(points[1:], 1):
        left = points[right_index - 1]
        gap = (right.time - left.time).total_seconds()
        rounded = int(round(gap))
        if not math.isclose(gap, rounded, abs_tol=1e-6):
            die(f"粗轨道 LED 不是整秒采样：{left.time} -> {right.time}")
        if rounded < 1 or rounded > max_gap_seconds:
            die(
                f"LED 缺口超过{max_gap_seconds}秒："
                f"{left.time} -> {right.time}"
            )
        if rounded > 1:
            start = max(0, right_index - half_window)
            stop = min(len(points), right_index + half_window + 1)
            window = points[start:stop]
            origin = window[0].time
            x = [(point.time - origin).total_seconds() for point in window]
            target_base = (left.time - origin).total_seconds()
            for offset in range(1, rounded):
                target = left.time + dt.timedelta(seconds=offset)
                target_x = target_base + offset
                position = tuple(
                    hermite_high_order(
                        x,
                        [point.position[index] for point in window],
                        [point.velocity[index] for point in window],
                        target_x,
                    )
                    for index in range(3)
                )
                velocity = tuple(
                    spline_value(x, [point.velocity[index] for point in window], target_x)
                    for index in range(3)
                )
                repaired.append(OrbitPoint(target, position, velocity))
        repaired.append(right)
    return repaired


def gmtsar_clock_to_datetime(clock: float, prm: Path, key: str) -> dt.datetime:
    """Convert GMTSAR YYYYDDD.fractional-day clock to a UTC datetime.

    GMTSAR's str_date2JD uses a zero-based day index: January 1 is day 000.
    """
    whole = int(math.floor(clock))
    year = whole // 1000
    day_index = whole % 1000
    max_day_index = 365 if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) else 364
    if year < 1900 or not 0 <= day_index <= max_day_index:
        die(f"{prm} 中 {key}={clock} 不是有效的 YYYYDDD.fraction 时间")
    fraction = clock - whole
    return (
        dt.datetime(year, 1, 1, tzinfo=dt.timezone.utc)
        + dt.timedelta(days=day_index + fraction)
    )


def scene_time_window(prm: Path) -> tuple[dt.datetime, dt.datetime]:
    start = gmtsar_clock_to_datetime(prm_value(prm, "SC_clock_start"), prm, "SC_clock_start")
    stop = gmtsar_clock_to_datetime(prm_value(prm, "SC_clock_stop"), prm, "SC_clock_stop")
    if stop <= start:
        die(f"{prm} 的 SC_clock_stop 不晚于 SC_clock_start")
    return start, stop


def select_orbit_window(
    points: list[OrbitPoint],
    scene_start: dt.datetime,
    scene_stop: dt.datetime,
    padding_seconds: int = 200,
) -> list[OrbitPoint]:
    """Keep the scene interval plus padding, with one bracketing point per side."""
    times = [point.time for point in points]
    wanted_start = scene_start - dt.timedelta(seconds=padding_seconds)
    wanted_stop = scene_stop + dt.timedelta(seconds=padding_seconds)
    left = max(0, bisect.bisect_left(times, wanted_start) - 1)
    right = min(len(points), bisect.bisect_right(times, wanted_stop) + 1)
    selected = points[left:right]
    if len(selected) < 2:
        die(
            "精密轨道与影像时段无足够交集："
            f"影像 {scene_start.isoformat()} -> {scene_stop.isoformat()}，"
            f"轨道 {points[0].time.isoformat()} -> {points[-1].time.isoformat()}"
        )
    return selected


def hermite_between(left: OrbitPoint, right: OrbitPoint, timestamp: dt.datetime) -> OrbitPoint:
    total = (right.time - left.time).total_seconds()
    elapsed = (timestamp - left.time).total_seconds()
    u = elapsed / total
    h00 = 2 * u**3 - 3 * u**2 + 1
    h10 = u**3 - 2 * u**2 + u
    h01 = -2 * u**3 + 3 * u**2
    h11 = u**3 - u**2
    dh00 = (6 * u**2 - 6 * u) / total
    dh10 = 3 * u**2 - 4 * u + 1
    dh01 = (-6 * u**2 + 6 * u) / total
    dh11 = 3 * u**2 - 2 * u
    position = tuple(
        h00 * left.position[index]
        + h10 * total * left.velocity[index]
        + h01 * right.position[index]
        + h11 * total * right.velocity[index]
        for index in range(3)
    )
    velocity = tuple(
        dh00 * left.position[index]
        + dh10 * left.velocity[index]
        + dh01 * right.position[index]
        + dh11 * right.velocity[index]
        for index in range(3)
    )
    return OrbitPoint(timestamp, position, velocity)


def regularize_orbit(
    points: list[OrbitPoint], extension_seconds: int = 5, max_gap_seconds: int = 20
) -> list[OrbitPoint]:
    regular: list[OrbitPoint] = [points[0]]
    for left, right in zip(points, points[1:]):
        gap = (right.time - left.time).total_seconds()
        rounded = int(round(gap))
        if not math.isclose(gap, rounded, abs_tol=1e-6):
            die(f"精密轨道不是整秒采样：{left.time} -> {right.time}")
        if rounded > max_gap_seconds:
            die(
                f"轨道缺口超过{max_gap_seconds}秒："
                f"{left.time} -> {right.time}"
            )
        for offset in range(1, rounded):
            regular.append(hermite_between(left, right, left.time + dt.timedelta(seconds=offset)))
        regular.append(right)

    first, second = regular[0], regular[1]
    last_before, last = regular[-2], regular[-1]
    first_dt = (second.time - first.time).total_seconds()
    last_dt = (last.time - last_before.time).total_seconds()
    acceleration_start = tuple(
        (second.velocity[index] - first.velocity[index]) / first_dt for index in range(3)
    )
    acceleration_end = tuple(
        (last.velocity[index] - last_before.velocity[index]) / last_dt for index in range(3)
    )

    prefix: list[OrbitPoint] = []
    for seconds in range(extension_seconds, 0, -1):
        delta = -float(seconds)
        position = tuple(
            first.position[index]
            + first.velocity[index] * delta
            + 0.5 * acceleration_start[index] * delta**2
            for index in range(3)
        )
        velocity = tuple(
            first.velocity[index] + acceleration_start[index] * delta for index in range(3)
        )
        prefix.append(OrbitPoint(first.time + dt.timedelta(seconds=delta), position, velocity))

    suffix: list[OrbitPoint] = []
    for seconds in range(1, extension_seconds + 1):
        delta = float(seconds)
        position = tuple(
            last.position[index]
            + last.velocity[index] * delta
            + 0.5 * acceleration_end[index] * delta**2
            for index in range(3)
        )
        velocity = tuple(last.velocity[index] + acceleration_end[index] * delta for index in range(3))
        suffix.append(OrbitPoint(last.time + dt.timedelta(seconds=delta), position, velocity))
    return prefix + regular + suffix


def seconds_of_day(timestamp: dt.datetime) -> float:
    return (
        timestamp.hour * 3600
        + timestamp.minute * 60
        + timestamp.second
        + timestamp.microsecond / 1_000_000
    )


def write_led(path: Path, points: list[OrbitPoint]) -> None:
    first = points[0].time
    temp_fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(temp_fd, "w", encoding="ascii") as stream:
            stream.write(
                f"{len(points)} {first.year} {first.timetuple().tm_yday - 1} "
                f"{seconds_of_day(first):.6f} 1.000000\n"
            )
            for point in points:
                timestamp = point.time
                values = point.position + point.velocity
                stream.write(
                    f"{timestamp.year} {timestamp.timetuple().tm_yday - 1} "
                    f"{seconds_of_day(timestamp):.6f} "
                    + " ".join(f"{value:.9f}" for value in values)
                    + "\n"
                )
        os.replace(temp_name, path)
    except BaseException:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def apply_precise_orbit(raw_dir: Path, scene: Scene) -> str:
    prm, _, led = raw_outputs(raw_dir, scene.output_stem)
    if scene.orbit is None:
        # No external precise orbit is available. Preserve the original LED,
        # then repair its sampling from that immutable copy so repeated runs do
        # not keep changing an already repaired file. This follows the
        # LT_LED_repair.m method: high-order Hermite position and spline
        # velocity interpolation around each missing second, without endpoint
        # extension.
        metadata_led = auxiliary_path(raw_dir, scene.output_stem, ".LED.metadata")
        if not metadata_led.exists():
            metadata_led = raw_dir / AUX_ARCHIVE_DIRNAME / f"{scene.output_stem}.LED.metadata"
            metadata_led.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(led, metadata_led)
        points = parse_led_orbit(metadata_led)
        points = repair_led_matlab_style(points, window_points=10, max_gap_seconds=120)
        write_led(led, points)
        if not led.is_file() or led.stat().st_size == 0:
            die(f"粗轨道 LED 修复失败：{scene.output_stem}")
        return "metadata_repaired"
    metadata_led = auxiliary_path(raw_dir, scene.output_stem, ".LED.metadata")
    if not metadata_led.exists():
        metadata_led = raw_dir / AUX_ARCHIVE_DIRNAME / f"{scene.output_stem}.LED.metadata"
        metadata_led.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(led, metadata_led)
    scene_start, scene_stop = scene_time_window(prm)
    points = parse_gps_orbit(scene.orbit)
    # GpsData_GAS_C 通常覆盖约 25 小时。只保留成像时段前后 200 秒，
    # 与 GMTSAR ext_orb_lt1 的时间窗口一致，避免生成超大 LED。
    points = select_orbit_window(points, scene_start, scene_stop, padding_seconds=200)
    # Precise GPS orbits already contain position and velocity at each epoch.
    # Use the stable local two-point cubic Hermite interpolation for missing
    # seconds (the earlier Python method), rather than a wide high-order fit.
    # The 20-second limit prevents fabricating a long unsupported orbit span.
    # The additional boundary extension is required by calc_dop_orb when a
    # SCIE file ends exactly at the image endpoint.
    points = regularize_orbit(points, extension_seconds=5, max_gap_seconds=20)
    if points[0].time > scene_start or points[-1].time < scene_stop:
        die(
            f"{scene.output_stem} 精密轨道未覆盖完整成像时段："
            f"影像 {scene_start.isoformat()} -> {scene_stop.isoformat()}，"
            f"轨道 {points[0].time.isoformat()} -> {points[-1].time.isoformat()}"
        )
    write_led(led, points)
    if not led.is_file() or led.stat().st_size == 0:
        die(f"精密 LED 生成失败：{scene.output_stem}")
    return "precise"


def recalculate_prm(raw_dir: Path, scene: Scene) -> None:
    prm, _, _ = raw_outputs(raw_dir, scene.output_stem)
    original = auxiliary_path(raw_dir, scene.output_stem, ".PRM.make_slc")
    log = raw_dir / f"{scene.output_stem}.calc_dop_orb.log"
    # Preserve the original make_slc_lt1 PRM. Re-running only the orbit stage must
    # not use an already calc_dop_orb-augmented PRM as its new base.
    if not original.is_file():
        original = raw_dir / AUX_ARCHIVE_DIRNAME / f"{scene.output_stem}.PRM.make_slc"
        original.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(prm, original)
    original_arg = os.path.relpath(original, raw_dir)
    result = subprocess.run(
        ["calc_dop_orb", original_arg, log.name, "0", "0"],
        cwd=raw_dir,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != 0 or not log.is_file() or log.stat().st_size == 0:
        die(f"calc_dop_orb 失败：{scene.output_stem}\n{result.stdout}")
    temp = prm.with_name(f".{prm.name}.tmp.{os.getpid()}")
    with temp.open("wb") as output:
        output.write(original.read_bytes())
        output.write(log.read_bytes())
        output.write(b"fdd1                    = 0\n")
        output.write(b"fddd1                   = 0\n")
    temp.replace(prm)


def write_orbit_marker(raw_dir: Path, scene: Scene, used_factor: float, orbit_source: str) -> None:
    marker = raw_dir / f"{scene.output_stem}{MARKER}"
    marker.write_text(
        json.dumps(
            {
                "scene": scene.stem,
                "output_stem": scene.output_stem,
                "metadata": str(scene.metadata),
                "raster": str(scene.raster),
                "orbit": str(scene.orbit) if scene.orbit else None,
                "orbit_source": orbit_source,
                "orbit_repair_method": ORBIT_REPAIR_METHOD,
                "slc_factor": used_factor,
                "completed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def write_missing_orbit_report(root: Path, missing: list[Scene]) -> Path:
    """Write a stable list of scenes that use a repaired metadata orbit."""
    report = root / "run1.2.3_missing_precise_orbits.tsv"
    lines = ["satellite\tdate\toutput_stem\tproduct\n"]
    lines.extend(
        f"{scene.satellite}\t{scene.date}\t{scene.output_stem}\t{scene.stem}\n"
        for scene in missing
    )
    report.write_text("".join(lines), encoding="utf-8")
    return report


def print_orbit_date_summary(scenes: list[Scene], missing: list[Scene]) -> None:
    """Print date-level orbit details alongside the count summary."""
    precise = [scene for scene in scenes if scene.orbit is not None]
    if precise:
        labels = ", ".join(
            f"{scene.output_stem}({scene.satellite})" for scene in precise
        )
        print(f"[DATES] 精密轨道已应用：{labels}")
    if missing:
        labels = ", ".join(
            f"{scene.output_stem}({scene.satellite})" for scene in missing
        )
        print(f"[DATES] 粗轨道 LED 已修复：{labels}")


def archive_auxiliary_files(raw_dir: Path, scenes: list[Scene]) -> Path:
    """Move non-active Run 1.2 artifacts out of raw after a formal run."""
    archive = raw_dir / AUX_ARCHIVE_DIRNAME
    archive.mkdir(parents=True, exist_ok=True)
    for scene in scenes:
        for suffix in AUXILIARY_SUFFIXES:
            source = raw_dir / f"{scene.output_stem}{suffix}"
            if not source.exists() or source.is_symlink():
                continue
            target = archive / source.name
            if target.exists():
                # Keep immutable PRM/LED backups; replace only transient logs
                # and completion markers from a newer rerun.
                if suffix in {MARKER, ".make_slc.log", ".calc_dop_orb.log"}:
                    source.replace(target)
                continue
            shutil.move(str(source), str(target))
    return archive


def archive_sampling_inputs(raw_dir: Path, scenes: list[Scene]) -> Path:
    """Back up the current PRM/SLC before common sampling rewrites them."""
    archive = raw_dir / SAMPLE_ARCHIVE_DIRNAME
    archive.mkdir(parents=True, exist_ok=True)
    for scene in scenes:
        for suffix in (".PRM", ".SLC"):
            source = raw_dir / f"{scene.output_stem}{suffix}"
            target = archive / source.name
            if not source.is_file() or target.exists():
                continue
            try:
                # A hard link is instantaneous and preserves the old inode when
                # samp_slc.csh replaces the active file with mv.
                os.link(source, target)
            except OSError:
                shutil.copy2(source, target)
    return archive


def prepare_scene_inputs(raw_dir: Path, scene: Scene) -> tuple[str, float, str]:
    # Preserve the vendor .meta.xml filename. Run 1.2.2 reads it directly.
    # The later p2p_processing.csh run starts at stage 2 and uses PRM/SLC/LED,
    # so no shortened <stem>.xml alias is required by this workflow.
    ensure_link(raw_dir / f"{scene.stem}.meta.xml", scene.metadata)
    ensure_link(raw_dir / f"{scene.stem}.tiff", scene.raster)
    return scene.output_stem, 0.0, "links"


def make_scene_slc(raw_dir: Path, scene: Scene, factor: float, force: bool) -> tuple[str, float, str]:
    prepare_scene_inputs(raw_dir, scene)
    if slc_is_ready(raw_dir, scene) and not force:
        return scene.output_stem, factor, "skip"
    if force:
        backup_existing(raw_dir, scene)
    elif any(path.exists() for path in raw_outputs(raw_dir, scene.output_stem)):
        die(f"{scene.output_stem} 已有部分 raw 输出；请检查或使用 --force 备份后重做")
    used_factor = run_make_slc(raw_dir, scene, factor)
    return scene.output_stem, used_factor, "metadata"


def apply_scene_orbit(raw_dir: Path, scene: Scene, factor: float, force: bool) -> tuple[str, float, str]:
    if scene_is_complete(raw_dir, scene) and not force:
        return scene.output_stem, factor, "skip"
    if not slc_is_ready(raw_dir, scene):
        die(f"{scene.output_stem} 缺少 PRM/SLC/LED，请先运行 Run 1.2.2")
    orbit_source = apply_precise_orbit(raw_dir, scene)
    recalculate_prm(raw_dir, scene)
    write_orbit_marker(raw_dir, scene, factor, orbit_source)
    return scene.output_stem, factor, orbit_source


def process_scene(raw_dir: Path, scene: Scene, factor: float, force: bool) -> tuple[str, float, str]:
    if scene_is_complete(raw_dir, scene) and not force:
        return scene.output_stem, factor, "skip"
    _, used_factor, _ = make_scene_slc(raw_dir, scene, factor, force)
    return apply_scene_orbit(raw_dir, scene, used_factor, force=False)


def prm_value(path: Path, key: str) -> float:
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*([-+0-9.eE]+)")
    for line in path.read_text(encoding="ascii", errors="ignore").splitlines():
        match = pattern.match(line)
        if match:
            return float(match.group(1))
    die(f"{path} 中找不到 {key}")


def common_sampling_targets(raw_dir: Path, scenes: list[Scene]) -> tuple[float, float]:
    prfs = [prm_value(raw_dir / f"{scene.output_stem}.PRM", "PRF") for scene in scenes]
    rates = [prm_value(raw_dir / f"{scene.output_stem}.PRM", "rng_samp_rate") for scene in scenes]
    # Use the exact maximum PRF. Rounding up would resample every scene more
    # than necessary, while rounding down would downsample the fastest scene.
    return max(prfs), max(rates)


def resample_scene_in_workspace(
    raw_dir: Path,
    archive: Path,
    scene: Scene,
    target_prf: float,
    target_rate: float,
) -> None:
    """Run samp_slc.csh in an isolated directory for safe parallelism."""
    stem = scene.output_stem
    raw_prm = raw_dir / f"{stem}.PRM"
    raw_slc = raw_dir / f"{stem}.SLC"
    work = Path(tempfile.mkdtemp(prefix=f".{stem}.sampling.", dir=raw_dir))
    log = archive / f"{stem}.samp_slc.log"
    command = [
        "samp_slc.csh",
        stem,
        f"{target_prf:.12g}",
        f"{target_rate:.12g}",
    ]
    try:
        shutil.copy2(raw_prm, work / f"{stem}.PRM")
        # resamp obtains the input image name from PRM. Both common LT-1 names
        # are linked into the private workspace so the vendor PRM is portable.
        for suffix in (".SLC", ".LED"):
            source = raw_dir / f"{stem}{suffix}"
            if source.exists():
                (work / source.name).symlink_to(os.path.relpath(source, work))
        raw_alias = work / f"{stem}.raw"
        raw_alias.symlink_to(os.path.relpath(raw_slc, work))
        result = subprocess.run(
            command,
            cwd=work,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        log.write_text(result.stdout, encoding="utf-8")
        if result.returncode != 0:
            die(f"samp_slc.csh 失败：{stem}，见 {log}")
        work_prm = work / f"{stem}.PRM"
        work_slc = work / f"{stem}.SLC"
        if not work_prm.is_file() or work_prm.stat().st_size == 0:
            die(f"samp_slc.csh 未生成 PRM：{stem}")
        if not work_slc.is_file() or work_slc.stat().st_size == 0:
            die(f"samp_slc.csh 未生成 SLC：{stem}")
        os.replace(work_prm, raw_prm)
        os.replace(work_slc, raw_slc)
    except RuntimeError:
        raise
    except OSError as error:
        die(f"Run 1.2.4 文件操作失败：{stem}: {error}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def cleanup_sampling_workdirs(raw_dir: Path) -> None:
    """Remove only temporary directories created by parallel Run 1.2.4 jobs."""
    for path in raw_dir.glob(".*.sampling.*"):
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)


def common_sampling(
    raw_dir: Path, scenes: list[Scene], jobs: int
) -> tuple[float, float]:
    cleanup_sampling_workdirs(raw_dir)
    target_prf, target_rate = common_sampling_targets(raw_dir, scenes)
    archive = archive_sampling_inputs(raw_dir, scenes)
    failures: list[str] = []
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(jobs, len(scenes))) as executor:
            futures = {
                executor.submit(
                    resample_scene_in_workspace,
                    raw_dir,
                    archive,
                    scene,
                    target_prf,
                    target_rate,
                ): scene
                for scene in scenes
            }
            for future in concurrent.futures.as_completed(futures):
                scene = futures[future]
                try:
                    future.result()
                    print(f"[DONE] Run 1.2.4 {scene.output_stem}", flush=True)
                except Exception as error:
                    failures.append(f"{scene.output_stem}\t{error}")
                    print(f"[FAILED] Run 1.2.4 {scene.output_stem}: {error}", file=sys.stderr, flush=True)
    finally:
        cleanup_sampling_workdirs(raw_dir)
    if failures:
        die("Run 1.2.4 失败：\n" + "\n".join(failures))
    return target_prf, target_rate


def write_data_list(path: Path, scenes: list[Scene], master: Scene) -> None:
    ordered = [master] + [scene for scene in scenes if scene != master]
    path.write_text("".join(f"{scene.output_stem}\n" for scene in ordered), encoding="ascii")


def ensure_config(path: Path) -> None:
    if path.is_file() and path.stat().st_size > 0:
        return
    result = subprocess.run(
        ["pop_config.csh", "LT1"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0 or "SLC_factor" not in result.stdout:
        die(f"pop_config.csh LT1 生成配置失败：{result.stderr.strip()}")
    temp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temp.write_text(result.stdout, encoding="utf-8")
    temp.replace(path)


def main() -> int:
    args = parse_args()
    formal = args.mode == "1"
    step = args.step
    root = Path.cwd().resolve()
    data_dir = root / "data"
    orbit_dir = data_dir / "orbit"
    raw_dir = root / "raw"
    config_path = root / "config.LT1.txt"
    if not data_dir.is_dir():
        die(f"找不到 {data_dir}；请在 Ascending/ 或 Descending/ 目录运行")
    # Run 1.2.1/1.2.2 只使用 meta.xml 内置粗轨。只有总控和
    # Run 1.2.3 需要查找 data/orbit/ 中的精密轨道。
    match_precise_orbits = step in {"all", "orbit"}
    if match_precise_orbits and not orbit_dir.is_dir():
        die(f"找不到精密轨道目录：{orbit_dir}")
    scenes = discover_scenes(data_dir, orbit_dir, match_precise_orbits)
    master = select_master(scenes, args.master)
    missing = [scene for scene in scenes if scene.orbit is None]
    data_list_path = root / "data.list"

    if step in {"slc", "orbit", "sample"}:
        if not data_list_path.is_file():
            die("找不到 data.list，请先正式运行 Run 1.2.1")
        listed = [line.strip() for line in data_list_path.read_text(encoding="ascii").splitlines() if line.strip()]
        if not listed:
            die("data.list 为空，请重新运行 Run 1.2.1")
        if listed[0] != master.output_stem:
            die(
                f"主影像不一致：data.list 第一行是 {listed[0]}，"
                f"本次 --master 对应 {master.output_stem}"
            )

    if step == "prepare":
        status_function = inputs_are_ready
        step_title = "Run 1.2.1 准备 raw 输入"
    elif step == "slc":
        status_function = slc_is_ready
        step_title = "Run 1.2.2 生成 SLC/PRM/元数据 LED"
    elif step == "orbit":
        status_function = scene_is_complete
        step_title = "Run 1.2.3 应用精密轨道"
    elif step == "sample":
        status_function = slc_is_ready
        step_title = "Run 1.2.4 统一 PRF/距离采样率"
    else:
        status_function = scene_is_complete
        step_title = "Run 1.2 总控（1.2.1→1.2.2→1.2.3）"

    print("=" * 72)
    print(f"LT-1 {step_title}  模式：{'FORMAL' if formal else 'PREVIEW'}")
    print(f"轨道方向目录：{root}")
    print(f"解压产品：{data_dir}/LT1*/")
    if match_precise_orbits:
        print(f"精密轨道：{orbit_dir}/")
    else:
        print("轨道来源：meta.xml 内置粗轨（本步不检查精密轨道）")
    print(f"处理输出：{raw_dir}/")
    print(f"GMTSAR 配置：{config_path} ({'已存在' if config_path.is_file() else '将生成'})")
    print(f"影像数量：{len(scenes)}  并行数：{args.jobs}  初始 SLC_factor：{args.slc_factor:g}")
    print(f"主影像产品：{master.stem}")
    print(f"主影像输出：{master.output_stem}")
    print("=" * 72)
    for scene in scenes:
        status = "READY" if status_function(raw_dir, scene) else "PENDING"
        role = " MASTER" if scene == master else ""
        print(f"[{status}{role}] {scene.satellite} {scene.date}  {scene.stem}")
        print(f"          GMTSAR 输出名：{scene.output_stem}")
        if match_precise_orbits:
            orbit_text = scene.orbit.name if scene.orbit else "MISSING"
            print(f"          精密轨道：{orbit_text}")
    print("-" * 72)
    if match_precise_orbits:
        print(f"精密轨道匹配：{len(scenes) - len(missing)}/{len(scenes)}")
    else:
        print("精密轨道匹配：留到 Run 1.2.3 执行")
    run_sampling = step == "sample" or (step == "all" and args.common_sampling)
    if run_sampling:
        print("统一采样：启用（最大 PRF + 最大距离采样率）")
        if all(slc_is_ready(raw_dir, scene) for scene in scenes):
            target_prf, target_rate = common_sampling_targets(raw_dir, scenes)
            print("当前各景采样参数：")
            for scene in scenes:
                prm = raw_dir / f"{scene.output_stem}.PRM"
                current_prf = prm_value(prm, "PRF")
                current_rate = prm_value(prm, "rng_samp_rate")
                print(
                    f"  {scene.output_stem}: PRF={current_prf:g}, "
                    f"rng_samp_rate={current_rate:.12g}"
                )
            print(f"目标采样率：PRF={target_prf}, rng_samp_rate={target_rate:.12g}")
    else:
        print("统一采样：未启用")

    needs_orbit = step in {"all", "orbit"}
    if needs_orbit and missing:
        names = ", ".join(f"{scene.satellite}_{scene.date}" for scene in missing)
        print(f"[FALLBACK] {len(missing)} 景缺少精密轨道，将修复 Run 1.2.2 生成的粗轨道 LED：{names}")
        if args.require_precise_orbit and not args.allow_missing_orbit:
            if formal:
                die(f"以下数据缺少精密轨道：{names}")
            print(f"[BLOCKED] 缺少精密轨道：{names}")

    if not formal:
        print("\n预览完成，未修改任何文件。")
        if step == "all":
            print(f"确认后执行：./run1.2_preprocess_LT1.py 1 --master {master.date}")
        return 0

    required_commands: set[str] = set()
    if step in {"all", "prepare"}:
        required_commands.add("pop_config.csh")
    if step in {"all", "slc"}:
        required_commands.add("make_slc_lt1")
    if step in {"all", "orbit"}:
        required_commands.add("calc_dop_orb")
    if run_sampling:
        required_commands.add("samp_slc.csh")
    for command in sorted(required_commands):
        if shutil.which(command) is None:
            die(f"PATH 中找不到 GMTSAR 命令：{command}")

    lock_path = root / ".run1.2_preprocess_LT1.lock"
    lock = lock_path.open("w", encoding="ascii")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        die("已有另一个 Run 1.2 在当前目录运行")
    lock.write(f"pid={os.getpid()}\n")
    lock.flush()

    raw_dir.mkdir(parents=True, exist_ok=True)
    missing_report: Path | None = None
    if needs_orbit and formal:
        missing_report = write_missing_orbit_report(root, missing)
    if step in {"all", "prepare"}:
        ensure_config(config_path)
        for scene in scenes:
            prepare_scene_inputs(raw_dir, scene)
        write_data_list(data_list_path, scenes, master)
        print(f"[DONE] Run 1.2.1：已准备 {len(scenes)} 景 raw 输入链接")

    if step == "prepare":
        print(f"[SUCCESS] 生成 {data_list_path}")
        print(
            f"[NEXT] ./run1.2.2_make_slc_LT1.sh 1 --master {master.date} "
            f"--jobs {args.jobs}"
        )
        return 0

    if step == "sample":
        not_ready = [scene.output_stem for scene in scenes if not slc_is_ready(raw_dir, scene)]
        if not_ready:
            die(f"{len(not_ready)} 景缺少 PRM/SLC/LED，请先完成 Run 1.2.2")
        target_prf, target_rate = common_sampling(raw_dir, scenes, args.jobs)
        marker = root / ".run1.2.4_common_sampling_complete.json"
        marker.write_text(
            json.dumps(
                {
                    "target_prf": target_prf,
                    "target_rng_samp_rate": target_rate,
                    "scene_count": len(scenes),
                    "completed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"[ARCHIVE] Run 1.2.4 旧 PRM/SLC 和日志已备份：{raw_dir / SAMPLE_ARCHIVE_DIRNAME}")
        print(f"[SUCCESS] Run 1.2.4：PRF={target_prf}, rng_samp_rate={target_rate:.12g}")
        return 0

    if step == "slc":
        worker = lambda scene: make_scene_slc(raw_dir, scene, args.slc_factor, args.force)
    elif step == "orbit":
        worker = lambda scene: apply_scene_orbit(raw_dir, scene, args.slc_factor, args.force)
    else:
        worker = lambda scene: process_scene(raw_dir, scene, args.slc_factor, args.force)

    failures: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = {
            executor.submit(worker, scene): scene for scene in scenes
        }
        for future in concurrent.futures.as_completed(futures):
            scene = futures[future]
            try:
                stem, factor, source = future.result()
                print(f"[DONE] {stem}  factor={factor:g}  orbit={source}", flush=True)
            except Exception as error:  # keep other independent scenes running
                failures.append(f"{scene.output_stem}\t{scene.stem}\t{error}")
                print(f"[FAILED] {scene.output_stem} ({scene.stem}): {error}", file=sys.stderr, flush=True)

    failure_file = root / f"run1.2_{step}_failed.tsv"
    failure_file.write_text("".join(f"{line}\n" for line in failures), encoding="utf-8")
    if failures:
        die(f"{len(failures)} 景处理失败，见 {failure_file}")

    archive_path: Path | None = None
    if needs_orbit:
        archive_path = archive_auxiliary_files(raw_dir, scenes)

    if step == "slc":
        print(f"[SUCCESS] Run 1.2.2：已生成 {len(scenes)} 景 SLC/PRM/元数据 LED")
        print(
            f"[NEXT] ./run1.2.3_apply_precise_orbit_LT1.sh 1 "
            f"--master {master.date} --jobs {args.jobs}"
        )
        return 0

    if step == "orbit":
        print(
            f"[SUMMARY] 精密轨道={len(scenes) - len(missing)} 景；"
            f"粗轨道 LED 修复={len(missing)} 景"
        )
        print_orbit_date_summary(scenes, missing)
        if missing_report is not None:
            print(f"[REPORT] 缺失精密轨道清单：{missing_report}")
        if archive_path is not None:
            print(f"[ARCHIVE] 备份和日志已归档：{archive_path}")
        print(f"[SUCCESS] Run 1.2.3：已完成 {len(scenes)} 景轨道处理")
        print(
            f"[NEXT] 可选执行 ./run1.2.4_common_sampling_LT1.sh "
            f"--master {master.date}"
        )
        return 0

    if run_sampling:
        target_prf, target_rate = common_sampling(raw_dir, scenes, args.jobs)
        print(f"[ARCHIVE] Run 1.2.4 旧 PRM/SLC 和日志已备份：{raw_dir / SAMPLE_ARCHIVE_DIRNAME}")
        print(f"[DONE] 统一采样：PRF={target_prf}, rng_samp_rate={target_rate:.12g}")

    if needs_orbit:
        print(
            f"[SUMMARY] 精密轨道={len(scenes) - len(missing)} 景；"
            f"粗轨道 LED 修复={len(missing)} 景"
        )
        print_orbit_date_summary(scenes, missing)
        if missing_report is not None:
            print(f"[REPORT] 缺失精密轨道清单：{missing_report}")
        if archive_path is not None:
            print(f"[ARCHIVE] 备份和日志已归档：{archive_path}")

    print(f"[SUCCESS] 生成 {data_list_path}")
    print(f"[SUCCESS] data.list 第一行主影像：{master.output_stem}")
    print(f"[SUCCESS] raw 产品目录：{raw_dir}")
    print("[NEXT] 检查配准参数后运行：")
    print(
        f"       batch_processing.csh LT1 {master.output_stem} data.list 2 "
        f"{config_path.name}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        raise SystemExit(1)
