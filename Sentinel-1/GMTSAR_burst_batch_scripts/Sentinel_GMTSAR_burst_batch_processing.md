<a id="english"></a>

[English](#english) | [中文](#中文说明)


# Sentinel-1 GMTSAR Burst Batch Processing Guide

Author: Xin Wang, University of Science and Technology of China (USTC), Hefei, China
Workflow: Sentinel-1 single-burst/single-subswath preprocessing, interferometry, unwrapping and SBAS

## 1. Overview

This directory contains a batch workflow for processing one Sentinel-1 burst stack with GMTSAR. The scripts are designed to run from a track root directory whose name starts with `T`, for example:

```text
/data2/xinw/Huangshan_landsides/S1/T142A/
```

The default directory structure is:

```text
T142A/
├── data_burst/                 # SAFE products and orbit files
├── topo/                       # geographic DEM
├── burst/
│   ├── raw/                    # linked XML/TIFF/EOF and preprocessing products
│   ├── topo/                   # radar-coordinate topography products
│   └── intf_all/               # interferogram directories
├── sbas_burst/                 # direct SBAS products from unwrap.grd
└── sbas_burst_pin/             # optional DEM-corrected and reference-pinned SBAS products
```

All commands in this guide are run from the track root (`T*`), not from this script directory, unless explicitly stated otherwise.

## 2. Recommended workflow

The normal burst workflow is:

```text
Run 2.1  validate SAFE files and download orbit files
Run 2.2  determine the DEM region and generate dem.grd
Run 2.3  link burst inputs into burst/raw and burst/topo
Run 3.1  generate data.in and select the middle acquisition as master
Run 3.2  preprocess and align the burst stack
Run 3.3  select and confirm the interferogram network
Run 3.4  generate radar-coordinate topography
Run 3.5  generate interferograms
Run 3.6  generate the stack coherence mask
Run 3.7  generate the radar-coordinate land mask
Run 3.8  preview and unwrap interferograms
Run 3.9  align corr.grd geometry with unwrap.grd
Run 4.1  prepare the SBAS network
Run 4.2  generate SBAS tables and the SBAS command
Run 4.3  run SBAS
Run 4.4  geocode and plot the SBAS velocity
```

The direct SBAS route uses `burst/intf_all/<pair>/unwrap.grd`. Runs 3.10 and 3.11 are optional and are needed only for the DEM-corrected, reference-pinned route.

## 3. Software requirements

The workflow expects the following commands to be available in `PATH`:

```text
GMTSAR, GMT, tcsh, Python 3, GNU parallel, make_dem.csh,
download_sentinel_orbits_linux_new.csh,
preproc_batch_tops_parallel_new_wx.csh
```

Python scripts require the packages used by the local scripts, including NumPy and the NetCDF/GMT-compatible Python environment where applicable.

Make the scripts executable after copying them to a server:

```bash
chmod +x run*.sh run*.py select_pairs_regular.csh
```

## 4. Input preparation

Place the selected Sentinel-1 SAFE directories under `data_burst/`:

```text
T142A/
└── data_burst/
    ├── S1A_*.SAFE
    ├── S1A_*.SAFE
    └── ...
```

The SAFE products must describe the same burst stack, polarization and subswath. The default polarization is VV. The script can automatically identify a common `IW1`, `IW2` or `IW3` subswath.

## 5. Run 2: prepare inputs

### Run 2.1: validate SAFE products and obtain orbit files

Check only:

```bash
./run2.1_prepare_SAFE_orbits.sh
```

Formal run using precise POEORB files:

```bash
./run2.1_prepare_SAFE_orbits.sh 1
```

Use restituted RESORB files when precise files are unavailable:

```bash
./run2.1_prepare_SAFE_orbits.sh 1 --orbit-mode 2
```

Useful options:

```bash
--data-dir data_burst
--swath AUTO
--polarization vv
--downloader /path/to/download_sentinel_orbits_linux_new.csh
```

Main outputs:

```text
data_burst/SAFE_filelist
data_burst/burst_SAFE_inventory.tsv
data_burst/*.EOF
data_burst/run2.1_orbit_download.log
```

The inventory records the acquisition date, satellite, subswath, polarization, SAFE directory and annotation XML used by later steps.

### Run 2.2: determine the DEM region and generate the DEM

Display the command guide:

```bash
./run2.2_prepare_topo_DEM_burst.py
```

Mode 1 calculates and saves the DEM bounds without downloading a DEM:

```bash
./run2.2_prepare_topo_DEM_burst.py 1
```

Inspect:

```text
topo/dem_region_actual.txt
topo/dem_region_margin.txt
topo/dem_region.txt
```

Mode 2 generates and plots the DEM:

```bash
./run2.2_prepare_topo_DEM_burst.py 2
```

Optional settings:

```bash
./run2.2_prepare_topo_DEM_burst.py 2 --margin 0.3 --resolution 1
```

Main outputs:

```text
topo/dem.grd
topo/dem.pdf
topo/make_dem.log
topo/plot_dem.log
```

The default margin is 0.2 degrees on every side. Mode 2 calls `make_dem.csh` with resolution mode 1 by default.

### Run 2.3: link the burst inputs

Show the guide:

```bash
./run2.3_link_burst_raw_topo.sh
```

Preview and validate all planned links:

```bash
./run2.3_link_burst_raw_topo.sh 1
```

Create the links:

```bash
./run2.3_link_burst_raw_topo.sh 2
```

Main outputs:

```text
burst/raw/*.xml
burst/raw/*.tiff
burst/raw/*.EOF
burst/raw/dem.grd
burst/topo/dem.grd
burst/burst_swath.txt
burst/run2.3_link_inventory.tsv
```

These are symbolic links. The original SAFE, TIFF, XML, EOF and DEM files are not copied or deleted.

## 6. Run 3: preprocessing and interferograms

### Run 3.1: generate `data.in`

Show the guide:

```bash
./run3.1_prep_data_burst.sh
```

Preview:

```bash
./run3.1_prep_data_burst.sh 1
```

Formal run:

```bash
./run3.1_prep_data_burst.sh 2
```

The script runs `prep_data_linux.csh`, resolves compatible orbit revisions when necessary, and moves the temporal-middle acquisition to the first line of `data.in`. For an even number of acquisitions, it uses the middle-front record.

Main outputs:

```text
burst/raw/data.in
burst/raw/data.in.from_prep_data
burst/raw/data.in.orig
burst/raw/data.in.before_middle_first
burst/raw/prep_data.log
```

### Run 3.2: preprocess the burst stack

Show the guide:

```bash
./run3.2_preproc_batch_tops_burst.sh
```

Recommended standard processing with five concurrent pair jobs:

```bash
./run3.2_preproc_batch_tops_burst.sh 5 1
```

ESD alternatives:

```bash
./run3.2_preproc_batch_tops_burst.sh 5 2 0   # average
./run3.2_preproc_batch_tops_burst.sh 5 2 1   # median, recommended ESD mode
./run3.2_preproc_batch_tops_burst.sh 5 2 2   # interpolation
```

The first value is the maximum number of concurrent pair jobs. Reduce it to 2 or 3 on a smaller computer.

Main outputs:

```text
burst/raw/*ALL*.PRM
burst/raw/*ALL*.LED
burst/raw/*ALL*.SLC
burst/raw/baseline_table.dat
burst/raw/baseline.ps
burst/raw/preproc_all.log
```

### Run 3.3: select the interferogram network

Show the guide:

```bash
./run3.3_make_intf_config_burst.sh
```

Mode 1 creates a preview using a 60-day temporal threshold and a 150 m spatial-baseline threshold:

```bash
./run3.3_make_intf_config_burst.sh 1 60 150
```

Inspect:

```text
burst/baseline.pdf
burst/intf.in.preview
```

If the network is suitable, finalize it:

```bash
./run3.3_make_intf_config_burst.sh 2
```

Mode 2 accepts the latest preview and generates the finalized `burst/intf.in` and `burst/batch_tops.config`. The `master_image` is derived from the first record of `burst/raw/data.in`.

### Run 3.4: generate radar-coordinate topography

Show and check the command:

```bash
./run3.4_dem2topo_ra_burst.sh
```

Formal run:

```bash
./run3.4_dem2topo_ra_burst.sh 1
```

Main outputs under `burst/topo/` include:

```text
topo_ra.grd
trans.dat
dem2topo_ra.log
```

The script links the selected master PRM/LED, runs the radar-coordinate topography workflow and validates the outputs.

### Run 3.5: generate burst interferograms

Show the guide:

```bash
./run3.5_intf_tops_parallel_burst.sh
```

Run with five concurrent interferogram jobs:

```bash
./run3.5_intf_tops_parallel_burst.sh 5
```

Main outputs:

```text
burst/intf_all/<pair>/corr.grd
burst/intf_all/<pair>/mask.grd
burst/intf_all/<pair>/phasefilt.grd
burst/run3.5_expected_pairs.tsv
burst/run3.5_failed_pairs.tsv
```

The script validates the expected pair list and reports incomplete pairs instead of silently accepting them.

### Run 3.6: generate a stack coherence mask

Example using a mean-coherence threshold of 0.075, batches of 50 grids and five parallel batch jobs:

```bash
./run3.6_stack_coherence_mask_parallel_burst.sh 0.075 50 5
```

The first parameter is the mean-coherence threshold. `BATCH=50` means that up to 50 correlation grids are summed in one batch; it is not the parallel-job count. The last value controls parallel batch jobs.

Main outputs under `burst/`:

```text
mean_corr.grd
mask_def.grd
mask_def.pdf
```

### Run 3.7: generate the radar-coordinate land mask

Check only:

```bash
./run3.7_make_landmask_ra_burst.sh
```

Formal run:

```bash
./run3.7_make_landmask_ra_burst.sh 1
```

Main outputs under `burst/`:

```text
landmask_ra.grd
landmask_ra.pdf
run3.7_complete
```

The final land mask is resampled to the exact interferogram-grid geometry.

### Run 3.8: preview and unwrap the interferograms

Check the inputs and display commands:

```bash
./run3.8_unwrap_burst_parallel.sh
```

Mode 1 previews one pre-SNAPHU input using the default correlation threshold:

```bash
./run3.8_unwrap_burst_parallel.sh 1
```

Specify a threshold, pair or radar crop when required:

```bash
./run3.8_unwrap_burst_parallel.sh 1 0.1
./run3.8_unwrap_burst_parallel.sh 1 0.1 2022005_2022017
./run3.8_unwrap_burst_parallel.sh 1 0.1 2022005_2022017 0/24560/0/1396
```

Mode 2 starts resumable parallel unwrapping through `nohup`:

```bash
./run3.8_unwrap_burst_parallel.sh 2 5 0.1
```

With an optional radar crop:

```bash
./run3.8_unwrap_burst_parallel.sh 2 5 0.1 0/24560/0/1396
```

Monitor:

```bash
tail -f burst/run3.8_unwrap_burst_parallel.nohup.log
```

Main outputs in every finalized pair directory:

```text
unwrap.grd
unwrap.pdf
run3.8_unwrap_parameters.txt
```

If processing is interrupted, rerun the same Mode 2 command. Completed pairs with matching parameters are skipped, and only incomplete pairs are processed.

### Run 3.9: align `corr.grd` with `unwrap.grd`

Preview five pairs across the full pair list:

```bash
./run3.9_match_corr_to_unwrap_burst.sh
```

Equivalent explicit preview with 20 workers and five sampled pairs:

```bash
./run3.9_match_corr_to_unwrap_burst.sh 0 20 5
```

Formally crop all correlation grids in parallel:

```bash
./run3.9_match_corr_to_unwrap_burst.sh 1 20
```

The formal mode crops or resamples each original `corr.grd` to match the corresponding `unwrap.grd` geometry. It does not modify `unwrap.grd`.

Main outputs:

```text
burst/run3.9_corr_alignment.tsv
burst/run3.9_failed_pairs.tsv
burst/run3.9_complete
```

## 7. Optional DEM and reference-point correction

Skip this section when direct SBAS from `unwrap.grd` is desired. Continue directly to Section 8.

### Run 3.10: correct residual DEM-related phase

Show the guide:

```bash
./run3.10_dem_correction_parallel_all_in_one.sh
```

Recommended example using 10 parallel interferograms and a six-parameter model:

```bash
./run3.10_dem_correction_parallel_all_in_one.sh 10 6
```

Allowed model sizes are 4, 6 and 9. The main output in each pair directory is:

```text
burst/intf_all/<pair>/unwrap_dem_correct.grd
```

### Run 3.11: apply a reference-area correction

Check the required command syntax:

```bash
./run3.11_reference_dem_correct_parallel.sh
```

The reference region is mandatory. Example:

```bash
./run3.11_reference_dem_correct_parallel.sh 10 10000/10096/5000/5024
```

The first parameter is the number of parallel jobs. The second parameter is the radar-coordinate reference region `xmin/xmax/ymin/ymax`.

Main output in each pair directory:

```text
burst/intf_all/<pair>/unwrap_dem_correct_pin_up.grd
```

Inspect the chosen reference region carefully before accepting these products.

## 8. Run 4: direct SBAS route

This is the recommended route when external DEM correction and reference-point correction are not required.

### Run 4.1: prepare the direct SBAS network

Check only:

```bash
./run4.1_prepare_sbas_network_burst.sh
```

Formal run:

```bash
./run4.1_prepare_sbas_network_burst.sh 1
```

Inputs are `unwrap.grd` and the geometry-matched `corr.grd` from every finalized pair.

Outputs:

```text
sbas_burst/intflist_new
sbas_burst/intf.in
sbas_burst/baseline_table.dat
sbas_burst/supermaster.PRM
sbas_burst/supermaster.LED
sbas_burst/run4.1_missing_pairs.tsv
sbas_burst/run4.1_complete
```

All finalized pairs must be complete. Incomplete pairs are reported and are not silently excluded.

### Run 4.2: generate SBAS tables and command

Check the inputs and calculated parameters:

```bash
./run4.2_generate_sbas_tables_burst.sh
```

Generate tables using the default 38-degree incidence angle and smoothing 1.0:

```bash
./run4.2_generate_sbas_tables_burst.sh 1
```

Specify the incidence angle and smoothing value explicitly:

```bash
./run4.2_generate_sbas_tables_burst.sh 1 38 1.0
```

Outputs:

```text
sbas_burst/intf.tab
sbas_burst/scene.tab
sbas_burst/prep_sbas.log
sbas_burst/range_check.log
sbas_burst/run_sbas_parallel.sh
sbas_burst/run4.2_complete
```

This step prepares the command but does not start `sbas_parallel`.

### Run 4.3: run SBAS

Check the inputs, table counts, command and PID state:

```bash
./run4.3_sbas_parallel_burst.sh
```

Submit SBAS through `nohup`:

```bash
./run4.3_sbas_parallel_burst.sh 1
```

Do not add another `nohup` or trailing `&`. Monitor with:

```bash
tail -f sbas_burst/run4.3_sbas_parallel.log
```

### Run 4.4: geocode and plot velocity

Check only:

```bash
./run4.4_geocode_sbas_velocity_burst.sh
```

Formal run:

```bash
./run4.4_geocode_sbas_velocity_burst.sh 1
```

Default settings:

```text
Spatial filter: 400 m
Color range: automatically determined from vel_ll.grd
```

Optional fixed color range:

```bash
VEL_CPT_MIN=-20 VEL_CPT_MAX=20 VEL_CPT_STEP=2 \
./run4.4_geocode_sbas_velocity_burst.sh 1
```

Outputs in `sbas_burst/`:

```text
vel_ll.grd
vel_ll.cpt
vel_ll.pdf
vel_ll KML/KMZ image products
run4.4_complete
```

## 9. Run 4: optional DEM-corrected and reference-pinned SBAS route

Use this route only after Runs 3.10 and 3.11 have successfully generated `unwrap_dem_correct_pin_up.grd` for every accepted pair.

```bash
./run4.1_prepare_sbas_network_pin_burst.sh
./run4.1_prepare_sbas_network_pin_burst.sh 1

./run4.2_generate_sbas_tables_pin_burst.sh
./run4.2_generate_sbas_tables_pin_burst.sh 1 38 1.0

./run4.3_sbas_parallel_pin_burst.sh
./run4.3_sbas_parallel_pin_burst.sh 1

./run4.4_geocode_sbas_velocity_pin_burst.sh
./run4.4_geocode_sbas_velocity_pin_burst.sh 1
```

The corresponding output directory is:

```text
sbas_burst_pin/
```

The pin workflow uses:

```text
burst/intf_all/<pair>/unwrap_dem_correct_pin_up.grd
```

Do not mix files from `sbas_burst/` and `sbas_burst_pin/` in one inversion.

## 10. Compact command sequence

The following sequence shows the normal direct-SBAS workflow. Adjust thresholds, job counts and paths for the server.

```bash
# Run 2
./run2.1_prepare_SAFE_orbits.sh
./run2.1_prepare_SAFE_orbits.sh 1
./run2.2_prepare_topo_DEM_burst.py 1
./run2.2_prepare_topo_DEM_burst.py 2
./run2.3_link_burst_raw_topo.sh 1
./run2.3_link_burst_raw_topo.sh 2

# Run 3
./run3.1_prep_data_burst.sh 1
./run3.1_prep_data_burst.sh 2
./run3.2_preproc_batch_tops_burst.sh 5 1
./run3.3_make_intf_config_burst.sh 1 60 150
./run3.3_make_intf_config_burst.sh 2
./run3.4_dem2topo_ra_burst.sh 1
./run3.5_intf_tops_parallel_burst.sh 5
./run3.6_stack_coherence_mask_parallel_burst.sh 0.075 50 5
./run3.7_make_landmask_ra_burst.sh
./run3.7_make_landmask_ra_burst.sh 1
./run3.8_unwrap_burst_parallel.sh 1 0.1
./run3.8_unwrap_burst_parallel.sh 2 5 0.1
./run3.9_match_corr_to_unwrap_burst.sh 0 20 5
./run3.9_match_corr_to_unwrap_burst.sh 1 20

# Run 4: direct SBAS
./run4.1_prepare_sbas_network_burst.sh
./run4.1_prepare_sbas_network_burst.sh 1
./run4.2_generate_sbas_tables_burst.sh
./run4.2_generate_sbas_tables_burst.sh 1 38 1.0
./run4.3_sbas_parallel_burst.sh
./run4.3_sbas_parallel_burst.sh 1
./run4.4_geocode_sbas_velocity_burst.sh
./run4.4_geocode_sbas_velocity_burst.sh 1
```

## 11. General safety rules

- Always run a script without arguments or in preview/check mode first when that mode is available.
- Inspect `baseline.pdf`, DEM bounds, pre-SNAPHU previews and failure reports before continuing.
- Do not start the next step while a previous `nohup` process is still running.
- Rerun Run 3.8 with exactly the same parameters to resume interrupted unwrapping.
- Treat a non-empty `run*_failed_pairs.tsv` as an unresolved error.
- Adjust parallel job counts to available CPU, memory and disk I/O capacity.
- Preserve `run*.complete`, inventory and manifest files because later scripts use them for validation.
- Use either the direct SBAS route or the pin-corrected route consistently.



---

<a id="中文说明"></a>

[Back to English](#english) | [中文](#中文说明)

# Sentinel-1 GMTSAR Burst 批处理说明书

作者：王欣，中国科学技术大学（USTC），合肥
流程：Sentinel-1 单 burst／单子条带预处理、干涉、解缠与 SBAS

## 1. 流程说明

这套脚本用于处理一个 Sentinel-1 burst 时序。所有命令默认在 `T*` 轨道根目录运行，例如：

```text
/data2/xinw/Huangshan_landslides/S1/T142A/
```

默认目录结构：

```text
T142A/
├── data_burst/          # SAFE 与轨道文件
├── topo/                # 地理坐标 DEM
├── burst/
│   ├── raw/             # XML/TIFF/EOF 链接及预处理结果
│   ├── topo/            # 雷达坐标地形结果
│   └── intf_all/        # 干涉对
├── sbas_burst/          # 直接使用 unwrap.grd 的 SBAS
└── sbas_burst_pin/      # 可选 DEM 改正和参考区归零 SBAS
```

## 2. 推荐主流程

```text
Run 2.1  检查 SAFE 并下载轨道文件
Run 2.2  根据 XML 计算 DEM 范围并生成 DEM
Run 2.3  链接 burst 输入文件
Run 3.1  生成 data.in，选择时间中间影像作为主影像
Run 3.2  预处理并配准 burst 时序
Run 3.3  预览并确认干涉网络
Run 3.4  生成雷达坐标地形和 trans.dat
Run 3.5  并行生成干涉图
Run 3.6  叠加相关性并生成 mask_def.grd
Run 3.7  生成 landmask_ra.grd
Run 3.8  预览 SNAPHU 输入并可续跑并行解缠
Run 3.9  将 corr.grd 匹配到 unwrap.grd 范围
Run 4.1  准备 SBAS 网络
Run 4.2  生成 SBAS 表格和运行命令
Run 4.3  后台运行 SBAS
Run 4.4  投影和绘制 SBAS 速度
```

正常情况下直接使用 `unwrap.grd` 进入 Run 4。只有需要 DEM 误差改正及稳定区归零时，才执行 Run 3.10、Run 3.11 和带 `_pin_` 的 Run 4 脚本。

## 3. Run 2：数据准备

### Run 2.1：SAFE 与轨道文件

```bash
# 只检查
./run2.1_prepare_SAFE_orbits.sh

# 正式生成清单并下载精密轨道
./run2.1_prepare_SAFE_orbits.sh 1

# 精密轨道不可用时选择 RESORB
./run2.1_prepare_SAFE_orbits.sh 1 --orbit-mode 2
```

主要输出：

```text
data_burst/SAFE_filelist
data_burst/burst_SAFE_inventory.tsv
data_burst/*.EOF
data_burst/run2.1_orbit_download.log
```

### Run 2.2：DEM 范围与 DEM

```bash
# 显示说明
./run2.2_prepare_topo_DEM_burst.py

# 只计算和保存范围
./run2.2_prepare_topo_DEM_burst.py 1

# 下载 DEM 并生成 PDF
./run2.2_prepare_topo_DEM_burst.py 2
```

默认向四周扩展 `0.2°`，可以使用 `--margin 0.3` 修改。主要输出为 `topo/dem.grd`、`topo/dem.pdf` 和三份 DEM 范围文件。

### Run 2.3：建立输入链接

```bash
./run2.3_link_burst_raw_topo.sh       # 显示说明
./run2.3_link_burst_raw_topo.sh 1     # 预览链接
./run2.3_link_burst_raw_topo.sh 2     # 正式建立链接
```

输出位于 `burst/raw/`、`burst/topo/`，并生成 `burst/burst_swath.txt`。原始 SAFE、XML、TIFF、EOF 和 DEM 不会被删除。

## 4. Run 3：预处理、干涉与解缠

### Run 3.1：生成 `data.in`

```bash
./run3.1_prep_data_burst.sh
./run3.1_prep_data_burst.sh 1
./run3.1_prep_data_burst.sh 2
```

Mode 1 只检查；Mode 2 运行 `prep_data_linux.csh`，并把时间中间影像移动到 `data.in` 第一行。

### Run 3.2：预处理

推荐标准模式：

```bash
./run3.2_preproc_batch_tops_burst.sh 5 1
```

ESD 模式：

```bash
./run3.2_preproc_batch_tops_burst.sh 5 2 0   # average
./run3.2_preproc_batch_tops_burst.sh 5 2 1   # median，推荐
./run3.2_preproc_batch_tops_burst.sh 5 2 2   # interpolation
```

第一个参数是并行干涉对数量。小型计算机可改为 2 或 3。

### Run 3.3：选择干涉网络

```bash
# 60 天时间基线、150 m 空间基线
./run3.3_make_intf_config_burst.sh 1 60 150

# 查看 burst/baseline.pdf 后确认网络
./run3.3_make_intf_config_burst.sh 2
```

Mode 2 根据 `burst/raw/data.in` 第一行确定 `master_image`，并生成正式 `burst/intf.in` 与 `burst/batch_tops.config`。

### Run 3.4：雷达坐标地形

```bash
./run3.4_dem2topo_ra_burst.sh
./run3.4_dem2topo_ra_burst.sh 1
```

主要输出：

```text
burst/topo/trans.dat
burst/topo/topo_ra.grd
burst/topo/dem2topo_ra.log
```

### Run 3.5：生成干涉图

```bash
./run3.5_intf_tops_parallel_burst.sh 5
```

结果位于 `burst/intf_all/<pair>/`。脚本逐对检查 `corr.grd`、`mask.grd`、`phasefilt.grd` 等结果并生成失败清单。

### Run 3.6：平均相关性掩膜

```bash
./run3.6_stack_coherence_mask_parallel_burst.sh 0.075 50 5
```

参数依次为：平均相关性阈值、每批叠加的 `corr.grd` 数量、并行批次数。主要输出：

```text
burst/mean_corr.grd
burst/mask_def.grd
burst/mask_def.pdf
```

### Run 3.7：陆地掩膜

```bash
./run3.7_make_landmask_ra_burst.sh
./run3.7_make_landmask_ra_burst.sh 1
```

正式运行生成与干涉网格完全一致的 `burst/landmask_ra.grd` 和 `burst/landmask_ra.pdf`。

### Run 3.8：并行解缠

```bash
# 检查
./run3.8_unwrap_burst_parallel.sh

# 预览默认干涉对
./run3.8_unwrap_burst_parallel.sh 1 0.1

# 指定干涉对预览
./run3.8_unwrap_burst_parallel.sh 1 0.1 2022005_2022017

# 5 个并行正式解缠
./run3.8_unwrap_burst_parallel.sh 2 5 0.1
```

如需裁剪雷达范围，可在最后增加 `xmin/xmax/ymin/ymax`。Mode 2 通过 `nohup` 后台运行：

```bash
tail -f burst/run3.8_unwrap_burst_parallel.nohup.log
```

中断后使用完全相同的 Mode 2 命令重跑。脚本会跳过参数一致且已有完整 `unwrap.grd`、`unwrap.pdf` 的干涉对。

### Run 3.9：匹配相关性网格

```bash
# 抽查 5 个干涉对
./run3.9_match_corr_to_unwrap_burst.sh 0 20 5

# 20 个并行正式处理全部干涉对
./run3.9_match_corr_to_unwrap_burst.sh 1 20
```

正式模式使 `corr.grd` 与对应 `unwrap.grd` 的范围、分辨率、行列数和注册方式一致，不修改 `unwrap.grd`。

## 5. 可选 DEM 改正与参考区归零

不需要该改正时，跳过本节并直接运行 Run 4。

```bash
# 10 个并行，6 参数 DEM 误差模型
./run3.10_dem_correction_parallel_all_in_one.sh 10 6

# 强制指定稳定参考区
./run3.11_reference_dem_correct_parallel.sh 10 10000/10096/5000/5024
```

Run 3.10 输出 `unwrap_dem_correct.grd`；Run 3.11 从用户指定的雷达坐标窗口计算中位数并生成 `unwrap_dem_correct_pin_up.grd`。参考区必须位于稳定且有效的相位区域。

## 6. Run 4：直接 SBAS 主线

```bash
# Run 4.1：检查并正式准备网络
./run4.1_prepare_sbas_network_burst.sh
./run4.1_prepare_sbas_network_burst.sh 1

# Run 4.2：检查并生成 SBAS 表格；38° 入射角，平滑 1.0
./run4.2_generate_sbas_tables_burst.sh
./run4.2_generate_sbas_tables_burst.sh 1 38 1.0

# Run 4.3：检查并由脚本通过 nohup 提交 SBAS
./run4.3_sbas_parallel_burst.sh
./run4.3_sbas_parallel_burst.sh 1
tail -f sbas_burst/run4.3_sbas_parallel.log

# Run 4.4：检查并正式投影速度
./run4.4_geocode_sbas_velocity_burst.sh
./run4.4_geocode_sbas_velocity_burst.sh 1
```

最终主要结果位于：

```text
sbas_burst/vel.grd
sbas_burst/vel_ll.grd
sbas_burst/vel_ll.pdf
sbas_burst/vel_ll KML/KMZ products
```

## 7. Run 4：可选 pin 改正 SBAS

只有全部干涉对均已有 `unwrap_dem_correct_pin_up.grd` 时才使用：

```bash
./run4.1_prepare_sbas_network_pin_burst.sh
./run4.1_prepare_sbas_network_pin_burst.sh 1
./run4.2_generate_sbas_tables_pin_burst.sh
./run4.2_generate_sbas_tables_pin_burst.sh 1 38 1.0
./run4.3_sbas_parallel_pin_burst.sh
./run4.3_sbas_parallel_pin_burst.sh 1
./run4.4_geocode_sbas_velocity_pin_burst.sh
./run4.4_geocode_sbas_velocity_pin_burst.sh 1
```

该路线的输出目录是 `sbas_burst_pin/`。不要在一次 SBAS 反演中混用 `sbas_burst/` 和 `sbas_burst_pin/` 的文件。

## 8. 使用原则

- 有检查或预览模式时，先检查再正式运行。
- 继续下一步前检查 DEM、时空基线、SNAPHU 输入和失败清单。
- `run*_failed_pairs.tsv` 非空时，先解决失败干涉对。
- 后台任务未结束时不要重复启动相同步骤。
- 根据 CPU、内存和磁盘读写能力调整并行数；并行数过大不一定更快。
- 保留 inventory、manifest、参数记录和 `run*.complete`，后续脚本会使用它们验证流程状态。

