#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Run 5.1: remove annual and semiannual signals from SBAS displacement grids.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 22, 2026

import os
import re
import time
import shutil
import argparse
import subprocess
import fcntl
from datetime import datetime
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed

import numpy as np
from netCDF4 import Dataset


TAG_RE = re.compile(r"disp_(\d{7})\.grd$")


def tag_to_decimal_year(tag: str) -> float:
    year = int(tag[:4])
    doy = int(tag[4:])
    days_in_year = (datetime(year + 1, 1, 1) - datetime(year, 1, 1)).days
    if doy < 0 or doy >= days_in_year:
        raise ValueError(f"无效的 GMTSAR 年内日编号: {tag}")
    # GMTSAR displacement names use zero-based day of year: 000 = January 1.
    return year + doy / 365.25


def find_grid_var(ds: Dataset) -> str:
    candidates = []
    for name, var in ds.variables.items():
        if var.ndim == 2:
            candidates.append(name)
    if not candidates:
        raise RuntimeError("没有找到二维网格变量")
    if "z" in candidates:
        return "z"
    return candidates[0]


def read_grid_block(var, y0, y1):
    arr = var[y0:y1, :]
    if np.ma.isMaskedArray(arr):
        arr = arr.filled(np.nan)
    return np.asarray(arr, dtype=np.float64)


def create_output_like(src_path: str, out_path: str, zname: str) -> Dataset:
    src = Dataset(src_path, "r")
    src_z = src.variables[zname]

    dst = Dataset(out_path, "w", format="NETCDF4")

    for dname, dim in src.dimensions.items():
        dst.createDimension(dname, len(dim))

    for att in src.ncattrs():
        dst.setncattr(att, src.getncattr(att))

    for cname in src_z.dimensions:
        svar = src.variables[cname]
        fill_value = svar.getncattr("_FillValue") if "_FillValue" in svar.ncattrs() else None
        if fill_value is None:
            dvar = dst.createVariable(cname, svar.dtype, svar.dimensions)
        else:
            dvar = dst.createVariable(cname, svar.dtype, svar.dimensions, fill_value=fill_value)

        dvar[:] = svar[:]
        for att in svar.ncattrs():
            if att == "_FillValue":
                continue
            dvar.setncattr(att, svar.getncattr(att))

    z_fill = src_z.getncattr("_FillValue") if "_FillValue" in src_z.ncattrs() else None
    if z_fill is None:
        zvar = dst.createVariable(
            zname, "f4", src_z.dimensions, zlib=True, complevel=3, shuffle=True
        )
    else:
        zvar = dst.createVariable(
            zname, "f4", src_z.dimensions,
            fill_value=z_fill, zlib=True, complevel=3, shuffle=True
        )

    for att in src_z.ncattrs():
        if att == "_FillValue":
            continue
        zvar.setncattr(att, src_z.getncattr(att))

    remark_old = ""
    if "Remark" in dst.ncattrs():
        remark_old = dst.getncattr("Remark")
    extra = " | seasonal removed | re-referenced to first epoch"
    dst.setncattr("Remark", (remark_old + extra).strip())

    src.close()
    return dst


def build_design_matrix(t_rel: np.ndarray, annual_only: bool = False, no_trend: bool = False) -> np.ndarray:
    cols = [np.ones_like(t_rel)]

    if not no_trend:
        cols.append(t_rel)

    cols.append(np.sin(2 * np.pi * t_rel))
    cols.append(np.cos(2 * np.pi * t_rel))

    if not annual_only:
        cols.append(np.sin(4 * np.pi * t_rel))
        cols.append(np.cos(4 * np.pi * t_rel))

    return np.column_stack(cols)


def seasonal_from_beta(G: np.ndarray, beta: np.ndarray, annual_only: bool = False, no_trend: bool = False) -> np.ndarray:
    start = 1 if no_trend else 2
    end = start + 2 if annual_only else start + 4
    return G[:, start:end] @ beta[start:end]


