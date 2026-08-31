# Sentinel-1 GMTSAR SBAS 批处理说明书

本文档只说明各阶段应该怎样执行、如何检查以及如何断点续跑。数据准备代码单独保存在 `run1.1`、`run1.2`、`run1.3` 脚本中，正式 GMTSAR 代码从 Run 2 开始；流程变更同时同步到原有 `README.md`。

## 总体流程

目录分工：

| 阶段 | 工作目录 | 保存内容 |
| --- | --- | --- |
| Run 1.1～Run 1.3 | `/data2/xinw/HMF_Sentinel1_data/Descending/T34` | ASF 下载脚本、ZIP、清理后的 `T34_SAFE/`、日志和失败清单 |
| Run 2 及以后 | `/data2/xinw/InSAR_processing/Descending/T34` | GMTSAR 分帧、拼接、干涉、解缠、SBAS 脚本和处理结果 |

Run 2 从数据准备目录的 `T34_SAFE/` 读取经过 Run 1.3 清理的 VV 数据；GMTSAR 中间结果只写入 `InSAR_processing`，不写回 `HMF_Sentinel1_data`。

| 阶段 | 脚本 | 任务 | 当前状态 |
| --- | --- | --- | --- |
| Run 1.1 | `run1.1_download_S1.py` | 正常下载或按失败清单补下载 ZIP | 已建立，待服务器实测 |
| Run 1.2 | `run1.2_unzip_S1.sh` | 实际解压、记录失败并整理 SAFE | 已建立，待服务器实测 |
| Run 1.3 | `run1.3_remove_VH_keep_VV_delete_zip_S1.sh` | 删除 VH、保留 VV，安全清理 ZIP | 已通过隔离样本测试 |
| Run 2.1 | `run2.1_prepare_SAFE_orbits.sh` | 预览 SAFE 输入，正式生成清单并下载 Sentinel-1 轨道文件 | 已通过预览/正式模拟测试 |
| Run 2.2 | `run2.2_organize_frames.sh` | 检查 `pins.ll` 并预览/正式重组 TOPS 帧 | 已通过隔离流程测试，待服务器实测 |
| Run 2.3 | `run2.3_prepare_topo_DEM.py` | 汇总重组帧 XML 范围并在 `topo/` 生成 DEM | 已通过隔离流程测试，待服务器实测 |
| Run 2.4 | `run2.4_link_raw_topo.sh` | 建立 F1/F2/F3 并链接对应 IW、EOF 和 DEM | 已通过隔离流程测试，待服务器实测 |
| Run 3.1 | `run3.1_prep_data_F123.sh` | 对 F1/F2/F3 生成 `data.in` 并把中间记录移到首行 | 已通过隔离流程测试，待服务器实测 |
| Run 3.2 | `run3.2_preproc_batch_tops_F123.sh` | 两层并行预处理 F1/F2/F3 并验证 PRM/LED/SLC | 已通过隔离流程测试，待服务器实测 |
| Run 3.3 | `run3.3_make_intf_config_F123.sh` | 先预览 F1 时空基线网络，再生成 F1/F2/F3 的 `intf.in` 和配置文件 | 已通过隔离流程测试，待服务器实测 |
| Run 3.4 | `run3.4_dem2topo_ra_F123.sh` / `run3.4_dem2topo_ra_parallel_F123.sh` | 生成 F1/F2/F3 雷达坐标地形，可选 OpenMP 加速 | 已建立 |
| Run 3.5 | `run3.5_intf_tops_parallel_F123.sh` | 并行生成 F1/F2/F3 TOPS 干涉图 | 已建立并完成服务器批处理 |
| Run 3.6 | `run3.6_merge_F123.sh` / `run3.6_merge_F123_parallel_trans.sh` | 预览拼接缝并正式拼接 F1/F2/F3 | 已建立并完成服务器批处理 |
| Run 3.7 | `run3.7_plot_merge_corr_phasefilt.sh` | 检查并绘制拼接后的相关性和滤波相位 | 已建立 |
| Run 3.8 | `run3.8_stack_coherence_mask_parallel.sh` | 并行计算平均相关性并生成 `mask_def.grd` | 已建立 |
| Run 3.9 | `run3.9_make_landmask_ra.sh` | 生成雷达坐标陆地掩膜 | 已建立 |
| Run 3.10 | `run3.10_unwrap_merge_parallel.sh` | 预览 SNAPHU 输入并可续跑并行解缠 | 已建立 |
| Run 3.11 | `run3.11_prepare_dem_ra_and_link.sh` | 生成统一雷达坐标 DEM、PDF 并链接到全部干涉对 | 已建立 |
| Run 3.12 | `run3.12_dem_correction_parallel_all_in_one.sh` / `run3.12_dem_correction_matlablike_2000px_parallel_all.sh` | 全局或局部模型并行改正 DEM 相关误差 | 已建立 |
| Run 3.13 | `run3.13_reference_dem_correct_parallel.sh` | 按用户指定稳定区域统一相位参考 | 已建立 |
| Run 4.1 | `run4.1_update_sbas_intf_baseline.sh` | 筛选最终干涉对并准备 SBAS 清单和基线表 | 已通过模拟测试 |
| Run 4.2 | `run4.2_generate_sbas_tables_command.sh` | 生成 `intf.tab`、`scene.tab` 和 `sbas_parallel` 命令 | 已通过模拟测试 |
| Run 4.3 | `run4.3_sbas_parallel.sh` | 检查并通过 `nohup` 后台提交内部 `run_sbas_parallel.sh` | 已通过模拟测试 |
| Run 4.4 | `run4.4_geocode_sbas_velocity.sh` | 将 SBAS 速度投影到经纬度并生成 PDF/KML | 已通过模拟测试 |
| Run 5.1 | `run5.1_remove_season_from_grd_stack_parallel.py` | 并行去除 SBAS 位移中的年周期和半年周期 | 已通过小型栅格测试 |
| Run 5.2 | `run5.2_plot_deseason_point_timeseries.py` | 绘制原始、季节项和去季节三行点时间序列 | 已通过小型栅格测试 |
| Run 5.3 | `run5.3_make_velocity_from_deseason_parallel.py` | 并行重估去季节位移的线性速度 | 已通过语法与结构检查 |
| Run 5.4 | `run5.4_proj_vel_deseason_to_ll.sh` | 使用400 m滤波将去季节速度投影到经纬度 | 已通过语法与结构检查 |
| Run 6.1 | `run6.1_grid_gnss_horizontal_velocity.sh` | 使用 gpsgridder 插值 GNSS 东向和北向速度 | 已通过语法与结构检查 |
| Run 6.2 | `run6.2_resample_GNSS_to_InSAR_grid.sh` | 将 GNSS 网格匹配到 InSAR 经纬度网格 | 已通过语法与结构检查 |
| Run 6.3 | `run6.3_project_GNSS_to_LOS.py` | 将 GNSS 东/北向速度投影到 LOS | 已通过语法与结构检查 |
| Run 6.4 | `run6.4_project_GNSS_LOS_to_radar.sh` | 将 GNSS LOS 速度投影到 InSAR 雷达网格 | 已通过语法与结构检查 |
| Run 6.5 | `run6.5_build_GNSS_LOS_timeseries.sh` | 按 InSAR 日期生成 GNSS LOS 累积位移时序 | 已通过语法与结构检查 |
| Run 6.6 | `run6.6_validate_GNSS_LOS_timeseries.py` | 重新拟合并验证 GNSS LOS 时序 | 已通过语法与结构检查 |
| Run 6.7 | `run6.7_correct_displacement_with_GNSS.sh` | 去除 InSAR 与 GNSS 的长波长位移差异 | 已通过语法与结构检查 |
| Run 6.8 | `run6.8_make_velocity_from_GNSS_corrected_timeseries.py` | 拟合 GNSS 改正后速度和长波长改正速度 | 已通过语法与结构检查 |
| Run 6.9 | `run6.9_geocode_GNSS_corrected_velocity.sh` | 将两套速度投影到经纬度并绘图 | 已通过语法与结构检查 |

当前执行链：

```text
run1.1_download_S1.py
└── 正常下载或 --failed 定向补下载 → size/PK/ZIP 结构快速检查

run1.2_unzip_S1.sh
└── 无参数预览；加 1 后 GNU Parallel 实际解压 → SAFE 检查 → 失败写入 failed_zip.txt

failed_zip.txt
└── 交给 Run 1.1 定向重下 → 再次执行 Run 1.2（自动跳过已完成 SAFE）

run1.3_remove_VH_keep_VV_delete_zip_S1.sh
└── 删除 VH → 检查 VV → 安全删除对应 ZIP

切换到 /data2/xinw/InSAR_processing/Descending/T34
├── Run 2.1 生成 SAFE_filelist 并下载轨道文件
├── Run 2.2 检查 pins.ll → mode=1 预览 → mode=2 正式重组帧
├── Run 2.3 汇总重组帧全部 XML → 计算 DEM 范围 → 在 topo/ 生成 dem.grd
├── Run 2.4 建立 F1/F2/F3 → 链接对应 IW、EOF 和 DEM
├── Run 3.1 对 F1/F2/F3 运行 prep_data_linux.csh → 中间记录移到 data.in 首行
├── Run 3.2 同时预处理 F1/F2/F3 → 检查 PRM/LED/SLC 和 baseline_table.dat
├── Run 3.3 预览并确认 F1 时空基线网络 → 生成 F1/F2/F3 的 intf.in 和配置
├── Run 3.4 将 DEM 转换到 F1/F2/F3 主影像雷达坐标
├── Run 3.5 并行生成 F1/F2/F3 干涉图并逐对验证
├── Run 3.6 预览拼接缝 → 正式拼接全部 F1/F2/F3 干涉对
├── Run 3.7 检查并抽样绘制拼接后的 corr/phasefilt
├── Run 3.8 叠加全部 corr → 生成 mean_corr.grd 和 mask_def.grd
├── Run 3.9 生成与相位网格一致的 landmask_ra.grd
├── Run 3.10 预览组合掩膜输入 → 可续跑并行 SNAPHU 解缠
├── Run 3.11 生成与解缠网格一致的雷达坐标 DEM 并链接到全部干涉对
├── Run 3.12 使用全局模型或 2000px 局部模型改正 DEM 相关误差
├── Run 3.13 使用用户指定稳定区统一参考 DEM 改正后的解缠相位
├── Run 4.1 筛选最终干涉对 → 更新 SBAS intf.in 和 baseline_table.dat
├── Run 4.2 生成 intf.tab、scene.tab 和内部 run_sbas_parallel.sh
├── Run 4.3 正式运行 sbas_parallel 时序反演
├── Run 4.4 投影 vel.grd → 生成经纬度速度网格、CPT、PDF 和 KML
├── Run 5.1 对 disp_*.grd 去除年/半年周期 → 输出 disp_deseason/
├── Run 5.2 对比原始、季节项和去季节时间序列 → 输出检查图与文本
├── Run 5.3 对去季节位移逐像元线性拟合 → 输出速度网格和预览图
├── Run 5.4 使用 trans.dat 和400 m滤波 → 投影去季节速度到经纬度
├── Run 6.1 使用 gpsgridder → 生成 GNSS 东向和北向速度网格
├── Run 6.2 将 GNSS 网格匹配到 InSAR 经纬度网格
├── Run 6.3 将 GNSS 东/北向速度投影到 LOS
├── Run 6.4 将 GNSS LOS 速度投影到雷达坐标
├── Run 6.5 按 InSAR 日期生成 GNSS LOS 累积位移时序
├── Run 6.6 重新拟合 GNSS LOS 时序并验证
├── Run 6.7 去除去季节 InSAR 位移与 GNSS 的长波长差异
├── Run 6.8 拟合 GNSS 改正后速度和长波长改正速度
└── Run 6.9 投影两套速度到经纬度，分别绘图并输出最终速度 KML
```

