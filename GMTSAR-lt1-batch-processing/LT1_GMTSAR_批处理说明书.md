# LT-1 GMTSAR 批处理说明书

## 1. 用途与运行原则

本流程用于 LT-1A/LT-1B 条带模式 SLC 数据的轨道处理、雷达坐标裁剪、配准、干涉、解缠、SBAS 反演和点时序提取。

所有命令均在对应的轨道方向目录中执行：

```text
LT1/
├── Ascending/
└── Descending/
```

大多数 Shell 脚本有两种模式：

- 不加 `1`：检查或预览，不正式处理。
- 加 `1`：正式执行。

解缠 Run 3.10 例外：`1` 是单幅预览，`2` 是并行正式解缠。每个脚本都可先无参数运行查看当前帮助。

## 2. 软件与原始目录

需要已正确安装并进入 GMTSAR/GMT 环境，常用命令包括：

```text
gmt, make_dem.csh, make_slc_lt1, calc_dop_orb, cut_slc
SAT_baseline, xcorr, fitoffset.csh, resamp
batch_processing.csh, proj_ra2ll.csh, grd2kml.csh
snaphu_interp.csh, prep_sbas.csh, sbas_parallel
```

原始文件放置方式：

```text
Ascending/                         # 或 Descending/
├── data/
│   ├── zip/                      # LT1*.tar.gz
│   └── orbit/                    # 精密轨道 txt
├── topo/                         # DEM 和雷达坐标地形
├── raw/                          # 全幅 PRM/SLC/LED
├── SLC/                          # 裁剪并配准后的 PRM/SLC/LED
├── intf_all/                     # 干涉对结果
└── sbas_detrend/                 # SBAS 结果
```

## 3. 处理流程总览

```text
压缩包
  ↓ Run 1.1 解压
meta.xml + TIFF
  ↓ Run 1.2.1 准备 raw/ 和 data.list
  ↓ Run 1.2.2 生成全幅 PRM/SLC/粗轨 LED
  ↓ Run 1.2.3 应用精密轨道，缺失时修复粗轨
  ↓ Run 1.2.4 统一采样（可选）
raw/全幅数据
  ↓ Run 2.1 下载 DEM
  ↓ Run 2.2 经纬度 ROI 转 region_cut
  ↓ Run 2.3 更新 GMTSAR 参数
  ↓ Run 3.1 先裁剪全部 SLC，再配准
SLC/裁剪配准数据
  ↓ Run 3.2 生成 topo_ra.grd/trans.dat
  ↓ Run 3.3 计算基线并选干涉对
  ↓ Run 3.4 生成干涉图
  ↓ Run 3.5–3.9 总览、解缠 ROI、相干性掩膜和陆地掩膜
  ↓ Run 3.10 解缠
  ↓ Run 3.11 长波趋势去除
  ↓ Run 3.12 稳定区参考
unwrap_detrend_ref_pin.grd
  ↓ Run 4.1–4.4 SBAS 反演和速度地理编码
  ↓ Run 4.5–4.6 经纬度点时序提取与绘图
```

## 4. Run 1：解压、SLC 与轨道

### 4.1 Run 1.1：解压

```bash
./run1.1_unzip_LT1.sh
./run1.1_unzip_LT1.sh 1 --jobs 5
```

脚本将 `data/zip/*.tar.gz` 并行解压到 `data/`，不修改 `zip/` 和 `orbit/` 中的原文件。

### 4.2 Run 1.2.1：准备 raw 数据

```bash
./run1.2.1_prepare_raw_LT1.sh --master 20250423
./run1.2.1_prepare_raw_LT1.sh 1 --master 20250423
```

主要生成：

- `raw/*.meta.xml` 和 `raw/*.tiff`。
- `data.list`，主影像必须在第一行。
- 不存在时创建 `config.LT1.txt`。

