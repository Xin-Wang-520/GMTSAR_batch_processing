#!/usr/bin/env python3
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 29, 2026

"""Calculate a frame-wide DEM region and optionally run GMTSAR make_dem.csh."""

from __future__ import annotations

import argparse
import math
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


FRAME_RE = re.compile(r"^F[0-9]{4}_F[0-9]{4}$")
TRACK_RE = re.compile(r"^T[0-9]+$")


def print_command_guide() -> None:
    """Show the two-stage workflow without touching any processing files."""
    root = Path.cwd().resolve()
    print("========================================")
    print("Run 2.3 command guide (processing NOT started)")
    print(f"Current directory : {root}")
    print()
    print("Mode 1 - preview and save the DEM region:")
    print("  ./run2.3_prepare_topo_DEM.py 1")
    print()
    print("  Reads all selected Sentinel-1 annotation XML files.")
    print("  Calculates the frame-wide geographic bounds.")
    print("  Creates/updates: topo/dem_region.txt")
    print("  Does NOT download or generate topo/dem.grd.")
    print()
    print("Mode 2 - formally generate the DEM:")
    print("  ./run2.3_prepare_topo_DEM.py 2")
    print()
    print("  Rechecks the XML bounds and dem_region.txt.")
    print("  Runs make_dem.csh and generates: topo/dem.grd")
    print("  Stops if topo/dem.grd already exists.")
    print()
    print("Default settings:")
    print("  Polarization : vv")
    print("  DEM margin   : 0.3 degree beyond outward 0.1-degree rounding")
    print("  DEM mode     : 1 (make_dem.csh resolution argument)")
    print()
    print("If organized/ contains multiple frame directories:")
    print("  ./run2.3_prepare_topo_DEM.py 1 --frame F2399_F2449")
    print("  ./run2.3_prepare_topo_DEM.py 2 --frame F2399_F2449")
    print("========================================")
    print("[INFO] No processing was started.")


def fail(message: str) -> "NoReturn":
    print(f"[ERROR] {message}", file=sys.stderr)
    raise SystemExit(1)


@dataclass(frozen=True)
class Bounds:
    west: float
    east: float
    south: float
    north: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Read all Sentinel-1 VV annotation XML files in one organized frame, "
            "calculate a DEM region, and optionally run make_dem.csh."
        )
    )
    parser.add_argument(
        "mode",
        choices=("1", "2"),
        help="1: calculate/save region; 2: calculate region and run make_dem.csh",
    )
    parser.add_argument(
        "--frame",
        help="frame directory name, for example F2399_F2449 (auto if unique)",
    )
    parser.add_argument(
        "--organized-dir",
        default="organized",
        help="organized directory relative to the track root (default: organized)",
    )
    parser.add_argument(
        "--topo-dir",
        default="topo",
        help="topo directory relative to the track root (default: topo)",
    )
    parser.add_argument(
        "--polarization",
        default="vv",
        choices=("vv", "vh", "hh", "hv"),
        help="annotation polarization (default: vv)",
    )
    parser.add_argument(
        "--margin",
        type=float,
        default=0.3,
        help="extra margin in degrees after outward 0.1-degree rounding (default: 0.3)",
    )
    parser.add_argument(
        "--resolution",
        type=int,
        default=1,
        help="final make_dem.csh resolution argument (default: 1)",
    )
    return parser.parse_args()