## 通用原则

- 在对应轨道目录（例如 `T34`、`T56`、`T158`）中按 Run 编号依次执行。
- 每一步开始前检查上一步的数量、文件完整性和日志，不只根据进程退出状态判断成功。
- 删除 ZIP、极化文件或中间结果的脚本必须先提供检查模式，确认后才允许正式删除。
- 后台运行时将标准输出和错误输出写入独立日志。
- 脚本中不保存 Earthdata 用户名和密码，认证信息只放在权限为 `600` 的 `~/.netrc` 中。
- 同一工作目录中不要同时启动同一个 Run 的多个实例。

## Run 1.1：下载 Sentinel-1 ZIP

### 目的

从 ASF 生成的 `download*.py` 中提取所有 Sentinel-1 ZIP 地址，将产品下载到当前轨道目录的 `zip/` 子目录。正式文件使用 `.zip` 后缀；未完成文件使用 `.zip.part` 后缀，以便下次运行继续下载。

### 脚本

`run1.1_download_S1.py`

### 运行前目录

```text
T34/
├── download*.py
└── run1.1_download_S1.py
```

建立 Earthdata 认证文件：

```text
machine urs.earthdata.nasa.gov
  login YOUR_USERNAME
  password YOUR_PASSWORD
```

设置认证文件权限：

```bash
chmod 600 ~/.netrc
```

确认依赖：

```bash
command -v python3
command -v curl
```

### 运行

查看参数：

```bash
python3 run1.1_download_S1.py --help
```

前台运行：

```bash
python3 run1.1_download_S1.py
```

后台运行：

```bash
nohup python3 run1.1_download_S1.py > run1.1_download_S1.log 2>&1 &
```

查看日志：

```bash
tail -f run1.1_download_S1.log
```

Run 1.1 只做文件大小、PK 文件头、ZIP 中央目录和 SAFE manifest 快速检查，不执行 `unzip -t`。CRC 完整性由 Run 1.2 实际解压负责。

Run 1.2 生成 `failed_zip.txt` 后，定向补下载：

```bash
python3 run1.1_download_S1.py --failed failed_zip.txt
```

该模式只删除并重新下载清单内的 `.zip`/`.zip.part`；清单外产品全部跳过。清单中的文件名必须能在当前 `download*.py` URL 中找到。

### 输出

```text
T34/
├── asf_cookies.txt
├── url_list_from_download_py.txt
├── run1.1_download_S1.log
└── zip/
    ├── S1*_IW_SLC_*.zip
    └── S1*_IW_SLC_*.zip.part
```

- `.zip`：已通过 Run 1.1 大小、PK/ZIP 结构和 `*.SAFE/manifest.safe` 快速检查的产品。
- `.zip.part`：下载中断后保留的临时文件；不要手动改名为 `.zip`。
- `url_list_from_download_py.txt`：去重后的本次目标 URL 清单。
- `asf_cookies.txt`：下载认证产生的 cookie，不应提交到公开仓库。

### 完成检查

统计 URL、完整产品和断点文件：

```bash
wc -l url_list_from_download_py.txt
find zip -maxdepth 1 -type f -name '*.zip' | wc -l
find zip -maxdepth 1 -type f -name '*.zip.part' | wc -l
```

Run 1.1 完成时应满足：

1. 脚本退出状态为 `0`，日志末尾出现 `[OK]`。
2. URL 数量与 `.zip` 文件数量一致。
3. `zip/` 中不存在 `.zip.part` 文件。
4. 没有出现不同 URL 对应同一文件名的冲突提示。

查看后台任务最终退出情况时，应以日志总结和上述数量检查为准。

### 断点续跑

网络中断、终端关闭或手动停止后，直接重新执行同一命令：

```bash
python3 run1.1_download_S1.py
```

脚本会跳过有效的 `.zip`，并通过 `curl --continue-at -` 从 `.zip.part` 继续。不要删除 `.zip.part`，否则会从头下载。

### 安全说明

- 默认启用 TLS 证书校验，不再默认使用 `curl -k`。
- 只有在已经确认服务器证书问题且接受风险时，才可临时添加 `--insecure`。
- 脚本使用目录锁，避免两个 Run 1.1 进程同时写同一文件。
- cookie 文件会自动设置为仅当前用户可读写（权限 `600`）。
- 如果服务器拒绝 Range 续传，脚本会删除对应的 `.part` 并自动从头重试该文件。
- 快速检查能排除 HTML 登录页、过小文件、损坏的中央目录及不含 SAFE manifest 的产品；成员 CRC 错误由 Run 1.2 实际解压发现。

## Run 1.2：解压 ZIP 并建立 SAFE 完成标记

### 目的

使用 GNU Parallel 并行解压 `zip/*.zip`。每个产品先解压到 `.run1.2_unzip_tmp/`，确认 SAFE 基本结构有效后，再移动到正式的 `T*_SAFE/`，避免中断时在正式目录中留下半截 TIFF。

### 脚本与依赖

脚本：`run1.2_unzip_S1.sh`

```bash
command -v bash
command -v unzip
command -v parallel
command -v od
command -v stat
```

脚本优先使用 `flock` 防止重复运行；没有 `flock` 时自动使用目录锁。

### 运行

先执行无参数只读预览：

```bash
chmod +x run1.2_unzip_S1.sh
./run1.2_unzip_S1.sh
```

预览只统计 ZIP 总数、快速检查异常数、已完成 SAFE 数量和待解压数量，不创建 `T*_SAFE/`、日志、完成标记或 `failed_zip.txt`。确认后正式运行：

```bash
./run1.2_unzip_S1.sh 1
```

正式模式默认并行数为 10。可根据服务器磁盘吞吐和剩余空间调低：

```bash
./run1.2_unzip_S1.sh 1 --jobs 4 --interval 30
```

查看全部参数：

```bash
./run1.2_unzip_S1.sh --help
```

### 临时空间

并行任务会先写入 `.run1.2_unzip_tmp/`，因此运行时需要为同时解压的产品预留额外空间。并行数越大，瞬时磁盘占用和随机读写压力越大。如果磁盘空间紧张，应先降低 `--jobs`。

### 验证与完成标记

每个通过验证的正式 SAFE 内会生成：

```text
.run1.2_unzip_complete
```

标记记录源 ZIP 文件名、ZIP 字节数和完成时间。Run 1.2 的验证条件包括：

1. ZIP 大于指定的最小合理大小且具有标准 ZIP 文件头。
2. `unzip` 成功退出；Run 1.2 会再次读取并校验实际压缩内容。
3. ZIP 顶层产品名与目标 SAFE 名一致。
4. `manifest.safe` 存在且非空。
5. `measurement/`、`annotation/` 存在。
6. 至少存在一个非空 TIFF 和一个非空主 annotation XML。
7. 完成标记中的 ZIP 文件名和字节数与当前源 ZIP 一致。
8. 任一解压或结构验证失败时记录 `[FAILED]`，worker 返回非零状态。
9. 全部 ZIP 都尝试完成后，所有缺少有效完成标记的产品写入 `failed_zip.txt`。

查看总体进度和详细日志：

```bash
tail -f run1.2_unzip_S1_progress.log
tail -f run1.2_unzip_S1.log
column -t run1.2_unzip_S1_parallel_joblog.txt | less -S
```

统计 ZIP、SAFE 和完成标记：

```bash
TRACK="$(basename "$(pwd -P)")"
find zip -maxdepth 1 -type f -name '*.zip' | wc -l
find "${TRACK}_SAFE" -maxdepth 1 -type d -name '*.SAFE' | wc -l
find "${TRACK}_SAFE" -mindepth 2 -maxdepth 2 -type f -name '.run1.2_unzip_complete' | wc -l
```

三者应一一对应，且日志末尾应出现 `[OK] Run 1.2 completed successfully`。

检查失败清单：

```bash
wc -l failed_zip.txt
cat failed_zip.txt
```

成功时该文件为空；失败时每行保存一个 ZIP 文件名。补下载并再次运行 Run 1.2：

```bash
python3 run1.1_download_S1.py --failed failed_zip.txt
./run1.2_unzip_S1.sh
./run1.2_unzip_S1.sh 1
```

### 断点续跑与旧 SAFE

中断或补下载后先无参数预览，再执行 `./run1.2_unzip_S1.sh 1` 正式续跑。已有有效完成标记且与源 ZIP 文件名、大小一致的 SAFE 会显示 `[SKIP]`；没有标记、标记不匹配或结构不完整的 SAFE 才会重新解压。

重新解压成功后，旧 SAFE 不会直接删除，而会改名保留为：

```text
产品名.SAFE.incomplete.时间.PID
```

确认新的正式 SAFE 正常后，可在后续单独审核这些备份。Run 1.3 不会处理或删除此类 `.incomplete.*` 目录。

## Run 1.3：删除 VH、保留 VV并安全清理 ZIP

### 目的

只处理 `T*_SAFE/` 下名称严格以 `.SAFE` 结尾的正式产品：删除文件名中含 `-vh-` 的文件，保留 VV；只有源 ZIP 与 Run 1.2 完成标记一致且 VV 检查通过时，才删除该 ZIP。

### 脚本

`run1.3_remove_VH_keep_VV_delete_zip_S1.sh`

### 第一次运行：dry-run

```bash
chmod +x run1.3_remove_VH_keep_VV_delete_zip_S1.sh
./run1.3_remove_VH_keep_VV_delete_zip_S1.sh
```

默认模式不会删除任何文件，只生成以下清单：

```text
run1.3_remove_VH_keep_VV_delete_zip_S1_vh_files.txt
zip/run1.3_all_zip_before_cleanup.txt
zip/run1.3_zip_ready_to_delete.txt
zip/run1.3_kept_zip_list.txt
```

检查数量和保留原因：

```bash
wc -l run1.3_remove_VH_keep_VV_delete_zip_S1_vh_files.txt
wc -l zip/run1.3_all_zip_before_cleanup.txt
wc -l zip/run1.3_zip_ready_to_delete.txt
wc -l zip/run1.3_kept_zip_list.txt
cat zip/run1.3_kept_zip_list.txt
```

### ZIP 允许删除的条件

对应产品必须同时满足：

1. 正式 `.SAFE` 目录存在。
2. `manifest.safe` 存在且非空。
3. `measurement/` 和 `annotation/` 存在。
4. Run 1.2 完成标记存在且非空。
5. 标记中的源 ZIP 文件名与当前 ZIP 一致。
6. 标记中的源 ZIP 字节数与当前 ZIP 一致。
7. 至少存在一个非空 VV TIFF。
8. 至少存在一个非空 VV 主 annotation XML。
9. VV TIFF 与主 annotation XML 数量一致。

任一条件不满足，ZIP 都会保留，具体原因写入 `run1.3_kept_zip_list.txt`。

### 第二次运行：正式删除

确认 dry-run 清单无误后：

```bash
./run1.3_remove_VH_keep_VV_delete_zip_S1.sh --delete
```

正式删除前必须同时通过整批门禁：

1. 根目录 `failed_zip.txt` 存在且为空。
2. `zip/run1.3_kept_zip_list.txt` 为空。
3. `zip/run1.3_zip_ready_to_delete.txt` 数量等于当前 ZIP 总数。

任一条件不满足，脚本会在删除 VH 之前退出，因此不会形成“部分产品已清理、部分产品仍失败”的混合状态。dry-run 会用 `[BLOCK]` 明确显示阻止正式删除的原因。

正式模式按以下顺序执行：