Run 1.2.1–1.2.4 的 Shell 入口内部统一调用
`run1.2_preprocess_LT1.py`。正常使用时运行对应的 Shell 脚本即可，
不需直接运行该 Python 文件。

### 4.3 Run 1.2.2：生成全幅 SLC

```bash
./run1.2.2_make_slc_LT1.sh --master 20250423 --jobs 5
./run1.2.2_make_slc_LT1.sh 1 --master 20250423 --jobs 5
```

输出位于 `raw/`：

```text
LT1_YYYYMMDD.PRM
LT1_YYYYMMDD.SLC
LT1_YYYYMMDD.LED
```

此时 LED 使用 `meta.xml` 内置粗轨。

### 4.4 Run 1.2.3：精密轨道与粗轨修复

```bash
./run1.2.3_apply_precise_orbit_LT1.sh --master 20250423
./run1.2.3_apply_precise_orbit_LT1.sh 1 --master 20250423 --jobs 5
```

支持：

- 13 列 `*.scie.gps.txt`。
- 带头文件的 18 列 `GpsData_GAS_C` 轨道。

精密轨道使用相邻两点三次 Hermite 插值补齐短缺口，首尾扩展 5 秒。缺少精密轨道时，对 Run 1.2.2 的粗轨 LED 使用 MATLAB-style 高阶 Hermite/spline 方法修复。缺轨日期会写入：

```text
run1.2.3_missing_precise_orbits.tsv
```

如不允许粗轨回退，增加 `--require-precise-orbit`。

### 4.5 Run 1.2.4：统一采样（可选）

```bash
./run1.2.4_common_sampling_LT1.sh --master 20250423
./run1.2.4_common_sampling_LT1.sh 1 --master 20250423 --jobs 5
```

脚本以所有景中的最大 PRF 和最大距离采样率为目标采样率。该步骤会重写大型 SLC，建议先预览。

## 5. Run 2：DEM、ROI 与配置

### 5.1 Run 2.1：生成 DEM

```bash
./run2.1_prepare_topo_DEM_LT1.sh
./run2.1_prepare_topo_DEM_LT1.sh 1 --margin-deg 0.30 --resolution 1
```

脚本读取所有 LT-1 `meta.xml` 角点范围，四周增加 0.3°，然后截取到一位小数（舍弃多余小数，不是四舍五入）。

- `--resolution 1`：SRTM 1 arc-second。
- `--resolution 2`：SRTM 3 arc-second。
- 输出：`topo/dem.grd`。

### 5.2 Run 2.2：地理矩形转雷达 `region_cut`

```bash
./run2.2_geo_to_radar_region_LT1.sh \
  --master 20250423 \
  --upper-left 118.75 30.07 \
  --lower-right 118.87 29.97

./run2.2_geo_to_radar_region_LT1.sh 1 \
  --master 20250423 \
  --upper-left 118.75 30.07 \
  --lower-right 118.87 29.97 \
  --margin 500
```

正式模式将 `region_cut` 写入 `config.LT1.txt`。报告文件：

```text
run2.2_roi.ratll
run2.2_region_report.txt
```

### 5.3 Run 2.3：更新配置

```bash
./run2.3_update_config_LT1.sh
./run2.3_update_config_LT1.sh 1
```

当前默认值：

```text
proc_stage = 2
filter_wavelength = 60
dec_factor = 1
azimuth_dec = 1
range_dec = 1
```

`azimuth_dec=2` 在某些 LT-1 PRF 下可能使 GMTSAR 内部 `idec=0`，因此当前使用 `1/1`。

## 6. Run 3：配准、干涉与解缠

### 6.1 Run 3.1：先裁剪再配准

推荐并行版：

```bash
./run3.1_batch_alignment_LT1_parallel.sh --master 20250423 --jobs 4
./run3.1_batch_alignment_LT1_parallel.sh 1 --master 20250423 --jobs 4
```

单进程版：

