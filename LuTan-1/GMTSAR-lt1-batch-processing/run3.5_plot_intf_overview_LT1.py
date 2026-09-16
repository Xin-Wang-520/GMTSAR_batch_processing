#!/usr/bin/env python3
"""Plot three date-sorted contact sheets from GMTSAR intf_all products.

Run from Ascending/ or Descending/:
    python3 run3.5_plot_intf_overview_LT1.py
    python3 run3.5_plot_intf_overview_LT1.py --cols 5 --dpi 200

Dependencies: numpy matplotlib xarray scipy h5netcdf h5py
Input grids are read-only. Missing/bad grids appear as labeled empty panels.
GMT seven-digit directory IDs use zero-based day-of-year by default.
"""

import argparse
import datetime as dt
import math
from pathlib import Path
import re
import sys


def arguments():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--input', type=Path, default=Path('intf_all'), help='Input directory (default: intf_all)')
    parser.add_argument('--output', type=Path, help='Output directory (default: intf_all_overview)')
    parser.add_argument('--cols', type=int, default=5, help='Panels per row (default: 5)')
    parser.add_argument('--dpi', type=int, default=180)
    parser.add_argument('--max-pixels', type=int, default=600, help='Maximum samples per grid axis for display only')
    parser.add_argument('--amp-percentile', type=float, default=98, help='Shared amplitude upper color limit percentile')
    parser.add_argument('--pdf', action='store_true', help='Also save PDF versions (PNG is always saved)')
    parser.add_argument('--day-origin', type=int, choices=(0, 1), default=0, help='Day-of-year origin in seven-digit directory IDs')
    args = parser.parse_args()
    if args.cols < 1 or args.dpi < 1 or args.max_pixels < 2 or not 0 < args.amp_percentile <= 100:
        parser.error('cols/dpi must be positive, max-pixels >= 2, and amp-percentile in (0,100]')
    return args


def pair_dates(name, day_origin):
    tokens = re.findall(r'(?<!\d)(\d{8}|\d{7})(?!\d)', name)
    if len(tokens) != 2:
        raise ValueError('expected two YYYYMMDD or YYYYDDD date IDs')
    dates = []
    for token in tokens:
        if len(token) == 8:
            dates.append(dt.datetime.strptime(token, '%Y%m%d').date())
        else:
            year, day = int(token[:4]), int(token[4:]) - day_origin
            date = dt.date(year, 1, 1) + dt.timedelta(days=day)
            if day < 0 or date.year != year:
                raise ValueError('day-of-year outside the year')
            dates.append(date)
    return tuple(dates)


def read_grid(path, max_pixels):
    """Read modern NetCDF and GMT classic flattened grids, without modifying them."""
    with xr.open_dataset(path, decode_times=False) as ds:
        if 'dimension' in ds and 'z' in ds and ds['z'].ndim == 1:
            # GMT classic stores flattened rows from north to south.
            nx, ny = (int(v) for v in ds['dimension'].values)
            sx, sy = max(1, math.ceil(nx/max_pixels)), max(1, math.ceil(ny/max_pixels))
            indices = (np.arange(0, ny, sy)[:, None]*nx + np.arange(0, nx, sx)).ravel()
            values = ds['z'].isel({ds['z'].dims[0]: indices}).values
            data = values.reshape(len(range(0, ny, sy)), len(range(0, nx, sx)))[::-1]
            extent = (*ds['x_range'].values, *ds['y_range'].values)
        else:
            candidates = [v for v in ds.data_vars.values() if v.ndim == 2]
            if not candidates:
                raise ValueError('no 2-D grid found')
            grid = ds['z'] if 'z' in ds and ds['z'].ndim == 2 else candidates[0]
            # GMT normally stores (y,x), but also accept transposed grids.
            if grid.dims[0].lower() in ('x', 'lon', 'longitude'):
                grid = grid.transpose()
            yd, xd = grid.dims
            ny, nx = grid.shape
            x = np.asarray(grid[xd].values) if xd in grid.coords else np.arange(nx)
            y = np.asarray(grid[yd].values) if yd in grid.coords else np.arange(ny)
            if x.ndim != 1 or y.ndim != 1 or nx < 2 or ny < 2:
                raise ValueError('expected a rectangular grid with 1-D coordinates')
            extent = (float(np.min(x)), float(np.max(x)), float(np.min(y)), float(np.max(y)))
            data = grid.isel({yd: slice(None, None, max(1, math.ceil(ny/max_pixels))),
                              xd: slice(None, None, max(1, math.ceil(nx/max_pixels)))}).values
            if y[0] > y[-1]:
                data = data[::-1]
            if x[0] > x[-1]:
                data = data[:, ::-1]
        data = np.array(data, dtype=np.float32, copy=True)
        data[~np.isfinite(data)] = np.nan
        if not np.isfinite(data).any():
            raise ValueError('grid contains no finite values')
        return data, extent