def process_one_chunk(files, zname, y0, y1, G, annual_only, no_trend, tmpdir):
    t0 = time.time()

    in_dss = [Dataset(f, "r") for f in files]
    nr = y1 - y0
    nx = in_dss[0].variables[zname].shape[1]
    nt = len(files)

    stack = np.empty((nt, nr, nx), dtype=np.float64)
    for k, ds in enumerate(in_dss):
        stack[k, :, :] = read_grid_block(ds.variables[zname], y0, y1)

    for ds in in_dss:
        ds.close()

    Y = stack.reshape(nt, -1)   # (T, P)
    Y_out = Y.copy()

    finite = np.isfinite(Y)
    nobs = finite.sum(axis=0)
    full = finite.all(axis=0)

    ncoef = G.shape[1]
    G_pinv = np.linalg.pinv(G)

    # 1) 完整时序像元：批量解
    if np.any(full):
        beta_full = G_pinv @ Y[:, full]
        seas_full = seasonal_from_beta(
            G, beta_full,
            annual_only=annual_only,
            no_trend=no_trend
        )
        Y_out[:, full] = Y[:, full] - seas_full

    # 2) 部分缺测像元：逐像元拟合
    partial_idx = np.where((~full) & (nobs >= ncoef))[0]
    for idx in partial_idx:
        mask = finite[:, idx]
        yv = Y[mask, idx]
        Gv = G[mask, :]
        beta, *_ = np.linalg.lstsq(Gv, yv, rcond=None)

        seas = seasonal_from_beta(
            G, beta,
            annual_only=annual_only,
            no_trend=no_trend
        )

        yc = Y[:, idx].copy()
        yc[mask] = Y[mask, idx] - seas[mask]
        Y_out[:, idx] = yc

    # 3) 重新参考到第一期：让第一期重新为 0
    ref = Y_out[0, :].copy()
    valid_ref = np.isfinite(ref)
    Y_out[:, valid_ref] = Y_out[:, valid_ref] - ref[valid_ref]

    chunk_out = Y_out.reshape(nt, nr, nx).astype(np.float32)

    tmp_path = os.path.join(tmpdir, f"chunk_{y0}_{y1}.npy")
    np.save(tmp_path, chunk_out)

    elapsed = time.time() - t0
    return y0, y1, tmp_path, elapsed


def refresh_gmt_header(outdir, files):
    print("开始刷新 GMT header 中的 z_min/z_max ...", flush=True)

    for i, f in enumerate(files, start=1):
        out_path = os.path.join(outdir, os.path.basename(f))
        tmp_path = out_path + ".tmp.grd"

        subprocess.run(
            ["gmt", "grdmath", out_path, "1", "MUL", "=", tmp_path],
            check=True
        )
        os.replace(tmp_path, out_path)
        print(f"[{i:>3d}/{len(files)}] 已刷新: {os.path.basename(out_path)}", flush=True)


def validate_inputs(files):
    """Read only grid headers and require identical variables and dimensions."""
    first_shape = None
    first_dims = None
    zname = None

    for index, path in enumerate(files, start=1):
        with Dataset(path, "r") as ds:
            current_zname = find_grid_var(ds)
            current_var = ds.variables[current_zname]
            current_shape = current_var.shape
            current_dims = current_var.dimensions

            if index == 1:
                zname = current_zname
                first_shape = current_shape
                first_dims = current_dims
            elif (current_zname != zname or current_shape != first_shape
                  or current_dims != first_dims):
                raise RuntimeError(
                    f"网格结构不一致: {path.name}; "
                    f"expected {zname}/{first_shape}/{first_dims}, "
                    f"got {current_zname}/{current_shape}/{current_dims}"
                )

    return zname, first_shape