```bash
./run3.1_batch_alignment_LT1.sh 1 --master 20250423
```

当前流程是：

1. 从 `config.LT1.txt` 读取 `region_cut`。
2. 删除原 `SLC/`，从 `raw/` 把每景 PRM/SLC 裁剪一次。
3. 所有裁剪文件放在 `SLC/`。
4. 对从影像执行 `SAT_baseline → xcorr → fitoffset.csh → resamp`。
5. 配准全程仅使用 `SLC/` 中裁剪后且尺寸一致的 PRM/SLC。

输出含义：

- `LT1_YYYYMMDD.PRM`：最终配准 PRM。
- `LT1_YYYYMMDD.SLC`：最终配准 SLC。
- `*.PRM0` / `*.PRMresamp`：配准中间产物，不用于后续基线计算。
- `*.LED`：轨道文件。

> 重要：不能再把 `raw/MASTER.PRM` 复制到 `SLC/` 覆盖裁剪主影像 PRM。PRM 尺寸与 SLC 文件不一致会造成地形尺寸错误、干涉失败或完全失相干。

### 6.2 Run 3.2：DEM 转雷达坐标

```bash
./run3.2_dem_ra_LT1.sh --master 20250423
./run3.2_dem_ra_LT1.sh 1 --master 20250423
```

主要输出：

```text
topo/topo_ra.grd
topo/trans.dat
SLC/amp-LT1_YYYYMMDD.grd
```

每次重做 Run 3.1 或修改裁剪范围后，必须重做 Run 3.2。`topo_ra.grd` 可以是 SLC 的整数倍降采样，例如 SLC `7220×9348` 对应 topo `1805×2337`，比例为 `4×4`。

### 6.3 Run 3.3：基线与干涉对

```bash
./run3.3_select_pairs_LT1.sh \
  --master 20250423 --max-days 60 --max-baseline 200

./run3.3_select_pairs_LT1.sh 1 \
  --master 20250423 --max-days 120 --max-baseline 700
```

输出：

```text
intf.list
baseline_table.LT1.dat
baseline_LT1.ps
baseline_LT1.pdf
baseline_LT1.png
```

时空基线图的连线严格来自 `intf.list`，标题中显示时间阈值、基线阈值和干涉对数。如出现某景不在任何干涉对中，需要检查它与其他景的时间差和垂直基线差是否超过阈值。

### 6.4 Run 3.4：生成干涉图

推荐先预览并从 4 个并行任务开始：

```bash
./run3.4_batch_interferometry_LT1_parallel.sh \
  --master 20250423 --jobs 4

./run3.4_batch_interferometry_LT1_parallel.sh 1 \
  --master 20250423 --jobs 4
```

单进程版：

```bash
./run3.4_batch_interferometry_LT1.sh 1 --master 20250423
```

每个干涉对输出到：

```text
intf_all/YYYYDDD_YYYYDDD/
```

常用文件：

- `corr.grd`：两景影像的局部相干性。
- `display_amp.grd`：两景 SLC 幅度的显示产品。
- `phasefilt.grd`：滤波后的缠绕干涉相位。
- `phase.cpt`：相位色标。

如日志中首先出现 `The dimension SLC must be multiplication factor of topo_ra`，后面的 `Cannot find real.grd` 等通常只是连锁错误。应先检查 Run 3.1 的 PRM/SLC 尺寸，再重做 Run 3.2。

### 6.5 Run 3.5：干涉结果总览

```bash
python3 run3.5_plot_intf_overview_LT1.py --cols 5 --dpi 180
```

默认输出目录为 `intf_all_overview/`，分别生成 `corr.grd`、`display_amp.grd` 和 `phasefilt.grd` 的日期排序 PNG 总览。为提高速度，可减小 `--dpi` 和 `--max-pixels`；只有需要 PDF 时才加 `--pdf`。

### 6.6 Run 3.6：地理编码首个缠绕干涉对