1. 删除清单中的正式 SAFE 内 VH 文件。
2. 再次扫描，确认正式 SAFE 中 VH 数量为 0。
3. 重新生成 ZIP 安全检查清单。
4. 删除 `run1.3_zip_ready_to_delete.txt` 中仍然检查通过的 ZIP。
5. 将时间和 ZIP 文件名追加到 `zip/run1.3_deleted_zip_list.txt`。
6. 检查剩余 ZIP 数量是否等于保留清单数量。

### 删除后检查

```bash
TRACK="$(basename "$(pwd -P)")"
find "${TRACK}_SAFE" -mindepth 2 -type f -iname '*-vh-*' | wc -l
find "${TRACK}_SAFE" -mindepth 2 -type f -iname '*-vv-*' | wc -l
find zip -maxdepth 1 -type f -name '*.zip' | wc -l
cat zip/run1.3_deleted_zip_list.txt
cat zip/run1.3_kept_zip_list.txt
```

第一个结果应为 0；VV 数量应大于 0。剩余 ZIP 可以为 0，也可以是因安全检查未通过而保留的产品，此时必须检查保留原因。

### 断点续跑

Run 1.3 中断后可重新执行同一命令：

```bash
./run1.3_remove_VH_keep_VV_delete_zip_S1.sh --delete
```

已删除文件会自动跳过。若 `zip/` 中已没有 ZIP，脚本不会覆盖以前保存的 ZIP 清单和删除记录。

## Run 2.1：生成 SAFE 清单并下载轨道文件

Run 2.1 从以下目录运行：

```bash
/data2/xinw/InSAR_processing/Descending/T34
```

输入 SAFE 来源为：

```bash
/data2/xinw/HMF_Sentinel1_data/Descending/T34/T34_SAFE
```

脚本：`run2.1_prepare_SAFE_orbits.sh`

该脚本等价于并增强以下手工步骤：

```bash
mkdir -p organized
find /data2/xinw/HMF_Sentinel1_data/Descending/T34/T34_SAFE \
  -mindepth 1 -maxdepth 1 -type d -name '*.SAFE' | sort \
  > organized/SAFE_filelist
cd organized
download_sentinel_orbits_linux_new.csh SAFE_filelist 1
```

脚本不会复制 SAFE，只在 `SAFE_filelist` 中保存绝对路径。它会自动从当前目录识别 `Descending` 和 `T34`，原子更新清单，并检查轨道下载日志中的 `[ERROR]`。

### 运行

无参数只检查和预览，不创建 `organized/`、SAFE 清单、日志、锁或轨道文件：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run2.1_prepare_SAFE_orbits.sh
./run2.1_prepare_SAFE_orbits.sh
```

正式生成清单并下载 POEORB 精密轨道：

```bash
./run2.1_prepare_SAFE_orbits.sh 1
```

默认 `--mode 1` 下载 POEORB 精密轨道。下载 RESORB：

```bash
./run2.1_prepare_SAFE_orbits.sh 1 --mode 2
```

若 `download_sentinel_orbits_linux_new.csh` 不在 `PATH` 中：

```bash
./run2.1_prepare_SAFE_orbits.sh 1 \
  --downloader /实际路径/download_sentinel_orbits_linux_new.csh
```

也可覆盖默认 SAFE 来源：

```bash
./run2.1_prepare_SAFE_orbits.sh 1 \
  --source-safe /data2/xinw/HMF_Sentinel1_data/Descending/T34/T34_SAFE
```

### 输出

```text
T34/
├── run2.1_prepare_SAFE_orbits.sh
├── run2.1_prepare_SAFE_orbits.log
└── organized/
    ├── SAFE_filelist
    ├── run2.1_orbit_download.log
    └── S1*_OPER_AUX_*ORB_*.EOF
```

完成条件：脚本退出状态为 0、轨道日志无 `[ERROR]`、`organized/` 中至少存在一个 `.EOF` 文件。若个别场景没有匹配轨道，脚本返回非零状态并保留完整日志供检查。

## Run 2.2：按 `pins.ll` 预览并重组 TOPS 帧

Run 2.2 从轨道根目录运行，不要先 `cd organized`：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
```

如果服务器没有按 `Ascending/Descending` 建立父目录，例如轨道目录为 `/data2/xinw/InSAR_processing/T63`，需要在 mode 后明确给出方向。方向参数不区分大小写：

```bash
cd /data2/xinw/InSAR_processing/T63
./run2.2_organize_frames.sh 1 ascending
./run2.2_organize_frames.sh 2 ascending
```

也可以使用完整选项 `./run2.2_organize_frames.sh 1 --direction Ascending`。mode=1 与 mode=2 必须使用相同方向，否则保存的预检状态检查不会通过。

脚本：`run2.2_organize_frames.sh`

它读取 Run 2.1 生成的 `organized/SAFE_filelist` 和 `.EOF` 轨道文件，调用：

```bash
organize_files_tops_linux_nex_xinw.csh SAFE_filelist pins.ll MODE vv
```

`pins.ll` 已存在时脚本直接读取；不存在或为空时，脚本会交互询问两个点，每次在同一行输入“经度 纬度”，并自动生成 `organized/pins.ll`，无需先使用 `vi`。文件必须恰好两行，每行是 `经度 纬度`：

| 轨道方向 | 第 1 行 | 第 2 行 |
| --- | --- | --- |
| 降轨 Descending | 左上角点 | 右下角点 |
| 升轨 Ascending | 右下角点 | 左上角点 |

降轨示例（数值只用于说明格式，请换成实际范围）：

```text
100.0 36.0
102.0 34.0
```

脚本会从当前目录识别升轨/降轨，按上表自动询问、检查并写入。已存在且非空的 `pins.ll` 不会被覆盖。

首次只运行 mode=1 预检，不正式生成帧目录：

```bash
chmod +x run2.2_organize_frames.sh
./run2.2_organize_frames.sh 1
cat organized/run2.2_mode1_summary.txt
```

mode=1 默认同时预检 5 个日期；并行时 `[PREVIEW START]` 和 `[PREVIEW DONE]` 的显示顺序可能不按日期排列。可显式使用 `./run2.2_organize_frames.sh 1 --jobs 5`。

降轨首次运行时的交互格式：

```text
[INPUT] pins.ll not found or empty: .../organized/pins.ll
[INPUT] Direction: Descending
[INPUT] Enter one point per line: longitude latitude (separated by a space)
Upper-left point (longitude latitude, example: 100.123456 36.123456)
> 100.0 36.0
Lower-right point (longitude latitude, example: 102.123456 34.123456)
> 102.0 34.0
[OK] Created pins file: .../organized/pins.ll
```

升轨会自动按“右下点 → 左上点”的顺序询问。

mode=1 不生成正式帧目录。它保存 good/skip 日期，并筛选 good dates 对应的 SAFE，生成：

```text
organized/run2.2_mode1_good_dates.txt
organized/run2.2_mode1_skip_dates.txt
organized/SAFE_filelist_mode2
```

生成过滤清单时还会检查所选 SAFE 的 IW1/IW2/IW3 VV XML 和 TIFF。确认数量、日期和跳过清单正确后执行 mode=2：

```bash
./run2.2_organize_frames.sh 2
```

mode=1 和 mode=2 都默认并行处理 5 个日期；资源紧张时可用 `--jobs 3` 等方式降低并行数。正式长时间运行建议：

```bash
nohup ./run2.2_organize_frames.sh 2 --jobs 5 > run2.2_mode2_nohup.log 2>&1 &
```

SSH 断线时任务会继续；若进程被中断或服务器重启，重新执行 mode=2 即可验证已有输出并从未完成日期继续。

mode=2 只读取 `SAFE_filelist_mode2`，按日期建立独立工作目录，默认同时处理 5 个日期。某一天失败时写入失败清单并继续后面的日期，不会让临时 `.xml`、`.tiff` 或 `tmp*` 文件污染其他日期。

第一步保存 `run2.2_mode1_preview.state`。如果 `SAFE_filelist`、`pins.ll`、极化方式、组织程序或过滤清单发生变化，必须重新执行 mode=1。

旧版预检可尝试从原 good-dates 文件或 `run2.2_mode1_preview.log` 恢复；无法恢复时才需要重新运行 mode=1。

如果原始组织程序不在 `PATH` 中：

```bash
./run2.2_organize_frames.sh 1 --organizer /home/xinw/实际路径/organize_files_tops_linux_nex_xinw.csh
```

正式运行前，脚本会检查 SAFE 绝对路径、轨道文件、`pins.ll` 数值与顺序、GMTSAR 命令以及 mode=1 结果。用 `nohup` 或调度系统非交互运行前，应先在终端生成 `pins.ll`。

mode=2 支持续跑：完整输出自动显示 `[SKIP]`，失败或缺失日期重新处理，不需要 `--allow-existing`。并行数可用 `--jobs N` 调整。

### 主要输出

```text
T34/
├── run2.2_organize_frames.sh
├── run2.2_organize_frames.log
└── organized/
    ├── pins.ll
    ├── run2.2_mode1_preview.log
    ├── run2.2_mode1_summary.txt
    ├── run2.2_mode1_good_dates.txt
    ├── run2.2_mode1_skip_dates.txt
    ├── run2.2_mode1_failed_dates.txt
    ├── run2.2_mode1_date_logs/
    ├── SAFE_filelist_mode2
    ├── run2.2_mode1_preview.state
    ├── run2.2_mode2_execute.log
    ├── run2.2_mode2_success_dates.txt
    ├── run2.2_mode2_failed_dates.txt
    ├── run2.2_mode2_date_logs/
    └── F????_F????/
```

失败清单每行记录日期、失败原因和该日期日志。存在失败日期时，其他日期仍继续完成，但脚本最终返回非零状态。修复后重新执行 `./run2.2_organize_frames.sh 2`，完整日期自动跳过，只补失败日期。

---

## Run 2.3：根据重组帧 XML 计算范围并生成 DEM

从轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run2.3_prepare_topo_DEM.py
```

直接输入脚本名只显示 mode 1、mode 2、默认参数及推荐命令，不读取 XML，也不创建或修改文件：

```bash
./run2.3_prepare_topo_DEM.py
```

脚本默认自动识别 `organized/` 下唯一的 `F????_F????`。若存在多个 frame，则使用：

```bash
./run2.3_prepare_topo_DEM.py 1 --frame F2399_F2449
```

脚本检查每个输出 SAFE 是否恰好具有 IW1、IW2、IW3 各一个 VV XML，并读取所有日期、所有 subswath 的 `geolocationGridPoint`。原始并集向外取整到 0.1°后，四周默认再扩大 0.3°。

先计算并检查范围：

```bash
./run2.3_prepare_topo_DEM.py 1
cat topo/dem_region.txt
```

Mode 1 创建 `topo/` 和 `dem_region.txt`，但不下载 DEM。确认 `Raw W/E/S/N`、`Final W/E/S/N`、SAFE/XML 数量和 `make_dem.csh` 命令后正式执行：

```bash
./run2.3_prepare_topo_DEM.py 2
```

Mode 2 在 `topo/` 中调用 `make_dem.csh W E S N 1`，日志写入 `topo/run2.3_make_dem.log`，并检查最终 `dem.grd` 是否存在且非空。已有 `dem.grd` 时停止，避免覆盖。

```text
T34/
├── run2.3_prepare_topo_DEM.py
├── organized/
│   └── F2399_F2449/
└── topo/
    ├── dem_region.txt
    ├── run2.3_make_dem.log
    └── dem.grd
```

脚本不写死轨道号或 frame 名称，可直接复制到其他 `T编号` 根目录使用。默认 `--margin 0.3`、`--polarization vv` 和 `--resolution 1`。

---

## Run 2.4：建立 F1/F2/F3 并链接原始输入与 DEM

从轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run2.4_link_raw_topo.sh
./run2.4_link_raw_topo.sh
```