def model_description(annual_only, no_trend):
    terms = ["常数"]
    if not no_trend:
        terms.append("线性趋势")
    terms.append("年周期")
    if not annual_only:
        terms.append("半年周期")
    return " + ".join(terms)


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Run 5.1：并行去除 sbas_demcorr_pin/disp_YYYYDDD.grd "
            "中的年/半年周期，并重新参考到第一期"
        )
    )
    parser.add_argument("mode", nargs="?", choices=["1"], help="省略为检查；1 为正式运行")
    parser.add_argument("--chunk", type=int, default=128, help="按行分块大小（默认：128）")
    parser.add_argument("--jobs", type=int, default=20, help="并行进程数（默认：20）")
    parser.add_argument("--annual-only", action="store_true", help="只去除年周期")
    parser.add_argument("--no-trend", action="store_true", help="拟合模型中不包含线性趋势")
    parser.add_argument("--keep-tmp", action="store_true", help="保留临时块文件")
    parser.add_argument("--skip-refresh-header", action="store_true", help="跳过 GMT z_min/z_max 刷新")
    args = parser.parse_args()

    if args.jobs < 1:
        parser.error("--jobs 必须是正整数")
    if args.chunk < 1:
        parser.error("--chunk 必须是正整数")

    root = Path.cwd().resolve()
    if not re.fullmatch(r"T\d+", root.name):
        raise SystemExit(f"[ERROR] 请在 T数字 轨道根目录运行（当前：{root}）")

    sbas_dir = root / "sbas_demcorr_pin"
    if not sbas_dir.is_dir():
        raise SystemExit(f"[ERROR] 找不到目录：{sbas_dir}")

    candidates = sorted(sbas_dir.glob("disp_*.grd"))
    tagged = []
    for path in candidates:
        match = TAG_RE.fullmatch(path.name)
        if match:
            tagged.append((match.group(1), path.resolve()))

    if not tagged:
        raise SystemExit(f"[ERROR] {sbas_dir} 中没有 disp_YYYYDDD.grd")

    tags = [item[0] for item in tagged]
    if len(tags) != len(set(tags)):
        raise SystemExit("[ERROR] disp 时间标签存在重复")

    files = [item[1] for item in tagged]
    zname, (ny, nx) = validate_inputs(files)

    times = np.array([tag_to_decimal_year(tag) for tag in tags], dtype=np.float64)
    t_rel = times - times[0]
    G = build_design_matrix(t_rel, args.annual_only, args.no_trend)
    ncoef = G.shape[1]
    if len(files) < ncoef:
        raise SystemExit(f"[ERROR] 期数 {len(files)} 少于模型参数数 {ncoef}")

    output_dir = sbas_dir / "disp_deseason"
    existing_outputs = list(output_dir.glob("disp_*.grd")) if output_dir.is_dir() else []
    chunks = [(y0, min(ny, y0 + args.chunk)) for y0 in range(0, ny, args.chunk)]
    memory_gib = len(files) * args.chunk * nx * 8 / 1024 ** 3

    print("========================================", flush=True)
    print("Run 5.1: remove seasonal signals from SBAS displacement grids", flush=True)
    print(f"Mode              : {'FORMAL' if args.mode == '1' else 'CHECK ONLY'}", flush=True)
    print(f"Track root        : {root}", flush=True)
    print(f"SBAS directory    : {sbas_dir}", flush=True)
    print(f"Input grids       : {len(files)}", flush=True)
    print(f"First epoch       : {tags[0]}", flush=True)
    print(f"Last epoch        : {tags[-1]}", flush=True)
    print(f"Grid variable     : {zname}", flush=True)
    print(f"Grid size         : ny={ny}, nx={nx}", flush=True)
    print(f"Model             : {model_description(args.annual_only, args.no_trend)}", flush=True)
    print("Removed terms     : annual and semiannual" if not args.annual_only
          else "Removed terms     : annual only", flush=True)
    print("Reference         : first epoch = 0", flush=True)
    print(f"Chunk rows        : {args.chunk}", flush=True)
    print(f"Parallel jobs     : {args.jobs}", flush=True)
    print(f"Chunks            : {len(chunks)}", flush=True)
    print(f"Memory/job approx : {memory_gib:.2f} GiB plus overhead", flush=True)
    print(f"Output directory  : {output_dir}", flush=True)
    print(f"Existing outputs  : {len(existing_outputs)}", flush=True)
    print("========================================", flush=True)

    if args.mode is None:
        print("[CHECK ONLY] No output or temporary file was created.", flush=True)
        print("[NEXT] Formal run:", flush=True)
        print("  ./run5.1_remove_season_from_grd_stack_parallel.py 1", flush=True)
        print("[OPTION] Adjust parallel jobs when memory or storage is busy:", flush=True)
        print("  ./run5.1_remove_season_from_grd_stack_parallel.py 1 --jobs 5", flush=True)
        return

    if shutil.which("gmt") is None and not args.skip_refresh_header:
        raise SystemExit("[ERROR] 找不到 GMT；或明确使用 --skip-refresh-header")

    lock_path = sbas_dir / ".run5.1_remove_season.lock"
    lock_handle = lock_path.open("w")
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("[ERROR] 另一个 Run 5.1 正在运行")

    stamp = f"{os.getpid()}_{int(time.time())}"
    staging_dir = sbas_dir / f".run5.1_output_tmp_{stamp}"
    tmpdir = sbas_dir / f".run5.1_chunks_tmp_{stamp}"
    old_dir = sbas_dir / f".run5.1_old_{stamp}"
    staging_dir.mkdir()
    tmpdir.mkdir()

    out_dss = []
    success = False
    t_all0 = time.time()
    try:
        for path in files:
            out_path = staging_dir / path.name
            out_dss.append(create_output_like(str(path), str(out_path), zname))

        finished = 0
        with ProcessPoolExecutor(max_workers=args.jobs) as executor:
            futures = {
                executor.submit(
                    process_one_chunk,
                    [str(path) for path in files], zname, y0, y1, G,
                    args.annual_only, args.no_trend, str(tmpdir)
                ): (y0, y1)
                for y0, y1 in chunks
            }

            for future in as_completed(futures):
                y0_submit, y1_submit = futures[future]
                try:
                    y0, y1, tmp_path, elapsed = future.result()
                except Exception as exc:
                    raise RuntimeError(f"块 {y0_submit}:{y1_submit} 失败: {exc}") from exc

                chunk_data = np.load(tmp_path, mmap_mode="r")
                for index, ds_out in enumerate(out_dss):
                    array = chunk_data[index, :, :]
                    target = ds_out.variables[zname]
                    target[y0:y1, :] = (
                        np.ma.masked_invalid(array) if np.isnan(array).any() else array
                    )
                del chunk_data

                if not args.keep_tmp:
                    Path(tmp_path).unlink(missing_ok=True)

                finished += 1
                wall = time.time() - t_all0
                rate = finished / wall if wall > 0 else 0.0
                remaining = (len(chunks) - finished) / rate if rate > 0 else float("nan")
                print(
                    f"[{finished:>3d}/{len(chunks)}] {finished/len(chunks)*100:6.2f}% | "
                    f"rows {y0}:{y1} | chunk {elapsed:6.1f}s | "
                    f"elapsed {wall/60:7.1f} min | remaining {remaining/60:7.1f} min",
                    flush=True
                )

        for ds_out in out_dss:
            ds_out.close()
        out_dss.clear()

        if not args.skip_refresh_header:
            refresh_gmt_header(str(staging_dir), [str(path) for path in files])

        outputs = sorted(staging_dir.glob("disp_*.grd"))
        if len(outputs) != len(files) or any(path.stat().st_size == 0 for path in outputs):
            raise RuntimeError("输出数量或文件大小检查失败")

        elapsed = time.time() - t_all0
        marker = staging_dir / "run5.1_complete"
        marker.write_text(
            f"completed={datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %z')}\n"
            f"track={root.name}\n"
            f"input_grids={len(files)}\n"
            f"first_epoch={tags[0]}\n"
            f"last_epoch={tags[-1]}\n"
            f"model={model_description(args.annual_only, args.no_trend)}\n"
            f"jobs={args.jobs}\n"
            f"chunk={args.chunk}\n"
            f"elapsed_seconds={elapsed:.3f}\n"
        )

        if output_dir.exists():
            os.replace(output_dir, old_dir)
        try:
            os.replace(staging_dir, output_dir)
        except Exception:
            if old_dir.exists() and not output_dir.exists():
                os.replace(old_dir, output_dir)
            raise
        if old_dir.exists():
            shutil.rmtree(old_dir)

        success = True
        print("========================================", flush=True)
        print("[DONE] Run 5.1 seasonal correction completed", flush=True)
        print(f"Output grids : {len(outputs)}", flush=True)
        print(f"Output dir   : {output_dir}", flush=True)
        print(f"Elapsed      : {elapsed/60:.1f} min", flush=True)
        print("========================================", flush=True)
    finally:
        for ds_out in out_dss:
            try:
                ds_out.close()
            except Exception:
                pass
        if not args.keep_tmp and tmpdir.exists():
            shutil.rmtree(tmpdir, ignore_errors=True)
        if not success and staging_dir.exists():
            shutil.rmtree(staging_dir, ignore_errors=True)
        if old_dir.exists() and not output_dir.exists():
            os.replace(old_dir, output_dir)
        lock_handle.close()
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