```bash
./run3.6_geocode_first_pair_LT1.sh
./run3.6_geocode_first_pair_LT1.sh 1 --wavelength 100
```

输出 `phasefilt_ll.grd` 及 KML/KMZ，用于在 Google Earth 中确定解缠范围。这是解缠前的缠绕相位，不是位移。

### 6.7 Run 3.7：解缠区域预览

```bash
python3 run3.7_preview_unwrap_region_LT1.py \
  --master 20250423 \
  --upper-left 118.75 30.07 \
  --lower-right 118.87 29.97
```

脚本用 DEM 高程和 `SAT_llt2rat` 把地理矩形转为雷达坐标，裁剪首个 `phasefilt.grd` 作预览。主要输出：

```text
run3.7_unwrap_roi/radar_region.txt
run3.7_unwrap_roi/phasefilt_roi.grd
run3.7_unwrap_roi/phasefilt_roi.png
run3.7_unwrap_roi/region_report.txt
```

### 6.8 Run 3.8：平均相干性掩膜

```bash
./run3.8_stack_coherence_mask_LT1_parallel.sh
./run3.8_stack_coherence_mask_LT1_parallel.sh 0.075 10 5
```

参数依次为：相干性阈值、每批干涉图数、并行批数。如只有 3 个干涉对却设置 5 个并行任务，只会有实际需要的任务运行，不会凭空生成额外任务。

输出位于 `intf_all/`：

```text
mean_corr.grd
mask_def.grd
mask_def.pdf
```

### 6.9 Run 3.9：雷达坐标陆地掩膜

```bash
./run3.9_make_landmask_ra_LT1.sh
./run3.9_make_landmask_ra_LT1.sh 1
```

输出：

```text
intf_all/landmask_ra.grd
intf_all/landmask_ra.pdf
```

脚本会检查 `landmask.csh` 结果的第一个或第三个起始边界是否与模板零边界一致。如因 GMT 注册产生 0.x 偏差，将对应输入边界改为 `-4` 重做，然后用模板区域重采样。

### 6.10 Run 3.10：SNAPHU 解缠

预览一个干涉对的解缠前掩膜：

```bash
./run3.10_unwrap_LT1_parallel.sh 1 0.0001
```

正式并行解缠：

```bash
./run3.10_unwrap_LT1_parallel.sh 2 5 0.0001
```

区域规则：

- 如存在 `run3.7_unwrap_roi/radar_region.txt`，默认使用该 ROI。
- 如不存在，必须显式传入 `--region X0/X1/Y0/Y1` 或 `--full`。
- 完整解缠示例：

```bash
./run3.10_unwrap_LT1_parallel.sh 2 5 0.0001 --full
```

每对主要输出：

```text
unwrap.grd
unwrap.pdf
conncomp.grd
phasefilt_interp.grd
```

脚本会自动后台运行，不需再加 `nohup` 或 `&`。监视：

```bash
tail -f run3.10_unwrap_LT1_parallel.nohup.log
```

### 6.11 Run 3.11：长波趋势去除

```bash
./run3.11_detrend_unwrap_LT1_parallel.sh
./run3.11_detrend_unwrap_LT1_parallel.sh 1 --jobs 5
```

对每个 `unwrap.grd` 执行：

```bash
gmt grdtrend unwrap.grd -N6r \
  -Tunwrap_trend.grd \
  -Dunwrap_detrend.grd
```

这是多项式长波趋势去除，用于抑制可能的电离层延迟或残余轨道斜坡，不是分频或 TEC 电离层校正。需检查对比图，避免把真实宽范围形变一并拟合掉。

输出：

```text
intf_all/<pair>/unwrap_detrend.grd
run3.11_detrend_overview/<pair>_detrend_comparison.png
run3.11_detrend_overview/unwrap_detrend_all.png
```

中间趋势网格 `unwrap_trend.grd` 绘图后删除。

