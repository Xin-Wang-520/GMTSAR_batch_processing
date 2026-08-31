#!/usr/bin/env bash
#
# Self-contained fast replacement for GMTSAR snaphu_interp.csh.
#
# The embedded Python implementation reproduces GMTSAR nearest_grid.c:
#   - identical nearest-neighbour distance
#   - identical equidistant-candidate order
#   - identical radius-boundary behavior
#   - identical z values and NaN extent
#
# No external nearest_grid Python file is required.
#
# Modified by : Xin Wang
# Affiliation : University of Science and Technology of China (USTC)
#               Hefei, China
# Updated     : 2026-07-29
#

set -euo pipefail

usage()
{
    cat <<'EOF'

Usage:

  snaphu_interp_fast_combined.sh \
      correlation_threshold maximum_discontinuity \
      [rng0/rngf/azi0/azif]

Example:

  ./snaphu_interp_fast_combined.sh 0.1 0

Nearest-grid validation mode:

  ./snaphu_interp_fast_combined.sh \
      --nearest-only input.grd output.grd search_radius

Python selection:

  The script uses $NEAREST_GRID_PYTHON when it is defined;
  otherwise it uses python3.

  Example:

      export NEAREST_GRID_PYTHON=/path/to/conda/env/bin/python

Required Python packages:

  numpy scipy netCDF4

EOF
}

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

python_cmd="${NEAREST_GRID_PYTHON:-python3}"

command -v "$python_cmd" >/dev/null 2>&1 ||
    die "Python command not found: $python_cmd"

"$python_cmd" -c 'import numpy, scipy, netCDF4' >/dev/null 2>&1 ||
    die "$python_cmd must provide numpy, scipy, and netCDF4"