def resolve_under_root(root: Path, value: str, label: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = root / path
    try:
        return path.resolve(strict=False)
    except OSError as exc:
        fail(f"cannot resolve {label}: {path} ({exc})")


def choose_frame(organized_dir: Path, requested: str | None) -> Path:
    if requested:
        if not FRAME_RE.fullmatch(requested):
            fail("--frame must look like F2399_F2449")
        frame = organized_dir / requested
        if not frame.is_dir():
            fail(f"frame directory not found: {frame}")
        return frame.resolve()

    frames = sorted(
        path.resolve()
        for path in organized_dir.iterdir()
        if path.is_dir() and FRAME_RE.fullmatch(path.name)
    )
    if not frames:
        fail(f"no F????_F???? frame directory found in {organized_dir}")
    if len(frames) > 1:
        names = ", ".join(path.name for path in frames)
        fail(f"multiple frame directories found ({names}); use --frame Fxxxx_Fxxxx")
    return frames[0]


def xml_subswath(name: str, polarization: str) -> int | None:
    lower = name.lower()
    if not lower.endswith(".xml") or f"-{polarization}-" not in lower:
        return None
    match = re.search(r"-iw([123])-", lower)
    return int(match.group(1)) if match else None


def collect_xml_files(frame_dir: Path, polarization: str) -> tuple[list[Path], int]:
    safe_dirs = sorted(
        path for path in frame_dir.iterdir() if path.is_dir() and path.name.endswith(".SAFE")
    )
    if not safe_dirs:
        fail(f"no .SAFE directories found in {frame_dir}")

    xml_files: list[Path] = []
    problems: list[str] = []
    for safe_dir in safe_dirs:
        annotation = safe_dir / "annotation"
        if not annotation.is_dir():
            problems.append(f"{safe_dir.name}: annotation directory missing")
            continue

        by_iw: dict[int, list[Path]] = {1: [], 2: [], 3: []}
        for path in annotation.iterdir():
            if not path.is_file():
                continue
            iw = xml_subswath(path.name, polarization)
            if iw is not None:
                by_iw[iw].append(path)

        for iw in (1, 2, 3):
            matches = sorted(by_iw[iw])
            if len(matches) != 1:
                problems.append(
                    f"{safe_dir.name}: IW{iw} {polarization.upper()} XML count={len(matches)}"
                )
            else:
                xml_files.append(matches[0])

    if problems:
        for problem in problems:
            print(f"[INPUT ERROR] {problem}", file=sys.stderr)
        fail("frame XML integrity check failed")

    return xml_files, len(safe_dirs)


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def read_xml_bounds(xml_path: Path) -> Bounds:
    west = math.inf
    east = -math.inf
    south = math.inf
    north = -math.inf
    point_count = 0

    try:
        for _, element in ET.iterparse(xml_path, events=("end",)):
            if local_name(element.tag) != "geolocationGridPoint":
                continue
            latitude = None
            longitude = None
            for child in element:
                name = local_name(child.tag)
                if name == "latitude" and child.text is not None:
                    latitude = float(child.text)
                elif name == "longitude" and child.text is not None:
                    longitude = float(child.text)
            if latitude is not None and longitude is not None:
                if not (-90.0 <= latitude <= 90.0 and -180.0 <= longitude <= 180.0):
                    fail(f"invalid longitude/latitude in {xml_path}")
                west = min(west, longitude)
                east = max(east, longitude)
                south = min(south, latitude)
                north = max(north, latitude)
                point_count += 1
            element.clear()
    except (ET.ParseError, OSError, ValueError) as exc:
        fail(f"cannot parse geolocation points from {xml_path}: {exc}")

    if point_count == 0:
        fail(f"no geolocationGridPoint coordinates found in {xml_path}")
    return Bounds(west, east, south, north)


def merge_xml_bounds(xml_files: list[Path]) -> Bounds:
    merged = Bounds(math.inf, -math.inf, math.inf, -math.inf)
    total = len(xml_files)
    for index, xml_path in enumerate(xml_files, start=1):
        if index == 1 or index == total or index % 100 == 0:
            print(f"[READ {index}/{total}] {xml_path.name}")
        current = read_xml_bounds(xml_path)
        merged = Bounds(
            min(merged.west, current.west),
            max(merged.east, current.east),
            min(merged.south, current.south),
            max(merged.north, current.north),
        )

    if merged.east - merged.west > 180.0:
        fail("longitude span exceeds 180 degrees; antimeridian frames are not supported")
    return merged


def outward_region(raw: Bounds, margin: float) -> Bounds:
    if not math.isfinite(margin) or margin < 0.0:
        fail("--margin must be a finite non-negative number")
    return Bounds(
        math.floor(raw.west * 10.0) / 10.0 - margin,
        math.ceil(raw.east * 10.0) / 10.0 + margin,
        math.floor(raw.south * 10.0) / 10.0 - margin,
        math.ceil(raw.north * 10.0) / 10.0 + margin,
    )


def format_number(value: float) -> str:
    if abs(value) < 0.0000001:
        value = 0.0
    return f"{value:.1f}"


def command_for(region: Bounds, resolution: int) -> list[str]:
    return [
        "make_dem.csh",
        format_number(region.west),
        format_number(region.east),
        format_number(region.south),
        format_number(region.north),
        str(resolution),
    ]


def write_region_file(
    output: Path,
    root: Path,
    frame_dir: Path,
    safe_count: int,
    xml_count: int,
    raw: Bounds,
    final: Bounds,
    margin: float,
    command: list[str],
) -> None:
    lines = [
        f"track_root={root}",
        f"frame={frame_dir.name}",
        f"safe_count={safe_count}",
        f"xml_count={xml_count}",
        f"polarization_xml_per_safe=3",
        f"raw_west={raw.west:.12f}",
        f"raw_east={raw.east:.12f}",
        f"raw_south={raw.south:.12f}",
        f"raw_north={raw.north:.12f}",
        f"margin_degrees={margin:.1f}",
        f"west={format_number(final.west)}",
        f"east={format_number(final.east)}",
        f"south={format_number(final.south)}",
        f"north={format_number(final.north)}",
        "gmt_region=-R"
        f"{format_number(final.west)}/{format_number(final.east)}/"
        f"{format_number(final.south)}/{format_number(final.north)}",
        f"command={' '.join(command)}",
    ]
    temporary = output.with_name(output.name + f".tmp.{os.getpid()}")
    temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
    temporary.replace(output)


def run_make_dem(command: list[str], topo_dir: Path) -> None:
    executable = shutil.which(command[0])
    if executable is None:
        fail("make_dem.csh was not found in PATH")

    dem_path = topo_dir / "dem.grd"
    if dem_path.exists():
        fail(f"DEM already exists: {dem_path}; move or remove it before rerunning mode 2")

    command[0] = executable
    log_path = topo_dir / "run2.3_make_dem.log"
    print(f"[START] {' '.join(command)}")
    print(f"[LOG] {log_path}")

    environment = os.environ.copy()
    environment.update({"LC_ALL": "C", "LANG": "C", "LANGUAGE": "C"})
    with log_path.open("w", encoding="utf-8") as log:
        log.write(f"Command: {' '.join(command)}\n")
        log.flush()
        process = subprocess.Popen(
            command,
            cwd=topo_dir,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=environment,
        )
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="")
            log.write(line)
        return_code = process.wait()

    if return_code != 0:
        fail(f"make_dem.csh exited with status {return_code}; inspect {log_path}")
    if not dem_path.is_file() or dem_path.stat().st_size == 0:
        fail(f"make_dem.csh finished but a non-empty dem.grd was not found in {topo_dir}")
    print(f"[DONE] DEM created: {dem_path}")