### 6.12 Run 3.12：稳定区参考

使用稳定点周围 `5×5` 像元平均值：

```bash
./run3.12_reference_detrend_LT1_parallel.sh 1 \
  --pin RANGE AZIMUTH --window 5 --jobs 5
```

也可直接给稳定矩形：

```bash
./run3.12_reference_detrend_LT1_parallel.sh 1 \
  --region XMIN/XMAX/YMIN/YMAX --jobs 5
```

计算关系：

```text
unwrap_detrend_ref_pin.grd
    = unwrap_detrend.grd - 稳定区参考值
```

后续 Run 4 统一使用 `unwrap_detrend_ref_pin.grd`。

## 7. Run 4：SBAS 与点时序

### 7.1 Run 4.1：整理 SBAS 干涉对

```bash
./run4.1_update_sbas_intf_baseline_LT1.sh
./run4.1_update_sbas_intf_baseline_LT1.sh 1
```

脚本会：

- 检查每对 `unwrap_detrend_ref_pin.grd`。
- 使用 `baseline_table.LT1.dat` 建立日期和干涉目录映射。
- 在每个干涉对目录中生成与解缠 ROI 几何完全一致的 `corr_sbas.grd`。
- 生成 `sbas_detrend/intflist_new`、`intf.in` 和 `baseline_table.dat`。

### 7.2 Run 4.2：生成 SBAS 表格和命令

```bash
./run4.2_generate_sbas_tables_command_LT1.sh
./run4.2_generate_sbas_tables_command_LT1.sh 1 38 1.0
```

两个参数分别为入射角和平滑系数。脚本运行 `prep_sbas.csh`，并生成：

```text
sbas_detrend/intf.tab
sbas_detrend/scene.tab
sbas_detrend/supermaster.PRM
sbas_detrend/run_sbas_parallel.sh
```

本步只准备命令，不开始 SBAS 反演。

### 7.3 Run 4.3：SBAS 反演

```bash
./run4.3_sbas_parallel_LT1.sh
./run4.3_sbas_parallel_LT1.sh 1
```

脚本自动在后台执行：

```bash
tail -f sbas_detrend/run4.3_sbas_parallel.log
```

主要结果：

```text
sbas_detrend/vel.grd
sbas_detrend/disp_YYYYDDD.grd
```

`vel.grd` 已是雷达坐标速度结果，无需再复制为 `vel_ra.grd`。

### 7.4 Run 4.4：速度地理编码

```bash
./run4.4_geocode_sbas_velocity_LT1.sh
./run4.4_geocode_sbas_velocity_LT1.sh 1
```

默认滤波为自动模式：脚本优先从 `config.LT1.txt` 读取
`filter_wavelength`，在 SBAS 模板干涉对中匹配同名的
`gauss_<filter_wavelength>`。正式运行时将它链接到
`sbas_detrend/`，再直接从链接名称中读取滤波参数。例如：

```text
sbas_detrend/gauss_60 -> ../intf_all/<pair>/gauss_60
proj_ra2ll.csh trans.dat vel.grd vel_ll.grd 60
```

如需要也可手动指定已存在的滤波：

```bash
./run4.4_geocode_sbas_velocity_LT1.sh 1 60
```

手动指定速度色标为 `-10～+10 mm/yr`：

```bash
./run4.4_geocode_sbas_velocity_LT1.sh 1 60 10
```

输出位于 `sbas_detrend/`：

```text
vel_ll.grd
vel_ll.cpt
vel_ll.pdf
vel_ll.png
vel_ll.kml
vel_ll.kmz
```

自动色标使用 `vel_ll.grd` 最大绝对值四舍五入后的对称范围。KMZ 由 KML 和 PNG 合并，可直接在 Google Earth 中打开。

### 7.5 Run 4.5：提取点时序

直接提取一个点，默认使用 `5×5` 窗口：

