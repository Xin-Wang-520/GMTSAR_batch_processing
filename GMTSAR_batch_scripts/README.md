<a id="english"></a>

[English](#english) | [中文](#中文说明)

# Sentinel-1 GMTSAR SBAS Batch Processing Workflow

This directory provides a reusable batch workflow for Sentinel-1 TOPS processing with GMTSAR. It covers ASF download validation, SAFE extraction and cleanup, frame organization, DEM preparation, preprocessing, interferogram generation, IW1/IW2/IW3 merging, unwrapping, SBAS inversion, seasonal-signal removal and GNSS referencing.

Author: Xin Wang, University of Science and Technology of China (USTC), Hefei, China

## English quick navigation

- [Directory layout](#english-directory-layout)
- [Processing stages](#english-processing-stages)
- [Recommended commands](#english-recommended-commands)
- [Parallel processing and restart rules](#english-parallel-processing-and-restart-rules)
- [Open the complete Chinese guide](#中文说明)

<a id="english-directory-layout"></a>

## Directory layout

Runs 1.1–1.3 prepare downloaded Sentinel-1 products in the data directory:

```text
/data2/xinw/HMF_Sentinel1_data/Descending/T34/
├── zip/
├── T34_SAFE/
├── run1.1_download_S1.py
├── run1.2_unzip_S1.sh
└── run1.3_remove_VH_keep_VV_delete_zip_S1.sh
```

Run 2 and all later GMTSAR steps are performed in the track-processing directory:

```text
/data2/xinw/InSAR_processing/Descending/T34/
├── organized/
├── topo/
├── F1/
├── F2/
├── F3/
├── merge/
├── sbas_demcorr_pin/
└── GNSS2LOS_correction/
```

The GMTSAR directory reads the cleaned SAFE products but never writes processing results back into the original Sentinel-1 data directory.

<a id="english-processing-stages"></a>

## Processing stages

| Stage | Main task | Main products |
| --- | --- | --- |
| Run 1.1 | Download or re-download failed Sentinel-1 ZIP files | validated ZIP files |
| Run 1.2 | Preview/formally extract ZIP files and validate SAFE structure | `T*_SAFE/*.SAFE`, `failed_zip.txt` |
| Run 1.3 | Remove VH, keep VV and safely remove verified ZIP files | VV-only SAFE stack |
| Run 2.1 | Build `SAFE_filelist` and download orbit files | SAFE list and EOF files |
| Run 2.2 | Preview and organize TOPS frames by date | organized frame directories |
| Run 2.3 | Derive DEM bounds from frame XML files | `topo/dem.grd` and DEM PDF |
| Run 2.4 | Create F1/F2/F3 and link IW, EOF and DEM inputs | `F1/raw`, `F2/raw`, `F3/raw` |
| Run 3.1 | Generate `data.in` and select the temporal-middle master | `F*/raw/data.in` |
| Run 3.2 | Preprocess and align F1/F2/F3 | PRM, LED, SLC and baseline tables |
| Run 3.3 | Preview and confirm the interferogram network | `intf.in`, config and baseline PDF |
| Run 3.4 | Convert DEM to master-image radar coordinates | `topo_ra.grd` and `trans.dat` |
| Run 3.5 | Generate and validate interferograms | `F*/intf_all/<pair>/` |
| Run 3.6 | Preview seams and merge F1/F2/F3 | `merge/<pair>/` |
| Run 3.7–3.9 | Plot merged products and build coherence/land masks | QC plots and mask grids |
| Run 3.10 | Preview SNAPHU inputs and perform resumable unwrapping | `unwrap.grd`, `unwrap.pdf` |
| Run 3.11–3.13 | Generate radar DEM, correct DEM error and apply reference area | corrected unwrap grids |
| Run 4.1–4.4 | Prepare, run and geocode SBAS | displacement/velocity grids, PDF and KML |
| Run 5.1–5.4 | Remove seasonal components and rebuild velocity | deseasoned displacement/velocity |
| Run 6.1–6.9 | Grid GNSS, project to LOS and reference InSAR | GNSS-corrected displacement/velocity |

<a id="english-recommended-commands"></a>

## Recommended commands

Run every script without arguments first when it provides a check or command-guide mode. Use formal mode only after the reported inputs and parameters are correct.

```bash
# Original-data directory
./run1.1_download_S1.py
./run1.2_unzip_S1.sh
./run1.2_unzip_S1.sh 1
./run1.3_remove_VH_keep_VV_delete_zip_S1.sh
./run1.3_remove_VH_keep_VV_delete_zip_S1.sh --delete

# Track-processing directory
./run2.1_prepare_SAFE_orbits.sh
./run2.1_prepare_SAFE_orbits.sh 1
./run2.2_organize_frames.sh 1
./run2.2_organize_frames.sh 2
./run2.3_prepare_topo_DEM.py 1
./run2.3_prepare_topo_DEM.py 2
./run3.1_prep_data_F123.sh
./run3.1_prep_data_F123.sh 1
./run3.2_preproc_batch_tops_F123.sh 5 1
./run3.3_make_intf_config_F123.sh 1 60 150
./run3.3_make_intf_config_F123.sh 2
./run3.5_intf_tops_parallel_F123.sh 5
./run3.8_stack_coherence_mask_parallel.sh 0.075 50 5
./run3.9_make_landmask_ra.sh 1
./run3.10_unwrap_merge_parallel.sh 1 0.0001
./run3.10_unwrap_merge_parallel.sh 2 5 0.0001
```

For Run 3.13, the reference area is mandatory and must be selected from a stable radar-coordinate region. Review all quality-control plots before SBAS.

The complete argument descriptions, server examples, output inventories and troubleshooting notes are provided in the [Chinese section](#中文说明).

<a id="english-parallel-processing-and-restart-rules"></a>

## Parallel processing and restart rules

- Reduce parallel job counts on computers with limited CPU, memory or disk throughput.
- A large job count does not always make processing faster; GMT grids can be limited by disk I/O.
- Preview/check modes do not modify processing products.
- Resumable scripts validate existing outputs and process only missing or incomplete records.
- Preserve `run*.complete`, manifests, inventories and failure reports for later validation.
- Treat every non-empty failure report as unresolved until its log has been inspected.
- Do not start a second formal process while an existing PID from the same run is active.

---

<a id="中文说明"></a>

[Back to English](#english) | [中文](#中文说明)


# Sentinel-1 GMTSAR 时序批处理流程

本说明书用于持续整理 Sentinel-1 数据从 ASF 下载、SAFE 解压与清理、GMTSAR 分帧处理、拼接、干涉、解缠到 SBAS 时序反演的自动化脚本。所有脚本按 `run1`、`run2`、`run3`……的顺序逐步定稿，并同步记录输入、输出、运行方式、日志和断点续跑方法。

> 当前状态：Run 1.1～Run 1.3 完成原始数据准备；Run 2.1～Run 2.4 覆盖轨道、分帧、DEM 和输入链接；Run 3.1～Run 3.13 已覆盖预处理、选对、雷达地形、干涉、三子条带拼接、质量预览、并行解缠、DEM误差改正和参考区归零；Run 4.1～Run 4.4 已覆盖 SBAS 输入筛选、表格准备、正式并行反演和速度投影；Run 5.1～Run 5.4 覆盖季节性改正；Run 6.1～Run 6.9 覆盖 GNSS 水平速度插值、LOS 投影、时序验证、长波长 GNSS 参考改正以及最终速度投影。

## 文档与脚本维护约定

- 本文件是批处理流程的唯一主说明书，后续正式 GMTSAR 处理阶段均直接追加到这里。
- 每一步先根据服务器上的真实脚本修改，再进行语法检查和实际测试，测试通过后更新本说明书。
- Bash 脚本统一使用 `#!/usr/bin/env bash`、`set -euo pipefail`，并设置 `LC_ALL=C`、`LANG=C` 和 `LANGUAGE=C`。
- 可复用脚本优先从当前目录名自动识别 `T34`、`T56`、`T158` 等轨道号，避免在代码中写死轨道。
- 涉及删除数据的步骤默认使用 `dry-run`，只有显式传入 `--delete` 后才执行删除。
- 每一步记录脚本名称、输入、输出、依赖、运行命令、日志、验证方法和断点续跑方式。
- 实际运行版本以同目录独立的 `run1`、`run2`、`run3` 脚本为准；章节内长代码块用于归档，服务器验证后再整体同步。

## T34 降轨

### 数据准备与正式处理目录分工

Run 1.1～Run 1.3 属于 Sentinel-1 原始数据准备阶段，脚本和数据统一放在：

```bash
/data2/xinw/HMF_Sentinel1_data/Descending/T34
```

该目录保存 `download*.py`、`zip/`、`T34_SAFE/`、下载/解压日志及失败清单。

Run 2.1 开始进入 GMTSAR 正式处理阶段，脚本和处理结果统一放在：

```bash
/data2/xinw/InSAR_processing/Descending/T34
```

Run 2.1 及后续脚本从前一目录的 `T34_SAFE/` 读取经过 Run 1.3 清理、仅保留 VV 的 SAFE 数据。GMTSAR 分帧、拼接、干涉、解缠和 SBAS 中间结果不得写回原始数据准备目录。

### 当前脚本执行链

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
├── Run 6.6 重新拟合 GNSS LOS 时序并验证日期与速度
├── Run 6.7 用 GNSS LOS 时序改正去季节 InSAR 位移的长波长差异
├── Run 6.8 拟合 GNSS 改正后速度及被去除的长波长改正速度
└── Run 6.9 将两套速度投影到经纬度，分别绘图并输出最终速度 KML
```

### Run 1.1：下载 Sentinel-1 数据

#### 工作目录

```bash
/data2/xinw/HMF_Sentinel1_data/Descending/T34
```

#### 脚本名称

```bash
run1.1_download_S1.py
```

该脚本用于完成 T34 轨道 Sentinel-1 原始数据下载，是整个时序批处理流程的第一步。

#### 主要功能

- 自动查找当前目录下的 `download*.py`
- 从 ASF 官方下载脚本中提取 Sentinel-1 ZIP 下载链接
- 将所有原始数据统一下载到 `zip/` 文件夹
- 使用 `~/.netrc` 中保存的 Earthdata 账号信息
- 支持断点续传
- 自动跳过已经完整下载的数据
- 自动识别过小或文件头异常的 ZIP 文件
- 支持 `--failed failed_zip.txt` 只补下载 Run 1.2 判定失败的产品
- 自动删除异常文件并重新下载
- 自动重试下载失败的数据
- 当仍有文件下载失败时返回非零状态

#### 当前目录结构

```text
T34/
├── run1.1_download_S1.py
├── download*.py
├── asf_cookies.txt
├── url_list_from_download_py.txt
├── run1.1_download_S1.log
└── zip/
    └── *.zip
```

其中：

- `download*.py`：ASF 网站生成的官方批量下载脚本
- `run1.1_download_S1.py`：Sentinel-1 数据下载脚本
- `zip/`：统一存放下载完成的 Sentinel-1 ZIP 数据
- `url_list_from_download_py.txt`：从 ASF 下载脚本中提取的 URL 列表
- `asf_cookies.txt`：ASF 和 Earthdata 登录过程中产生的 cookie
- `run1.1_download_S1.log`：后台下载日志

#### 运行方法

进入 T34 工作目录：

```bash
cd /data2/xinw/HMF_Sentinel1_data/Descending/T34
```

赋予脚本执行权限：

```bash
chmod +x run1.1_download_S1.py
```

前台运行：

```bash
./run1.1_download_S1.py
```

后台运行：

```bash
nohup ./run1.1_download_S1.py > run1.1_download_S1.log 2>&1 &
```

实时查看下载日志：

```bash
tail -f run1.1_download_S1.log
```

查看当前已下载的 ZIP 文件数量：

```bash
find zip -maxdepth 1 -type f -name "*.zip" | wc -l
```

Run 1.2 产生失败清单后，只补下载其中的数据：

```bash
./run1.1_download_S1.py --failed failed_zip.txt
```

补下载模式会从 `download*.py` 中匹配清单内的 ZIP 文件名，删除对应旧 `.zip`/`.zip.part` 后从头下载，不会处理清单外的数据。

#### 断点续跑

下载被中断后，可以直接重新执行：

```bash
./run1.1_download_S1.py
```

脚本会自动跳过已经完整下载的 ZIP 文件，并重新下载缺失、损坏或不完整的数据。

#### 第一阶段输出

第一阶段完成后，所有 Sentinel-1 原始压缩数据位于：

```bash
/data2/xinw/HMF_Sentinel1_data/Descending/T34/zip
```

该目录中的 ZIP 文件将作为下一步数据解压和 SAFE 数据整理的输入。

---

### Run 1.1 完整脚本

文件名：

```bash
run1.1_download_S1.py
```

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import glob
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

# ============================================================
# run1.1_download_S1.py
#
# Sentinel-1 ASF 数据下载脚本
#
# 功能：
#   1. 自动查找当前目录下的 download*.py
#   2. 从 ASF 官方下载脚本中提取全部 .zip URL
#   3. 将数据统一下载到 zip/ 文件夹
#   4. 支持 Earthdata ~/.netrc 登录
#   5. 支持 cookie、断点续传和自动重试
#   6. 自动跳过已经完整下载的压缩包
#   7. 自动删除过小或文件头错误的假 zip
#   8. 支持根据 failed_zip.txt 定向补下载
#   9. CRC 完整性由 Run 1.2 实际解压负责
#  10. 任意文件下载失败时返回非零退出状态
#
# 默认运行：
#   ./run1.1_download_S1.py
#
# 后台运行：
#   nohup ./run1.1_download_S1.py > run1.1_download_S1.log 2>&1 &
#
# 查看日志：
#   tail -f run1.1_download_S1.log
#
# 指定其他输出目录：
#   ./run1.1_download_S1.py --outdir other_zip
#
# 指定下载脚本匹配模式：
#   ./run1.1_download_S1.py --pattern "download-all-*.py"
#
# ~/.netrc 示例：
#
#   machine urs.earthdata.nasa.gov
#     login your_username
#     password your_password
#
# 设置权限：
#   chmod 600 ~/.netrc
# ============================================================

DEFAULT_PATTERN = "download*.py"
DEFAULT_OUTDIR = "zip"
URL_LIST_FILE = "url_list_from_download_py.txt"
COOKIE_FILE = "asf_cookies.txt"
MIN_GOOD_SIZE_MB = 100
MAX_RETRY_PER_FILE = 3
RETRY_WAIT_SECONDS = 10


def parse_args():
    pattern = DEFAULT_PATTERN
    outdir = DEFAULT_OUTDIR

    args = sys.argv[1:]
    i = 0

    while i < len(args):
        arg = args[i]

        if arg == "--pattern":
            if i + 1 >= len(args):
                print("[ERROR] --pattern 后面必须提供匹配模式。")
                sys.exit(2)

            pattern = args[i + 1]
            i += 2

        elif arg == "--outdir":
            if i + 1 >= len(args):
                print("[ERROR] --outdir 后面必须提供输出目录。")
                sys.exit(2)

            outdir = args[i + 1]
            i += 2

        elif arg in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)

        else:
            print(f"[WARNING] 忽略未知参数：{arg}")
            i += 1

    return pattern, Path(outdir)


def find_download_py(pattern):
    matched_files = sorted(glob.glob(pattern))
    myself = Path(__file__).resolve()
    result = []

    for filename in matched_files:
        path = Path(filename)

        try:
            if path.resolve() == myself:
                continue
        except OSError:
            pass

        result.append(filename)

    return result


def extract_urls_from_file(path):
    try:
        text = Path(path).read_text(
            encoding="utf-8",
            errors="ignore",
        )
    except OSError as exc:
        print(f"[ERROR] 无法读取文件：{path}")
        print(f"        {exc}")
        return []

    urls = re.findall(
        r'https?://[^\s\'"]+?\.zip',
        text,
    )

    clean_urls = []

    for url in urls:
        url = url.strip()
        url = url.rstrip(",);]}")

        if "asf.alaska.edu" in url.lower() and ".zip" in url.lower():
            clean_urls.append(url)

    return clean_urls


def normalize_url(url):
    return (
        url.strip()
        .strip("'")
        .strip('"')
        .rstrip(",")
    )


def write_url_list(urls):
    output = Path(URL_LIST_FILE)

    output.write_text(
        "\n".join(urls) + "\n",
        encoding="utf-8",
    )

    print(f"[INFO] 已写入 URL 列表：{output.resolve()}")


def zip_signature_is_valid(path):
    try:
        with path.open("rb") as file_obj:
            signature = file_obj.read(4)

        return signature in (
            b"PK\x03\x04",
            b"PK\x05\x06",
            b"PK\x07\x08",
        )

    except OSError:
        return False


def is_good_zip(path):
    if not path.exists():
        return False

    if not path.is_file():
        return False

    try:
        size_bytes = path.stat().st_size
    except OSError:
        return False

    minimum_size = MIN_GOOD_SIZE_MB * 1024 * 1024

    if size_bytes < minimum_size:
        return False

    return zip_signature_is_valid(path)


def remove_bad_file(path):
    if not path.exists():
        return

    if is_good_zip(path):
        return

    try:
        size_bytes = path.stat().st_size
    except OSError:
        size_bytes = -1

    print(
        f"[WARNING] 删除疑似损坏或不完整文件："
        f"{path}，大小={size_bytes} bytes"
    )

    try:
        path.unlink()
    except OSError as exc:
        print(f"[ERROR] 无法删除文件：{path}")
        print(f"        {exc}")
        raise


def count_existing_good(outdir, urls):
    good_count = 0
    bad_count = 0

    for url in urls:
        filename = os.path.basename(urlparse(url).path)
        output_file = outdir / filename

        if not output_file.exists():
            continue

        if is_good_zip(output_file):
            good_count += 1
        else:
            bad_count += 1

    return good_count, bad_count


def check_netrc():
    netrc_path = Path.home() / ".netrc"

    if not netrc_path.exists():
        print("[ERROR] 找不到 ~/.netrc")
        print()
        print("请创建 ~/.netrc，内容示例：")
        print()
        print("machine urs.earthdata.nasa.gov")
        print("  login your_username")
        print("  password your_password")
        print()
        print("然后执行：")
        print()
        print("chmod 600 ~/.netrc")
        print()

        sys.exit(1)

    try:
        permission = netrc_path.stat().st_mode & 0o777
    except OSError as exc:
        print(f"[ERROR] 无法读取 ~/.netrc 权限：{exc}")
        sys.exit(1)

    if permission != 0o600:
        print(
            f"[WARNING] ~/.netrc 当前权限为 "
            f"{oct(permission)}，自动修改为 600"
        )

        try:
            netrc_path.chmod(0o600)
        except OSError as exc:
            print(f"[ERROR] 无法修改 ~/.netrc 权限：{exc}")
            sys.exit(1)

    return netrc_path


def check_required_commands():
    result = subprocess.run(
        ["bash", "-lc", "command -v curl"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    if result.returncode != 0:
        print("[ERROR] 系统中找不到 curl。")
        sys.exit(1)


def download_one(url, outdir, cookie, netrc_path):
    filename = os.path.basename(urlparse(url).path)

    if not filename:
        print(f"[ERROR] 无法从 URL 获取文件名：{url}")
        return False

    output_file = outdir / filename

    if is_good_zip(output_file):
        size_mb = output_file.stat().st_size / 1024 / 1024

        print(
            f"[SKIP] 完整 ZIP 已存在："
            f"{output_file}，{size_mb:.1f} MB"
        )

        return True

    try:
        remove_bad_file(output_file)
    except OSError:
        return False

    command = [
        "curl",
        "-k",
        "-L",
        "--netrc-file",
        str(netrc_path),
        "-c",
        str(cookie),
        "-b",
        str(cookie),
        "--fail",
        "--retry",
        "10",
        "--retry-delay",
        "10",
        "--retry-all-errors",
        "--connect-timeout",
        "30",
        "--speed-time",
        "120",
        "--speed-limit",
        "1024",
        "-C",
        "-",
        "--show-error",
        "-o",
        str(output_file),
        url,
    ]

    for attempt in range(1, MAX_RETRY_PER_FILE + 1):
        print()
        print(
            f"[TRY {attempt}/{MAX_RETRY_PER_FILE}] "
            f"{filename}"
        )

        try:
            result = subprocess.run(command)
        except KeyboardInterrupt:
            print()
            print("[INTERRUPTED] 用户中断下载。")
            raise
        except OSError as exc:
            print(f"[ERROR] 无法执行 curl：{exc}")
            return False

        if result.returncode == 0 and is_good_zip(output_file):
            size_mb = output_file.stat().st_size / 1024 / 1024

            print(
                f"[OK] 下载完成："
                f"{output_file}，{size_mb:.1f} MB"
            )

            return True

        print(
            f"[ERROR] curl 返回失败，或下载结果不是有效 ZIP。"
            f"returncode={result.returncode}"
        )

        try:
            remove_bad_file(output_file)
        except OSError:
            return False

        if attempt < MAX_RETRY_PER_FILE:
            print(
                f"[INFO] {RETRY_WAIT_SECONDS} 秒后重新尝试。"
            )
            time.sleep(RETRY_WAIT_SECONDS)

    print(f"[FAIL] 下载失败：{url}")

    return False


def main():
    pattern, outdir = parse_args()

    check_required_commands()

    try:
        outdir.mkdir(
            parents=True,
            exist_ok=True,
        )
    except OSError as exc:
        print(f"[ERROR] 无法创建下载目录：{outdir}")
        print(f"        {exc}")
        sys.exit(1)

    netrc_path = check_netrc()
    cookie = Path(COOKIE_FILE)

    print("========================================")
    print("Run 1.1: ASF Sentinel-1 download")
    print("========================================")
    print(f"Current directory : {Path.cwd()}")
    print(f"Script pattern    : {pattern}")
    print(f"Download directory: {outdir.resolve()}")
    print(f"Cookie file       : {cookie.resolve()}")
    print(f"Netrc file        : {netrc_path}")
    print(f"Minimum ZIP size  : {MIN_GOOD_SIZE_MB} MB")
    print("========================================")

    download_scripts = find_download_py(pattern)

    if not download_scripts:
        print()
        print(
            f"[ERROR] 当前目录没有找到匹配的下载脚本："
            f"{pattern}"
        )
        print()
        print("例如应存在：")
        print("  download-all-2026-07-10.py")
        print()

        sys.exit(1)

    print()
    print("[INFO] 找到以下 ASF 下载脚本：")

    for filename in download_scripts:
        print(f"  - {filename}")

    all_urls = []

    for filename in download_scripts:
        urls = extract_urls_from_file(filename)

        print(
            f"[INFO] {filename}: "
            f"提取到 {len(urls)} 个 ZIP URL"
        )

        all_urls.extend(urls)

    urls = sorted(
        set(
            normalize_url(url)
            for url in all_urls
            if normalize_url(url)
        )
    )

    if not urls:
        print()
        print("[ERROR] 没有从 download*.py 中找到 ASF ZIP URL。")
        sys.exit(1)

    write_url_list(urls)

    good_count, bad_count = count_existing_good(
        outdir,
        urls,
    )

    print()
    print("========================================")
    print(f"URL 总数          : {len(urls)}")
    print(f"已有完整 ZIP      : {good_count}")
    print(f"已有异常 ZIP      : {bad_count}")
    print(f"需要检查或下载    : {len(urls) - good_count}")
    print("========================================")

    success_count = 0
    fail_count = 0

    for index, url in enumerate(urls, start=1):
        filename = os.path.basename(urlparse(url).path)

        print()
        print("=" * 80)
        print(f"[{index}/{len(urls)}] {filename}")
        print("=" * 80)

        try:
            success = download_one(
                url=url,
                outdir=outdir,
                cookie=cookie,
                netrc_path=netrc_path,
            )
        except KeyboardInterrupt:
            print()
            print("========================================")
            print("[INTERRUPTED] 下载任务被用户中断。")
            print("下次重新运行可从已有文件继续。")
            print("========================================")
            sys.exit(130)

        if success:
            success_count += 1
        else:
            fail_count += 1

    final_good_count, final_bad_count = count_existing_good(
        outdir,
        urls,
    )

    print()
    print("========================================")
    print("Run 1.1 finished")
    print("========================================")
    print(f"本次成功或跳过    : {success_count}")
    print(f"本次失败          : {fail_count}")
    print(f"最终完整 ZIP      : {final_good_count}")
    print(f"最终异常 ZIP      : {final_bad_count}")
    print(f"URL 总数          : {len(urls)}")
    print(f"下载目录          : {outdir.resolve()}")
    print("========================================")

    if fail_count > 0:
        print(
            f"[ERROR] 仍有 {fail_count} 个文件下载失败。"
        )
        print(
            "[INFO] 可以重新运行 ./run1.1_download_S1.py，"
            "完整文件会自动跳过。"
        )
        sys.exit(1)

    if final_good_count != len(urls):
        print(
            "[ERROR] 完整 ZIP 数量与 URL 总数不一致。"
        )
        sys.exit(1)

    print("[OK] 所有 Sentinel-1 ZIP 文件均已准备完成。")
    sys.exit(0)


if __name__ == "__main__":
    main()
```

#### 当前状态

- [x] Run 1.1：下载 Sentinel-1 ZIP 数据
- [x] Run 1.2：解压 ZIP、记录失败并整理 SAFE
- [x] Run 1.3：删除 VH、检查 VV并安全清理 ZIP
- [ ] Run 2.1：生成 SAFE_filelist 并下载轨道文件
- [ ] Run 2.2：检查 pins.ll 并预览/正式重组 TOPS 帧
- [ ] Run 3：F1、F2、F3 分帧预处理
- [ ] Run 4：Merge 拼接
- [ ] Run 5：干涉、滤波、掩膜与解缠
- [ ] Run 6：SBAS 时序处理

---

## Run 1.2：解压 Sentinel-1 ZIP 数据

### 工作目录

脚本需要放在轨道目录下运行，例如：

```bash
/data2/xinw/HMF_Sentinel1_data/Descending/T34
```

脚本会自动读取当前目录名，并识别轨道号。

例如：

```text
当前目录：/data2/xinw/HMF_Sentinel1_data/Descending/T34
自动识别：TRACK=T34
输出目录：T34_SAFE/
```

将同一脚本复制到其他轨道目录后，无需修改轨道号。

例如：

```text
T56 目录  → T56_SAFE/
T85 目录  → T85_SAFE/
T158 目录 → T158_SAFE/
```

### 脚本名称

```bash
run1.2_unzip_S1.sh
```

该脚本用于从 `zip/` 文件夹读取 Sentinel-1 ZIP 文件，并将解压后的 SAFE 数据统一保存到当前轨道对应的 `T*_SAFE/` 文件夹。

### 输入与输出

输入数据：

```text
zip/*.zip
```

输出数据：

```text
T*_SAFE/*.SAFE
```

运行过程中还会生成：

```text
run1.2_unzip_S1.log
run1.2_unzip_S1_progress.log
run1.2_unzip_S1_parallel_joblog.txt
failed_zip.txt
```

其中：

- `run1.2_unzip_S1.log`：详细解压日志
- `run1.2_unzip_S1_progress.log`：解压进度日志
- `run1.2_unzip_S1_parallel_joblog.txt`：GNU Parallel 任务状态日志
- `failed_zip.txt`：Run 1.2 未能成功解压并建立有效完成标记的 ZIP 文件名；成功时为空

### 主要功能

- 自动从当前目录名识别 Sentinel-1 轨道号
- 自动检查当前目录是否符合 `T数字` 格式
- 自动在 `zip/` 文件夹中查找全部 ZIP 文件
- 自动创建对应的 `T*_SAFE/` 文件夹
- 快速检查 ZIP 文件大小
- 快速检查 ZIP 文件头是否为标准 ZIP 格式
- 使用 GNU Parallel 并行解压
- 默认同时运行 10 个解压任务
- 每 30 秒记录一次解压进度
- 先解压到临时目录，检查通过后再移动到正式 SAFE
- 根据 `.run1.2_unzip_complete` 自动跳过已经成功解压的 SAFE
- 解压完成后检查 SAFE 目录结构
- 检查每个 SAFE 是否包含：
  - `manifest.safe`
  - `annotation/`
  - `measurement/`
- 检查 ZIP 数量和 SAFE 数量是否一致
- 全部任务结束后自动生成 `failed_zip.txt`
- 解压失败时返回非零退出状态
- 设置标准 `C` locale，避免 GNU Parallel 和 Perl 的 locale 警告

### Locale 设置

脚本开头包含：

```bash
export LC_ALL=C
export LANG=C
export LANGUAGE=C
```

这三行用于避免服务器上出现类似下面的警告：

```text
perl: warning: Setting locale failed.
perl: warning: Falling back to the standard locale ("C").
```

该设置不影响数据处理结果，只用于统一命令行环境和日志输出。

### 当前目录结构

```text
T34/
├── run1.1_download_S1.py
├── run1.2_unzip_S1.sh
├── download*.py
├── zip/
│   └── *.zip
├── T34_SAFE/
│   └── *.SAFE
├── run1.1_download_S1.log
├── run1.2_unzip_S1.log
├── run1.2_unzip_S1_progress.log
└── run1.2_unzip_S1_parallel_joblog.txt
```

### ZIP 快速检查与解压复核

Run 1.1 只进行大小、PK 文件头和 ZIP/SAFE 基本结构快速检查，不再对上千个产品逐个运行 `unzip -t`。Run 1.2 开始时再次执行快速预检查：

1. 检查 ZIP 文件是否大于 100 MB
2. 检查前 4 个字节是否为标准 ZIP 文件头

标准 ZIP 文件头为：

```text
504b0304
```

快速检查可以发现：

- 下载错误页面
- 过小的异常文件
- 非 ZIP 文件
- 文件头已经损坏的文件

随后由 Run 1.2 的实际 `unzip` 返回状态和 SAFE 结构检查完成 CRC 复核。任何未完成产品都会写入根目录的 `failed_zip.txt`，每行一个 ZIP 文件名。

### 运行方法

进入轨道目录：

```bash
cd /data2/xinw/HMF_Sentinel1_data/Descending/T34
```

赋予执行权限：

```bash
chmod +x run1.2_unzip_S1.sh
```

先进行只读预览：

```bash
./run1.2_unzip_S1.sh
```

预览显示 ZIP 总数、快速检查异常数、已完成 SAFE 和待解压数量，不创建或修改任何处理文件。确认后正式运行：

```bash
./run1.2_unzip_S1.sh 1
```

### 查看进度

查看解压进度：

```bash
tail -f run1.2_unzip_S1_progress.log
```

查看详细日志：

```bash
tail -f run1.2_unzip_S1.log
```

查看 GNU Parallel 任务日志：

```bash
column -t run1.2_unzip_S1_parallel_joblog.txt | less -S
```

### 查看运行进程

查看并行解压相关进程：

```bash
pgrep -af "unzip|parallel"
```

查看主任务进程：

```bash
ps -fp <PID>
```

其中 `<PID>` 为脚本启动后显示的：

```text
Unzip main PID
```

### 统计 ZIP 和 SAFE 数量

统计 ZIP 文件数量：

```bash
find zip -maxdepth 1 -type f -name "*.zip" | wc -l
```

统计已经生成的 SAFE 数量：

```bash
find T34_SAFE -maxdepth 1 -type d -name "*.SAFE" | wc -l
```

对于其他轨道，将 `T34_SAFE` 替换为对应目录，也可以使用自动识别方式：

```bash
TRACK="$(basename "$(pwd -P)")"
find "${TRACK}_SAFE" -maxdepth 1 -type d -name "*.SAFE" | wc -l
```

### 断点续跑

解压过程中断后，先检查续跑状态：

```bash
./run1.2_unzip_S1.sh
```

确认后正式续跑：

```bash
./run1.2_unzip_S1.sh 1
```

脚本根据每个 SAFE 内的完成标记：

```text
.run1.2_unzip_complete
```

因此，已成功解压且标记中的 ZIP 文件名、大小仍一致的产品会显示 `[SKIP]`；失败或未完成产品才会重新解压。

若 Run 1.2 生成了失败清单，执行以下闭环：

```bash
cat failed_zip.txt
./run1.1_download_S1.py --failed failed_zip.txt
./run1.2_unzip_S1.sh
./run1.2_unzip_S1.sh 1
```

第二次 Run 1.2 会跳过已经完成的 SAFE，只处理补下载后仍缺少有效完成标记的产品。

### 当前测试结果

T34 轨道测试中：

```text
ZIP total   : 1021
Jobs        : 10
Interval    : 30 s
SAFE_DIR    : T34_SAFE
```

快速 ZIP 检查结果：

```text
[INFO] ZIP check progress: 100/1021
[INFO] ZIP check progress: 200/1021
...
[INFO] ZIP check progress: 1021/1021
[OK] All ZIP files passed the fast check.
```

随后成功进入并行解压阶段：

```text
Start unzip...
Unzip main PID: 3613161
```

### Run 1.2 完整脚本

```bash
#!/usr/bin/env bash
set -euo pipefail

# Avoid locale warnings from GNU Parallel / Perl
export LC_ALL=C
export LANG=C
export LANGUAGE=C

# ============================================================
# Author : Xin Wang
# Affil. : University of Science and Technology of China (USTC)
#
# Script : run1.2_unzip_S1.sh
#
# Purpose:
#   1. Automatically identify the track name from the current
#      directory, such as T34, T56, T158.
#   2. Read Sentinel-1 ZIP files from zip/.
#   3. Perform a fast ZIP size and signature check.
#   4. Extract SAFE data into T*_SAFE/.
#   5. Monitor extraction progress.
#
# Input:
#   zip/*.zip
#
# Output:
#   T*_SAFE/*.SAFE
#   run1.2_unzip_S1.log
#   run1.2_unzip_S1_progress.log
#   run1.2_unzip_S1_parallel_joblog.txt
# ============================================================

WORK_DIR="$(pwd -P)"
TRACK="$(basename "${WORK_DIR}")"

if [[ ! "${TRACK}" =~ ^T[0-9]+$ ]]; then
    echo "[ERROR] Current directory name is not a valid track name."
    echo "[ERROR] Expected format: T34, T56, T107, T158 ..."
    echo "[ERROR] Current directory: ${WORK_DIR}"
    echo "[ERROR] Detected name    : ${TRACK}"
    exit 1
fi

ZIP_DIR="zip"
SAFE_DIR="${TRACK}_SAFE"

JOBS=10
INTERVAL=30

MIN_ZIP_SIZE_MB=100
MIN_ZIP_SIZE_BYTES=$((MIN_ZIP_SIZE_MB * 1024 * 1024))

UNZIP_LOG="run1.2_unzip_S1.log"
PROGRESS_LOG="run1.2_unzip_S1_progress.log"
PARALLEL_LOG="run1.2_unzip_S1_parallel_joblog.txt"

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

count_safe() {
    find "${SAFE_DIR}" \
        -maxdepth 1 \
        -type d \
        -name "*.SAFE" \
        -print |
        wc -l |
        awk '{print $1}'
}

count_running_unzip() {
    pgrep \
        -u "${USER}" \
        -f "unzip .* -d ${SAFE_DIR}" \
        2>/dev/null |
        wc -l |
        awk '{print $1}'
}

check_safe_structure() {
    local safe_path="$1"

    [[ -f "${safe_path}/manifest.safe" ]] || return 1
    [[ -d "${safe_path}/annotation" ]] || return 1
    [[ -d "${safe_path}/measurement" ]] || return 1

    return 0
}

command -v unzip >/dev/null 2>&1 ||
    die "Cannot find command: unzip"

command -v parallel >/dev/null 2>&1 ||
    die "Cannot find GNU parallel"

command -v od >/dev/null 2>&1 ||
    die "Cannot find command: od"

command -v stat >/dev/null 2>&1 ||
    die "Cannot find command: stat"

[[ -d "${ZIP_DIR}" ]] ||
    die "Cannot find ZIP directory: ${ZIP_DIR}/"

mkdir -p "${SAFE_DIR}"

mapfile -d '' ZIP_FILES < <(
    find "${ZIP_DIR}" \
        -maxdepth 1 \
        -type f \
        -name "*.zip" \
        -print0 |
        sort -z
)

ZIP_TOTAL=${#ZIP_FILES[@]}

if [[ "${ZIP_TOTAL}" -eq 0 ]]; then
    die "No *.zip files found in ${ZIP_DIR}/"
fi

{
    echo "========================================"
    echo "Run 1.2: Sentinel-1 unzip"
    echo "========================================"
    echo "Current dir : ${WORK_DIR}"
    echo "Track       : ${TRACK}"
    echo "ZIP_DIR     : ${ZIP_DIR}"
    echo "SAFE_DIR    : ${SAFE_DIR}"
    echo "ZIP total   : ${ZIP_TOTAL}"
    echo "Jobs        : ${JOBS}"
    echo "Interval    : ${INTERVAL} s"
    echo "Minimum ZIP : ${MIN_ZIP_SIZE_MB} MB"
    echo "Unzip log   : ${UNZIP_LOG}"
    echo "Progress log: ${PROGRESS_LOG}"
    echo "Parallel log: ${PARALLEL_LOG}"
    echo "Start time  : $(date '+%F %T')"
    echo "========================================"
    echo
} | tee "${UNZIP_LOG}"

echo "[INFO] Performing fast ZIP checks..." |
    tee -a "${UNZIP_LOG}"

BAD_ZIP_COUNT=0
CHECKED_ZIP_COUNT=0

for zip_file in "${ZIP_FILES[@]}"; do
    CHECKED_ZIP_COUNT=$((CHECKED_ZIP_COUNT + 1))

    size_bytes=$(
        stat -c "%s" "${zip_file}" 2>/dev/null ||
        echo 0
    )

    signature=$(
        od -An -tx1 -N4 "${zip_file}" 2>/dev/null |
        tr -d ' \n'
    )

    if [[ "${size_bytes}" -lt "${MIN_ZIP_SIZE_BYTES}" ]]; then
        echo \
            "[BAD] ZIP is too small: ${zip_file} (${size_bytes} bytes)" |
            tee -a "${UNZIP_LOG}"

        BAD_ZIP_COUNT=$((BAD_ZIP_COUNT + 1))
        continue
    fi

    if [[ "${signature}" != "504b0304" ]]; then
        echo \
            "[BAD] Invalid ZIP signature: ${zip_file} (${signature})" |
            tee -a "${UNZIP_LOG}"

        BAD_ZIP_COUNT=$((BAD_ZIP_COUNT + 1))
        continue
    fi

    echo "[OK] Fast ZIP check: ${zip_file}" >> "${UNZIP_LOG}"

    if (( CHECKED_ZIP_COUNT % 100 == 0 ||
          CHECKED_ZIP_COUNT == ZIP_TOTAL )); then

        echo \
            "[INFO] ZIP check progress: ${CHECKED_ZIP_COUNT}/${ZIP_TOTAL}" |
            tee -a "${UNZIP_LOG}"
    fi
done

if [[ "${BAD_ZIP_COUNT}" -gt 0 ]]; then
    die "${BAD_ZIP_COUNT} ZIP files failed the fast check. Re-run Run 1.1 first."
fi

echo "[OK] All ZIP files passed the fast check." |
    tee -a "${UNZIP_LOG}"

echo | tee -a "${UNZIP_LOG}"

echo "[$(date '+%F %T')] Start unzip..." |
    tee -a "${UNZIP_LOG}"

find "${ZIP_DIR}" \
    -maxdepth 1 \
    -type f \
    -name "*.zip" \
    -print0 |
parallel \
    -0 \
    -j "${JOBS}" \
    --joblog "${PARALLEL_LOG}" \
    '
        echo "[START] {}"

        if unzip -n -q "{}" -d "'"${SAFE_DIR}"'"; then
            echo "[DONE] {}"
        else
            echo "[FAILED] {}"
            exit 1
        fi
    ' \
    >> "${UNZIP_LOG}" 2>&1 &

UNZIP_PID=$!

echo "[INFO] Unzip main PID: ${UNZIP_PID}" |
    tee -a "${UNZIP_LOG}"

echo "[INFO] Monitor with:" |
    tee -a "${UNZIP_LOG}"

echo "       tail -f ${PROGRESS_LOG}" |
    tee -a "${UNZIP_LOG}"

echo | tee -a "${UNZIP_LOG}"

{
    echo "========================================"
    echo "Run 1.2 progress monitor"
    echo "Track   : ${TRACK}"
    echo "Started : $(date '+%F %T')"
    echo "========================================"

    while kill -0 "${UNZIP_PID}" 2>/dev/null; do
        SAFE_DONE=$(count_safe)
        LEFT=$((ZIP_TOTAL - SAFE_DONE))

        if [[ "${LEFT}" -lt 0 ]]; then
            LEFT=0
        fi

        RUNNING_UNZIP=$(count_running_unzip)

        printf \
            "[%s] total_zip=%d done_SAFE=%d running_unzip=%d left=%d\n" \
            "$(date '+%F %T')" \
            "${ZIP_TOTAL}" \
            "${SAFE_DONE}" \
            "${RUNNING_UNZIP}" \
            "${LEFT}"

        sleep "${INTERVAL}"
    done

    if wait "${UNZIP_PID}"; then
        UNZIP_STATUS=0
    else
        UNZIP_STATUS=$?
    fi

    SAFE_DONE=$(count_safe)
    LEFT=$((ZIP_TOTAL - SAFE_DONE))

    if [[ "${LEFT}" -lt 0 ]]; then
        LEFT=0
    fi

    echo
    echo "========================================"
    echo "Parallel unzip finished"
    echo "Finish time : $(date '+%F %T')"
    echo "Exit status : ${UNZIP_STATUS}"
    echo "total_zip   : ${ZIP_TOTAL}"
    echo "done_SAFE   : ${SAFE_DONE}"
    echo "left        : ${LEFT}"
    echo "========================================"

    echo
    echo "[INFO] Checking SAFE directory structure..."

    BAD_SAFE_COUNT=0

    while IFS= read -r -d '' safe_path; do
        if check_safe_structure "${safe_path}"; then
            echo "[OK] ${safe_path}"
        else
            echo "[BAD] Incomplete SAFE structure: ${safe_path}"
            BAD_SAFE_COUNT=$((BAD_SAFE_COUNT + 1))
        fi
    done < <(
        find "${SAFE_DIR}" \
            -maxdepth 1 \
            -type d \
            -name "*.SAFE" \
            -print0 |
            sort -z
    )

    echo
    echo "========================================"
    echo "Final validation"
    echo "Track          : ${TRACK}"
    echo "ZIP total      : ${ZIP_TOTAL}"
    echo "SAFE total     : ${SAFE_DONE}"
    echo "Bad SAFE count : ${BAD_SAFE_COUNT}"
    echo "SAFE directory : ${SAFE_DIR}"
    echo "========================================"

    echo
    echo "[INFO] Possible unzip errors:"

    grep -Ei \
        "error|cannot|failed|bad zipfile|end-of-central-directory|unexpected end" \
        "${UNZIP_LOG}" ||
        echo "No obvious unzip errors found."

    if [[ "${UNZIP_STATUS}" -ne 0 ]]; then
        exit "${UNZIP_STATUS}"
    fi

    if [[ "${SAFE_DONE}" -ne "${ZIP_TOTAL}" ]]; then
        echo "[ERROR] SAFE count does not match ZIP count."
        exit 1
    fi

    if [[ "${BAD_SAFE_COUNT}" -gt 0 ]]; then
        echo "[ERROR] ${BAD_SAFE_COUNT} incomplete SAFE directories found."
        exit 1
    fi

    echo
    echo "[OK] Run 1.2 completed successfully."
    echo "[OK] Track automatically detected: ${TRACK}"
    echo "[OK] All SAFE directories are in: ${SAFE_DIR}/"

} | tee "${PROGRESS_LOG}"
```

### 当前状态

- [x] Run 1.1：下载 Sentinel-1 ZIP 数据
- [x] Run 1.2：解压 ZIP、记录失败并整理 SAFE
- [x] Run 1.3：删除 VH、检查 VV并安全清理 ZIP
- [ ] Run 2.1：生成 SAFE_filelist 并下载轨道文件
- [ ] Run 2.2：检查 pins.ll 并预览/正式重组 TOPS 帧
- [ ] Run 3：F1、F2、F3 分帧预处理
- [ ] Run 4：Merge 拼接
- [ ] Run 5：干涉、滤波、掩膜与解缠
- [ ] Run 6：SBAS 时序处理


---

## Run 1.3：删除 VH、保留 VV，并清理原始 ZIP

### 工作目录

脚本放在具体轨道目录下运行，例如：

```bash
/data2/xinw/HMF_Sentinel1_data/Descending/T34
```

脚本会自动读取当前目录名并识别轨道号。

例如当前目录为：

```text
/data2/xinw/HMF_Sentinel1_data/Descending/T34
```

则自动设置：

```text
TRACK=T34
SAFE_DIR=T34_SAFE
ZIP_DIR=zip
```

因此，同一个脚本可以直接复制到其他轨道目录使用，无需手动修改轨道号。

例如：

```text
T56  → T56_SAFE
T85  → T85_SAFE
T158 → T158_SAFE
```

### 脚本名称

```bash
run1.3_remove_VH_keep_VV_delete_zip_S1.sh
```

该脚本用于删除 Sentinel-1 双极化数据中的 VH 文件，仅保留 VV 数据；在确认对应 SAFE 目录和 VV 文件完整后，再删除原始 ZIP 文件。

### 输入数据

解压后的 Sentinel-1 SAFE 数据：

```text
T*_SAFE/*.SAFE
```

Run 1.1 下载的原始 ZIP 数据：

```text
zip/*.zip
```

### 输出结果

清理后的 SAFE 数据：

```text
T*_SAFE/*.SAFE
```

轨道主目录下生成：

```text
run1.3_remove_VH_keep_VV_delete_zip_S1.log
run1.3_remove_VH_keep_VV_delete_zip_S1_vh_files.txt
```

`zip/` 文件夹中保留以下清单：

```text
zip/run1.3_all_zip_before_cleanup.txt
zip/run1.3_zip_ready_to_delete.txt
zip/run1.3_deleted_zip_list.txt
zip/run1.3_kept_zip_list.txt
```

其中：

- `run1.3_all_zip_before_cleanup.txt`：删除前全部 ZIP 文件名
- `run1.3_zip_ready_to_delete.txt`：检查通过、允许删除的 ZIP
- `run1.3_deleted_zip_list.txt`：实际删除的 ZIP 及删除时间
- `run1.3_kept_zip_list.txt`：由于 SAFE 或 VV 数据不完整而保留的 ZIP
- `run1.3_remove_VH_keep_VV_delete_zip_S1_vh_files.txt`：检测到的 VH 文件清单
- `run1.3_remove_VH_keep_VV_delete_zip_S1.log`：完整运行日志

即使全部 ZIP 文件被删除，`zip/` 文件夹和上述清单仍会保留。

### 主要功能

- 自动从当前目录名识别轨道号
- 自动检查目录名是否符合 `T数字` 格式
- 自动识别对应的 `T*_SAFE/`
- 扫描并列出全部 VH 极化文件
- 删除 VH TIFF 和 VH XML 文件
- 保留 VV TIFF 和 VV XML 文件
- 检查 ZIP 与 SAFE 是否一一对应
- 检查 `manifest.safe` 是否存在且非空
- 检查 `measurement/` 和 `annotation/` 是否存在
- 检查 VV TIFF 和 VV annotation XML 是否存在且非空
- 只有检查通过的 ZIP 才允许删除
- 未通过检查的 ZIP 会继续保留
- 正式删除前要求 `failed_zip.txt` 存在且为空
- 正式删除前要求全部 ZIP 均进入允许删除清单，保留清单必须为空
- 默认使用安全的 `dry-run` 模式
- 只有显式添加 `--delete` 才真正删除数据
- 设置标准 `C` locale，避免 Perl 和 GNU Parallel 的 locale 警告

### Locale 设置

脚本开头包含：

```bash
export LC_ALL=C
export LANG=C
export LANGUAGE=C
```

该设置只用于统一命令行环境和日志输出，不影响数据处理结果。

### 目录结构

Run 1.3 执行前：

```text
T34/
├── run1.1_download_S1.py
├── run1.2_unzip_S1.sh
├── run1.3_remove_VH_keep_VV_delete_zip_S1.sh
├── zip/
│   └── *.zip
└── T34_SAFE/
    └── *.SAFE
```

Run 1.3 正式删除完成后：

```text
T34/
├── run1.1_download_S1.py
├── run1.2_unzip_S1.sh
├── run1.3_remove_VH_keep_VV_delete_zip_S1.sh
├── run1.3_remove_VH_keep_VV_delete_zip_S1.log
├── run1.3_remove_VH_keep_VV_delete_zip_S1_vh_files.txt
├── zip/
│   ├── run1.3_all_zip_before_cleanup.txt
│   ├── run1.3_zip_ready_to_delete.txt
│   ├── run1.3_deleted_zip_list.txt
│   └── run1.3_kept_zip_list.txt
└── T34_SAFE/
    └── *.SAFE
```

### 删除的 VH 文件

主要删除：

```text
measurement/*-vh-*.tiff
annotation/*-vh-*.xml
annotation/calibration/*-vh-*.xml
annotation/rfi/*-vh-*.xml
```

保留：

```text
measurement/*-vv-*.tiff
annotation/*-vv-*.xml
annotation/calibration/*-vv-*.xml
annotation/rfi/*-vv-*.xml
```

### ZIP 删除条件

只有同时满足以下条件，ZIP 文件才会进入允许删除清单：

1. 对应的 `.SAFE` 目录存在
2. `manifest.safe` 存在且非空
3. `measurement/` 目录存在
4. `annotation/` 目录存在
5. 至少存在一个非空 VV TIFF 文件
6. 至少存在一个非空 VV annotation XML 文件

任意条件不满足时，对应 ZIP 会被保留，并记录到：

```text
zip/run1.3_kept_zip_list.txt
```

### 第一次运行：检查模式

赋予脚本执行权限：

```bash
chmod +x run1.3_remove_VH_keep_VV_delete_zip_S1.sh
```

默认运行方式：

```bash
./run1.3_remove_VH_keep_VV_delete_zip_S1.sh
```

默认是 `dry-run`，只会：

- 扫描 VH 文件
- 检查 SAFE 和 VV 数据
- 生成 ZIP 清单
- 显示允许删除和必须保留的数量
- 显示 `failed_zip.txt` 和保留清单是否阻止正式删除

不会真正删除任何文件。

### 检查清单

查看 VH 文件数量：

```bash
wc -l run1.3_remove_VH_keep_VV_delete_zip_S1_vh_files.txt
```

查看删除前 ZIP 总数：

```bash
wc -l zip/run1.3_all_zip_before_cleanup.txt
```

查看允许删除的 ZIP 数量：

```bash
wc -l zip/run1.3_zip_ready_to_delete.txt
```

查看需要保留的 ZIP 数量：

```bash
wc -l zip/run1.3_kept_zip_list.txt
```

查看需要保留的 ZIP 及原因：

```bash
cat zip/run1.3_kept_zip_list.txt
```

### 第二次运行：正式删除

确认检查结果无误后执行：

```bash
./run1.3_remove_VH_keep_VV_delete_zip_S1.sh --delete
```

正式删除的整批门禁条件：

1. `failed_zip.txt` 存在且内容为空
2. `run1.3_kept_zip_list.txt` 为空
3. `run1.3_zip_ready_to_delete.txt` 数量等于当前 ZIP 总数

任一条件不满足时，脚本会在删除 VH 之前退出，不会删除任何数据。

该命令会：

1. 删除检测到的 VH 文件
2. 再次检查 SAFE 和 VV 数据
3. 删除检查通过的 ZIP 文件
4. 保留检查未通过的 ZIP 文件
5. 在 `zip/` 中保存全部清单

### 删除后检查

检查是否还有 VH 文件：

```bash
TRACK="$(basename "$(pwd -P)")"
find "${TRACK}_SAFE" -type f -name "*-vh-*" | wc -l
```

正常结果应为：

```text
0
```

检查剩余 ZIP 数量：

```bash
find zip -maxdepth 1 -type f -name "*.zip" | wc -l
```

如果所有 SAFE 数据完整，正常结果应为：

```text
0
```

查看实际删除记录数量：

```bash
wc -l zip/run1.3_deleted_zip_list.txt
```

查看前 20 条删除记录：

```bash
head -20 zip/run1.3_deleted_zip_list.txt
```

### 断点续跑

如果脚本在删除过程中中断，可以重新执行：

```bash
./run1.3_remove_VH_keep_VV_delete_zip_S1.sh --delete
```

已经删除的 VH 和 ZIP 不会再次处理，剩余文件会继续检查和清理。

当 `zip/` 中已经没有 ZIP 时，脚本不会覆盖此前保存的清单。

### 当前状态

- [x] Run 1.1：下载 Sentinel-1 ZIP 数据
- [x] Run 1.2：解压 ZIP、记录失败并整理 SAFE
- [x] Run 1.3：删除 VH、检查 VV并安全清理 ZIP
- [ ] Run 2.1：生成 SAFE_filelist 并下载轨道文件
- [ ] Run 2.2：检查 pins.ll 并预览/正式重组 TOPS 帧
- [ ] Run 3：F1、F2、F3 分帧预处理
- [ ] Run 4：Merge 拼接
- [ ] Run 5：干涉、滤波、掩膜与解缠
- [ ] Run 6：SBAS 时序处理

---

## Run 2.1：生成 SAFE 清单并下载 Sentinel-1 轨道文件

### 工作目录

```bash
/data2/xinw/InSAR_processing/Descending/T34
```

### 输入

Run 1.3 清理后的 SAFE：

```bash
/data2/xinw/HMF_Sentinel1_data/Descending/T34/T34_SAFE/*.SAFE
```

已有轨道下载程序：

```bash
download_sentinel_orbits_linux_new.csh
```

### 脚本

```bash
run2.1_prepare_SAFE_orbits.sh
```

无参数运行只检查轨道目录、SAFE 来源、SAFE 数量、下载器、已有清单和已有 EOF，不创建或修改目录、清单、日志、锁或轨道文件：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run2.1_prepare_SAFE_orbits.sh
./run2.1_prepare_SAFE_orbits.sh
```

检查通过后，参数 `1` 才正式创建 `organized/`，使用 `find + sort` 原子生成绝对路径清单 `organized/SAFE_filelist`，然后在 `organized/` 中调用轨道下载程序。SAFE 数据不会被复制。

默认下载 POEORB 精密轨道：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
./run2.1_prepare_SAFE_orbits.sh 1
```

下载 RESORB 快速轨道：

```bash
./run2.1_prepare_SAFE_orbits.sh 1 --mode 2
```

如果下载程序不在 `PATH` 中：

```bash
./run2.1_prepare_SAFE_orbits.sh 1 \
  --downloader /实际路径/download_sentinel_orbits_linux_new.csh
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

### 完成检查

```bash
wc -l organized/SAFE_filelist
find organized -maxdepth 1 -type f -name '*.EOF' | wc -l
grep '\[ERROR\]' organized/run2.1_orbit_download.log
```

脚本只有在下载程序退出状态为 0、日志中没有 `[ERROR]` 且至少存在一个 `.EOF` 时才返回成功。单个场景轨道匹配失败时，原 csh 程序虽然继续处理其他场景，但 Run 2.1 最终仍返回非零状态并保留日志。

---

## Run 2.2：按 `pins.ll` 预览并重组 TOPS 帧

### 工作目录

```bash
/data2/xinw/InSAR_processing/Descending/T34
```

Run 2.2 从 `T34` 根目录运行，脚本自动进入 `organized/` 调用原始 csh 程序。不需要手动 `cd organized`。

如果服务器的轨道目录没有 `Ascending/Descending` 父目录，例如 `/data2/xinw/InSAR_processing/T63`，可把方向直接写在 mode 后面：

```bash
cd /data2/xinw/InSAR_processing/T63
./run2.2_organize_frames.sh 1 ascending
./run2.2_organize_frames.sh 2 ascending
```

方向参数不区分大小写，也兼容 `--direction Ascending`。mode=1 与 mode=2 必须使用相同方向。

### 脚本和输入

```bash
run2.2_organize_frames.sh
```

脚本使用：

- `organized/SAFE_filelist`：Run 2.1 生成的 SAFE 绝对路径清单。
- `organized/*.EOF`：Run 2.1 下载的轨道文件。
- `organized/pins.ll`：已存在时直接读取；不存在或为空时，脚本交互询问两个经纬度点并自动生成。
- `organize_files_tops_linux_nex_xinw.csh`：已有的 TOPS 帧重组程序。

`pins.ll` 必须恰好两行，每行格式为 `经度 纬度`：

| 轨道方向 | 第 1 行 | 第 2 行 |
| --- | --- | --- |
| 降轨 Descending | 左上角点 | 右下角点 |
| 升轨 Ascending | 右下角点 | 左上角点 |

降轨格式示例（请换成实际经纬度）：

```text
100.0 36.0
102.0 34.0
```

不需要先用 `vi` 建立该文件。脚本会根据当前目录中的 `Ascending` 或 `Descending` 自动确定询问顺序，验证数值和方位后原子生成 `organized/pins.ll`。若文件已存在且非空，脚本只检查和使用，不会覆盖。

### 运行

第一次先执行 mode=1 预检：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run2.2_organize_frames.sh
./run2.2_organize_frames.sh 1
cat organized/run2.2_mode1_summary.txt
```

mode=1 默认同时预检 5 个日期，因此终端中的 `[PREVIEW START]` 和 `[PREVIEW DONE]` 顺序可能不按日期排列，这是正常并行输出。可显式指定：

```bash
./run2.2_organize_frames.sh 1 --jobs 5
```

如果 `organized/pins.ll` 不存在，降轨第一次运行会出现：

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

每个点在同一行输入“经度 纬度”，中间使用空格。升轨时脚本会自动改为先询问右下点，再询问左上点。

mode=1 不生成正式帧目录。它会保存 good/skip 日期，并从原始 `SAFE_filelist` 中筛选出 good dates 对应的 SAFE，生成：

```text
organized/run2.2_mode1_good_dates.txt
organized/run2.2_mode1_skip_dates.txt
organized/SAFE_filelist_mode2
```

生成过滤清单时，脚本还会逐个检查所选 SAFE 的 IW1/IW2/IW3 VV XML 和 TIFF；缺失项写入 `run2.2_mode1_input_errors.txt` 并停止。

确认数量和日期正确后执行 mode=2：

```bash
./run2.2_organize_frames.sh 2
```

mode=1 和 mode=2 都默认并行处理 5 个日期。若服务器磁盘 I/O 或内存压力较大，可降低并行数：

```bash
./run2.2_organize_frames.sh 2 --jobs 3
```

正式长时间运行建议使用：

```bash
nohup ./run2.2_organize_frames.sh 2 --jobs 5 > run2.2_mode2_nohup.log 2>&1 &
```

SSH 断线时 `nohup` 任务继续运行；即使进程被手动中断或服务器重启，之后重新执行 mode=2 也会清理上次的隔离临时目录、验证已有输出并从未完成日期继续。

mode=2 不再把所有 SAFE 一次性交给原 csh。它只读取 `SAFE_filelist_mode2`，按日期逐个建立隔离工作目录，并对每个日期单独调用组织程序。某一天失败时，该日期写入失败清单，临时目录被清理，后续日期继续处理，因而不会发生临时 `.xml`、`.tiff` 或 `tmp*` 文件向后污染。

第一步还会保存 `run2.2_mode1_preview.state`。如果 `SAFE_filelist`、`pins.ll`、极化方式、组织程序或过滤清单在两步之间变化，mode=2 会停止并要求重新执行 mode=1。

旧版 Run 2.2 已完成的预检可以尝试恢复：新版会优先读取旧的 good-dates 文件；若该文件已被旧版 mode=2 删除，则从 `run2.2_mode1_preview.log` 的 `Good dates` 段恢复。无法恢复时才要求重新运行 mode=1。

如果 csh 程序不在 `PATH` 中：

```bash
./run2.2_organize_frames.sh 1 --organizer /home/xinw/实际路径/organize_files_tops_linux_nex_xinw.csh
```

脚本会自动识别当前路径中的 `Descending` 和 `T34`，检查 SAFE 路径、轨道文件、`pins.ll` 范围与顺序、GMTSAR 命令和 mode=1 统计。非交互后台运行时，应确保 `pins.ll` 已提前生成，否则脚本会因无法读取输入而停止。

mode=2 支持续跑：已有输出会逐日期检查 IW1/IW2/IW3 VV XML/TIFF，完整日期自动显示 `[SKIP]`；失败或缺失日期重新处理，不再需要 `--allow-existing`。

### 输出与完成检查

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

`run2.2_mode2_failed_dates.txt` 每行记录“日期、失败原因、该日期日志路径”。mode=2 会继续完成其他日期，但只要存在失败日期，脚本最终返回非零状态。修复问题后再次执行 `./run2.2_organize_frames.sh 2`，已完成日期自动跳过，只补失败日期。

---

## Run 2.3：根据重组帧 XML 计算范围并生成 DEM

### 工作目录与脚本

脚本从具体轨道的根目录运行，例如：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run2.3_prepare_topo_DEM.py
```

无参数运行只显示命令指南，不读取 XML，不创建 `topo/`，也不生成任何处理结果：

```bash
./run2.3_prepare_topo_DEM.py
```

终端会明确说明 Mode 1 只计算并保存范围、Mode 2 正式调用 `make_dem.csh` 生成 DEM，以及默认极化、边界和分辨率参数。

脚本名称：

```text
run2.3_prepare_topo_DEM.py
```

默认输入为 `organized/` 下唯一的 `F????_F????` 目录。例如 T34 的输入结构为：

```text
T34/
├── run2.3_prepare_topo_DEM.py
└── organized/
    └── F2399_F2449/
        ├── S1A_*.SAFE/
        ├── S1A_*.SAFE/
        └── ...
```

如果一个轨道下存在多个 frame，必须明确指定：

```bash
./run2.3_prepare_topo_DEM.py 1 --frame F2399_F2449
```

### DEM 范围计算方法

脚本读取目标 frame 下全部 SAFE，而不是只抽取首、中、末三景。每个 SAFE 必须恰好包含 IW1、IW2、IW3 各一个 VV annotation XML。随后：

1. 汇总所有 XML 中的 `geolocationGridPoint` 经纬度；
2. 计算全部日期和三个 subswath 的经纬度并集；
3. W、S 向下取整到 0.1°，E、N 向上取整到 0.1°；
4. 四周默认再扩大 0.3°；
5. 生成 `make_dem.csh W E S N 1` 命令。

可用 `--margin` 修改额外边界，例如 `--margin 0.5`。默认极化为 `vv`，默认 `make_dem.csh` 最后一个分辨率参数为 `1`。

### Mode 1：计算并检查范围

```bash
./run2.3_prepare_topo_DEM.py 1
cat topo/dem_region.txt
```

Mode 1 会创建 `topo/` 并写入 `topo/dem_region.txt`，但不下载 DEM。终端和范围文件都会记录：

```text
Raw W/E/S/N
Final W/E/S/N
GMT -R region
make_dem.csh command
SAFE/XML count
```

检查 frame、SAFE/XML 数量和最终范围正确后再运行 Mode 2。

### Mode 2：正式生成 DEM

```bash
./run2.3_prepare_topo_DEM.py 2
```

脚本重新读取 XML 并核对范围，然后在 `topo/` 内运行：

```text
make_dem.csh W E S N 1
```

标准输出和错误写入 `topo/run2.3_make_dem.log`。命令退出后还会检查 `topo/dem.grd` 是否存在且非空；若已经存在 `dem.grd`，脚本会停止，避免无意覆盖。

### 主要输出

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

该脚本不写死 `T34` 或 `F2399_F2449`。复制到其他 `T编号` 目录后，可以自动使用唯一 frame；存在多个 frame 时用 `--frame` 指定。

---

## Run 2.4：建立 F1/F2/F3 并链接原始输入与 DEM

### 工作目录与输入

脚本从具体轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run2.4_link_raw_topo.sh
./run2.4_link_raw_topo.sh
```

运行前必须已有：

```text
organized/F????_F????/*.SAFE/annotation/*iw[123]*vv*.xml
organized/F????_F????/*.SAFE/measurement/*iw[123]*vv*.tiff
organized/*.EOF
topo/dem.grd
```

脚本自动使用 `organized/` 下唯一的 `F????_F????`。若存在多个 frame，则指定：

```bash
./run2.4_link_raw_topo.sh --frame F2399_F2449
```

### 链接关系

```text
F1/raw/
├── IW1 VV XML/TIFF → organized/F????_F????/*.SAFE/
├── *.EOF           → organized/*.EOF
└── dem.grd          → topo/dem.grd

F2/raw/
├── IW2 VV XML/TIFF → organized/F????_F????/*.SAFE/
├── *.EOF           → organized/*.EOF
└── dem.grd          → topo/dem.grd

F3/raw/
├── IW3 VV XML/TIFF → organized/F????_F????/*.SAFE/
├── *.EOF           → organized/*.EOF
└── dem.grd          → topo/dem.grd

F1/topo/dem.grd → topo/dem.grd
F2/topo/dem.grd → topo/dem.grd
F3/topo/dem.grd → topo/dem.grd
```

这些都是相对符号链接，不复制大型 TIFF、EOF 或 DEM。脚本运行前统计 SAFE 数量，并要求每个 IW 的 VV XML 和 TIFF 数量都等于 SAFE 数量；缺失或重复时停止。

脚本可以重复执行：已有同名符号链接会更新；若目标位置存在同名普通文件，则停止并拒绝覆盖。创建完成后还会检查 `F1/F2/F3` 中是否存在断开的符号链接。

默认极化为 VV；其他极化可使用 `--polarization vh|hh|hv`。脚本不写死 T34，可复制到其他 `T编号` 目录运行。

### 输出目录

```text
T34/
├── run2.4_link_raw_topo.sh
├── organized/
│   ├── F2399_F2449/
│   └── *.EOF
├── topo/
│   └── dem.grd
├── F1/
│   ├── raw/
│   └── topo/
├── F2/
│   ├── raw/
│   └── topo/
└── F3/
    ├── raw/
    └── topo/
```

---

## Run 3.1：为 F1/F2/F3 生成并调整 `data.in`

从轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run3.1_prep_data_F123.sh
./run3.1_prep_data_F123.sh
```

无参数只检查输入并显示命令指南，不删除旧文件，也不运行 `prep_data_linux.csh`。终端会分别显示 F1/F2/F3 的 XML、TIFF、EOF、DEM 链接数量和 READY 状态。

检查通过后使用模式1正式运行：

```bash
./run3.1_prep_data_F123.sh 1
```

模式1依次进入 `F1/raw`、`F2/raw`、`F3/raw`。每个目录开始前再次检查：

- VV XML 和 TIFF 符号链接均存在且数量相等；
- 至少存在一个 EOF 链接；
- 恰好存在一个 `dem.grd` 链接；
- 所有符号链接都能解析到真实文件；
- `prep_data_linux.csh` 位于 `PATH`。

通过检查后，脚本清理上一次准备阶段生成的 `data.in`、备份、列表和日志，但不删除 XML、TIFF、EOF、DEM 或其他处理文件。随后运行：

```bash
prep_data_linux.csh > prep_data.log 2>&1
```

新生成的原始顺序保存为：

```text
data.in.orig
```

若 `data.in` 至少有 3 条记录，脚本选择中间记录；偶数条时选择中间靠前的记录：

```text
5 条 → 第 3 条
6 条 → 第 3 条
7 条 → 第 4 条
8 条 → 第 4 条
```

选中的记录移动到 `data.in` 第一行，其余记录保持原有相对顺序。移动前内容同时保存为 `data.in.before_middle_first`。该策略以 `prep_data_linux.csh` 输出已经按时间排序为前提，用于把时间序列中部影像放在参考位置。

### 主要输出

```text
F1/raw/
├── data.in
├── data.in.orig
├── data.in.before_middle_first
└── prep_data.log

F2/raw/  # 同样四类输出
F3/raw/  # 同样四类输出
```

任意一个 F 的链接检查、`prep_data_linux.csh` 或 `data.in` 验证失败时，Run 3.1 立即停止，不继续产生后续不完整结果。

---

## Run 3.2：并行预处理 F1/F2/F3

### 工作目录与运行命令

Run 3.1 完成后，从轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run3.2_preproc_batch_tops_F123.sh
./run3.2_preproc_batch_tops_F123.sh
```

无参数运行只显示推荐命令和并行提示，然后退出，不会开始处理。正式标准处理必须明确运行：

```bash
./run3.2_preproc_batch_tops_F123.sh 5 1
```

其中 `5` 是每个 frame 的建议并行任务数，`1` 是标准预处理模式。无参数提示还会列出三种 ESD 备选命令。

完整参数格式：

```text
./run3.2_preproc_batch_tops_F123.sh NCORES_PER_FRAME MODE [ESD_MODE]
```

建议的一般配置是 `NCORES_PER_FRAME=5`、`MODE=1`。脚本要求提供前两个参数；选择 ESD（MODE=2）时还必须提供第三个 `ESD_MODE`。这里的 MODE 是自定义脚本 `/home/xinw/bin/own/preproc_batch_tops_parallel_new_wx.csh` 的模式：

| MODE | 实际处理 |
| --- | --- |
| `1` | 标准模式；每个影像对调用 `preproc_batch_tops.csh data.in dem.grd 2` |
| `2` | ESD 模式；调用 `preproc_batch_tops_esd.csh data.in dem.grd 2 ESD_MODE` |

标准处理使用：

```bash
./run3.2_preproc_batch_tops_F123.sh 5 1
```

三种 ESD 命令：

```bash
./run3.2_preproc_batch_tops_F123.sh 5 2 0  # average
./run3.2_preproc_batch_tops_F123.sh 5 2 1  # median
./run3.2_preproc_batch_tops_F123.sh 5 2 2  # interpolation
```

`ESD_MODE` 只在 `MODE=2` 时有效，其含义由 GMTSAR 的 `preproc_batch_tops_esd.csh` 确定：

| ESD_MODE | ESD 方式 | 修正特点 |
| --- | --- | --- |
| `0` | average | 使用平均残余方位偏移，对整景施加常数修正 |
| `1` | median | 使用中位数残余方位偏移，对整景施加常数修正；一般 ESD 建议值 |
| `2` | interpolation | 将残余方位偏移空间插值成格网，施加空间变化修正 |

一般处理默认使用标准模式：

```bash
./run3.2_preproc_batch_tops_F123.sh 5 1
```

只在需要 ESD 时，再使用默认的中位数 ESD 方式：

```bash
./run3.2_preproc_batch_tops_F123.sh 5 2 1
```

注意这里有两层模式参数：Run 3.2 的第二个参数 `2` 用来选择 ESD 脚本；内部命令 `preproc_batch_tops_esd.csh data.in dem.grd 2 ESD_MODE` 中的第一个 `2` 表示生成并配准 PRM/LED/SLC，不是 `ESD_MODE`。

脚本不使用交互菜单。无参数只打印标准模式、三种 ESD 命令和并行建议，不执行预处理；提示中明确说明需要 ESD 时默认建议 median（`ESD_MODE=1`）。必须输入完整命令 `./run3.2_preproc_batch_tops_F123.sh 5 1` 才会开始标准处理。

### 两层并行关系

F1、F2、F3 由 Run 3.2 同时启动；每个 frame 内部再由自定义 csh 启动 `NCORES_PER_FRAME` 个影像对任务。因此使用默认值 `5` 时近似最大任务数为：

```text
3 frame × 5 jobs = 15 jobs
```

第一个参数可以自行调整。脚本显示服务器 CPU 线程数；请求任务数超过 CPU 时给出警告。CPU、内存或磁盘 I/O 能力较弱时可降低为 `3` 或 `2`，例如：

```bash
./run3.2_preproc_batch_tops_F123.sh 3 1
```

正式长时间运行建议：

```bash
nohup ./run3.2_preproc_batch_tops_F123.sh 5 1 \
  > run3.2_preproc_batch_tops.nohup.log 2>&1 &
```

### 运行前检查

三个 frame 必须全部通过检查后才启动：

- `F1/raw`、`F2/raw`、`F3/raw` 和 `data.in` 存在；
- `data.in` 至少两条记录；
- VV XML、TIFF 数量分别等于 `data.in` 记录数；
- EOF 存在，`dem.grd` 唯一且所有符号链接有效；
- `tcsh`、GNU Parallel、GMT、标准/ESD 预处理脚本和 baseline 命令位于 `PATH`；
- 同一轨道中没有另一个 Run 3.2 实例运行。

### 重跑与完成检查

每次运行会在各自 `raw/` 中清理上次的：

```text
*.PRM  *.LED  *.SLC
baseline.ps  baseline.pdf  baseline_table.dat
preproc.cmd  tmp_dirlist  prmlist  log_*
20??????_20??????/
```

不会删除 `data.in`、XML、TIFF、EOF 或 `dem.grd`。随后重新执行全部影像对。

每个 frame 完成后必须满足：

```text
*ALL*.PRM 数量 = data.in 记录数
*ALL*.LED 数量 = data.in 记录数
*ALL*.SLC 数量 = data.in 记录数
baseline_table.dat 行数 = data.in 记录数
标准 MODE=1 时 baseline.ps 存在且非空
```

标准模式生成 `baseline.ps` 后，自定义脚本 `preproc_batch_tops_parallel_new_wx.csh` 会在每个 `F?/raw` 中自动执行：

```bash
gmt psconvert baseline.ps -Tf -A
```

因此可以直接查看：

```text
F1/raw/baseline.pdf
F2/raw/baseline.pdf
F3/raw/baseline.pdf
```

自定义 CSH 检查 GMT 命令状态和 `baseline.pdf` 是否生成；Run 3.2 保持原逻辑，只明确检查 `baseline.ps`，不再单独增加 PDF 检查。若自定义 CSH 因转换失败返回非零状态，Run 3.2 仍会通过原有的子脚本退出状态发现失败，相关输出保存在对应的 `preproc_all.log`。

日志分别保存在：

```text
F1/raw/preproc_all.log
F2/raw/preproc_all.log
F3/raw/preproc_all.log
```

一个 frame 失败不会立即终止另外两个已经启动的任务；脚本等待三者结束后汇总状态，只要一个失败就返回非零状态，不会误报全部完成。

---

## Run 3.3：生成 F1/F2/F3 的 intf.in 和 batch_tops.config

Run 3.2 完成后，在轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run3.3_make_intf_config_F123.sh
./run3.3_make_intf_config_F123.sh
```

无参数只显示命令，不处理。模式1只在 F1 选择干涉对并生成时空基线网络图：

```bash
./run3.3_make_intf_config_F123.sh 1 60 150
```

```text
1   = PREVIEW
60  = threshold_time，时间基线阈值，单位：天
150 = threshold_baseline，空间基线阈值，单位：米
```

模式1调用：

```text
select_pairs_new.csh baseline_table.dat threshold_time threshold_baseline
```

默认依赖：

```text
/home/xinw/bin/own/batch_tops.config
/home/xinw/bin/own/select_pairs_new.csh
```

运行前检查 `F1/F2/F3`、F1 的 `data.in`、`baseline_table.dat`、模板和选对脚本。F1 的基线表行数必须等于 `data.in` 记录数。

脚本从 `F1/data.in` 第一行提取主影像日期，将 `F1/batch_tops.config` 中的 `master_image` 更新为：

```text
S1_YYYYMMDD_ALL_F1
```

选对输出记录到 `F1/select_pairs_new.log`，并生成：

```text
F1/intf.in
F1/baseline.ps
F1/baseline.pdf
F1/run3.3_preview.info
```

`baseline.pdf` 中的点表示影像，连线表示已选干涉对。先查看该图；如果网络不合适，用新阈值重新运行模式1。

模式1同时生成 `F1/batch_tops.config`。`master_image` 的日期来自 `F1/raw/data.in` 第一行，也就是 Run3.1 调整到首行的统一主影像：

```text
F1/raw/data.in 第一行的日期 YYYYMMDD
→ master_image = S1_YYYYMMDD_ALL_F1
```

确认后运行模式2：

```bash
./run3.3_make_intf_config_F123.sh 2
```

模式2不会重新选对，而是将最近一次预览确认的 F1 网络和配置复制到 F2/F3，并仅替换影像名后缀：

```text
_F1 → _F2
_F1 → _F3
```

最终输出：

```text
F1/intf.in  F1/batch_tops.config
F2/intf.in  F2/batch_tops.config
F3/intf.in  F3/batch_tops.config
```

三个 `intf.in` 的行数必须相同，三个配置的 `master_image` 必须分别对应 F1、F2、F3。该设计保证三个子波段使用完全相同的日期对。

---

## Run 3.4：并行运行 F1/F2/F3 的 dem2topo_ra

Run3.3 模式2完成后，在轨道根目录运行：

```bash
cd /data2/xinw/InSAR_processing/Descending/T34
chmod +x run3.4_dem2topo_ra_F123.sh
./run3.4_dem2topo_ra_F123.sh
```

无参数只打印使用说明，不启动任务。正式提交：

```bash
./run3.4_dem2topo_ra_F123.sh 1
```

脚本先读取三个 `batch_tops.config` 的 `master_image`，检查其后缀分别为 `_ALL_F1`、`_ALL_F2`、`_ALL_F3`，并确认对应 PRM、LED 和 `topo/dem.grd` 存在。三个 frame 全部通过后，在各自 `topo/` 中链接主影像 PRM/LED，并执行：

```text
dem2topo_ra.csh <master_image>.PRM dem.grd 0
```

三个任务并行运行，PID与日志为：

```text
F1/topo/dem2topo_ra.pid  F1/topo/dem2topo_ra.log
F2/topo/dem2topo_ra.pid  F2/topo/dem2topo_ra.log
F3/topo/dem2topo_ra.pid  F3/topo/dem2topo_ra.log
```

Run3.4 只有模式1。脚本启动三个任务后自动等待，并在结束后检查每个命令的退出状态、`trans.dat` 和 `topo_ra.grd`。任意 frame 失败时显示对应日志最后20行并返回非零状态；三个 frame 全部成功才显示最终 `[DONE]`。

实时查看日志：

```bash
tail -f F1/topo/dem2topo_ra.log
tail -f F2/topo/dem2topo_ra.log
tail -f F3/topo/dem2topo_ra.log
```

需要关闭终端时，应把整个 Run3.4 放到后台，保留自动检查流程：

```bash
nohup ./run3.4_dem2topo_ra_F123.sh 1 \
  > run3.4_dem2topo_ra.nohup.log 2>&1 &
```

模式1会阻止同一 frame 的重复任务。重新运行已结束任务时，只清理旧的转换输出、PID和日志，不删除 DEM、PRM、LED或配置文件。

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

Run3.4完成后，在轨道根目录先查看命令说明：

```bash
./run3.5_intf_tops_parallel_F123.sh
```

无参数不会启动处理，但会逐个检查 F1/F2/F3 的 `intf.in`、干涉对数量、`batch_tops.config`、`proc_stage=2` 和 `topo_phase=1`，并显示 `[CHECK OK]` 或 `[CHECK ERROR]`。正式运行时指定每个 frame 内部同时处理的干涉对数量，推荐为5：

```bash
./run3.5_intf_tops_parallel_F123.sh 5
```

该命令相当于同时进入 F1、F2、F3，并分别执行：

```bash
nohup intf_tops_parallel.csh intf.in batch_tops.config 5 >& itp.log &
```

因此 F1/F2/F3 同时运行，每个 frame 最多5个干涉对任务，总并行任务约为15。计算机CPU或内存较少时可将参数改为3。

运行前，脚本要求 `batch_tops.config` 中：

```text
proc_stage = 2
topo_phase = 1
```

脚本还会检查 `intf.in` 格式和重复记录、全部 PRM/LED/SLC、`topo_ra.grd`，以及启用地理编码时所需的 `trans.dat`。如果发现中断遗留的 `F?/intf/<日期对>/`，脚本停止并要求先检查，避免在旧目录中继续写入。

长时间运行建议：

```bash
nohup ./run3.5_intf_tops_parallel_F123.sh 5 \
  > run3.5_intf_tops_parallel.nohup.log 2>&1 &
```

日志和输出：

```text
F1/itp.log       F1/intf_all/<日期对>/
F2/itp.log       F2/intf_all/<日期对>/
F3/itp.log       F3/intf_all/<日期对>/
```

脚本等待三个 frame 全部结束，并检查每个单对日志的完成标志、输出目录和 `.grd` 文件。失败记录保存在对应的 `F?/run3.5_failed_pairs.tsv`。

---

## Run 3.6：清理临时文件并拼接 F1/F2/F3

Run3.5 的 F1、F2、F3 全部成功后，在轨道根目录先执行无参数检查：

```bash
./run3.6_merge_F123.sh
```

无参数统计三个 `intf_all/` 的日期对，检查三组日期目录是否完全一致，并逐个日期对检查非空的 `corr.grd`、`mask.grd`、`phasefilt.grd`。终端会显示三种网格的数量；若有缺失，会列出 frame、日期对和缺少的文件。该模式还显示待删除的临时文件数量，但不会删除文件或启动拼接。

第一步直接从最终 `merge_list` 中选择第一个、中间一个和最后一个记录，并生成预览图：

```bash
./run3.6_merge_F123.sh 1 15
```

模式1从经过主影像优先排序的最终 `merge_list` 中直接选择第1行、中间行和最后1行。每个目标日期对拼接 F1/F2/F3 后，用GMT分别绘制：

```text
merge/run3.6_check_merge_seams_plots/<日期对>_corr.pdf
merge/run3.6_check_merge_seams_plots/<日期对>_mask.pdf
merge/run3.6_check_merge_seams_plots/<日期对>_phasefilt.pdf
```

共生成9个PDF。最终 `merge_list` 的第1行已经是主影像相关记录，可直接满足 `merge_batch_parallel.sh` 的统一主影像要求，因此预览只计算这3个日期对，不再附加初始化日期对。模式1复制一份 `preview_batch_tops.config`，将 `threshold_snaphu`、`threshold_geocode`、`correct_iono` 设为0，并使用执行结束后自动删除的空 `trans.dat` 占位文件阻止真实投影LUT生成；因此模式1只做拼接和PDF，不计算真实 `trans.dat`。绘图格式沿用GMTSAR `geocode.csh`：横轴 Range、纵轴 Azimuth，顶部放置水平色标，并通过 `gmt psconvert -Tf -P -A -Z` 输出PDF。`corr` 和 `mask` 使用0–1灰度、NaN为灰色；`phasefilt` 使用 −3.15 到3.15 rad 色标。模式1到这里停止，不会开始其余日期对。检查图中的 F1/F2、F2/F3 连接位置是否存在明显突变、空白带或错位。

确认预览结果可以接受后，第二步正式拼接全部日期对：

```bash
./run3.6_merge_F123.sh 2 15
```

正式模式必须在模式号后给出并行数，推荐15。CPU或内存较少时，可以改为5或3：

```bash
./run3.6_merge_F123.sh 2 5
```

GMTSAR 原始 `merge_batch_parallel.sh` 最后的 `parallel parallel_func` 没有设置作业数，会默认使用可用CPU核心。Run3.6通过 GNU Parallel 的 `PARALLEL="--jobs 15"` 环境选项限制并行数，不需要修改系统GMTSAR脚本。

两个模式共同执行输入检查和必要清理：

1. 确认 F1/F2/F3 的干涉日期对集合完全相同；
2. 检查每个日期对都包含非空的 `corr.grd`、`mask.grd` 和 `phasefilt.grd`；
3. 如果任意一个 frame 的某日期对缺少网格，将该日期对在 F1/F2/F3 中的三个目录全部列入删除计划；只有用户在交互终端准确输入 `DELETE` 才执行删除；
4. 删除轨道根目录下 `F*/intf_20*.in` 和 `F*/intf_20*.log`，但保留 `F*/intf.in`、`F*/itp.log` 和其余 `F*/intf_all/`；
5. 创建 `merge/`，由 F1 日期目录生成 `intflist` 和三子条带 `merge_list`；主影像排序使用临时文件，结束后不保留 `merge_list.orig`；
6. 复制 F1 的 `batch_tops.config`，将 merge 配置中的 `proc_stage` 设为1；
7. 建立 `merge/dem.grd -> ../topo/dem.grd`。

模式2要求 `merge/run3.6_preview_complete` 和 `merge/run3.6_check_merge_seams_plots/` 存在，证明模式1预览已完成。启动后会删除 `merge/` 根目录下全部名称以 `20` 开头的预览拼接结果目录，以及 `preview*`、`run3.6_preview_*` 控制文件；该清理不进入也不影响 `F1/F2/F3/intf_all/`。唯一保留的是 `merge/run3.6_check_merge_seams_plots/` 中的9个PDF。随后模式2从完整 `merge_list` 重新处理全部日期对。模式2还会删除可能遗留的空 `trans.dat`，然后由正式配置生成真实投影LUT。`merge_list.orig` 不会生成，若目录中存在旧文件，脚本会将其删除。

如果发现缺失或空网格，详细清单写入 `run3.6_missing_grids.tsv`。用户确认后，实际删除记录写入 `run3.6_deleted_pairs.tsv`。脚本不会修改 F1/F2/F3 的 `intf.in`。

缺失网格时不能直接使用 `nohup` 确认删除：`nohup` 没有交互输入，脚本会安全停止。应先在正常终端运行模式1、核对清单并输入 `DELETE`。预览确认后，模式2可以使用下面的 `nohup` 命令。

脚本保留原有的主影像排序逻辑：主影像位于干涉对左侧的记录被移到 `merge_list` 前部。

长时间运行建议：

```bash
nohup ./run3.6_merge_F123.sh 2 15 \
  > run3.6_merge_F123.nohup.log 2>&1 &
```

监控：

```bash
tail -f run3.6_merge_F123.nohup.log
tail -f merge/merge_batch.log
```

若 `merge/intf_all/` 已存在且含有结果，脚本会停止，避免覆盖以前的拼接结果。

### Run 3.6 并行生成 trans.dat 的独立版本

标准 `run3.6_merge_F123.sh` 保持不变。需要使用 OpenMP 版 `SAT_llt2rat_para` 加速正式 `trans.dat` 时，使用单独脚本：

```bash
./run3.6_merge_F123_parallel_trans.sh 2 15 5
```

参数依次表示：模式2、15个干涉对拼接并行任务、5个 `trans.dat` OpenMP线程。并行程序默认路径为：

```text
/home/xinw/bin/own/SAT_llt2rat_para
```

该脚本临时在 `PATH` 前端放置一个参数转换器，把GMTSAR原调用：

```text
SAT_llt2rat master.PRM 1 -bod
```

转换为：

```text
SAT_llt2rat_para master.PRM dem.grd -bod
```

转换器只在本次模式2运行期间存在，结束后自动删除；不替换GMTSAR安装目录中的原始 `SAT_llt2rat`，也不修改标准Run3.6。模式1仍可通过并行版入口运行，但不会生成真实LUT：

```bash
./run3.6_merge_F123_parallel_trans.sh 1 15
```

日志中出现下面内容表示并行程序已接管LUT计算：

```text
[PARALLEL TRANS] 5 threads, PRM=supermaster.PRM, DEM=dem.grd
```

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

在轨道根目录执行无参数检查：

~~~bash
./run4.4_geocode_sbas_velocity.sh
~~~

它检查 `sbas_demcorr_pin/vel.grd`、大于 20 MiB 的 `merge/trans.dat`、`F1/intf_all/20*/gauss_400` 和相关 GMTSAR/GMT 命令，不创建或修改结果。正式运行默认使用 400 m 空间滤波：

~~~bash
./run4.4_geocode_sbas_velocity.sh 1
~~~

脚本在 `sbas_demcorr_pin/` 链接 `trans.dat` 和 `gauss_400`，生成：

~~~text
vel_ll.grd             使用 400 m 空间滤波的经纬度速度，供 KML 使用
vel_ll.cpt             默认 -10/10/1 的 jet 色标
vel_ll.pdf             GMT 绘制的经纬度速度图
vel_ll.kml             以及 grd2kml.csh 生成的配套文件
run4.4_complete        完成记录
~~~

默认色标范围可用 `VEL_CPT_MIN`、`VEL_CPT_MAX` 和 `VEL_CPT_STEP` 环境变量修改。重复正式运行时，脚本直接删除并重新生成上一轮 Run 4.4 产品，不建立备份目录。PDF 标题固定为 `SBAS velocity`。

## Run 5.1：并行去除位移时间序列中的季节项

在轨道根目录无参数运行，只检查 `sbas_demcorr_pin/disp_YYYYDDD.grd`，不创建文件：

~~~bash
./run5.1_remove_season_from_grd_stack_parallel.py
~~~

正式运行默认使用20个并行进程、每块128行：

~~~bash
./run5.1_remove_season_from_grd_stack_parallel.py 1
~~~

也可降低并行数：

~~~bash
./run5.1_remove_season_from_grd_stack_parallel.py 1 --jobs 5
~~~

默认模型为“常数＋线性趋势＋年周期正余弦＋半年周期正余弦”。脚本只减去年、半年周期，保留长期趋势，再把输出重新参考到第一期。结果写入：

~~~text
sbas_demcorr_pin/disp_deseason/disp_YYYYDDD.grd
sbas_demcorr_pin/disp_deseason/run5.1_complete
~~~

脚本先完成临时结果并检查数量，再替换正式输出；失败时保留原 `disp_deseason/`。


## Run 5.2：检查去季节前后的点时间序列

脚本放在轨道根目录运行。无参数时检查 Run 5.1 的完成标记、原始与去季节网格数量、历元集合、网格结构及检查点位置，不创建图或文本：

~~~bash
./run5.2_plot_deseason_point_timeseries.py
~~~

正式绘制默认的 W、E、S、N、C 五个雷达坐标检查点：

~~~bash
./run5.2_plot_deseason_point_timeseries.py 1
~~~

默认点沿用 T70 的设置：

~~~text
W  10000 16000
E  58000 16000
S  34000  5000
N  34000 28000
C  34000 16000
~~~

这里的 X、Y 是雷达网格坐标，不是经纬度。脚本会选取距离输入坐标最近的网格节点，并在检查信息中同时显示请求坐标、实际坐标和数组索引。用于其他轨道时，建议明确指定适合该轨道的点；一旦使用 `--point`，默认五点将全部被替换：

~~~bash
./run5.2_plot_deseason_point_timeseries.py 1 \
  --point P1 34000 16000 \
  --point P2 40000 12000
~~~

每个点生成一张三行 PNG：第一行为原始位移，第二行为被 Run 5.1 去除的季节项，即“原始－去季节”，第三行为去季节位移。默认同时输出逐历元文本：

~~~text
sbas_demcorr_pin/disp_deseason/run5.2_point_timeseries/
├── W_3rows.png
├── W_timeseries.txt
├── E_3rows.png
├── E_timeseries.txt
├── S_3rows.png
├── S_timeseries.txt
├── N_3rows.png
├── N_timeseries.txt
├── C_3rows.png
├── C_timeseries.txt
└── run5.2_complete
~~~

可用 `--dpi 300` 修改图片分辨率，或用 `--no-txt` 只生成图片。重复正式运行只清理和重建该输出目录中的 Run 5.2 PNG、TXT 与完成标记，不修改原始 `disp_*.grd` 或 Run 5.1 的去季节网格。

## Run 5.3：并行重估去季节速度

脚本放在轨道根目录运行，从 Run 5.1 的输出目录读取全部 `disp_YYYYDDD.grd`。无参数只检查输入历元、时间跨度、网格、并行参数和输出位置：

~~~bash
./run5.3_make_velocity_from_deseason_parallel.py
~~~

正式运行默认使用20个进程，每个任务处理512行：

~~~bash
./run5.3_make_velocity_from_deseason_parallel.py 1
~~~

服务器繁忙时可降低并行数：

~~~bash
./run5.3_make_velocity_from_deseason_parallel.py 1 --jobs 5
~~~

脚本对每个像元的去季节位移与时间做一元线性最小二乘拟合，将斜率由 mm/day 乘以365.0换算为 mm/yr。NaN 历元不参与该像元拟合；默认至少需要2个有效历元。输出为：

`disp_YYYYDDD.grd` 中的 `DDD` 按 GMTSAR 的从零起算规则解析，即 `000` 表示1月1日；Run 5.1、Run 5.2 和 Run 5.3 使用相同规则。

~~~text
sbas_demcorr_pin/disp_deseason/vel_deseason.grd
sbas_demcorr_pin/disp_deseason/vel_deseason.png
sbas_demcorr_pin/disp_deseason/run5.3_complete
~~~

有效观测数只在像元拟合过程中用于判断，不再单独写出网格。速度图使用速度绝对值第98百分位作为对称色标；为了避免超大网格绘图时占用过多内存，绘图阶段会自动降采样，但 `vel_deseason.grd` 保持完整分辨率。正式处理中使用临时文件，速度计算完成并刷新 GMT 网格后才替换正式结果；失败时不写完成标记。

## Run 5.4：投影去季节速度到经纬度

脚本放在轨道根目录运行。无参数检查 Run 5.3 速度、完成标记、大于20 MiB的正式 `merge/trans.dat`、第一个 F1 干涉对的 `gauss_400` 及所需命令，不创建或修改文件：

~~~bash
./run5.4_proj_vel_deseason_to_ll.sh
~~~

正式运行固定使用400 m空间滤波：

~~~bash
./run5.4_proj_vel_deseason_to_ll.sh 1
~~~

脚本在 `sbas_demcorr_pin/disp_deseason/` 中建立指向正式投影表和滤波文件的软链接，然后运行：

~~~bash
proj_ra2ll.csh trans.dat vel_deseason.grd vel_deseason_ll.grd 400
~~~

为避免失败时留下不完整的正式网格，实际命令先写临时文件，通过 `gmt grdinfo` 检查后再安装为正式结果。输出为：

~~~text
sbas_demcorr_pin/disp_deseason/vel_deseason_ll.grd
sbas_demcorr_pin/disp_deseason/vel_deseason_ll.cpt
sbas_demcorr_pin/disp_deseason/vel_deseason_ll.pdf
sbas_demcorr_pin/disp_deseason/run5.4_complete
~~~

`vel_deseason.grd` 是完整分辨率的雷达坐标速度，`vel_deseason_ll.grd` 是使用400 m滤波后的经纬度速度。脚本使用 GMT 绘制标题为 `Deseasoned SBAS velocity` 的 PDF，默认采用 jet 色标和 `-10/10/1 mm/yr` 范围，可用 `VEL_DESEASON_CPT_MIN`、`VEL_DESEASON_CPT_MAX`、`VEL_DESEASON_CPT_STEP` 调整。Run 5.4 不修改 Run 5.3 的雷达坐标速度。

## Run 6.1：插值 GNSS 东向和北向速度

把 GNSS 文本放在轨道根目录，默认文件名为：

~~~text
2024_HMF_GPS_ITRF_Panda_Eric_unique.txt
~~~

文件首行为表头，后续每行至少包含：

~~~text
longitude latitude east_mm north_mm east_error north_error
~~~

无参数只检查文件、前六列数值、站点数量、GMT、区域、分辨率和已有输出，不创建结果：

~~~bash
./run6.1_grid_gnss_horizontal_velocity.sh
~~~

正式使用截图中的 HMF 参数运行：

~~~bash
./run6.1_grid_gnss_horizontal_velocity.sh 1
~~~

对应核心命令为：

~~~bash
gmt gpsgridder gnss_stations_used.txt \
  -R70/100/24/37.5 -I2m -fg -W -r -Cn100% \
  -Ggps_%s.grd -V
~~~

默认结果放在独立目录：

~~~text
GNSS2LOS_correction/
├── GNSS_E_HMF.grd
├── GNSS_N_HMF.grd
├── GNSS_HMF.cpt
├── GNSS_E_HMF.pdf
├── GNSS_N_HMF.pdf
├── gnss_stations_used.txt
├── run6.1_gpsgridder.log
└── run6.1_complete
~~~

其中 `GNSS_E_HMF.grd` 是 GNSS 东向速度，`GNSS_N_HMF.grd` 是北向速度，单位继承输入表的 mm/yr。脚本分别生成同名 PDF，默认使用 jet 色标和 `-20/20/1 mm/yr` 范围；可通过 `GNSS_CPT_MIN`、`GNSS_CPT_MAX`、`GNSS_CPT_STEP` 修改。经纬度区域、网格间隔和输入文件可分别用 `--region`、`--increment`、`--gnss-file` 修改。脚本先在临时目录生成、验证并绘制两个网格，全部成功后才替换正式结果。

## Run 6.2：将 GNSS 网格匹配到 InSAR 网格

脚本在轨道根目录运行，以 `sbas_demcorr_pin/vel_ll.grd` 为模板。无参数只检查 Run 6.1 东向/北向网格、InSAR 经纬度速度网格、范围、分辨率和行列数：

~~~bash
./run6.2_resample_GNSS_to_InSAR_grid.sh
~~~

正式重采样并应用 `vel_ll.grd` 有效像元范围：

~~~bash
./run6.2_resample_GNSS_to_InSAR_grid.sh 1
~~~

输出为：

~~~text
GNSS2LOS_correction/GNSS_E.grd
GNSS2LOS_correction/GNSS_N.grd
GNSS2LOS_correction/GNSS_E.pdf
GNSS2LOS_correction/GNSS_N.pdf
GNSS2LOS_correction/run6.2_complete
~~~

`GNSS_E.grd` 和 `GNSS_N.grd` 与 `sbas_demcorr_pin/vel_ll.grd` 具有相同的范围、分辨率、行列数和网格注册方式。脚本仅保留 InSAR 速度网格内的有效区域，中间重采样网格和掩膜会自动清理。两幅 PDF 采用与 Run 5.4 一致的地图布局，标题位于图件上方，水平色标位于图件下方。

## Run 6.3：将 GNSS 水平速度投影到 LOS

无参数检查 Run 6.2 输出、网格一致性及默认投影几何，不生成结果：

~~~bash
./run6.3_project_GNSS_to_LOS.py
~~~

该检查模式只通过 `gmt grdinfo -C` 读取网格头信息，比较范围、分辨率、行列数和注册方式，不读取完整像元数组，因此即使网格很大也能快速完成。完整网格只在正式 LOS 投影时读取。

正式运行必须选择升轨或降轨。升轨默认轨道方位角 `350°`、入射角 `40°`：

~~~bash
./run6.3_project_GNSS_to_LOS.py 1 ascending
~~~

降轨默认轨道方位角 `190°`、入射角 `40°`。当前 `Descending/T34` 使用：

~~~bash
./run6.3_project_GNSS_to_LOS.py 1 descending
~~~

如果有更精确的轨道方位角或入射角，可以覆盖对应方向的默认值：

~~~bash
./run6.3_project_GNSS_to_LOS.py 1 descending --track 193 --look 40
~~~

脚本使用：

~~~text
LOS = [-sin(look) cos(track)] × East
    + [ sin(look) sin(track)] × North
~~~

其中 `track` 是从正北顺时针计算的卫星飞行方位角，`look` 是从垂直方向计算的雷达侧视角/入射角。升轨和降轨必须显式选择，防止错误地把升轨 `350°` 用于降轨。正式输出为：

~~~text
GNSS2LOS_correction/GNSS_to_LOS.grd
GNSS2LOS_correction/GNSS_to_LOS.pdf
GNSS2LOS_correction/run6.3_complete
~~~

PDF 使用兼容性更好的 GMT classic 流程 `grdimage → psscale → psconvert` 绘制，不依赖 `gmt begin/end` 现代会话；固定采用 jet 色标和 `-5/5/1 mm/yr` 范围。NaN 区域显示为灰色，标题位于上方，水平色标位于图件下方，与 Run 5.4、Run 6.2 的布局保持一致。Run 6.3 已合并原来的 LOS 计算和单独绘图脚本；Python 环境安装 `netCDF4` 或 `xarray` 中任意一个即可读取和写出 GMT 网格，不再依赖 Matplotlib 绘图。

## Run 6.4：投影 GNSS LOS 速度到雷达坐标

无参数在轨道根目录快速检查 Run 6.3 的经纬度 LOS 网格、`sbas_demcorr_pin/trans.dat` 和去季节位移模板：

~~~bash
./run6.4_project_GNSS_LOS_to_radar.sh
~~~

正式运行：

~~~bash
./run6.4_project_GNSS_LOS_to_radar.sh 1
~~~

脚本先运行 `proj_ll2ra.csh`，再用 GMT `surface -T0.1` 插值到第一个 `disp_YYYYDDD.grd` 的准确范围、分辨率、行列数和注册方式。输出为：

~~~text
GNSS2LOS_correction/GNSS_to_LOS_ra.grd
GNSS2LOS_correction/GNSS_to_LOS_ra.pdf
GNSS2LOS_correction/run6.4_complete
~~~

雷达坐标速度图使用 GMT classic 绘制，jet 色标为 `-5/5/1 mm/yr`。

## Run 6.5：生成 GNSS LOS 累积位移时序

无参数检查日期和输入，不生成网格：

~~~bash
./run6.5_build_GNSS_LOS_timeseries.sh
~~~

正式运行默认使用5个并行任务：

~~~bash
./run6.5_build_GNSS_LOS_timeseries.sh 1
~~~

也可指定并行数：

~~~bash
./run6.5_build_GNSS_LOS_timeseries.sh 1 10
~~~

日期严格按 GMTSAR 的零起算规则解析：

~~~text
date = January 1 + DDD days
YYYY000 = January 1
elapsed_years = actual elapsed days / 365.0
GNSS displacement = GNSS LOS velocity × elapsed_years
~~~

使用真实日期差，因此能正确跨越闰年；速度与 Run 6.6 均采用365.0天/年的换算约定。输出为：

~~~text
GNSS2LOS_correction/GNSS_LOS_timeseries/gnss_LOS_YYYYDDD.grd
GNSS2LOS_correction/run6.5_complete
~~~

脚本先在临时目录生成并验证全部期次，全部成功后才整体替换正式时序目录。

## Run 6.6：重新拟合并验证 GNSS LOS 时序

无参数只检查时序数量、首末日期和首末网格几何：

~~~bash
./run6.6_validate_GNSS_LOS_timeseries.py
~~~

正式运行默认使用5个进程和每块512行：

~~~bash
./run6.6_validate_GNSS_LOS_timeseries.py 1
~~~

可调整并行与分块：

~~~bash
./run6.6_validate_GNSS_LOS_timeseries.py 1 --jobs 10 --block-rows 512
~~~

脚本按照 `date = January 1 + DDD days` 解析每一期，对每个有效像元拟合 `mm/day` 斜率，再乘365.0恢复 `mm/yr` 速度，并与 Run 6.4 的参考速度相减。输出为：

~~~text
GNSS2LOS_correction/GNSS_LOS_validation/GNSS_to_LOS_ra_refit.grd
GNSS2LOS_correction/GNSS_LOS_validation/GNSS_to_LOS_ra_difference.grd
GNSS2LOS_correction/GNSS_LOS_validation/GNSS_LOS_validation_3panel.pdf
GNSS2LOS_correction/GNSS_LOS_validation/run6.6_complete
~~~

`GNSS_LOS_validation_3panel.pdf` 采用一行三列布局，依次显示 Run 6.4 参考速度、Run 6.6 重新拟合速度和“拟合−参考”差值。前两幅采用 `-5/5/1 mm/yr`，差值采用 `-0.01/0.01/0.001 mm/yr`，每幅图的水平色标均位于下方。差值接近零表示 Run 6.5 的时序生成正确。Run 6.6 不再生成单独的观测次数网格。如果拟合和差值网格已成功生成、但绘图阶段中断，重新运行会验证已有网格并跳过像元拟合，只重新绘图和写入完成标记。

## Run 6.7：使用 GNSS 时序改正去季节 InSAR 位移

无参数检查两套时序的日期是否一一对应、主影像 PRM 以及雷达网格参数，不生成结果：

~~~bash
./run6.7_correct_displacement_with_GNSS.sh
~~~

正式运行默认5个并行任务：

~~~bash
./run6.7_correct_displacement_with_GNSS.sh 1
./run6.7_correct_displacement_with_GNSS.sh 1 10
~~~

每一期先计算 `去季节 InSAR 位移 − GNSS LOS 位移`，将差值降低到约5 km网格并进行约80 km空间平滑，再从原始去季节 InSAR 位移中减去该长波长差值。这样保留 InSAR 的局部形变，同时使长波长信号参考到 GNSS。输出为：

~~~text
GNSS2LOS_correction/GNSS_corrected_displacement/disp_YYYYDDD_gnssref_5km_80km.grd
GNSS2LOS_correction/GNSS_corrected_displacement/diff_YYYYDDD_smooth80km_full.grd
GNSS2LOS_correction/run6.7_complete
~~~

脚本支持断点续跑：只有当两项输出均有效且比对应 InSAR/GNSS 输入更新时才跳过该期。

## Run 6.8：拟合 GNSS 改正后的速度

无参数只核对两套 Run 6.7 时序数量和日期：

~~~bash
./run6.8_make_velocity_from_GNSS_corrected_timeseries.py
~~~

正式运行默认5个进程、每块512行：

~~~bash
./run6.8_make_velocity_from_GNSS_corrected_timeseries.py 1
./run6.8_make_velocity_from_GNSS_corrected_timeseries.py 1 --jobs 10 --block-rows 512
~~~

日期继续采用零起算规则 `date = January 1 + DDD days`，即 `YYYY000` 为1月1日。脚本分别拟合 GNSS 改正后的 InSAR 位移和被去除的长波长差值，输出：

~~~text
GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km.grd
GNSS2LOS_correction/GNSS_corrected_displacement/vel_diff_smooth80km_full.grd
GNSS2LOS_correction/GNSS_corrected_displacement/GNSS_corrected_velocity_6panel.pdf
GNSS2LOS_correction/run6.8_complete
~~~

六联 PDF 使用两行三列布局。第一行为原始 SBAS 速度、Run 5.3 去季节速度和 Run 6.4 GNSS LOS 雷达坐标速度；第二行为 GNSS 改正后的最终速度、被去除的长波长改正速度和 `去季节速度−改正后速度−长波长改正` 的闭合残差。前五幅速度图采用 `-5/5/1 mm/yr` 范围，闭合残差采用 `-0.01/0.01/0.001 mm/yr`。上下两行留有独立标题和水平色标间距，闭合残差接近零表示 Run 6.7 和 Run 6.8 数学关系闭合。

## Run 6.9：投影 GNSS 改正后的速度到经纬度

无参数检查 Run 6.8 输出、`trans.dat` 和 `gauss_400`：

~~~bash
./run6.9_geocode_GNSS_corrected_velocity.sh
~~~

正式使用400 m空间滤波：

~~~bash
./run6.9_geocode_GNSS_corrected_velocity.sh 1
~~~

如确实准备了相应 `gauss_600` 文件，也可以指定600 m：

~~~bash
./run6.9_geocode_GNSS_corrected_velocity.sh 1 600
~~~

输出为：

~~~text
GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km_ll.grd
GNSS2LOS_correction/GNSS_corrected_displacement/vel_diff_smooth80km_full_ll.grd
GNSS2LOS_correction/GNSS_corrected_displacement/GNSS_corrected_velocity_ll.cpt
GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km_ll.pdf
GNSS2LOS_correction/GNSS_corrected_displacement/vel_diff_smooth80km_full_ll.pdf
GNSS2LOS_correction/GNSS_corrected_displacement/vel_gnssref_5km_80km_ll*.kml
GNSS2LOS_correction/run6.9_complete
~~~

两套速度分别保存为独立 PDF，均使用 `-5～5 mm/yr` 的 GMT `jet` 色标。KML 只对应 GNSS 改正后的最终 InSAR 速度，可直接加载到 Google Earth。
