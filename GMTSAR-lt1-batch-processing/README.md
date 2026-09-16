<a id="english"></a>

[English](#english) | [中文](#中文说明)

# LuTan-1 GMTSAR Batch Processing

This directory provides a reproducible GMTSAR workflow for LuTan-1 (LT-1A/LT-1B) stripmap SLC data. It covers archive extraction, SLC generation, orbit handling, radar-coordinate cropping, co-registration, interferogram generation, SNAPHU unwrapping, SBAS inversion, velocity geocoding, and point time-series extraction.

Author: Xin Wang, University of Science and Technology of China (USTC), Hefei, China

> This is a user-developed research workflow, not an official GMTSAR distribution. Inspect all parameters, logs, quality-control figures, and preview products before scientific use.

## Where this workflow belongs

The repository contains two satellite families:

- **Sentinel-1:** the existing full-frame, burst, and full-resolution cut-SLC workflows in the repository root;
- **LuTan-1:** this independent `GMTSAR-lt1-batch-processing/` workflow.

The Sentinel-1 directories remain at their existing paths so previously shared links and script references continue to work. The repository-level README provides separate Sentinel-1 and LuTan-1 navigation.

## Processing chain

```text
LT-1 archives
  -> extract products
  -> create full-frame PRM/SLC/coarse LED
  -> apply precise orbit or repair the metadata orbit
  -> optionally normalize PRF/range sampling
  -> prepare DEM and convert geographic ROI to region_cut
  -> crop every SLC first, then co-register the cropped stack
  -> generate topo_ra.grd and trans.dat
  -> calculate baselines and select interferogram pairs
  -> form/filter interferograms
  -> build coherence and land masks
  -> unwrap with SNAPHU
  -> remove long-wavelength trend and apply a stable reference area
  -> run SBAS, geocode velocity, and extract point time series
```

## Main entry points

| Stage | Scripts | Purpose |
|---|---|---|
| Run 1 | `run1.1`–`run1.2.4` | Extraction, raw SLC creation, precise/coarse orbit processing, optional common sampling |
| Run 2 | `run2.1`–`run2.3` | DEM, geographic-to-radar ROI, configuration |
| Run 3 | `run3.1`–`run3.12` | Crop-first alignment, radar DEM, pair selection, interferometry, masking, unwrapping, detrending, referencing |
| Run 4 | `run4.1`–`run4.7` | SBAS tables/inversion, velocity geocoding, point time series, local velocity maps |

For exact commands, parameters, outputs, and troubleshooting, see the [detailed Chinese manual](LT1_GMTSAR_批处理说明书.md).

## Directory used for one track

Run the scripts from an `Ascending/` or `Descending/` processing directory:

```text
Ascending/ or Descending/
├── data/
│   ├── zip/       # LT-1 product archives
│   └── orbit/     # precise-orbit text files
├── raw/           # full-frame PRM/SLC/LED
├── SLC/           # cropped and co-registered PRM/SLC/LED
├── topo/          # geographic DEM, topo_ra.grd, trans.dat
├── intf_all/      # interferogram directories
└── sbas_detrend/  # SBAS products
```

Do not place raw SAR products or generated processing directories in this source-code repository.

## Quick start

Copy or link the scripts into the track directory and make them executable:

```bash
chmod +x run*.sh run*.py
```

Every shell entry point prints help when called without the required arguments. Most scripts use preview/check mode by default and formal mode when the first argument is `1`. Run 3.10 is different: mode `1` previews one pair and mode `2` performs parallel unwrapping.

A representative ascending-stack sequence is:

```bash
./run1.1_unzip_LT1.sh 1 --jobs 5
./run1.2.1_prepare_raw_LT1.sh 1 --master 20250423
./run1.2.2_make_slc_LT1.sh 1 --master 20250423 --jobs 5
./run1.2.3_apply_precise_orbit_LT1.sh 1 --master 20250423 --jobs 5

./run2.1_prepare_topo_DEM_LT1.sh 1 --margin-deg 0.30 --resolution 1
./run2.2_geo_to_radar_region_LT1.sh 1 --master 20250423 \
  --upper-left 118.75 30.07 --lower-right 118.87 29.97
./run2.3_update_config_LT1.sh 1

./run3.1_batch_alignment_LT1_parallel.sh 1 --master 20250423 --jobs 5
./run3.2_dem_ra_LT1.sh 1 --master 20250423
./run3.3_select_pairs_LT1.sh 1 --master 20250423 \
  --max-days 120 --max-baseline 700
./run3.4_batch_interferometry_LT1_parallel.sh 1 --master 20250423 --jobs 5
```

Continue with Runs 3.5–3.12 and Runs 4.1–4.7 only after checking the preceding products. The detailed manual explains the required ROI, mask, reference, and SBAS choices.

## Main dependencies

- GMTSAR with LT1 support;
- GMT;
- Bash and `tcsh`;
- Python 3 and the packages imported by the selected Python scripts;
- GNU Parallel for parallel entry points;
- SNAPHU for phase unwrapping;
- sufficient memory and disk throughput for the selected job count.

The repository does not include GMTSAR, GMT, SNAPHU, raw LT-1 products, precise-orbit products, or generated InSAR results.

---

<a id="中文说明"></a>

[返回 English](#english) | [中文](#中文说明)

# 陆探一号 GMTSAR 批处理

本目录提供 LT-1A/LT-1B 条带模式 SLC 数据的 GMTSAR 批处理流程，包括数据解压、SLC 生成、轨道处理、雷达坐标裁剪、配准、干涉、SNAPHU 解缠、SBAS 反演、速度地理编码和点时序提取。

作者：王欣，中国科学技术大学（USTC），合肥

> 本流程由用户开发，不是 GMTSAR 官方发行版。用于科研之前，应检查全部参数、日志、质量控制图和预览产品。

## 仓库如何区分 S1 与 LT-1

建议按卫星分开理解和使用：

- **Sentinel-1：**仓库根目录中已有的完整分帧、单 Burst 和全分辨率裁剪流程；
- **陆探一号：**本目录 `GMTSAR-lt1-batch-processing/` 中的独立流程。

这次不移动已有 Sentinel-1 目录，避免以前分享的 GitHub 链接和脚本路径失效；仓库首页已经为 Sentinel-1 和陆探一号分别设置入口。

## 处理链

```text
LT-1 压缩包
  → 解压产品
  → 生成全幅 PRM/SLC/粗轨 LED
  → 应用精密轨道；缺失时修复元数据粗轨
  → 可选统一 PRF 和距离采样率
  → 准备 DEM，经纬度 ROI 转换为 region_cut
  → 先裁剪全部 SLC，再对裁剪后的时序配准
  → 生成 topo_ra.grd 和 trans.dat
  → 计算基线并选择干涉对
  → 生成和滤波干涉图
  → 生成平均相干性掩膜和陆地掩膜
  → SNAPHU 解缠
  → 去除长波趋势并进行稳定区参考
  → SBAS 反演、速度地理编码和点时序提取
```

## 脚本分组

| 阶段 | 脚本 | 作用 |
|---|---|---|
| Run 1 | `run1.1`–`run1.2.4` | 解压、全幅 SLC、精密／粗轨处理、可选统一采样 |
| Run 2 | `run2.1`–`run2.3` | DEM、经纬度 ROI 转雷达范围、配置参数 |
| Run 3 | `run3.1`–`run3.12` | 先裁剪再配准、雷达 DEM、选对、干涉、掩膜、解缠、去趋势和参考 |
| Run 4 | `run4.1`–`run4.7` | SBAS 表格和反演、速度投影、点时序和局部速度图 |

每一步的准确命令、参数、输出和常见问题见[中文详细说明书](LT1_GMTSAR_批处理说明书.md)。

## 单个轨道方向的工作目录

脚本应在 `Ascending/` 或 `Descending/` 目录中运行：

```text
Ascending/ 或 Descending/
├── data/
│   ├── zip/       # LT-1 产品压缩包
│   └── orbit/     # 精密轨道文本
├── raw/           # 全幅 PRM/SLC/LED
├── SLC/           # 裁剪并配准后的 PRM/SLC/LED
├── topo/          # DEM、topo_ra.grd、trans.dat
├── intf_all/      # 干涉对结果
└── sbas_detrend/  # SBAS 结果
```

不要把原始 SAR 数据和运行生成的大型结果提交到本代码仓库。

## 快速开始

把脚本复制或链接到轨道处理目录，并赋予执行权限：

```bash
chmod +x run*.sh run*.py
```

Shell 入口缺少必要参数时会显示帮助。大多数脚本不加 `1` 是检查／预览模式，第一个参数加 `1` 才正式处理。Run 3.10 例外：模式 `1` 预览一个干涉对，模式 `2` 才并行正式解缠。

一组升轨示例命令：

```bash
./run1.1_unzip_LT1.sh 1 --jobs 5
./run1.2.1_prepare_raw_LT1.sh 1 --master 20250423
./run1.2.2_make_slc_LT1.sh 1 --master 20250423 --jobs 5
./run1.2.3_apply_precise_orbit_LT1.sh 1 --master 20250423 --jobs 5

./run2.1_prepare_topo_DEM_LT1.sh 1 --margin-deg 0.30 --resolution 1
./run2.2_geo_to_radar_region_LT1.sh 1 --master 20250423 \
  --upper-left 118.75 30.07 --lower-right 118.87 29.97
./run2.3_update_config_LT1.sh 1

./run3.1_batch_alignment_LT1_parallel.sh 1 --master 20250423 --jobs 5
./run3.2_dem_ra_LT1.sh 1 --master 20250423
./run3.3_select_pairs_LT1.sh 1 --master 20250423 \
  --max-days 120 --max-baseline 700
./run3.4_batch_interferometry_LT1_parallel.sh 1 --master 20250423 --jobs 5
```

检查上述输出后，再继续 Run 3.5–3.12 和 Run 4.1–4.7。解缠范围、掩膜、参考区和 SBAS 输入的选择方法见详细说明书。

## 主要依赖

- 支持 LT1 的 GMTSAR；
- GMT；
- Bash 和 `tcsh`；
- Python 3 及脚本导入的相应软件包；
- 并行脚本需要 GNU Parallel；
- 解缠需要 SNAPHU；
- 与并行数相匹配的内存和磁盘读写能力。

本仓库不包含 GMTSAR、GMT、SNAPHU、LT-1 原始产品、精密轨道产品或运行生成的 InSAR 结果。
