#!/usr/bin/env python3
"""Run 4.6: plot Run 4.5 LT-1 SBAS point time series with Matplotlib."""

from __future__ import annotations

import argparse
import math
import os
import sys
from datetime import datetime
from pathlib import Path

try:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.dates as mdates
    import matplotlib.pyplot as plt
except ImportError as exc:
    print(f"[ERROR] Python package matplotlib is required: {exc}", file=sys.stderr)
    raise SystemExit(1)


DEFAULT_EVENT_DATE = "2025-05-25"
DEFAULT_EVENT_LABEL = "Landslide"


def die(message: str) -> "None":
    print(f"[ERROR] {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Read Run 4.5 time_series_<label>.dat files. A single point is "
            "drawn once; multiple points produce one combined overview by default."
        )
    )
    parser.add_argument(
        "event_date",
        nargs="?",
        help=f"event date in YYYY-MM-DD format (default: Run 4.5 record or {DEFAULT_EVENT_DATE})",
    )
    parser.add_argument(
        "event_label",
        nargs="?",
        help=f"event label (default: Run 4.5 record or {DEFAULT_EVENT_LABEL})",
    )
    parser.add_argument("--dpi", type=int, default=180, help="PNG resolution (default: 180)")
    parser.add_argument(
        "--individual",
        action="store_true",
        help="for multiple points, also draw one separate figure per point",
    )
    parser.add_argument(
        "--pdf",
        action="store_true",
        help="also save PDF files; by default only PNG files are written",
    )
    return parser.parse_args()


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def read_series(path: Path) -> dict[str, object]:
    dates = []
    displacement = []
    uncertainty = []
    total_records = 0
    missing_displacement = 0
    missing_uncertainty = 0
    longitude = math.nan
    latitude = math.nan

    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 6:
            die(f"invalid record in {path}:{line_number}")
        total_records += 1
        try:
            date_value = datetime.strptime(fields[1], "%Y-%m-%d")
            displacement_value = float(fields[2])
            uncertainty_value = float(fields[3])
            longitude = float(fields[4])
            latitude = float(fields[5])
        except ValueError as exc:
            die(f"invalid value in {path}:{line_number}: {exc}")
        if not math.isfinite(displacement_value):
            missing_displacement += 1
            continue
        if math.isfinite(uncertainty_value):
            uncertainty_value = abs(uncertainty_value)
        else:
            missing_uncertainty += 1
            uncertainty_value = math.nan
        dates.append(date_value)
        displacement.append(displacement_value)
        uncertainty.append(uncertainty_value)

    if not dates:
        die(f"no valid observations in {path}")

    order = sorted(range(len(dates)), key=dates.__getitem__)
    return {
        "label": path.stem.removeprefix("time_series_"),
        "longitude": longitude,
        "latitude": latitude,
        "dates": [dates[index] for index in order],
        "displacement": [displacement[index] for index in order],
        "uncertainty": [uncertainty[index] for index in order],
        "total_records": total_records,
        "missing_displacement": missing_displacement,
        "missing_uncertainty": missing_uncertainty,
    }


def style_time_axis(axis: plt.Axes) -> None:
    locator = mdates.AutoDateLocator(minticks=5, maxticks=10)
    axis.xaxis.set_major_locator(locator)
    axis.xaxis.set_major_formatter(mdates.ConciseDateFormatter(locator))
    axis.grid(True, color="0.85", linewidth=0.7, linestyle="--")
    axis.set_xlabel("Date")
    axis.set_ylabel("LOS displacement (mm)")


def mark_event(axis: plt.Axes, event_date: datetime, event_label: str) -> None:
    axis.axvline(
        event_date,
        color="black",
        linewidth=1.2,
        linestyle="--",
        label=f"{event_label}: {event_date:%Y-%m-%d}",
        zorder=2,
    )