def main(args):
    source = args.input.resolve()
    if not source.is_dir():
        raise ValueError(f'input directory not found: {source}')
    pairs = []
    for directory in source.iterdir():
        if not directory.is_dir():
            continue
        try:
            dates = pair_dates(directory.name, args.day_origin)
        except ValueError:
            print(f'[SKIP] Unrecognized pair directory: {directory.name}')
            continue
        pairs.append((dates, directory))
    pairs.sort(key=lambda item: (*item[0], item[1].name))
    if not pairs:
        raise ValueError('no date-named interferogram directories found')
    output = (args.output or Path('intf_all_overview')).resolve()
    output.mkdir(parents=True, exist_ok=True)
    print(f'[INPUT] {source}\n[PAIRS] {len(pairs)}\n[OUTPUT] {output}', flush=True)
    report = [f'Input: {source}', f'Directory day-of-year origin: {args.day_origin}',
              f'Display sampling: at most {args.max_pixels} pixels per axis; original grids unchanged.',
              'Amplitude uses a shared linear scale, not per-panel histogram equalization.']
    total_valid = 0
    for filename, title, cmap, limits, color_label in (
        ('corr.grd', 'Correlation', 'gray', (0, 1), 'Correlation'),
        ('display_amp.grd', 'Display amplitude', 'gray', None, 'Relative display amplitude'),
        ('phasefilt.grd', 'Filtered phase', 'hsv', (-math.pi, math.pi), 'Phase (rad)'),
    ):
        grids = []
        for dates, directory in pairs:
            try:
                grids.append(read_grid(directory/filename, args.max_pixels))
            except Exception as exc:
                grids.append(None)
                report.append(f'{directory.name}/{filename}: {exc}')
                print(f'[WARNING] {directory.name}/{filename}: {exc}', flush=True)
        valid = sum(grid is not None for grid in grids)
        total_valid += valid
        if limits is None:
            samples = [g[0][np.isfinite(g[0])][::max(1, g[0].size//10000)] for g in grids if g is not None]
            upper = float(np.percentile(np.concatenate(samples), args.amp_percentile)) if samples else 1
            limits = (0, upper if upper > 0 else 1)
        report.append(f'{filename}: valid={valid}/{len(pairs)}, color limits={limits}')
        cols = min(args.cols, len(pairs))
        rows = math.ceil(len(pairs)/cols)
        fig, axes = plt.subplots(rows, cols, figsize=(3.5*cols+0.6, 3.2*rows+0.7), squeeze=False,
                                 layout='constrained')
        fig.suptitle(f'{title} | {source.parent.name} | {len(pairs)} pairs', fontsize=15)
        palette = plt.get_cmap(cmap).copy()
        palette.set_bad('#dedede')
        for index, ((dates, directory), grid) in enumerate(zip(pairs, grids)):
            ax = axes.flat[index]
            ax.set_title(f'{dates[0]:%Y-%m-%d} / {dates[1]:%Y-%m-%d}', fontsize=9)
            if grid is None:
                ax.text(0.5, 0.5, 'Missing / unreadable grid', ha='center', va='center', transform=ax.transAxes, fontsize=8)
                ax.set_facecolor('#eeeeee')
                ax.set_xticks([])
                ax.set_yticks([])
            else:
                data, extent = grid
                ax.imshow(data, extent=extent, origin='lower', aspect='auto', cmap=palette,
                          vmin=limits[0], vmax=limits[1], interpolation='nearest', rasterized=True)
                ax.tick_params(labelsize=7)
            if index % cols == 0:
                ax.set_ylabel('Azimuth', fontsize=8)
            if index // cols == rows-1:
                ax.set_xlabel('Range', fontsize=8)
        for ax in list(axes.flat)[len(pairs):]:
            ax.set_visible(False)
        scalar = plt.cm.ScalarMappable(norm=plt.Normalize(*limits), cmap=palette)
        colorbar = fig.colorbar(scalar, ax=list(axes.flat)[:len(pairs)], shrink=0.7, pad=0.015, fraction=0.02)
        colorbar.set_label(color_label)
        if filename == 'phasefilt.grd':
            colorbar.set_ticks([-math.pi, 0, math.pi], labels=['−π', '0', 'π'])
        stem = Path(filename).stem + '_overview'
        fig.savefig(output/(stem+'.png'), dpi=args.dpi)
        if args.pdf:
            fig.savefig(output/(stem+'.pdf'), dpi=args.dpi)
        plt.close(fig)
        print(f'[SAVED] {stem}.png ({valid}/{len(pairs)} readable grids)', flush=True)
    (output/'plot_report.txt').write_text('\n'.join(report)+'\n', encoding='utf-8')
    if not total_valid:
        raise ValueError(f'no grids could be read; inspect {output}/plot_report.txt')
    print(f'[SUCCESS] Three overview figures saved in {output}')


if __name__ == '__main__':
    args = arguments()
    try:
        import numpy as np
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import xarray as xr
    except ImportError as exc:
        sys.exit(f'[ERROR] {exc}\nInstall dependencies: python3 -m pip install numpy matplotlib xarray scipy h5netcdf h5py')
    try:
        main(args)
    except Exception as exc:
        sys.exit(f'[ERROR] {exc}')