脚本要求 Run 2.2 的重组 SAFE、`organized/*.EOF` 和 Run 2.3 的 `topo/dem.grd` 已准备完成。它自动识别唯一的 `organized/F????_F????`；存在多个 frame 时使用：

```bash
./run2.4_link_raw_topo.sh --frame F2399_F2449
```

链接关系为：

```text
F1/raw → IW1 VV XML/TIFF + 全部 EOF + dem.grd
F2/raw → IW2 VV XML/TIFF + 全部 EOF + dem.grd
F3/raw → IW3 VV XML/TIFF + 全部 EOF + dem.grd

F1/topo/dem.grd → topo/dem.grd
F2/topo/dem.grd → topo/dem.grd
F3/topo/dem.grd → topo/dem.grd
```

脚本只建立相对符号链接，不复制大型数据。每个 IW 的 XML/TIFF 数量必须分别等于 SAFE 数量；链接完成后自动检查断链。重复执行会更新已有符号链接，但不会覆盖同名普通文件。

```text
T34/
├── run2.4_link_raw_topo.sh
├── organized/F2399_F2449/
├── organized/*.EOF
├── topo/dem.grd
├── F1/{raw,topo}/
├── F2/{raw,topo}/
└── F3/{raw,topo}/
```

脚本不写死轨道号，可复制到其他 `T编号` 根目录使用。默认链接 VV，其他极化可用 `--polarization` 指定。

---

## Run 3.1：为 F1/F2/F3 生成并调整 `data.in`

Run 2.4 完成后，从轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run3.1_prep_data_F123.sh
./run3.1_prep_data_F123.sh
```

无参数只检查 `F1/raw`、`F2/raw`、`F3/raw` 的 VV XML/TIFF、EOF、DEM 和断链情况，并显示正式命令，不清理或生成任何文件。检查通过后正式运行：

```bash
./run3.1_prep_data_F123.sh 1
```

模式1依次处理 `F1/raw`、`F2/raw`、`F3/raw`，先再次验证 VV XML/TIFF 数量相等、EOF 存在、`dem.grd` 唯一且全部符号链接有效，再运行：

```bash
prep_data_linux.csh > prep_data.log 2>&1
```

原始 `data.in` 保存为 `data.in.orig`。至少有 3 条记录时，把中间记录移到首行；偶数条选择中间靠前的一条，例如 6 条选第 3 条、8 条选第 4 条。移动前内容另存为 `data.in.before_middle_first`。

```text
F1/raw/
├── data.in
├── data.in.orig
├── data.in.before_middle_first
└── prep_data.log

F2/raw/  # 同样输出
F3/raw/  # 同样输出
```

该参考记录选择方式要求 `prep_data_linux.csh` 输出已按时间排序。任一 F 失败时脚本立即停止；旧的 XML、TIFF、EOF 和 DEM 链接不会被删除。

---

## Run 3.2：并行预处理 F1/F2/F3

Run 3.1 完成后，从轨道根目录执行标准预处理：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run3.2_preproc_batch_tops_F123.sh
./run3.2_preproc_batch_tops_F123.sh
```

无参数不会出现交互菜单，也不会开始处理，只显示推荐命令。正式标准处理必须运行：

```bash
./run3.2_preproc_batch_tops_F123.sh 5 1
```

`5` 是每个 frame 的建议并行任务数，`1` 表示一般使用的标准模式。无参数提示还会打印三种 ESD 备选命令。

参数格式：

```text
./run3.2_preproc_batch_tops_F123.sh NCORES_PER_FRAME MODE [ESD_MODE]
```

- MODE `1`：标准 `preproc_batch_tops.csh`；
- MODE `2`：`preproc_batch_tops_esd.csh`；
- 一般建议配置：`5 1`；前两个参数必须提供，MODE `2` 时还必须提供 `ESD_MODE`。

`ESD_MODE` 只在 MODE `2` 时使用：

- `0`：average，平均残余方位偏移，常数修正；
- `1`：median，中位数残余方位偏移，常数修正，也是一般 ESD 建议值；
- `2`：interpolation，对残余方位偏移进行空间插值修正。

一般处理默认运行：

```bash
./run3.2_preproc_batch_tops_F123.sh 5 1
```

有 ESD 需求时，可在以下三种方式中选择；一般优先使用中位数：

```bash
./run3.2_preproc_batch_tops_F123.sh 5 2 0  # average
./run3.2_preproc_batch_tops_F123.sh 5 2 1  # median
./run3.2_preproc_batch_tops_F123.sh 5 2 2  # interpolation
```

其内部命令为 `preproc_batch_tops_esd.csh data.in dem.grd 2 1`：前一个 `2` 是 GMTSAR 完整预处理/配准模式，最后的 `1` 才是 ESD 中位数模式。

脚本不会等待菜单选择。无参数只显示标准模式、三种 ESD 命令和并行说明后退出，并明确提示需要 ESD 时默认建议 median（`ESD_MODE=1`）；只有输入完整的 `5 1` 或 ESD 参数命令才开始处理。

F1、F2、F3 同时启动，每个 frame 内部再启动 `NCORES_PER_FRAME` 个影像对任务。默认值 `5` 对应近似 `3 × 5 = 15` 个任务。第一个参数可以自行调整；计算机 CPU、内存或磁盘 I/O 能力较弱时，可降低为 `3` 或 `2`。

长时间运行建议：

```bash
nohup ./run3.2_preproc_batch_tops_F123.sh 5 1 \
  > run3.2_preproc_batch_tops.nohup.log 2>&1 &
```

启动前统一检查三套 `data.in`、XML/TIFF、EOF、DEM、断链和依赖。每次重跑会清理旧的 PRM/LED/SLC、基线文件、影像对临时目录和日志，但保留 `data.in` 与所有输入链接。

完成后，每个 frame 的 PRM、LED、SLC 数量以及 `baseline_table.dat` 行数都必须等于 `data.in` 记录数；标准模式仍按原逻辑要求 `baseline.ps` 存在且非空。

标准模式生成 `baseline.ps` 后，自定义脚本 `preproc_batch_tops_parallel_new_wx.csh` 自动运行 `gmt psconvert baseline.ps -Tf -A`，生成：

```text
F1/raw/baseline.pdf
F2/raw/baseline.pdf
F3/raw/baseline.pdf
```

自定义 CSH 会检查转换命令和 PDF 文件；Run 3.2 不新增 PDF 文件检查，只保留原来的 `baseline.ps` 检查。若自定义 CSH 转换失败并返回非零状态，Run 3.2 会通过原有退出状态检查报告失败。

```text
F1/raw/preproc_all.log
F2/raw/preproc_all.log
F3/raw/preproc_all.log
```

三套任务都结束后统一汇总状态；任一 frame 失败时 Run 3.2 返回非零状态。

---

## Run 3.3：生成干涉对列表和处理配置

Run 3.2 完成后，从轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run3.3_make_intf_config_F123.sh
./run3.3_make_intf_config_F123.sh
```

无参数只显示两步命令，不开始选对。第一步使用模式1生成 F1 干涉网络和时空基线图：

```bash
./run3.3_make_intf_config_F123.sh 1 60 150
```

参数含义：

```text
1   = PREVIEW，只在 F1 选对并生成图
60  = threshold_time，时间基线阈值，单位：天
150 = threshold_baseline，空间基线阈值，单位：米
```

调用格式为：

```text
select_pairs_new.csh baseline_table.dat threshold_time threshold_baseline
```

模式1生成：

```text
F1/intf.in
F1/baseline.ps
F1/baseline.pdf
F1/run3.3_preview.info
F1/select_pairs_new.log
```

其中 `baseline.pdf` 是时空基线网络图：点表示影像，线表示选中的干涉对。先查看：

```text
/data2/xinw/InSAR_processing/Descending/T34/F1/baseline.pdf
```

如果网络过密或过疏，用新的时间基线和空间基线阈值重新执行模式1。模式1不会生成或覆盖 F2/F3 的正式文件。

模式1还会生成 `F1/batch_tops.config`。其 `master_image` 日期来自 `F1/raw/data.in` 第一行，即 Run3.1 调整到首行的统一主影像：

```text
F1/raw/data.in 第一行的日期 YYYYMMDD
→ master_image = S1_YYYYMMDD_ALL_F1
```

确认图和干涉对合适后执行：

```bash
./run3.3_make_intf_config_F123.sh 2
```

模式2不重新运行 `select_pairs_new.csh`，而是接受最近一次模式1的结果，将 F1 的 `intf.in` 和配置复制并转换为 F2/F3。

运行前要求：

- `F1`、`F2`、`F3` 已存在；
- `F1/raw/data.in` 与 `F1/raw/baseline_table.dat` 非空且行数相同；
- `/home/xinw/bin/own/batch_tops.config` 存在；
- `/home/xinw/bin/own/select_pairs_new.csh` 存在。

两步处理过程：

1. 将 F1 的 `data.in` 和 `baseline_table.dat` 复制到 `F1/`；
2. 从 `F1/data.in` 第一行提取统一主影像日期；
3. 将配置中的 `master_image` 设置为 `S1_日期_ALL_F1`；
4. 模式1只在 F1 上运行一次 `select_pairs_new.csh`，生成 `intf.in` 和 `baseline.pdf` 后停止；
5. 人工查看时空基线网络，必要时修改阈值并重跑模式1；
6. 模式2把确认后的干涉对和配置复制到 F2/F3，只把影像名后缀 `_F1` 改成 `_F2`、`_F3`；
7. 检查三个 `intf.in` 行数相同，并检查三个 `master_image`。

输出：

```text
F1/
├── baseline_table.dat
├── data.in
├── intf.in
├── batch_tops.config
├── baseline.pdf
├── run3.3_preview.info
└── select_pairs_new.log

F2/
├── intf.in
└── batch_tops.config

F3/
├── intf.in
└── batch_tops.config
```

这种方式保证 F1、F2、F3 使用经过人工查看的同一组日期对。`sed` 只替换影像名中的 `_F1`，不会替换配置文件里无关的 `F1` 字符。

---

## Run 3.4：生成雷达坐标地形文件

Run3.3 模式2完成后，在轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run3.4_dem2topo_ra_F123.sh
./run3.4_dem2topo_ra_F123.sh
```

无参数只显示命令，不启动任务。模式1统一检查后，同时提交 F1/F2/F3：

```bash
./run3.4_dem2topo_ra_F123.sh 1
```

每个 frame 从 `batch_tops.config` 读取 `master_image`，检查对应的：

```text
F?/raw/<master_image>.PRM
F?/raw/<master_image>.LED
F?/topo/dem.grd
```

然后在 `F?/topo/` 建立主影像 PRM/LED 链接，并同时运行：

```bash
nohup dem2topo_ra.csh <master_image>.PRM dem.grd 0 \
  > dem2topo_ra.log 2>&1 &
```

三个 frame 全部通过预检后才开始，避免只启动一部分。每个目录保存：

```text
F?/topo/dem2topo_ra.pid
F?/topo/dem2topo_ra.log
```

Run3.4 仅保留模式1。启动三个任务后不会立即退出，而是等待 F1/F2/F3 全部结束，然后自动检查：

- 每个 `dem2topo_ra.csh` 的退出状态为0；
- 每个 `trans.dat` 存在且非空；
- 每个 `topo_ra.grd` 存在且非空。

任意 frame 不满足条件时，脚本显示对应日志最后20行并返回失败；三个 frame 全部通过才显示 `[DONE]`。

实时查看某个 frame：

```bash
tail -f F1/topo/dem2topo_ra.log
```

长时间运行时，建议让整个 Run3.4 在 `nohup` 中执行，这样自动等待和最终检查不会因终端断开而中止：

```bash
nohup ./run3.4_dem2topo_ra_F123.sh 1 \
  > run3.4_dem2topo_ra.nohup.log 2>&1 &
```