```bash
./run4.5_extract_multi_point_timeseries_LT1.sh \
  118.781 29.993 luoshixing
```

自定义 `3×3` 窗口：

```bash
./run4.5_extract_multi_point_timeseries_LT1.sh \
  118.781 29.993 luoshixing 3 3
```

多点文件 `run4.5_points.txt` 格式：

```text
# longitude latitude label
118.774 30.010 Luosixing
118.790 30.020 StablePoint
```

运行：

```bash
./run4.5_extract_multi_point_timeseries_LT1.sh run4.5_points.txt 5 5
```

输出位于 `sbas_detrend/run4.5_time_series/`，其中 `time_series_<label>.dat` 是 Run 4.6 的数据源。

### 7.6 Run 4.6：Python 时序绘图

快速模式：

```bash
python3 run4.6_plot_timeseries_LT1.py
```

当只有一个点时，只画一次该点；当有多个点时，默认只生成一张合并总览 PNG，不反复绘制每个点。默认分辨率为 180 DPI。

更快的低分辨率总览：

```bash
python3 run4.6_plot_timeseries_LT1.py --dpi 120
```

需要各点单图时：

```bash
python3 run4.6_plot_timeseries_LT1.py --individual
```

需要 PDF 时：

```bash
python3 run4.6_plot_timeseries_LT1.py --pdf
```

可在命令行指定事件日期和标签：

```bash
python3 run4.6_plot_timeseries_LT1.py 2025-05-25 Landslide --dpi 180
```

输出位于：

```text
sbas_detrend/run4.6_python_time_series/
```

### 7.7 Run 4.7：绘制螺蛳形滑坡局部速度

默认范围为左上角 `118.770 30.010`、右下角
`118.781 29.991`，并用无填充红色方框标记 Run 4.5 的螺蛳形时序点
`118.776820 30.003311`。先检查：

```bash
./run4.7_plot_luoshixing_velocity_LT1.sh
```

正式裁剪并绘图：

```bash
./run4.7_plot_luoshixing_velocity_LT1.sh 1
```

如后续更换时序点，可直接指定标记坐标和文字：

```bash
./run4.7_plot_luoshixing_velocity_LT1.sh 1 \
  --point 118.776820 30.003311 \
  --point-label Luoshixing
```

脚本从 `sbas_detrend/vel_ll.grd` 裁剪小区域，读取裁剪后的实际
最小值和最大值，并以两者的最大绝对值生成对称 jet 色标。
如 `vel_ll.grd` 将 `118.x°E` 记录为等价的 `-241.x°`，脚本会自动进行
±360° 转换，并在输出网格和图中恢复为 `118.x°E`。
局部速度图使用 Mercator 投影并保留原有地理长宽比例，不强制拉伸为固定矩形。
输出位于轨道根目录的：

```text
run4.7_luoshixing_velocity/
├── vel_ll_luoshixing.grd
├── vel_ll_luoshixing.cpt
├── vel_ll_luoshixing.png
├── vel_ll_luoshixing.pdf
├── velocity_region_report.txt
└── run4.7_complete
```

## 8. 升轨和降轨主影像示例

升轨示例主影像：

```text
20250423
```

降轨示例主影像：

```text
20250518
```

降轨命令与升轨相同，只需在 `Descending/` 目录中运行并换成降轨主影像日期。

## 9. 常见问题

### 9.1 `--master must be YYYYMMDD`

脚本需要显式给主影像：

```bash
./run3.1_batch_alignment_LT1_parallel.sh --master 20250423 --jobs 4
```

### 9.2 `GMT grdtrack was not found in PATH`

当前终端没有进入安装了 GMT/GMTSAR 的环境。进入正确 Conda 环境后用以下命令检查：

```bash
command -v gmt
command -v grdtrack
command -v batch_processing.csh
```

### 9.3 `hermite interpolation point outside of data constraints`