def main() -> None:
    if len(sys.argv) == 1:
        print_command_guide()
        return

    args = parse_args()
    if args.resolution <= 0:
        fail("--resolution must be a positive integer")

    root = Path.cwd().resolve()
    if not TRACK_RE.fullmatch(root.name):
        fail(f"run this script in a T-number directory (current: {root})")

    organized_dir = resolve_under_root(root, args.organized_dir, "organized directory")
    if not organized_dir.is_dir():
        fail(f"organized directory not found: {organized_dir}")
    frame_dir = choose_frame(organized_dir, args.frame)
    xml_files, safe_count = collect_xml_files(frame_dir, args.polarization)

    print("========================================")
    print("Run 2.3: prepare frame-wide DEM")
    print(f"Mode           : {'EXECUTE' if args.mode == '2' else 'PREVIEW'}")
    print(f"Track root     : {root}")
    print(f"Frame          : {frame_dir}")
    print(f"SAFE total     : {safe_count}")
    print(f"XML total      : {len(xml_files)}")
    print(f"Polarization   : {args.polarization}")
    print(f"Margin         : {args.margin:.1f} degree")
    print("========================================")

    raw = merge_xml_bounds(xml_files)
    final = outward_region(raw, args.margin)
    command = command_for(final, args.resolution)

    topo_dir = resolve_under_root(root, args.topo_dir, "topo directory")
    topo_dir.mkdir(parents=True, exist_ok=True)
    region_file = topo_dir / "dem_region.txt"
    write_region_file(
        region_file,
        root,
        frame_dir,
        safe_count,
        len(xml_files),
        raw,
        final,
        args.margin,
        command,
    )

    print("========================================")
    print(
        "Raw W/E/S/N   : "
        f"{raw.west:.12f} {raw.east:.12f} {raw.south:.12f} {raw.north:.12f}"
    )
    print(
        "Final W/E/S/N : "
        f"{format_number(final.west)} {format_number(final.east)} "
        f"{format_number(final.south)} {format_number(final.north)}"
    )
    print(
        "GMT region    : -R"
        f"{format_number(final.west)}/{format_number(final.east)}/"
        f"{format_number(final.south)}/{format_number(final.north)}"
    )
    print(f"Command        : {' '.join(command)}")
    print(f"Region file    : {region_file}")
    print("========================================")

    if args.mode == "1":
        print("[PREVIEW DONE] Review topo/dem_region.txt, then run mode 2.")
        return
    run_make_dem(command, topo_dir)


if __name__ == "__main__":
    main()