模式1会拒绝重复启动仍在运行的 PID；重新运行已结束任务时，会清理该 frame 旧的 `dem2topo_ra.log`、`trans.dat`、`tmp_dem_ra.grd` 和 `topo_ra.grd`，但不删除 `dem.grd`、原始 PRM/LED 或配置文件。

---


### Run 3.4 并行加速版本

标准版 `run3.4_dem2topo_ra_F123.sh` 保留不变。服务器已经安装并编译并行坐标转换程序时，也可以使用：

```bash
./run3.4_dem2topo_ra_parallel_F123.sh
```

无参数只显示命令说明，不开始处理。默认正式运行：

```bash
./run3.4_dem2topo_ra_parallel_F123.sh 1
```

等价于：

```bash
./run3.4_dem2topo_ra_parallel_F123.sh 1 5 0
```

三个参数分别表示模式1、每个 frame 的 OpenMP 线程数和插值方式。F1、F2、F3 同时运行，默认每个 frame 使用5个 `SAT_llt2rat_para` 线程，因此最大约为15个坐标转换线程。

插值方式：

- `0`：GMT `surface`，默认且推荐用于正式处理，结果平滑并保持原始 GMTSAR 处理思路；
- `1`：GMT `triangulate`，小范围测试中插值阶段约快30倍，但可能出现三角形边界，主要用于快速预览。

所需服务器程序：

```text
/home/xinw/bin/own/dem2topo_ra_parallel.csh
/home/xinw/bin/own/SAT_llt2rat_para
```

主要输出：

```text
F1/topo/trans.dat  F1/topo/topo_ra.grd  F1/topo/topo_ra.pdf
F2/topo/trans.dat  F2/topo/topo_ra.grd  F2/topo/topo_ra.pdf
F3/topo/trans.dat  F3/topo/topo_ra.grd  F3/topo/topo_ra.pdf
```

长时间运行建议：

```bash
nohup ./run3.4_dem2topo_ra_parallel_F123.sh 1 5 0 \
  > run3.4_parallel.nohup.log 2>&1 &
```

标准版和并行版是二选一关系，不要同时处理相同的 F1/F2/F3。并行版会在重新运行时清理旧的 `trans.dat`、`topo_ra.grd` 和并行日志，但不会删除 DEM、PRM、LED 或配置文件。

---

## Run 3.5：并行生成 F1/F2/F3 TOPS 干涉图

Run3.4完成后，从轨道根目录运行。无参数显示说明，并自动检查 F1/F2/F3 是否存在非空的 `intf.in` 和 `batch_tops.config`、统计干涉对数量、确认 `proc_stage=2` 和 `topo_phase=1`；不会启动处理：

```bash
./run3.5_intf_tops_parallel_F123.sh
```

推荐每个 frame 使用5个并行干涉对任务：

```bash
./run3.5_intf_tops_parallel_F123.sh 5
```

脚本同时运行 F1、F2、F3；每个 frame 内部调用：

```bash
nohup intf_tops_parallel.csh intf.in batch_tops.config 5 >& itp.log &
```

总并行任务约为 `3 × 5 = 15`。运行前必须确认：

```text
proc_stage = 2
topo_phase = 1
```

`proc_stage=2` 会跳过共享 `topo/` 的重新生成，直接使用 Run3.4 已生成的 `topo_ra.grd` 和 `trans.dat`，避免并行任务同时清理地形文件。

长任务推荐：

```bash
nohup ./run3.5_intf_tops_parallel_F123.sh 5 \
  > run3.5_intf_tops_parallel.nohup.log 2>&1 &
```

主要输出：

```text
F1/itp.log       F1/intf_all/<日期对>/
F2/itp.log       F2/intf_all/<日期对>/
F3/itp.log       F3/intf_all/<日期对>/
```

脚本启动前检查 `intf.in`、配置、PRM/LED/SLC及地形文件；结束后检查每对日志的完成标志、对应 `intf_all` 目录和 `.grd` 结果。失败记录写入 `F?/run3.5_failed_pairs.tsv`。

---

## Run 3.6：清理 Run3.5 临时文件并拼接 F1/F2/F3

先进行只读检查：

```bash
./run3.6_merge_F123.sh
```

该命令检查 F1/F2/F3 的 `intf_all/` 日期对是否完全一致，逐个日期对统计并检查 `corr.grd`、`mask.grd`、`phasefilt.grd`，同时统计 `F*/intf_20*.in`、`F*/intf_20*.log`；不会删除或运行。若有网格缺失，终端会显示对应的 frame、干涉对和缺少的文件。

第一步直接选择最终 `merge_list` 的第一个、中间一个和最后一个记录并生成GMT预览图：

```bash
./run3.6_merge_F123.sh 1 15
```

模式1从经过主影像优先排序的最终 `merge_list` 取第一个、中间一个和最后一个日期对，拼接完成后分别绘制 `corr.grd`、`mask.grd`、`phasefilt.grd`，共生成9张图：

```text
merge/run3.6_check_merge_seams_plots/<日期对>_corr.pdf
merge/run3.6_check_merge_seams_plots/<日期对>_mask.pdf
merge/run3.6_check_merge_seams_plots/<日期对>_phasefilt.pdf
```

最终 `merge_list` 第1行已经是主影像相关记录，因此预览只计算这3个日期对，不额外加入初始化记录。模式1使用单独的 `preview_batch_tops.config` 关闭解缠、地理编码和电离层改正，并以运行后自动删除的空 `trans.dat` 占位文件阻止真实投影LUT生成，所以只进行拼接和绘图。绘图沿用GMTSAR `geocode.csh` 的GMT classic格式：Range/Azimuth坐标轴、顶部水平色标和 `psconvert -Tf` PDF转换。`corr`、`mask` 使用0–1灰度且NaN为灰色，`phasefilt` 使用 −3.15 到3.15 rad 色标。脚本随后停止，不会继续完整拼接。检查 F1/F2/F3 交界位置没有明显缝隙、空白或错位后，运行模式2：

```bash
./run3.6_merge_F123.sh 2 15
```

正式模式必须在模式号后给出并行数，推荐15；资源较少时可使用 `./run3.6_merge_F123.sh 2 5` 或把5改为3。原始 `merge_batch_parallel.sh` 没有作业数参数，Run3.6通过 GNU Parallel 的 `PARALLEL="--jobs 15"` 环境选项限制并行数，因此不修改GMTSAR安装目录中的原脚本。

模式1先检查每个干涉对都具有非空的 `corr.grd`、`mask.grd` 和 `phasefilt.grd`。如果任意一个 frame 的某日期对不完整，脚本会把该日期对在 F1/F2/F3 中的三个输出目录统一列入删除计划，并显示缺失来源。只有用户在交互终端准确输入 `DELETE` 后才会删除；其他输入均取消。缺失清单保存为 `run3.6_missing_grids.tsv`，确认后的删除记录保存为 `run3.6_deleted_pairs.tsv`，F1/F2/F3 的 `intf.in` 不修改。

完成网格检查或确认删除后，脚本清理 Run3.5 留下的 `intf_20*.in` 和 `intf_20*.log`，保留其余 `intf_all/`，再创建 `merge/`、生成 `intflist` 和 `merge_list`，复制 F1 配置并设置 `proc_stage=1`，链接轨道级 `topo/dem.grd`。主影像排序只使用临时文件，不生成 `merge_list.orig`，并会清除以前遗留的同名文件。模式2只有在模式1生成 `run3.6_preview_complete` 和 `run3.6_check_merge_seams_plots/` 后才允许启动；启动后删除 `merge/20*` 预览结果目录及全部预览控制文件，只保留该目录中的PDF，不影响 F1/F2/F3 的源干涉结果。随后清除可能遗留的空 `trans.dat`，使用正式配置生成真实LUT并完成整个列表。如果在 `nohup` 中检测到缺失网格，因为无法交互确认，脚本会安全停止而不删除。

服务器长任务：

```bash
nohup ./run3.6_merge_F123.sh 2 15 \
  > run3.6_merge_F123.nohup.log 2>&1 &
```

查看日志：

```bash
tail -f run3.6_merge_F123.nohup.log
tail -f merge/merge_batch.log
```

### Run 3.6 并行 trans.dat 版本

保留标准 `run3.6_merge_F123.sh` 不变。正式处理需要用 `/home/xinw/bin/own/SAT_llt2rat_para` 并行生成 `trans.dat` 时运行：

```bash
./run3.6_merge_F123_parallel_trans.sh 2 15 5
```

`15` 是干涉对拼接并行数，`5` 是 `SAT_llt2rat_para` 的OpenMP线程数。独立脚本只在当前任务中临时把GMTSAR的 `SAT_llt2rat master.PRM 1 -bod` 调用转换成 `SAT_llt2rat_para master.PRM dem.grd -bod`，任务结束即删除转换器，不修改GMTSAR安装和标准Run3.6。日志出现 `[PARALLEL TRANS] 5 threads` 表示并行LUT程序已启用。

---

## Run 3.7：检查并绘制拼接后的相关性与滤波相位

Run3.6 正式拼接完成后，从轨道根目录查看命令说明：

```bash
./run3.7_plot_merge_corr_phasefilt.sh
```

无参数只显示用法，不检查、不画图。第一步检查全部 `merge/20*` 干涉对目录：

```bash
./run3.7_plot_merge_corr_phasefilt.sh 1
```

模式1要求每个干涉对同时具有非空的：

```text
corr.grd
phasefilt.grd
```

检查成功后生成：

```text
merge/run3.7_check_complete
```

如果存在缺失或空文件，详细清单写入：

```text
merge/run3.7_missing_grids.tsv
```

脚本不会自动删除干涉对或网格。修复缺失结果后必须重新运行模式1。

推荐的模式2按第一景日期的年份分组，并选取每年实际干涉对列表约25%和75%位置的记录进行绘图：

```bash
./run3.7_plot_merge_corr_phasefilt.sh 2
```

某一年只有一个干涉对时只绘制一次；数据只覆盖一年中部分时段时，仍按该年现有列表的25%和75%位置选择，不要求完整覆盖全年。默认同时绘制5个干涉对。

其他选择方式：

```bash
# 指定日期：绘制所有包含该日期的干涉对
./run3.7_plot_merge_corr_phasefilt.sh 2 2021051 5

# 指定一个完整干涉对
./run3.7_plot_merge_corr_phasefilt.sh 2 2021051_2021063 1

# 绘制全部干涉对
./run3.7_plot_merge_corr_phasefilt.sh 2 all 5

# 根据文本清单绘图，每行一个干涉对
./run3.7_plot_merge_corr_phasefilt.sh 2 @pair_list.txt 5
```

输出按类型集中保存，不建立单独的日期文件夹，也不保留每对 `plot.log`：

```text
merge/run3.7_corr_phasefilt_jpg/
├── corr/<日期对>_corr.jpg
└── phasefilt/<日期对>_phasefilt.jpg
```

`corr` 使用0–1灰度，`phasefilt` 使用约 −π～π 彩色相位色标；NaN 区域统一显示为灰色。模式2开始前会再次检查全部网格，防止模式1以后数据发生变化。

## Run 3.8：并行叠加相关性并生成统一相干性掩膜

先执行无参数检查：

```bash
./run3.8_stack_coherence_mask_parallel.sh
```

该命令统计所有 `merge/20*/corr.grd`，确认每个干涉对都具有非空的相关性网格；不会创建或删除文件。推荐正式命令：

```bash
./run3.8_stack_coherence_mask_parallel.sh 0.075 50 5
```

参数含义：

```text
0.075 = 平均相关性阈值
50    = 每个批次叠加50个 corr.grd
5     = 同时运行5个批次
```

