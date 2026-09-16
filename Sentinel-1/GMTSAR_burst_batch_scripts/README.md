<a id="english"></a>

[English](#english) | [中文](#中文说明)

# Sentinel-1 GMTSAR Burst Batch Processing

This directory contains the single-burst/single-subswath Sentinel-1 GMTSAR workflow. It covers SAFE/orbit validation, DEM preparation, preprocessing, interferogram generation, coherence and land masks, resumable SNAPHU unwrapping, optional DEM/reference correction, SBAS inversion, and velocity geocoding.

Author: Xin Wang, University of Science and Technology of China (USTC), Hefei, China

## Documentation

- [Complete English guide](Sentinel_GMTSAR_burst_batch_processing.md#english)
- [完整中文说明](Sentinel_GMTSAR_burst_batch_processing.md#中文说明)

## Main workflow

```text
Run 2.1–2.3   SAFE/orbit, DEM and input links
Run 3.1–3.5   preprocessing, pair selection, radar DEM and interferograms
Run 3.6–3.9   coherence/land masks, unwrapping and corr-grid alignment
Run 3.10–3.11 optional DEM and reference-area correction
Run 4.1–4.4   SBAS preparation, inversion and velocity geocoding
```

Run scripts from a `T*` track root containing `data_burst/`, rather than from this source directory.

---

<a id="中文说明"></a>

[Back to English](#english) | [中文](#中文说明)

# Sentinel-1 GMTSAR Burst 批处理

本目录包含 Sentinel-1 单 burst／单子条带 GMTSAR 批处理流程，包括 SAFE 与轨道检查、DEM 准备、预处理、干涉图生成、相关性和陆地掩膜、可续跑 SNAPHU 解缠、可选 DEM／参考区改正、SBAS 反演和速度投影。

作者：王欣，中国科学技术大学（USTC），合肥

## 说明书

- [Complete English guide](Sentinel_GMTSAR_burst_batch_processing.md#english)
- [打开完整中文说明](Sentinel_GMTSAR_burst_batch_processing.md#中文说明)

所有脚本应在包含 `data_burst/` 的 `T*` 轨道根目录运行，不是在本代码目录运行。