nearest_grid_c_exact()
{
    local input_grid="$1"
    local output_grid="$2"
    local search_radius="$3"

    "$python_cmd" - "$input_grid" "$output_grid" "$search_radius" <<'PYTHON'
from __future__ import annotations

import math
import os
import shutil
import sys
import time
from pathlib import Path

import numpy as np
from netCDF4 import Dataset
from scipy.ndimage import distance_transform_edt


class FillError(RuntimeError):
    pass


def find_grid_variable(dataset):
    if "z" in dataset.variables and dataset.variables["z"].ndim == 2:
        return "z"
    candidates = [
        name
        for name, variable in dataset.variables.items()
        if variable.ndim == 2
        and np.issubdtype(variable.dtype, np.number)
    ]
    if len(candidates) != 1:
        found = ", ".join(candidates) if candidates else "none"
        raise FillError(
            f"cannot uniquely identify a 2-D grid variable; found: {found}"
        )
    return candidates[0]


def c_ring_offsets(distance_squared):
    if distance_squared <= 0:
        return ()

    offsets = []
    maximum_x = math.isqrt(distance_squared)
    minimum_x = math.isqrt(distance_squared // 2)

    for x_offset in range(minimum_x, maximum_x + 1):
        y_squared = distance_squared - x_offset * x_offset
        if y_squared < 0:
            continue

        y_offset = math.isqrt(y_squared)
        if y_offset * y_offset != y_squared or y_offset > x_offset:
            continue

        # GMT's in-memory row direction is opposite to the CF/NetCDF
        # variable direction read by netCDF4.  Row signs are reversed
        # relative to is[] in nearest_grid.c; column signs are unchanged.
        if y_offset == 0:
            offsets.extend(
                (
                    (-x_offset, 0),
                    (x_offset, 0),
                    (0, x_offset),
                    (0, -x_offset),
                )
            )
        elif x_offset != y_offset:
            offsets.extend(
                (
                    (-x_offset, y_offset),
                    (x_offset, y_offset),
                    (-x_offset, -y_offset),
                    (x_offset, -y_offset),
                    (-y_offset, x_offset),
                    (-y_offset, -x_offset),
                    (y_offset, x_offset),
                    (y_offset, -x_offset),
                )
            )
        else:
            offsets.extend(
                (
                    (-x_offset, x_offset),
                    (x_offset, x_offset),
                    (-x_offset, -x_offset),
                    (x_offset, -x_offset),
                )
            )

    if not offsets:
        raise FillError(
            f"no integer offsets for squared distance {distance_squared}"
        )
    return tuple(offsets)


def fill_group(source, output, rows, columns, offsets):
    unresolved = np.ones(rows.size, dtype=bool)
    n_rows, n_columns = source.shape
    filled = 0

    for row_offset, column_offset in offsets:
        if not np.any(unresolved):
            break

        candidate_rows = rows + row_offset
        candidate_columns = columns + column_offset
        inside = (
            unresolved
            & (candidate_rows >= 0)
            & (candidate_rows < n_rows)
            & (candidate_columns >= 0)
            & (candidate_columns < n_columns)
        )
        if not np.any(inside):
            continue

        inside_indices = np.flatnonzero(inside)
        valid_indices = inside_indices[
            ~np.isnan(
                source[
                    candidate_rows[inside_indices],
                    candidate_columns[inside_indices],
                ]
            )
        ]
        if valid_indices.size == 0:
            continue

        output[rows[valid_indices], columns[valid_indices]] = source[
            candidate_rows[valid_indices],
            candidate_columns[valid_indices],
        ]
        unresolved[valid_indices] = False
        filled += int(valid_indices.size)

    if np.any(unresolved):
        raise FillError(
            "distance-transform result had no valid candidate; "
            f"unresolved={int(np.count_nonzero(unresolved))}"
        )
    return filled


def reproduce_c_nearest(data, radius, block_rows=512):
    if data.ndim != 2:
        raise FillError(f"only 2-D grids are supported; ndim={data.ndim}")
    if radius < 0:
        raise FillError("search radius cannot be negative")

    invalid = np.isnan(data)
    invalid_count = int(np.count_nonzero(invalid))
    if invalid_count == data.size:
        raise FillError("input grid has no non-NaN samples")
    if invalid_count == 0:
        return data.copy(), 0, 0

    distances = distance_transform_edt(invalid)
    maximum_distance_squared = (
        None if radius == 0 else radius * radius + 1
    )

    output = data.copy()
    filled_count = 0
    ring_cache = {}

    for row0 in range(0, data.shape[0], block_rows):
        row1 = min(row0 + block_rows, data.shape[0])
        block_invalid = invalid[row0:row1]
        if not np.any(block_invalid):
            continue

        block_distance_squared = np.rint(
            distances[row0:row1] * distances[row0:row1]
        ).astype(np.int64)

        fillable = block_invalid.copy()
        if maximum_distance_squared is not None:
            fillable &= (
                block_distance_squared <= maximum_distance_squared
            )
        if not np.any(fillable):
            continue

        local_rows, columns = np.nonzero(fillable)
        rows = local_rows + row0
        keys = block_distance_squared[local_rows, columns]

        order = np.argsort(keys, kind="stable")
        rows = rows[order]
        columns = columns[order]
        keys = keys[order]

        starts = np.r_[0, np.flatnonzero(keys[1:] != keys[:-1]) + 1]
        ends = np.r_[starts[1:], keys.size]

        for start, end in zip(starts, ends):
            distance_squared = int(keys[start])
            offsets = ring_cache.get(distance_squared)
            if offsets is None:
                offsets = c_ring_offsets(distance_squared)
                ring_cache[distance_squared] = offsets

            filled_count += fill_group(
                data,
                output,
                rows[start:end],
                columns[start:end],
                offsets,
            )

    return output, invalid_count, filled_count


def main():
    if len(sys.argv) != 4:
        raise FillError(
            "embedded nearest grid expects input output radius"
        )

    input_path = Path(sys.argv[1]).resolve()
    output_path = Path(sys.argv[2]).resolve()
    try:
        radius = int(sys.argv[3])
    except ValueError as exc:
        raise FillError(f"invalid integer radius: {sys.argv[3]}") from exc

    if not input_path.is_file():
        raise FillError(f"input grid does not exist: {input_path}")
    if input_path == output_path:
        raise FillError("input and output paths must differ")

    started = time.perf_counter()
    with Dataset(input_path, "r") as source_dataset:
        grid_name = find_grid_variable(source_dataset)
        raw = source_dataset.variables[grid_name][:]
        if np.ma.isMaskedArray(raw):
            data = np.asarray(raw.filled(np.nan))
        else:
            data = np.asarray(raw).copy()

    output, invalid_count, filled_count = reproduce_c_nearest(
        data, radius
    )

    temporary_path = output_path.with_name(
        f".{output_path.name}.tmp-{os.getpid()}"
    )
    try:
        if temporary_path.exists():
            temporary_path.unlink()
        shutil.copy2(input_path, temporary_path)
        with Dataset(temporary_path, "r+") as target_dataset:
            target_dataset.variables[grid_name][:] = output
        os.replace(temporary_path, output_path)
    except Exception:
        if temporary_path.exists():
            temporary_path.unlink()
        raise

    elapsed = time.perf_counter() - started
    print(
        "C-exact nearest-neighbour grid written: "
        f"{output_path} "
        f"(radius={radius}, input_nan={invalid_count}, "
        f"filled={filled_count}, elapsed={elapsed:.2f}s)",
        flush=True,
    )


try:
    main()
except FillError as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    sys.exit(1)
PYTHON
}

if [[ "${1:-}" == "--nearest-only" ]]; then
    [[ $# -eq 4 ]] || {
        usage
        exit 1
    }

    input_grid="$2"
    output_grid="$3"
    search_radius="$4"

    [[ "$search_radius" =~ ^[0-9]+$ ]] ||
        die "search_radius must be a non-negative integer"

    rm -f "$output_grid"
    nearest_grid_c_exact "$input_grid" "$output_grid" "$search_radius"
    exit 0
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage
    exit 1
fi

correlation_threshold="$1"
maximum_discontinuity="$2"
radar_region="${3:-}"

[[ "$correlation_threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    die "invalid correlation threshold: $correlation_threshold"
[[ "$maximum_discontinuity" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    die "invalid maximum discontinuity: $maximum_discontinuity"

for command_name in \
    gmt \
    gmtsar_sharedir.csh \
    snaphu
do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "command not found: $command_name"
done

for input_file in phasefilt.grd corr.grd mask.grd; do
    [[ -s "$input_file" ]] ||
        die "missing input: $(pwd)/$input_file"
done

rm -f \
    mask_patch.grd \
    corr_patch.grd \
    phase_patch.grd \
    landmask_ra_patch.grd \
    mask_def_patch.grd \
    mask2_patch.grd \
    corr_tmp.grd \
    phase_tmp.grd \
    tmp.grd \
    phase.in \
    corr.in \
    unwrap.out \
    conncomp.out \
    snaphu.conf.brief

if [[ -n "$radar_region" ]]; then
    gmt grdcut mask.grd -R"$radar_region" -Gmask_patch.grd
    gmt grdcut corr.grd -R"$radar_region" -Gcorr_patch.grd
    gmt grdcut phasefilt.grd -R"$radar_region" -Gphase_patch.grd
else
    ln -s mask.grd mask_patch.grd
    ln -s corr.grd corr_patch.grd
    ln -s phasefilt.grd phase_patch.grd
fi

if [[ -f landmask_ra.grd ]]; then
    increment_option="$(gmt grdinfo -I phase_patch.grd)"
    if [[ -n "$radar_region" ]]; then
        gmt grdsample landmask_ra.grd \
            -R"$radar_region" "$increment_option" \
            -Glandmask_ra_patch.grd
    else
        gmt grdsample landmask_ra.grd \
            "$increment_option" \
            -Glandmask_ra_patch.grd
    fi
    gmt grdmath \
        phase_patch.grd landmask_ra_patch.grd MUL \
        = phase_patch.grd
fi

if [[ -f mask_def.grd ]]; then
    if [[ -n "$radar_region" ]]; then
        gmt grdcut mask_def.grd \
            -R"$radar_region" \
            -Gmask_def_patch.grd
    else
        cp mask_def.grd mask_def_patch.grd
    fi
    gmt grdmath \
        corr_patch.grd mask_def_patch.grd MUL \
        = corr_patch.grd
fi

gmt grdmath \
    corr_patch.grd "$correlation_threshold" GE 0 NAN \
    mask_patch.grd MUL \
    = mask2_patch.grd

gmt grdmath \
    corr_patch.grd 0 XOR 1 MIN \
    = corr_patch.grd

gmt grdmath \
    mask2_patch.grd corr_patch.grd MUL \
    = corr_tmp.grd

gmt grdmath \
    mask2_patch.grd phase_patch.grd MUL \
    = phase_tmp.grd

echo "C-exact fast nearest-neighbour interpolation ..."
rm -f tmp.grd
nearest_grid_c_exact phase_tmp.grd tmp.grd 300
mv -f tmp.grd phase_tmp.grd

gmt grd2xyz phase_tmp.grd -ZTLf -do0 > phase.in
gmt grd2xyz corr_tmp.grd -ZTLf -do0 > corr.in

sharedir="$(gmtsar_sharedir.csh)"
grid_width="$(gmt grdinfo -C phase_patch.grd | cut -f 10)"

echo "Unwrapping phase with SNAPHU ..."
if awk -v x="$maximum_discontinuity" \
    'BEGIN {exit !(x == 0)}'
then
    snaphu phase.in "$grid_width" \
        -f "$sharedir/snaphu/config/snaphu.conf.brief" \
        -c corr.in \
        -o unwrap.out \
        -v -s \
        -g conncomp.out
else
    sed \
        "s/.*DEFOMAX_CYCLE.*/DEFOMAX_CYCLE  $maximum_discontinuity/g" \
        "$sharedir/snaphu/config/snaphu.conf.brief" \
        > snaphu.conf.brief

    snaphu phase.in "$grid_width" \
        -f snaphu.conf.brief \
        -c corr.in \
        -o unwrap.out \
        -v -d \
        -g conncomp.out
fi

gmt xyz2grd unwrap.out \
    -ZTLf -r \
    $(gmt grdinfo -I- phase_patch.grd) \
    $(gmt grdinfo -I phase_patch.grd) \
    -Gtmp.grd

gmt xyz2grd conncomp.out \
    -ZTLu -r \
    $(gmt grdinfo -I- phase_patch.grd) \
    $(gmt grdinfo -I phase_patch.grd) \
    -Gconncomp.grd

gmt grdmath tmp.grd mask2_patch.grd MUL = tmp.grd
mv -f tmp.grd unwrap.grd

if [[ -f landmask_ra.grd ]]; then
    gmt grdmath \
        unwrap.grd landmask_ra_patch.grd MUL \
        = tmp.grd
    mv -f tmp.grd unwrap.grd
fi

if [[ -f mask_def.grd ]]; then
    gmt grdmath \
        unwrap.grd mask_def_patch.grd MUL \
        = tmp.grd
    mv -f tmp.grd unwrap.grd
fi

gmt grdgradient unwrap.grd \
    -Nt.9 -A0 \
    -Gunwrap_grad.grd

read -r phase_mean phase_std < <(
    gmt grdinfo unwrap.grd -C -L2 |
        awk '{print $12, $13}'
)

limit_upper="$(
    awk -v mean="$phase_mean" -v std="$phase_std" \
        'BEGIN {printf "%.12g", mean + 2*std}'
)"
limit_lower="$(
    awk -v mean="$phase_mean" -v std="$phase_std" \
        'BEGIN {printf "%.12g", mean - 2*std}'
)"
gmt makecpt \
    -Cseis -I -Z \
    -T"$limit_lower/$limit_upper/1" \
    -D > unwrap.cpt

gmt grdimage unwrap.grd \
    -Iunwrap_grad.grd \
    -Cunwrap.cpt \
    -JX6.5i \
    -Bxaf+lRange \
    -Byaf+lAzimuth \
    -BWSen \
    -X1.3i -Y3i \
    -P -K > unwrap.ps

gmt psscale \
    -Runwrap.grd \
    -J \
    -DJTC+w5/0.2+h+e \
    -Cunwrap.cpt \
    -Bxaf+l"Unwrapped phase" \
    -By+lrad \
    -O >> unwrap.ps

gmt psconvert -Tf -P -A -Z unwrap.ps
echo "Unwrapped phase map: unwrap.pdf"

rm -f \
    tmp.grd \
    corr_tmp.grd \
    unwrap.out \
    tmp2.grd \
    unwrap_grad.grd \
    phase_tmp.grd \
    conncomp.out \
    phase.in \
    corr.in

mv -f phase_patch.grd phasefilt_interp.grd

if [[ -n "$radar_region" ]]; then
    mv -f corr_patch.grd corr_cut.grd
fi

rm -f \
    mask_patch.grd \
    mask3.grd \
    mask3.out \
    corr_patch.grd \
    corr_cut.grd

echo "SNAPHU interpolation completed."