这里的 `50` 是每个批次包含的网格数，不是并行数；最后的 `5` 才是并行批次数。脚本先把所有相关性网格分批求和，再合并批次结果并除以总干涉对数量：

```text
全部 corr.grd
      ↓ 分批并行求和
mean_corr.grd
      ↓ mean_corr >= 0.075
mask_def.grd：有效像元=1，低相关像元=NaN
```

输出：

```text
merge/grid_list
merge/mean_corr.grd
merge/mask_def.grd
merge/mask_def.pdf
```

`mask_def.pdf` 使用灰色显示无效/NaN区域、红色显示有效掩膜。成功后自动删除 `stack_batches/`、批次网格、批次日志和求和临时文件，只保留以上正式结果。重新正式运行会替换旧的 Run3.8 输出。

## Run 3.9：生成雷达坐标陆地掩膜

必须从轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
./run3.9_make_landmask_ra.sh
```

无参数只检查，不生成文件。检查内容包括：

- `merge/dem.grd` 存在且非空；
- `merge/trans.dat` 存在并且大于20 MiB，避免误用模式1留下的空占位文件；
- 至少存在一个非空的 `merge/20*/phasefilt.grd`；
- 显示当前 `landmask_ra.grd` 和 PDF 是否已经存在。

正式生成：

```bash
./run3.9_make_landmask_ra.sh 1
```

脚本选择排序后的第一个 `phasefilt.grd` 作为雷达网格模板，读取其范围，随后在 `merge/` 中运行：

```text
landmask.csh <雷达坐标范围>
```

再使用 `gmt grdsample -R<模板网格>` 使陆地掩膜的范围、间隔、行列数和注册方式与 `phasefilt.grd` 完全一致。输出：

```text
merge/landmask_ra.grd
merge/landmask_ra.pdf
```

PDF 中灰色表示海洋、背景或NaN，红色表示陆地。正式运行会替换旧的陆地掩膜结果并清理 `landmask.grd`、XYZ和重采样临时文件。

## Run 3.10：预览 SNAPHU 输入并并行解缠

Run3.8 和 Run3.9 完成后，从轨道根目录先执行无参数检查：

```bash
./run3.10_unwrap_merge_parallel.sh
```

无参数模式会检查：

- 每个 `merge/20*` 干涉对目录都有非空的 `corr.grd`、`mask.grd`、`phasefilt.grd`；
- `merge/mask_def.grd` 和 `merge/landmask_ra.grd` 存在且与相位网格的范围、间隔、尺寸和注册方式一致；
- 统计已有的 `unwrap.grd`、`unwrap.pdf`、完整干涉对和待处理干涉对。

无参数只显示检查与命令说明，不生成预览，也不开始解缠。

### Run 3.10 模式1：预览一个解缠输入

使用默认相关性阈值 `0.0001`，自动选择排序后的中间干涉对：

```bash
./run3.10_unwrap_merge_parallel.sh 1 0.0001
```

指定一个干涉对目录：

```bash
./run3.10_unwrap_merge_parallel.sh 1 0.0001 2021051_2021063
```

模式1先组合：

```text
corr.grd >= 0.0001
        × mask.grd
        × mask_def.grd
        × landmask_ra.grd
        = combined mask
