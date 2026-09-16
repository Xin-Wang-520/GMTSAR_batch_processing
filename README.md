<a id="english"></a>

[English](#english) | [中文](#中文说明)

# GMTSAR Batch Processing

Reusable GMTSAR batch-processing workflows for Sentinel-1 and LuTan-1 (LT-1), including interferometry, phase unwrapping, SBAS time-series analysis, velocity geocoding, and point time-series extraction.

Author: Xin Wang, University of Science and Technology of China (USTC), Hefei, China

> This is a user-developed research workflow. It is not an official GMTSAR distribution. Review every preview, parameter and quality-control product before using the results in scientific analysis.

## Repository contents

```text
GMTSAR_batch_processing/
├── Sentinel-1/
│   ├── GMTSAR_batch_scripts/                   # full-frame IW1/IW2/IW3 workflow
│   ├── GMTSAR_burst_batch_scripts/             # single-burst workflow
│   ├── GMTSAR_cut_slc_full_resolution_scripts/ # cut-SLC workflow
│   └── GMTSAR_support_scripts/                 # helpers and accelerated programs
└── LuTan-1/
    └── GMTSAR-lt1-batch-processing/            # LT-1 stripmap workflow
```

## Choose a satellite workflow

| Satellite | Workflow | Documentation |
|---|---|---|
| Sentinel-1 | Full IW1/IW2/IW3 frames | [Open workflow](Sentinel-1/GMTSAR_batch_scripts/) |
| Sentinel-1 | Single burst/subswath | [Open workflow](Sentinel-1/GMTSAR_burst_batch_scripts/) |
| Sentinel-1 | Full-resolution cut SLC | [Open workflow](Sentinel-1/GMTSAR_cut_slc_full_resolution_scripts/) |
| LuTan-1 | LT-1A/LT-1B stripmap SLC | [Open bilingual workflow](LuTan-1/GMTSAR-lt1-batch-processing/) |

### Full-frame workflow

[`Sentinel-1/GMTSAR_batch_scripts/`](Sentinel-1/GMTSAR_batch_scripts/) processes Sentinel-1 data through the following stages:

```text
ASF download and SAFE validation
    → orbit files and TOPS frame organization
    → DEM preparation and F1/F2/F3 input links
    → preprocessing and interferogram-network selection
    → radar-coordinate topography
    → F1/F2/F3 interferograms and subswath merging
    → coherence/land masks and SNAPHU unwrapping
    → DEM-error and reference-area correction
    → SBAS inversion and velocity geocoding
    → seasonal correction
    → GNSS-to-LOS referencing
```

Documentation:

- [Full-frame README — English first, 中文可跳转](Sentinel-1/GMTSAR_batch_scripts/README.md)
- [Detailed Chinese processing manual](Sentinel-1/GMTSAR_batch_scripts/Sentinel_GMTSAR_batch_proeessing.md)

### Single-burst workflow

[`Sentinel-1/GMTSAR_burst_batch_scripts/`](Sentinel-1/GMTSAR_burst_batch_scripts/) processes one common Sentinel-1 burst/subswath stack without merging IW1/IW2/IW3.

```text
SAFE/orbit validation
    → burst DEM and input links
    → preprocessing and pair selection
    → radar-coordinate topography and interferograms
    → coherence/land masks
    → resumable SNAPHU unwrapping
    → optional DEM/reference correction
    → direct or reference-pinned SBAS
    → velocity geocoding
```

Documentation:

- [Burst README — English first, 中文可跳转](Sentinel-1/GMTSAR_burst_batch_scripts/README.md)
- [Complete bilingual burst manual](Sentinel-1/GMTSAR_burst_batch_scripts/Sentinel_GMTSAR_burst_batch_processing.md)

### Support programs

[`Sentinel-1/GMTSAR_support_scripts/`](Sentinel-1/GMTSAR_support_scripts/) contains custom tools used by selected processing steps, including:

- parallel `SAT_llt2rat` and `dem2topo_ra` support;
- TOPS frame organization and preprocessing helpers;
- experimental GMT-surface-compatible Python/Cython code;
- faster SNAPHU interpolation helpers.

Some support programs require compilation or installation in a user-controlled `bin` directory. Read the corresponding source and script headers before replacing any system GMTSAR executable.

### LuTan-1 workflow

[`LuTan-1/GMTSAR-lt1-batch-processing/`](LuTan-1/GMTSAR-lt1-batch-processing/) provides the independent LT-1A/LT-1B stripmap workflow:

```text
archive extraction and SLC generation
    → precise-orbit application or coarse-orbit repair
    → DEM and geographic-to-radar ROI
    → crop-first co-registration
    → baseline network and interferograms
    → coherence/land masks and SNAPHU unwrapping
    → detrending and stable-area referencing
    → SBAS velocity and point time series
```

Documentation:

- [LuTan-1 README — English first, 中文可跳转](LuTan-1/GMTSAR-lt1-batch-processing/README.md)
- [Detailed Chinese processing manual](LuTan-1/GMTSAR-lt1-batch-processing/LT1_GMTSAR_批处理说明书.md)

## Quick start

Clone with SSH:

```bash
git clone git@github.com:Xin-Wang-520/GMTSAR_batch_processing.git
cd GMTSAR_batch_processing
```

Copy the required workflow scripts into a track-processing directory, or run them from a location that preserves their expected relative paths. Make scripts executable:

```bash
chmod +x Sentinel-1/GMTSAR_batch_scripts/run*.sh
chmod +x Sentinel-1/GMTSAR_batch_scripts/run*.py
chmod +x Sentinel-1/GMTSAR_burst_batch_scripts/run*.sh
chmod +x Sentinel-1/GMTSAR_burst_batch_scripts/run*.py
chmod +x Sentinel-1/GMTSAR_burst_batch_scripts/*.csh
chmod +x LuTan-1/GMTSAR-lt1-batch-processing/run*.sh
chmod +x LuTan-1/GMTSAR-lt1-batch-processing/run*.py
```

Read the workflow-specific README before processing:

```text
Full IW1/IW2/IW3 frames → Sentinel-1/GMTSAR_batch_scripts/README.md
Single burst            → Sentinel-1/GMTSAR_burst_batch_scripts/README.md
LuTan-1 stripmap        → LuTan-1/GMTSAR-lt1-batch-processing/README.md
```

## Main dependencies

- Linux or another Unix-like environment suitable for GMTSAR;
- [GMTSAR](https://github.com/gmtsar/gmtsar);
- [GMT](https://www.generic-mapping-tools.org/);
- Bash and `tcsh`;
- Python 3 with the packages required by the selected Python scripts;
- GNU Parallel for parallel workflows;
- Sentinel-1 precise or restituted orbit access;
- sufficient storage, memory and disk throughput for large Sentinel-1 stacks.

The repository does not bundle GMTSAR, GMT, Sentinel-1 data or orbit products.

## Processing principles

- Run check/preview modes before formal modes whenever available.
- Inspect DEM bounds, baseline networks, seam previews, masks and pre-SNAPHU plots.
- Treat every non-empty failure report as unresolved.
- Preserve inventory, manifest, parameter and `run*.complete` files for restart validation.
- Use the same arguments when resuming a parameter-sensitive interrupted step.
- Adjust parallel job counts to CPU, memory and disk-I/O capacity.
- Do not mix direct, DEM-corrected and reference-pinned products in one SBAS inversion.
- Keep original Sentinel-1 data separate from GMTSAR processing results.

## Citation and acknowledgement

If these scripts contribute to a publication, cite the relevant GMTSAR, GMT, GNU Parallel, SNAPHU, Sentinel-1 and data-provider references required by the software and datasets used in the analysis.

---

<a id="中文说明"></a>

[Back to English](#english) | [中文](#中文说明)

# GMTSAR 批处理脚本

本仓库提供 Sentinel-1 和陆探一号（LT-1）的 GMTSAR 批处理流程，包括干涉、相位解缠、SBAS 时序反演、速度地理编码和点时序提取。

作者：王欣，中国科学技术大学（USTC），合肥

> 本仓库是用户开发的科研处理流程，不是 GMTSAR 官方发行版。正式科研使用前，请检查每一步的预览结果、参数、日志与质量控制图。

## 仓库目录

```text
GMTSAR_batch_processing/
├── Sentinel-1/
│   ├── GMTSAR_batch_scripts/                   # 完整 F1/F2/F3 流程
│   ├── GMTSAR_burst_batch_scripts/             # 单 Burst 流程
│   ├── GMTSAR_cut_slc_full_resolution_scripts/ # 全分辨率裁剪流程
│   └── GMTSAR_support_scripts/                 # 辅助和并行加速程序
└── LuTan-1/
    └── GMTSAR-lt1-batch-processing/            # 陆探一号条带模式流程
```

## 选择卫星流程

| 卫星 | 流程 | 说明书入口 |
|---|---|---|
| Sentinel-1 | 完整 IW1/IW2/IW3 分帧 | [进入流程](Sentinel-1/GMTSAR_batch_scripts/) |
| Sentinel-1 | 单 Burst／单子条带 | [进入流程](Sentinel-1/GMTSAR_burst_batch_scripts/) |
| Sentinel-1 | 全分辨率裁剪 SLC | [进入流程](Sentinel-1/GMTSAR_cut_slc_full_resolution_scripts/) |
| 陆探一号 | LT-1A/LT-1B 条带模式 SLC | [进入中英文流程](LuTan-1/GMTSAR-lt1-batch-processing/) |

### 完整 F1/F2/F3 流程

[`Sentinel-1/GMTSAR_batch_scripts/`](Sentinel-1/GMTSAR_batch_scripts/) 包括：

```text
ASF 下载和 SAFE 检查
    → 轨道下载与 TOPS 分帧
    → DEM 和 F1/F2/F3 输入链接
    → 预处理和干涉网络选择
    → 雷达坐标地形
    → F1/F2/F3 干涉和三子条带拼接
    → 相关性／陆地掩膜与 SNAPHU 解缠
    → DEM 误差和参考区改正
    → SBAS 与速度投影
    → 季节项改正
    → GNSS 到 LOS 参考改正
```

说明书：

- [完整分帧流程 README（English 在前，可跳转中文）](Sentinel-1/GMTSAR_batch_scripts/README.md)
- [详细中文处理说明书](Sentinel-1/GMTSAR_batch_scripts/Sentinel_GMTSAR_batch_proeessing.md)

### 单 Burst 流程

[`Sentinel-1/GMTSAR_burst_batch_scripts/`](Sentinel-1/GMTSAR_burst_batch_scripts/) 用于处理一个共同 Burst／子条带时序，不进行 IW1/IW2/IW3 拼接。

说明书：

- [Burst README（English 在前，可跳转中文）](Sentinel-1/GMTSAR_burst_batch_scripts/README.md)
- [Burst 完整中英文说明书](Sentinel-1/GMTSAR_burst_batch_scripts/Sentinel_GMTSAR_burst_batch_processing.md)

### 支持程序

[`Sentinel-1/GMTSAR_support_scripts/`](Sentinel-1/GMTSAR_support_scripts/) 保存部分步骤使用的自定义程序，包括：

- 并行 `SAT_llt2rat` 和 `dem2topo_ra` 支持程序；
- TOPS 分帧和并行预处理辅助脚本；
- GMT `surface` 兼容性试验代码；
- SNAPHU 快速插值辅助程序。

部分程序需要单独编译并安装到用户自己的 `bin` 目录。替换系统 GMTSAR 程序之前，必须阅读对应源码和脚本开头的说明。

### 陆探一号流程

[`LuTan-1/GMTSAR-lt1-batch-processing/`](LuTan-1/GMTSAR-lt1-batch-processing/) 是独立的 LT-1A/LT-1B 条带模式流程，覆盖解压、SLC 与轨道、DEM 与雷达 ROI、先裁剪再配准、干涉与解缠、去趋势与稳定区参考、SBAS 速度和点时序。

说明书：

- [陆探一号 README（English 在前，可跳转中文）](LuTan-1/GMTSAR-lt1-batch-processing/README.md)
- [详细中文处理说明书](LuTan-1/GMTSAR-lt1-batch-processing/LT1_GMTSAR_批处理说明书.md)

## 快速开始

使用 SSH 下载：

```bash
git clone git@github.com:Xin-Wang-520/GMTSAR_batch_processing.git
cd GMTSAR_batch_processing
```

赋予脚本执行权限：

```bash
chmod +x Sentinel-1/GMTSAR_batch_scripts/run*.sh
chmod +x Sentinel-1/GMTSAR_batch_scripts/run*.py
chmod +x Sentinel-1/GMTSAR_burst_batch_scripts/run*.sh
chmod +x Sentinel-1/GMTSAR_burst_batch_scripts/run*.py
chmod +x Sentinel-1/GMTSAR_burst_batch_scripts/*.csh
chmod +x LuTan-1/GMTSAR-lt1-batch-processing/run*.sh
chmod +x LuTan-1/GMTSAR-lt1-batch-processing/run*.py
```

开始处理前，根据数据类型阅读对应说明书：

```text
完整 IW1/IW2/IW3 分帧 → Sentinel-1/GMTSAR_batch_scripts/README.md
单 Burst             → Sentinel-1/GMTSAR_burst_batch_scripts/README.md
陆探一号条带模式       → LuTan-1/GMTSAR-lt1-batch-processing/README.md
```

## 主要依赖

- 适合运行 GMTSAR 的 Linux 或类 Unix 环境；
- GMTSAR、GMT、Bash 和 `tcsh`；
- Python 3 及所选 Python 脚本需要的包；
- GNU Parallel；
- Sentinel-1 精密或快速轨道文件；
- 足够的存储空间、内存和磁盘读写能力。

本仓库不包含 GMTSAR、GMT、Sentinel-1 原始数据和轨道产品。

## 使用原则

- 有检查或预览模式时，先检查再正式运行。
- 检查 DEM 范围、时空基线网络、拼接缝、掩膜和 SNAPHU 输入图。
- 失败清单非空时，不要继续后续步骤。
- 保留 inventory、manifest、参数文件和 `run*.complete`，以便后续验证和断点续跑。
- 参数敏感步骤中断后，使用完全相同的参数重跑。
- 根据 CPU、内存和磁盘读写能力合理设置并行数。
- 不要在同一次 SBAS 中混用直接解缠、DEM 改正和参考区改正结果。
- Sentinel-1 原始数据与 GMTSAR 处理结果应分目录保存。

## 引用

如果这些脚本用于论文或科研成果，请根据实际使用的软件与数据，引用 GMTSAR、GMT、GNU Parallel、SNAPHU、Sentinel-1 和数据提供机构要求的相关文献。
