#!/usr/bin/env python3
"""Select a geographic rectangle and preview a radar-space unwrapping region.

Example (run from Ascending/ or Descending/):
  python3 run3.7_preview_unwrap_region_LT1.py --master 20250423 \
      --upper-left 118.75 30.07 --lower-right 118.87 29.97

Uses Python's standard library and installed GMTSAR/GMT commands.
Only preview products are written; no unwrapping or config changes occur.
Coordinates use the cropped master PRM in SLC/, not the full raw PRM.
"""
import argparse
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys


def run(command, cwd, content=None):
    result = subprocess.run(command, cwd=cwd, input=content, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{' '.join(command)}\n{result.stderr}\n{result.stdout}")
    return result.stdout


def grid_info(path, cwd):
    fields = run(['gmt', 'grdinfo', str(path), '-Cn'], cwd).split()
    values = [float(v) for v in fields[:10]]
    if len(values) != 10 or not all(math.isfinite(v) for v in values):
        raise ValueError(f'Invalid grdinfo output: {path}')
    return values


def region_text(bounds):
    return '/'.join(f'{v:.12g}' for v in bounds)


def plot(grid, bounds, output, stem, title, cpt, box=None):
    region = '-R' + region_text(bounds)
    projection = '-JX16c/14c'
    ps = run(['gmt', 'grdimage', str(grid), region, projection, '-C'+str(cpt),
              '-Bxa+lRange', '-Bya+lAzimuth', '-BWSen+t'+title, '-Y4c', '-P', '-K'], output)
    if box:
        w, e, s, n = box
        polygon = f'{w} {s}\n{e} {s}\n{e} {n}\n{w} {n}\n{w} {s}\n'
        ps += run(['gmt', 'psxy', region, projection, '-W2p,black', '-O', '-K'], output, polygon)
    ps += run(['gmt', 'psscale', region, projection, '-C'+str(cpt),
               '-DJBC+w12c/0.35c+h+o0c/2c', '-Bxa1.57+lPhase (rad)', '-O'], output)
    ps_path = output/(stem+'.ps')
    ps_path.write_text(ps)
    run(['gmt', 'psconvert', ps_path.name, '-Tg', '-A', '-E150'], output)
    if not (output/(stem+'.png')).is_file():
        raise RuntimeError(f'PNG was not produced for {stem}')
    ps_path.unlink()


def main(args):
    root = Path.cwd().resolve()
    if not re.fullmatch(r'\d{8}', args.master):
        raise ValueError('--master must be YYYYMMDD')
    west, north = args.upper_left
    east, south = args.lower_right
    if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
        raise ValueError('Expected upper-left west/north and lower-right east/south')
    if not math.isfinite(args.margin) or args.margin < 0:
        raise ValueError('--margin must be a nonnegative radar-coordinate distance')
    for tool in ('gmt', 'SAT_llt2rat'):
        if not shutil.which(tool):
            raise ValueError(f'{tool} was not found in PATH')
    slc = root/'SLC'
    prm = slc/f'LT1_{args.master}.PRM'
    dem = root/'topo/dem.grd'
    pair_root = root/'intf_all'
    if not pair_root.is_dir():
        raise ValueError('intf_all/ not found')
    pairs = sorted(p for p in pair_root.iterdir() if p.is_dir() and re.fullmatch(r'\d{7}_\d{7}|\d{8}_\d{8}', p.name))
    if not pairs:
        raise ValueError('No date-named interferogram directories found')
    pair = pairs[0]
    phase = pair/'phasefilt.grd'
    cpt = pair/'phase.cpt'
    for path in (prm, dem, phase, cpt):
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing or empty input: {path}')
    params = dict(re.findall(r'^\s*(\w+)\s*=\s*(\S+)', prm.read_text(), re.M))
    led = Path(params.get('led_file', f'LT1_{args.master}.LED'))
    if not led.is_absolute():
        led = slc/led
    if not led.is_file():
        raise ValueError(f'Master orbit is not readable: {led}')
    full = grid_info(phase, root)
    nr, na = float(params['num_rng_bins']), float(params['num_lines'])
    if not (abs(full[0]) < 1e-6 and abs(full[2]) < 1e-6 and abs(full[1]-nr) < 1e-6 and abs(full[3]-na) < 1e-6):
        raise ValueError('phasefilt extent does not match the cropped master PRM; check Run 3.1/3.4 products')
    output = root/'run3.7_unwrap_roi'
    output.mkdir(exist_ok=True)
    print(f'[PAIR] {pair.name}\n[MASTER] {prm}\n[OUTPUT] {output}', flush=True)
    # Sample the whole rectangle, including all edges, to account for terrain
    # and nonlinear mapping. The result is an enclosing radar rectangle.
    points = ''.join(f'{west+(east-west)*i/20:.10f} {south+(north-south)*j/20:.10f}\n'
                     for j in range(21) for i in range(21))
    (output/'roi_lonlat.txt').write_text(points)
    heights = run(['gmt', 'grdtrack', '-G'+str(dem)], output, points)
    rows = [line.split() for line in heights.splitlines() if line.strip()]
    if len(rows) != 441 or any(len(r) < 3 or not all(math.isfinite(float(v)) for v in r[:3]) for r in rows):
        raise ValueError('DEM does not provide a valid height for every ROI sample')
    ratll = run(['SAT_llt2rat', prm.name, '1'], slc, heights)
    (output/'roi.ratll').write_text(ratll)
    radar = [list(map(float, line.split())) for line in ratll.splitlines() if line.strip()]
    if len(radar) != 441 or any(len(row) < 5 or not all(math.isfinite(v) for v in row) for row in radar):
        raise ValueError('Incomplete or invalid geographic-to-radar conversion')
    raw = [min(r[0] for r in radar), max(r[0] for r in radar), min(r[1] for r in radar), max(r[1] for r in radar)]
    requested = [raw[0]-args.margin, raw[1]+args.margin, raw[2]-args.margin, raw[3]+args.margin]
    # Round outward to actual phase grid boundaries (including decimated grids).
    snapped = [full[0]+math.floor((requested[0]-full[0])/full[6])*full[6],
               full[0]+math.ceil((requested[1]-full[0])/full[6])*full[6],
               full[2]+math.floor((requested[2]-full[2])/full[7])*full[7],
               full[2]+math.ceil((requested[3]-full[2])/full[7])*full[7]]
    crop = [max(full[0], snapped[0]), min(full[1], snapped[1]), max(full[2], snapped[2]), min(full[3], snapped[3])]
    if crop[0] >= crop[1] or crop[2] >= crop[3]:
        raise ValueError('ROI does not overlap the phase grid')
    if crop != snapped:
        print('[WARNING] ROI extends outside phase coverage; clipped to the available extent.')
    cropped = output/'phasefilt_roi.grd'
    run(['gmt', 'grdcut', str(phase), '-R'+region_text(crop), '-G'+str(cropped)], output)
    actual = grid_info(cropped, output)
    region = region_text(actual[:4])
    info = run(['gmt', 'grdinfo', str(cropped)], output)
    print(info, end='')
    nx, ny = int(actual[8]), int(actual[9])
    total, original = nx*ny, int(full[8])*int(full[9])
    lines = [f'Pair: {pair.name}', f'Master PRM: {prm}', f'Upper left: {west} {north}',
             f'Lower right: {east} {south}', f'Full radar region: {region_text(full[:4])}',
             f'Geographic ROI radar bounds: {region_text(raw)}', f'Margin: {args.margin}',
             f'Snaphu radar region: {region}', f'Grid size: {nx} x {ny}',
             f'Grid points: {total} (includes NaN/masked cells)', f'Original grid points: {original}',
             f'Retained: {100*total/original:.2f}%',
             'The radar rectangle encloses the sampled geographic ROI; its footprint is not an exact geographic rectangle.',
             'No unwrapping has been run. Use this range only for grids sharing the same radar coordinates.']
    (output/'radar_region.txt').write_text(region+'\n')
    (output/'region_report.txt').write_text('\n'.join(lines)+'\n\n'+info)
    print('\n'.join(lines), flush=True)
    plot(phase, full[:4], output, 'phasefilt_full_roi', f'{pair.name}: selected radar ROI', cpt, actual[:4])
    plot(cropped, actual[:4], output, 'phasefilt_roi', f'{pair.name}: {nx} x {ny} = {total} grid points', cpt)
    print(f'[SUCCESS] {output}/phasefilt_roi.png')
    print(f'[REGION] {region}')
    print(f'[LATER] In the interferogram directory: snaphu.csh <threshold> <defomax> {region}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--master', required=True, help='Stack master date YYYYMMDD')
    parser.add_argument('--upper-left', nargs=2, type=float, required=True, metavar=('LON', 'LAT'))
    parser.add_argument('--lower-right', nargs=2, type=float, required=True, metavar=('LON', 'LAT'))
    parser.add_argument('--margin', type=float, default=0, help='Extra margin in radar coordinates (default: 0)')
    if len(sys.argv) == 1:
        parser.print_help()
        sys.exit(0)
    try:
        main(parser.parse_args())
    except (ValueError, RuntimeError, OSError, KeyError) as exc:
        sys.exit(f'[ERROR] {exc}')