def save_figure(
    figure: plt.Figure, base: Path, dpi: int, save_pdf: bool
) -> None:
    figure.savefig(base.with_suffix(".png"), dpi=dpi, bbox_inches="tight")
    if save_pdf:
        figure.savefig(base.with_suffix(".pdf"), bbox_inches="tight")
    plt.close(figure)


def plot_individual(
    series: dict[str, object], output_dir: Path, event_date: datetime,
    event_label: str, color: object, dpi: int, save_pdf: bool
) -> None:
    figure, axis = plt.subplots(figsize=(9.0, 5.0), constrained_layout=True)
    axis.plot(
        series["dates"], series["displacement"], "o-",
        color=color, linewidth=1.3, markersize=3.8,
        label=str(series["label"]), zorder=3,
    )
    error_rows = [
        index for index, value in enumerate(series["uncertainty"])
        if math.isfinite(value)
    ]
    if error_rows:
        axis.errorbar(
            [series["dates"][index] for index in error_rows],
            [series["displacement"][index] for index in error_rows],
            yerr=[series["uncertainty"][index] for index in error_rows],
            fmt="none", ecolor=color, elinewidth=0.9,
            capsize=3.5, capthick=0.9, zorder=2,
        )
    mark_event(axis, event_date, event_label)
    style_time_axis(axis)
    axis.set_title(
        f'{series["label"]}  '
        f'({series["longitude"]:.6f}°E, {series["latitude"]:.6f}°N)'
    )
    axis.legend(loc="best", frameon=True)
    save_figure(
        figure, output_dir / f'time_series_{series["label"]}', dpi, save_pdf
    )


def plot_combined(
    all_series: list[dict[str, object]], output_dir: Path,
    event_date: datetime, event_label: str, dpi: int, save_pdf: bool
) -> None:
    figure, axis = plt.subplots(figsize=(11.0, 6.2), constrained_layout=True)
    colors = plt.get_cmap("tab20")
    for index, series in enumerate(all_series):
        color = colors(index % 20)
        axis.plot(
            series["dates"], series["displacement"], "o-",
            color=color, linewidth=1.15, markersize=3.0,
            label=str(series["label"]), zorder=3,
        )
        error_rows = [
            row for row, value in enumerate(series["uncertainty"])
            if math.isfinite(value)
        ]
        if error_rows:
            axis.errorbar(
                [series["dates"][row] for row in error_rows],
                [series["displacement"][row] for row in error_rows],
                yerr=[series["uncertainty"][row] for row in error_rows],
                fmt="none", ecolor=color, elinewidth=0.65,
                capsize=2.5, capthick=0.65, zorder=2,
            )
    mark_event(axis, event_date, event_label)
    style_time_axis(axis)
    axis.set_title("LT-1 SBAS displacement time series")
    column_count = 1 if len(all_series) <= 8 else 2
    axis.legend(loc="best", ncol=column_count, fontsize=8, frameon=True)
    save_figure(figure, output_dir / "time_series_all", dpi, save_pdf)