```

然后生成两张 PDF：

```text
merge/run3.10_presnaphu_preview/
├── <日期对>_combined_mask_presnaphu.pdf
└── <日期对>_phase_presnaphu.pdf
```

第一张只显示组合掩膜，不乘 `phasefilt.grd`；第二张显示 `phasefilt.grd × combined mask`。NaN 使用灰色。模式1不运行 `nearest_grid`、不运行 SNAPHU、不生成 `unwrap.grd`。`mask_all.grd`、预览相位网格和 CPT 全部位于临时目录，正常完成、报错或中断退出时都会删除，最终只保留两张 PDF。

### Run 3.10 模式2：正式可续跑并行解缠

推荐5个并行任务：

```bash
./run3.10_unwrap_merge_parallel.sh 2 5 0.0001
```

服务器资源充足时可以提高并行数，例如：

```bash
./run3.10_unwrap_merge_parallel.sh 2 20 0.0001
```

参数依次表示模式2、同时解缠的干涉对数量和相关性阈值。面向连续形变 SBAS 时，最大不连续参数固定在脚本内部为0，实际调用为：

```text
snaphu_interp.csh 0.0001 0
```

模式2会自动通过 `nohup` 提交后台实例并立即返回终端，不要再手工添加 `nohup` 或 `&`。主日志：

```bash
tail -f run3.10_unwrap_merge_parallel.nohup.log
```

正式后台实例从全部日期对生成：

```text
merge/intflist
```

完成标准是同一目录中的 `unwrap.grd` 和 `unwrap.pdf` 都存在且非空。已经完成的干涉对自动跳过，其他干涉对写入：

```text
merge/unwrap_pending_intflist
```

第一次运行时该清单通常包含全部干涉对；中断后重跑相同命令时只包含尚未完整完成的干涉对；全部完成时清单为空，不会重复解缠。

模式2在 `merge/` 中生成 `unwrap_intf.csh`，为每个待处理目录链接公共的 `landmask_ra.grd` 和 `mask_def.grd`，清理上次中断遗留的 SNAPHU 临时文件，然后调用系统 `PATH` 中的：

```text
unwrap_parallel.csh
snaphu_interp.csh
```

可用下面命令确认实际版本：

```bash
command -v unwrap_parallel.csh
command -v snaphu_interp.csh
```

由于 GMTSAR 原始 `unwrap_parallel.csh` 使用 `>>` 追加 `unwrap.cmd`，Run3.10 会在每次处理前后清理这个临时命令文件，避免续跑时重复执行旧任务。每个干涉对的实际日志集中保存到：

```text
merge/run3.10_unwrap_logs/<日期对>.log
```

全部并行任务结束后，脚本再次逐对检查 `unwrap.grd` 和 `unwrap.pdf`。任意结果缺失或为空时生成：

```text
merge/run3.10_failed_pairs.tsv
```

其中记录干涉对、缺少的结果和日志路径。修复问题后重新运行同一个模式2命令，只重做未完整完成部分。最终每个成功干涉对主要具有：

```text
merge/<日期对>/unwrap.grd
merge/<日期对>/unwrap.pdf
merge/<日期对>/conncomp.grd
merge/<日期对>/phasefilt_interp.grd
```

如果任意输入干涉对缺少 `corr.grd`、`mask.grd` 或 `phasefilt.grd`，Run3.10 会列出缺失项并停止，不自动删除、不跳过，也不会启动部分解缠任务。

## Run 3.11：准备 SBAS 使用的雷达坐标 DEM

Run 3.10 完成解缠后，在轨道根目录运行：

~~~bash
cd /data2/xinw/InSAR_processing/Descending/T34
./run3.11_prepare_dem_ra_and_link.sh
~~~

无参数模式只检查，不生成或修改文件。它检查 merge/dem.grd、确认 merge/trans.dat 大于 20 MiB，并确认所有 merge/20*_* 都具有非空的 unwrap.grd。为提高千幅级数据的检查速度，只对排序后的第一个、中间一个和最后一个 unwrap.grd 调用 gmt grdinfo 比较网格范围、间隔、尺寸和注册方式，其余文件只做存在/非空检查。

正式生成：

~~~bash
./run3.11_prepare_dem_ra_and_link.sh 1
~~~

脚本从模板 unwrap.grd 读取距离向和方位向间隔，执行：

~~~text
proj_ll2ra.csh trans.dat dem.grd <临时dem_ra.grd> -I<xinc>/<yinc>
~~~

再用 gmt grdsample 将结果严格重采样到模板网格。临时文件验证成功后才替换正式结果：

~~~text
merge/dem_ra.grd
merge/tmp_dem_ra.grd
merge/tmp_dem_ra.pdf
~~~

PDF 横轴为 Range、纵轴为 Azimuth、色标单位为 m，NaN 显示为灰色。每个干涉对建立相对链接：

~~~text
merge/<日期对>/tmp_dem_ra.grd -> ../tmp_dem_ra.grd
~~~

脚本不会覆盖用户已有的同名普通文件；成功后生成 merge/run3.11_complete。

## Run 3.12：并行改正解缠结果中的 DEM 相关误差

Run 3.12 提供两种互斥算法。两种脚本都会写入同名结果，不能连续叠加使用；通常先使用默认的全局六参数模型，只有全局模型仍留下明显空间变化残差时才选择 2000px 局部模型。

### 默认：全局 4/6/9 参数模型

无参数只显示命令说明：

~~~bash
./run3.12_dem_correction_parallel_all_in_one.sh
~~~

推荐正式命令：

~~~bash
./run3.12_dem_correction_parallel_all_in_one.sh 16 6
~~~

16 是同时处理的干涉对数量，可根据内存降低为 8；6 是推荐模型。每个干涉对使用 unwrap.grd 和 tmp_dem_ra.grd。六参数误差模型为：

~~~text
P1×DEM×x + P2×DEM×y + P3×DEM + P4 + P5×x + P6×y
~~~

参数通过 NumPy 伪逆最小二乘求解，最终计算：

~~~text
unwrap_dem_correct.grd = unwrap.grd - DEM误差模型
~~~

也可选择模型 4 或 9：

~~~bash
./run3.12_dem_correction_parallel_all_in_one.sh 16 4
./run3.12_dem_correction_parallel_all_in_one.sh 16 9
~~~

模型越复杂，越可能同时吸收真实长波形变，因此通常使用模型 6。每个干涉对输出：

~~~text
unwrap_dem_correct.grd
unwrap_dem_correction.png
dem_correction.log
~~~

PNG 依次显示原始解缠相位、拟合误差模型和改正结果。再次正式运行会重新计算并覆盖已有结果。

### 备选：MATLAB-like 2000px 局部模型

查看说明：

~~~bash
./run3.12_dem_correction_matlablike_2000px_parallel_all.sh
~~~

正式运行：

~~~bash
./run3.12_dem_correction_matlablike_2000px_parallel_all.sh 8 4
~~~

第一个参数表示同时处理 8 个干涉对，第二个参数表示每个干涉对内部使用 4 个进程；最多可能出现约 32 个 Python 工作进程，内存不足时建议改为 4 2。

该算法按 2000×2000 像素分块拟合 unwrap = p1×DEM + p2，把分块参数放在块中心，最近邻填充到完整网格，再以 sigma=2000/3、truncate=1.5 进行高斯平滑，最后从 unwrap.grd 中减去空间变化的局部模型。它与全局模型输出同名文件，并且是强制重算版本。

## Run 3.13：为 DEM 改正结果设置稳定参考区域

解缠相位仍有任意常数偏移，因此需要从每幅干涉图中减去同一稳定区域的中位数。无参数只检查输入并显示说明：

~~~bash
./run3.13_reference_dem_correct_parallel.sh
~~~

正式运行必须由用户明确提供并行数和雷达坐标范围，没有默认参考范围：

~~~bash
./run3.13_reference_dem_correct_parallel.sh 10 10000/10096/5000/5024
~~~

参数含义：

~~~text
10                       = 同时处理的干涉对数量
10000/10096/5000/5024    = xmin/xmax/ymin/ymax（Range/Azimuth）
~~~

参考区域应位于所有干涉对都有有效值的稳定、高相干、非水体区域，并避开强形变、图像边缘和残余地形误差。每个干涉对计算：

~~~text
参考中位数 = median(unwrap_dem_correct.grd 在指定区域内)
unwrap_dem_correct_pin_up.grd = unwrap_dem_correct.grd - 参考中位数
~~~

输出：

~~~text
merge/<日期对>/unwrap_dem_correct_pin_up.grd
merge/<日期对>/reference_dem_correct.info
merge/run3.13_reference_values.tsv
merge/run3.13_complete
~~~

相同参考范围下重新运行会跳过已经完成的干涉对；改变参考范围后会重新生成。

## Run 4.1：根据最终干涉对准备 SBAS 输入

脚本：run4.1_update_sbas_intf_baseline.sh。

无参数只检查，不创建或修改文件：

~~~bash
./run4.1_update_sbas_intf_baseline.sh
~~~

每个可进入 SBAS 的 merge/20*_* 目录必须同时包含非空的：

~~~text
corr.grd
phasefilt.grd
unwrap_dem_correct_pin_up.grd
~~~

缺少任意文件的干涉对会被记录并排除，但脚本绝不删除 merge/ 中的目录。正式生成并默认使用 F1 命名：

~~~bash
./run4.1_update_sbas_intf_baseline.sh 1
~~~

也可以明确指定：

~~~bash
./run4.1_update_sbas_intf_baseline.sh 1 F1
~~~

脚本根据有效目录生成 intflist_new，将 GMTSAR 零起始的 YYYYDOY 日期编号转换为实际 YYYYMMDD，例如：

~~~text
2021051_2021063
→ S1_20210221_ALL_F1:S1_20210305_ALL_F1
~~~

然后始终从原始 F1/baseline_table.dat 重新筛选实际参与 SBAS 的影像，避免重复运行时无法恢复先前被排除的日期。输出：

~~~text
sbas_demcorr_pin/
├── intflist_new
├── intf.in
├── baseline_table.dat
├── run4.1_missing_pairs.tsv
└── run4.1_complete
~~~

已有输出会在正式运行前备份到带时间戳的 sbas_demcorr_pin/run4.1_backup_* 目录。脚本验证 intf.in 干涉对数量、唯一影像数量和基线表记录数量一致后才写入结果。Run 4.1 只准备 SBAS 清单和基线表，不执行 SBAS 反演。

## Run 4.2：生成 GMTSAR SBAS 表格和并行反演命令

Run 4.1 正式完成后，在轨道根目录执行无参数检查：

~~~bash
./run4.2_generate_sbas_tables_command.sh
~~~

无参数模式检查：

- sbas_demcorr_pin/intflist_new、intf.in 和 baseline_table.dat 存在且非空；
- intflist_new 与 intf.in 的干涉对数量一致；
- 从 intflist_new 中选择第一个同时具有 supermaster.PRM、unwrap_dem_correct_pin_up.grd 和 corr.grd 的有效模板干涉对；
- 从模板 PRM 读取 radar_wavelength、rng_samp_rate 和 near_range；
- 从最终改正网格读取 x/y 范围、间隔和尺寸；
- 按 GMTSAR 手册公式计算影像中心斜距；
- 检查 prep_sbas.csh、GMT 和 Python 依赖。

无参数不会运行 prep_sbas.csh，也不会启动 sbas_parallel。

使用默认入射角 38° 和平滑参数 1.0 正式准备：

~~~bash
./run4.2_generate_sbas_tables_command.sh 1
~~~

也可以显式指定：

~~~bash
./run4.2_generate_sbas_tables_command.sh 1 38 1.0
~~~

脚本进入 sbas_demcorr_pin/ 后运行：

~~~text
prep_sbas.csh intf.in baseline_table.dat ../merge \
  unwrap_dem_correct_pin_up.grd corr.grd
~~~

随后从 prep_sbas.log 中自动提取 sbas_parallel 所需的 N、S、XDIM 和 YDIM。中心斜距使用：

~~~text
range = near_range
      + (c / rng_samp_rate / 2)
      × (((x_min + x_max) / 2) / 2)
~~~

最终生成：

~~~text
sbas_demcorr_pin/
├── intf.tab
├── scene.tab
├── supermaster.PRM
├── prep_sbas.log
├── range_check.log
├── run_sbas_parallel.sh
└── run4.2_complete
~~~

run_sbas_parallel.sh 中保存完整命令，例如：

~~~text
sbas_parallel intf.tab scene.tab N S XDIM YDIM \
  -smooth 1.0 -wavelength 0.0554658 \
  -incidence 38 -range <计算值> -rms -dem
~~~

Run 4.2 验证 intf.tab 行数与 Run 4.1 的有效干涉对数量一致，并备份已有 Run 4.2 文件。它只准备命令，不执行 SBAS 反演；实际反演放在后续 Run 4.3。

## Run 4.3：后台提交并行 SBAS 反演

Run 4.3 是放在轨道根目录的固定控制脚本：

~~~text
run4.3_sbas_parallel.sh
~~~

Run 4.2 生成的实际 SBAS 命令仍保存在：

~~~text
sbas_demcorr_pin/run_sbas_parallel.sh
~~~

先执行无参数检查：

~~~bash
./run4.3_sbas_parallel.sh
~~~

检查内容包括：

- intf.tab、scene.tab、run4.2_complete 和内部 run_sbas_parallel.sh 存在且非空；
- 内部命令文件具有执行权限；
- intf.tab 和 scene.tab 行数与 Run 4.2 记录的干涉对、影像数量一致；
- 能从内部脚本读取有效的 sbas_parallel 命令；
- 现有 PID 是否仍在运行。

无参数不会启动反演。正式后台提交：

~~~bash
./run4.3_sbas_parallel.sh 1
~~~

Run 4.3 内部执行：

~~~bash
cd sbas_demcorr_pin
nohup ./run_sbas_parallel.sh > run4.3_sbas_parallel.log 2>&1 &
~~~

因此调用 Run 4.3 时不要再手工添加 nohup 或结尾的 &。提交后生成：

~~~text
sbas_demcorr_pin/run4.3_sbas_parallel.log
sbas_demcorr_pin/run4.3_sbas_parallel.pid
sbas_demcorr_pin/run4.3_submission.info
~~~

监控日志：

~~~bash
tail -f sbas_demcorr_pin/run4.3_sbas_parallel.log
~~~

检查进程：

~~~bash
ps -p $(cat sbas_demcorr_pin/run4.3_sbas_parallel.pid)
~~~

如果 PID 对应的任务仍在运行，脚本拒绝重复提交。旧的日志、PID 和提交记录会在下一次正式提交前移动到带时间戳的 run4.3_backup_* 目录。Run 4.3 只负责安全提交和记录进程；SBAS 结果完整性检查将在后续步骤继续补充。

## Run 4.4：投影 SBAS 速度并生成 PDF/KML

脚本放在轨道根目录运行。无参数只检查 `sbas_demcorr_pin/vel.grd`、有效的 `merge/trans.dat`、`gauss_400` 和所需 GMTSAR/GMT 命令，不创建文件：

~~~bash
./run4.4_geocode_sbas_velocity.sh
~~~

正式运行，默认使用 400 m 空间滤波：

~~~bash
./run4.4_geocode_sbas_velocity.sh 1
~~~

脚本按干涉对目录名称排序，固定选择第一个 `F1/intf_all/20*_20*/gauss_400`。该路径和 400 m 滤波距离均不需要手动输入。

正式运行时，脚本在 `sbas_demcorr_pin/` 建立 `trans.dat` 和 `gauss_400` 软链接，只执行带 400 m 空间滤波的投影：

~~~text
sbas_demcorr_pin/vel_ll.grd
sbas_demcorr_pin/vel_ll.cpt
sbas_demcorr_pin/vel_ll.pdf
sbas_demcorr_pin/vel_ll.kml（以及 grd2kml.csh 生成的配套文件）
sbas_demcorr_pin/run4.4_complete
~~~

其中 `vel_ll.grd`、PDF 和 KML 都使用 400 m 空间滤波结果，不再额外生成未滤波速度网格。默认色标为 `-10/10/1`，可通过 `VEL_CPT_MIN`、`VEL_CPT_MAX` 和 `VEL_CPT_STEP` 临时调整。重复正式运行时，脚本直接删除并重新生成上一轮 Run 4.4 产品，不建立备份目录。PDF 标题固定为 `SBAS velocity`。

## Run 5.1：并行去除位移时间序列中的季节项

脚本放在轨道根目录运行，从 `sbas_demcorr_pin/` 自动读取全部 `disp_YYYYDDD.grd`。无参数只检查输入数量、起止历元、网格结构、模型、分块、并行数和预计单任务内存，不创建任何文件：

~~~bash
./run5.1_remove_season_from_grd_stack_parallel.py
~~~

正式运行保持原算法默认值：128行一块、20个并行进程：

~~~bash
./run5.1_remove_season_from_grd_stack_parallel.py 1
~~~

服务器内存或磁盘繁忙时可降低并行数：

~~~bash
./run5.1_remove_season_from_grd_stack_parallel.py 1 --jobs 5
~~~

默认逐像元拟合：

~~~text
常数 + 线性趋势 + 年周期正余弦 + 半年周期正余弦
~~~

脚本只减去年周期和半年周期，保留常数与长期线性趋势，然后把每个像元重新参考到第一期，使第一期位移为0。完整时序像元批量求解，部分缺测但有效观测数不少于模型参数数的像元单独最小二乘求解。

正式结果为：

~~~text
sbas_demcorr_pin/disp_deseason/disp_YYYYDDD.grd
sbas_demcorr_pin/disp_deseason/run5.1_complete
~~~

处理期间先写临时输出，全部分块成功、GMT头信息刷新完成且输出数量正确后才替换正式 `disp_deseason/`。失败时清理临时结果并保留原正式目录。同一轨道不允许同时运行两个 Run 5.1。


## Run 5.2：绘制去季节点时间序列

在轨道根目录无参数运行，检查原始与去季节历元、网格和检查点，不创建结果：

~~~bash
./run5.2_plot_deseason_point_timeseries.py
~~~

正式绘制默认的 W、E、S、N、C 五点：

~~~bash
./run5.2_plot_deseason_point_timeseries.py 1
~~~

默认坐标为 W(10000,16000)、E(58000,16000)、S(34000,5000)、N(34000,28000)、C(34000,16000)。这些是雷达网格 X/Y 坐标，不是经纬度；脚本使用最近的网格节点。不同轨道可重复添加 `--point NAME X Y`，使用自定义点时会替换全部默认点：

~~~bash
./run5.2_plot_deseason_point_timeseries.py 1 \
  --point P1 34000 16000 \
  --point P2 40000 12000
~~~

输出目录为：

~~~text
sbas_demcorr_pin/disp_deseason/run5.2_point_timeseries/
~~~

每个点输出 `<点名>_3rows.png` 和 `<点名>_timeseries.txt`。三行依次为原始位移、季节项（原始减去去季节结果）和去季节位移；全部成功后生成 `run5.2_complete`。可用 `--dpi` 调整 PNG 分辨率，用 `--no-txt` 关闭文本输出。

## Run 5.3：并行重估去季节速度

在轨道根目录无参数运行，只检查 Run 5.1 的去季节位移栈和处理参数：

~~~bash
./run5.3_make_velocity_from_deseason_parallel.py
~~~

正式运行默认使用20个并行进程、每块512行：

~~~bash
./run5.3_make_velocity_from_deseason_parallel.py 1
~~~

也可使用 `--jobs 5` 降低并行数。脚本对每个像元的去季节位移做线性拟合，忽略 NaN 历元，并把 mm/day 斜率乘以365.0得到 mm/yr。正式输出为：

GMTSAR 的 `disp_YYYYDDD.grd` 使用从零起算的年内日编号，`000` 表示1月1日；Run 5.1～Run 5.3 均按此规则解析日期。

~~~text
sbas_demcorr_pin/disp_deseason/vel_deseason.grd
sbas_demcorr_pin/disp_deseason/vel_deseason.png
sbas_demcorr_pin/disp_deseason/run5.3_complete
~~~

有效观测数只在像元拟合过程中用于判断，不再写成单独网格。PNG 自动使用第98百分位对称色标并按需要降采样绘图，不降低正式速度网格分辨率。

## Run 5.4：投影去季节速度到经纬度

在轨道根目录无参数运行，只检查 Run 5.3、正式 `merge/trans.dat`、第一个 F1 干涉对中的 `gauss_400` 和投影命令：

~~~bash
./run5.4_proj_vel_deseason_to_ll.sh
~~~

正式运行：

~~~bash
./run5.4_proj_vel_deseason_to_ll.sh 1
~~~

脚本固定使用400 m空间滤波，并在 `sbas_demcorr_pin/disp_deseason/` 运行 `proj_ra2ll.csh`。结果为：

~~~text
sbas_demcorr_pin/disp_deseason/vel_deseason_ll.grd
sbas_demcorr_pin/disp_deseason/vel_deseason_ll.cpt
sbas_demcorr_pin/disp_deseason/vel_deseason_ll.pdf
sbas_demcorr_pin/disp_deseason/run5.4_complete
~~~

投影先写临时网格，通过 GMT 检查后才替换正式结果；随后使用默认 `-10/10/1 mm/yr` 的 jet 色标绘制 `Deseasoned SBAS velocity` PDF。色标可通过 `VEL_DESEASON_CPT_MIN/MAX/STEP` 环境变量调整，原始 `vel_deseason.grd` 保持不变。

## Run 6.1：插值 GNSS 水平速度

默认从轨道根目录读取 `2024_HMF_GPS_ITRF_Panda_Eric_unique.txt`。无参数检查输入前六列、站点数量、区域和 GMT，不创建结果：

~~~bash
./run6.1_grid_gnss_horizontal_velocity.sh
~~~

正式运行：

~~~bash
./run6.1_grid_gnss_horizontal_velocity.sh 1
~~~

默认执行 `gmt gpsgridder`，参数为 `-R70/100/24/37.5 -I2m -fg -W -r -Cn100%`。输出为：

~~~text
GNSS2LOS_correction/GNSS_E_HMF.grd
GNSS2LOS_correction/GNSS_N_HMF.grd
GNSS2LOS_correction/GNSS_HMF.cpt
GNSS2LOS_correction/GNSS_E_HMF.pdf
GNSS2LOS_correction/GNSS_N_HMF.pdf
GNSS2LOS_correction/gnss_stations_used.txt
GNSS2LOS_correction/run6.1_gpsgridder.log
GNSS2LOS_correction/run6.1_complete
~~~

`GNSS_E_HMF.grd` 和 `GNSS_N_HMF.grd` 分别为东向、北向 GNSS 速度，单位为 mm/yr。两幅 PDF 默认采用 jet 色标和 `-20/20/1 mm/yr` 范围，可通过 `GNSS_CPT_MIN/MAX/STEP` 修改。其他输入、区域或分辨率可通过 `--gnss-file`、`--region`、`--increment` 指定。

## Run 6.2：匹配 GNSS 与 InSAR 经纬度网格

在轨道根目录先检查：

~~~bash
./run6.2_resample_GNSS_to_InSAR_grid.sh
~~~

正式运行：

~~~bash
./run6.2_resample_GNSS_to_InSAR_grid.sh 1
~~~

脚本把 Run 6.1 的 `GNSS_E_HMF.grd`、`GNSS_N_HMF.grd` 重采样到 `sbas_demcorr_pin/vel_ll.grd` 的范围、间隔、行列数和注册方式，并使用 `vel_ll.grd` 的有限值区域作为掩膜。输出为：

~~~text
GNSS2LOS_correction/GNSS_E.grd
GNSS2LOS_correction/GNSS_N.grd
GNSS2LOS_correction/GNSS_E.pdf
GNSS2LOS_correction/GNSS_N.pdf
GNSS2LOS_correction/run6.2_complete
~~~

`GNSS_E.pdf` 和 `GNSS_N.pdf` 使用与 Run 5.4 相同的 GMT 地图布局，标题在上方，水平色标放在图件下方，避免标题与色标重叠。

## Run 6.3：投影 GNSS 水平速度到 LOS

无参数快速检查，不计算：

~~~bash
./run6.3_project_GNSS_to_LOS.py
~~~

检查模式只使用 `gmt grdinfo -C` 读取东西向和北向网格的头信息，比较范围、分辨率、行列数和注册方式，不载入完整像元数组。正式模式才读取整个网格并计算 LOS。

正式运行必须选择轨道方向。升轨默认 `track=350°`、`look=40°`：

~~~bash
./run6.3_project_GNSS_to_LOS.py 1 ascending
~~~

降轨默认 `track=190°`、`look=40°`，当前 `Descending/T34` 使用：

~~~bash
./run6.3_project_GNSS_to_LOS.py 1 descending
~~~

如有更精确的轨道方位角或入射角，可覆盖默认值：

~~~bash
./run6.3_project_GNSS_to_LOS.py 1 descending --track 193 --look 40
~~~

计算公式为 `LOS = -sin(look)cos(track)×E + sin(look)sin(track)×N`。输出为：

~~~text
GNSS2LOS_correction/GNSS_to_LOS.grd
GNSS2LOS_correction/GNSS_to_LOS.pdf
GNSS2LOS_correction/run6.3_complete
~~~

Run 6.3 已把原来的 Python LOS 计算和 `run3_plot.csh` 绘图合并到一个脚本中。PDF 使用 GMT classic 流程 `grdimage → psscale → psconvert` 绘制，不依赖 `gmt begin/end` 现代会话；jet 色标固定为 `-5/5/1 mm/yr`。标题位于上方，水平色标位于图件下方，NaN 区域为灰色，与 Run 5.4、Run 6.2 的绘图布局一致。

## Run 6.4：GNSS LOS 经纬度速度转雷达坐标

~~~bash
./run6.4_project_GNSS_LOS_to_radar.sh
./run6.4_project_GNSS_LOS_to_radar.sh 1
~~~

脚本读取 `GNSS2LOS_correction/GNSS_to_LOS.grd` 和 `sbas_demcorr_pin/trans.dat`，通过 `proj_ll2ra.csh` 转换，再以第一个去季节 `disp_YYYYDDD.grd` 为模板进行 `surface -T0.1` 插值。输出：

~~~text
GNSS2LOS_correction/GNSS_to_LOS_ra.grd
GNSS2LOS_correction/GNSS_to_LOS_ra.pdf
GNSS2LOS_correction/run6.4_complete
~~~

## Run 6.5：生成每期 GNSS LOS 位移

~~~bash
./run6.5_build_GNSS_LOS_timeseries.sh
./run6.5_build_GNSS_LOS_timeseries.sh 1
./run6.5_build_GNSS_LOS_timeseries.sh 1 10
~~~

默认5个并行任务。日期使用零起算年内日：`date = January 1 + DDD days`，因此 `YYYY000` 为1月1日。脚本用实际日期差除以365.0，再乘 Run 6.4 的 LOS 速度，输出：

~~~text
GNSS2LOS_correction/GNSS_LOS_timeseries/gnss_LOS_YYYYDDD.grd
GNSS2LOS_correction/run6.5_complete
~~~

## Run 6.6：验证 GNSS LOS 位移时序

~~~bash
./run6.6_validate_GNSS_LOS_timeseries.py
./run6.6_validate_GNSS_LOS_timeseries.py 1
~~~

脚本重新拟合所有 `gnss_LOS_YYYYDDD.grd`，将 `mm/day` 斜率乘365.0得到速度，并与 Run 6.4 速度比较。默认5个进程，可用 `--jobs` 和 `--block-rows` 调整。输出：

~~~text
GNSS2LOS_correction/GNSS_LOS_validation/GNSS_to_LOS_ra_refit.grd
GNSS2LOS_correction/GNSS_LOS_validation/GNSS_to_LOS_ra_difference.grd
GNSS2LOS_correction/GNSS_LOS_validation/GNSS_LOS_validation_3panel.pdf
GNSS2LOS_correction/GNSS_LOS_validation/run6.6_complete
~~~

三联 PDF 使用一行三列布局：参考速度、重新拟合速度、拟合减参考差值。前两幅使用 `-5/5/1 mm/yr`，差值使用 `-0.01/0.01/0.001 mm/yr`，三个水平色标均位于对应图件下方。Run 6.6 支持绘图失败后的断点续跑：若拟合速度和差值网格有效且比 Run 6.5 输入更新，重新运行会跳过已完成的分块拟合，只补画 PDF 并写入完成标记。

## Run 6.7：使用 GNSS 改正去季节 InSAR 位移

~~~bash
./run6.7_correct_displacement_with_GNSS.sh
./run6.7_correct_displacement_with_GNSS.sh 1
./run6.7_correct_displacement_with_GNSS.sh 1 10
~~~

无参数检查 `sbas_demcorr_pin/disp_deseason/disp_YYYYDDD.grd` 与 `GNSS2LOS_correction/GNSS_LOS_timeseries/gnss_LOS_YYYYDDD.grd` 是否逐期对应。正式运行默认5个并行任务，计算 `InSAR−GNSS` 后进行约5 km粗采样和约80 km平滑，再从 InSAR 位移中去掉长波长差值。输出：

~~~text
GNSS2LOS_correction/GNSS_corrected_displacement/disp_YYYYDDD_gnssref_5km_80km.grd
GNSS2LOS_correction/GNSS_corrected_displacement/diff_YYYYDDD_smooth80km_full.grd
GNSS2LOS_correction/run6.7_complete
~~~

## Run 6.8：拟合改正后速度与长波长改正速度

~~~bash
./run6.8_make_velocity_from_GNSS_corrected_timeseries.py
./run6.8_make_velocity_from_GNSS_corrected_timeseries.py 1
./run6.8_make_velocity_from_GNSS_corrected_timeseries.py 1 --jobs 10 --block-rows 512
~~~

日期按 `January 1 + DDD days` 解释，`YYYY000` 为1月1日。脚本默认5进程，分别拟合两套 Run 6.7 时序并生成：

~~~text
GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km.grd
GNSS2LOS_correction/GNSS_corrected_displacement/vel_diff_smooth80km_full.grd
GNSS2LOS_correction/GNSS_corrected_displacement/GNSS_corrected_velocity_6panel.pdf
GNSS2LOS_correction/run6.8_complete
~~~

Run 6.8 的 PDF 使用两行三列布局：原始 SBAS 速度、去季节速度、GNSS LOS 速度、GNSS 改正后速度、被去除的长波长速度，以及 `去季节速度−改正后速度−长波长改正` 的闭合残差。前五幅使用 `-5/5/1 mm/yr`，残差使用 `-0.01/0.01/0.001 mm/yr`。脚本加大上下两行间距，避免上排水平色标与下排标题重叠。

## Run 6.9：投影最终速度到经纬度

~~~bash
./run6.9_geocode_GNSS_corrected_velocity.sh
./run6.9_geocode_GNSS_corrected_velocity.sh 1
./run6.9_geocode_GNSS_corrected_velocity.sh 1 600
~~~

默认使用 `gauss_400` 和400 m空间滤波。脚本将 GNSS 改正速度及被去除的长波长改正速度分别通过 `proj_ra2ll.csh` 投影到经纬度，并各自生成一张独立 GMT PDF。KML 只为 GNSS 改正后的最终速度生成：

~~~text
GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km_ll.grd
GNSS2LOS_correction/GNSS_corrected_displacement/vel_diff_smooth80km_full_ll.grd
GNSS2LOS_correction/GNSS_corrected_displacement/GNSS_corrected_velocity_ll.cpt
GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km_ll.pdf
GNSS2LOS_correction/GNSS_corrected_displacement/vel_diff_smooth80km_full_ll.pdf
GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km_ll*.kml
GNSS2LOS_correction/run6.9_complete
~~~