表示 `calc_dop_orb` 所需时刻超出 LED 轨道时间覆盖范围。Run 1.2.3 现已对短缺口插值并在首尾扩展 5 秒。仍失败时查看：

```text
run1.2_orbit_failed.tsv
raw/archive_run1.2.3/
```

### 9.4 SLC 与 `topo_ra.grd` 尺寸不兼容

首先比较：

```bash
gmt grdinfo topo/topo_ra.grd
grep -E '^(num_rng_bins|num_lines)' SLC/LT1_20250423.PRM
```

如刚重做 Run 3.1，应重做 Run 3.2，然后才能重做 Run 3.4。

### 9.5 干涉图完全失相干

优先检查：

1. `SLC/*.PRM` 中尺寸是否与实际 SLC 匹配。
2. 主影像 PRM 是否被 `raw/` 全幅 PRM 覆盖。
3. Run 3.1 配准日志中 `xcorr` 和 `fitoffset` 是否成功。
4. 干涉对的时间基线和垂直基线是否过大。
5. 相干性是否只在水体、林地或地表变化强的区域较低。

### 9.6 Run 4.6 绘图慢

默认已是快速模式：单点只画一次，多点只画一张总览，且只输出 PNG。进一步加速：

```bash
python3 run4.6_plot_timeseries_LT1.py --dpi 120
```

如输出目录中仍看到旧的 `time_series_all` 或单点图，它们可能是上一次运行留下的文件，不代表本次重复绘图。

## 10. 一组推荐的升轨命令顺序

```bash
# Run 1
./run1.1_unzip_LT1.sh 1 --jobs 5
./run1.2.1_prepare_raw_LT1.sh 1 --master 20250423
./run1.2.2_make_slc_LT1.sh 1 --master 20250423 --jobs 5
./run1.2.3_apply_precise_orbit_LT1.sh 1 --master 20250423 --jobs 5
./run1.2.4_common_sampling_LT1.sh 1 --master 20250423 --jobs 5

# Run 2
./run2.1_prepare_topo_DEM_LT1.sh 1 --margin-deg 0.30 --resolution 1
./run2.2_geo_to_radar_region_LT1.sh 1 --master 20250423 \
  --upper-left 118.75 30.07 --lower-right 118.87 29.97
./run2.3_update_config_LT1.sh 1

# Run 3
./run3.1_batch_alignment_LT1_parallel.sh 1 --master 20250423 --jobs 4
./run3.2_dem_ra_LT1.sh 1 --master 20250423
./run3.3_select_pairs_LT1.sh 1 --master 20250423 \
  --max-days 120 --max-baseline 700
./run3.4_batch_interferometry_LT1_parallel.sh 1 --master 20250423 --jobs 4
python3 run3.5_plot_intf_overview_LT1.py --cols 5 --dpi 180
./run3.8_stack_coherence_mask_LT1_parallel.sh 0.075 10 5
./run3.9_make_landmask_ra_LT1.sh 1
./run3.10_unwrap_LT1_parallel.sh 2 5 0.0001
./run3.11_detrend_unwrap_LT1_parallel.sh 1 --jobs 5
./run3.12_reference_detrend_LT1_parallel.sh 1 \
  --pin RANGE AZIMUTH --window 5 --jobs 5

# Run 4
./run4.1_update_sbas_intf_baseline_LT1.sh 1
./run4.2_generate_sbas_tables_command_LT1.sh 1 38 1.0
./run4.3_sbas_parallel_LT1.sh 1
./run4.4_geocode_sbas_velocity_LT1.sh 1
./run4.5_extract_multi_point_timeseries_LT1.sh \
  118.781 29.993 luoshixing
python3 run4.6_plot_timeseries_LT1.py --dpi 180
```

> `RANGE AZIMUTH`、地理 ROI、时间基线、垂直基线、入射角和事件日期必须根据实际区域和数据设置，不应机械照搬示例数值。