def main() -> None:
    args = parse_args()
    if args.dpi <= 0:
        die("--dpi must be a positive integer")

    root = Path.cwd().resolve()
    if root.name not in {"Ascending", "Descending"}:
        die(f"run in an LT-1 Ascending or Descending directory (current: {root})")

    branch = "LT1"
    input_dir = root / "sbas_detrend" / "run4.5_time_series"
    if not input_dir.is_dir():
        die(f"Run 4.5 output directory does not exist: {input_dir}")

    series_files = sorted(input_dir.glob("time_series_*.dat"))
    if not series_files:
        die(f"no time_series_<label>.dat files found in {input_dir}")

    run45 = read_key_values(input_dir / "run4.5_complete")
    event_date_text = (
        args.event_date
        or os.environ.get("LANDSLIDE_DATE")
        or run45.get("landslide_date")
        or DEFAULT_EVENT_DATE
    )
    event_label = (
        args.event_label
        or os.environ.get("LANDSLIDE_LABEL")
        or run45.get("landslide_label")
        or DEFAULT_EVENT_LABEL
    )
    try:
        event_date = datetime.strptime(event_date_text, "%Y-%m-%d")
    except ValueError:
        die(f"invalid event date (use YYYY-MM-DD): {event_date_text}")

    output_dir = input_dir.parent / "run4.6_python_time_series"
    output_dir.mkdir(parents=True, exist_ok=True)
    all_series = [read_series(path) for path in series_files]

    print("=" * 56)
    print("Run 4.6: plot LT-1 SBAS time series with Python")
    print(f"Track root       : {root}")
    print(f"SBAS branch      : {branch}")
    print(f"Input directory  : {input_dir}")
    print(f"Point count      : {len(all_series)}")
    print(f"Landslide marker : {event_date_text} ({event_label})")
    print(f"Output formats   : PNG{' + PDF' if args.pdf else ' only'}")
    print(f"Output directory : {output_dir}")
    print("=" * 56)

    colors = plt.get_cmap("tab20")
    if len(all_series) == 1:
        # A one-point combined figure would duplicate the individual figure.
        # Draw and save this point only once.
        series = all_series[0]
        print("[PLOT] Single-point mode: draw once; skip duplicate overview")
        plot_individual(
            series, output_dir, event_date, event_label, colors(0), args.dpi, args.pdf
        )
        print(
            f'  [PLOT] {series["label"]}: records={series["total_records"]}, '
            f'valid_displacement={len(series["dates"])}, '
            f'missing_displacement={series["missing_displacement"]}, '
            f'missing_uncertainty={series["missing_uncertainty"]}'
        )
        plot_mode = "single_once"
        primary_base = output_dir / f'time_series_{series["label"]}'
        combined_pdf = ""
        combined_png = ""
    else:
        if args.individual:
            print("[STEP 1] Draw every point separately")
            for index, series in enumerate(all_series):
                plot_individual(
                    series, output_dir, event_date, event_label,
                    colors(index % 20), args.dpi, args.pdf
                )
                print(
                    f'  [PLOT] {series["label"]}: records={series["total_records"]}, '
                    f'valid_displacement={len(series["dates"])}, '
                    f'missing_displacement={series["missing_displacement"]}, '
                    f'missing_uncertainty={series["missing_uncertainty"]}'
                )
            print("[STEP 2] Draw all point time series together")
        else:
            print("[PLOT] Fast overview mode: skip individual point figures")
        plot_combined(
            all_series, output_dir, event_date, event_label, args.dpi, args.pdf
        )
        plot_mode = "individual_and_combined" if args.individual else "combined_only"
        primary_base = output_dir / "time_series_all"
        combined_png = str(output_dir / "time_series_all.png")
        combined_pdf = str(output_dir / "time_series_all.pdf") if args.pdf else ""

    manifest = output_dir / "run4.6_complete"
    manifest.write_text(
        "status=COMPLETE\n"
        f"branch={branch}\n"
        f"input_directory={input_dir}\n"
        f"point_count={len(all_series)}\n"
        f"plot_mode={plot_mode}\n"
        f"formats=png{'/pdf' if args.pdf else ''}\n"
        f"landslide_date={event_date_text}\n"
        f"landslide_label={event_label}\n"
        f"primary_png={primary_base.with_suffix('.png')}\n"
        f"primary_pdf={primary_base.with_suffix('.pdf') if args.pdf else ''}\n"
        f"combined_pdf={combined_pdf}\n"
        f"combined_png={combined_png}\n",
        encoding="utf-8",
    )
    print("=" * 56)
    print("[DONE] Python time-series plots completed.")
    if len(all_series) == 1:
        print(f"Single plot      : {primary_base.with_suffix('.png')}")
    else:
        if args.individual:
            print(f"Individual plots : {output_dir}/time_series_<label>.png")
        print(f"Combined plot    : {output_dir}/time_series_all.png")
    if args.pdf:
        print("PDF output       : enabled")
    print("=" * 56)


if __name__ == "__main__":
    main()
