#!/usr/bin/env python3
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 21, 2026

"""Run 1.1: download Sentinel-1 ZIP products using fast checks."""

from __future__ import annotations

import argparse
import fcntl
import glob
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlparse


DEFAULT_PATTERN = "download*.py"
DEFAULT_OUTDIR = Path("zip")
DEFAULT_URL_LIST = Path("url_list_from_download_py.txt")
DEFAULT_COOKIE_FILE = Path("asf_cookies.txt")
DEFAULT_MIN_SIZE_MB = 100
DEFAULT_RETRIES = 3
DEFAULT_RETRY_WAIT = 10
LOCK_FILE = Path(".run1.1_download_S1.lock")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "从当前目录的 ASF download*.py 中提取 Sentinel-1 ZIP URL，"
            "并下载到 zip/。未完成的数据保存在 .part 文件中，可断点续传。"
        )
    )
    parser.add_argument(
        "--pattern",
        default=DEFAULT_PATTERN,
        help=f"ASF 下载脚本的匹配模式（默认：{DEFAULT_PATTERN}）",
    )
    parser.add_argument(
        "--outdir",
        type=Path,
        default=DEFAULT_OUTDIR,
        help=f"ZIP 输出目录（默认：{DEFAULT_OUTDIR}）",
    )
    parser.add_argument(
        "--min-size-mb",
        type=int,
        default=DEFAULT_MIN_SIZE_MB,
        help=f"产品最小合理大小，单位 MB（默认：{DEFAULT_MIN_SIZE_MB}）",
    )
    parser.add_argument(
        "--retries",
        type=int,
        default=DEFAULT_RETRIES,
        help=f"每个文件的脚本级重试次数（默认：{DEFAULT_RETRIES}）",
    )
    parser.add_argument(
        "--retry-wait",
        type=int,
        default=DEFAULT_RETRY_WAIT,
        help=f"两次脚本级重试之间的等待秒数（默认：{DEFAULT_RETRY_WAIT}）",
    )
    parser.add_argument(
        "--failed",
        type=Path,
        help="只从指定的 Run 1.2 failed_zip.txt 清单中补下载失败产品",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="关闭 TLS 证书校验；仅在明确了解风险时使用",
    )
    args = parser.parse_args()

    if args.min_size_mb < 0:
        parser.error("--min-size-mb 不能小于 0")
    if args.retries < 1:
        parser.error("--retries 必须大于或等于 1")
    if args.retry_wait < 0:
        parser.error("--retry-wait 不能小于 0")
    return args


def acquire_lock() -> object:
    lock_handle = LOCK_FILE.open("w", encoding="utf-8")
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_handle.close()
        raise RuntimeError(
            "检测到另一个 Run 1.1 进程正在当前目录运行；请勿同时启动两个下载任务。"
        )
    lock_handle.write(f"pid={os.getpid()}\n")
    lock_handle.flush()
    return lock_handle


def check_environment() -> Path:
    if shutil.which("curl") is None:
        raise RuntimeError("系统中找不到 curl。")

    netrc_path = Path.home() / ".netrc"
    if not netrc_path.is_file():
        raise RuntimeError(
            "找不到 ~/.netrc。请写入 Earthdata 账号后执行 chmod 600 ~/.netrc。"
        )

    permission = netrc_path.stat().st_mode & 0o777
    if permission & 0o077:
        raise RuntimeError(
            f"~/.netrc 权限过宽（当前 {oct(permission)}）；请执行 chmod 600 ~/.netrc。"
        )
    return netrc_path


def find_download_scripts(pattern: str) -> list[Path]:
    myself = Path(__file__).resolve()
    scripts = []
    for name in sorted(glob.glob(pattern)):
        path = Path(name)
        if path.is_file() and path.resolve() != myself:
            scripts.append(path)
    return scripts


def extract_urls(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    candidates = re.findall(
        r"https?://[^\s'\"<>]+?\.zip(?:\?[^\s'\"<>]*)?",
        text,
        flags=re.IGNORECASE,
    )
    urls = []
    for candidate in candidates:
        url = candidate.rstrip(",);]}")
        hostname = (urlparse(url).hostname or "").lower()
        if hostname == "asf.alaska.edu" or hostname.endswith(".asf.alaska.edu"):
            urls.append(url)
    return urls


def product_filename(url: str) -> str:
    name = Path(unquote(urlparse(url).path)).name
    if not name.lower().endswith(".zip") or name in {"", ".zip"}:
        raise ValueError(f"无法从 URL 获得合法 ZIP 文件名：{url}")
    return name


def read_failed_zip_names(path: Path) -> set[str]:
    if not path.is_file():
        raise RuntimeError(f"找不到失败清单：{path}")

    names = set()
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8", errors="ignore").splitlines(),
        start=1,
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        name = Path(line.split("\t", 1)[0].strip()).name
        if not name.lower().endswith(".zip"):
            raise RuntimeError(
                f"{path}:{line_number} 不是 ZIP 文件名：{raw_line!r}"
            )
        names.add(name)
    return names


def zip_is_valid(path: Path, min_size_mb: int) -> bool:
    if not path.is_file():
        return False
    if path.stat().st_size < min_size_mb * 1024 * 1024:
        return False
    if not has_zip_signature(path):
        return False

    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if not any(
                name.upper().endswith(".SAFE/MANIFEST.SAFE") for name in names
            ):
                return False
    except (OSError, zipfile.BadZipFile, RuntimeError):
        return False

    return True


def has_zip_signature(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return stream.read(4) in {b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"}
    except OSError:
        return False


def prepare_partial(final_path: Path) -> Path:
    part_path = final_path.with_name(final_path.name + ".part")
    if final_path.exists():
        if part_path.exists():
            print(f"[WARNING] 删除无法使用的异常文件：{final_path}", flush=True)
            final_path.unlink()
        else:
            print(f"[INFO] 将未完成文件转为断点续传文件：{part_path}", flush=True)
            final_path.replace(part_path)

    if part_path.exists() and part_path.stat().st_size > 0 and not has_zip_signature(part_path):
        print(f"[WARNING] 断点文件不是 ZIP 数据，将从头下载：{part_path}", flush=True)
        part_path.unlink()
    return part_path


def curl_command(
    url: str,
    part_path: Path,
    cookie_path: Path,
    netrc_path: Path,
    insecure: bool,
) -> list[str]:
    command = [
        "curl",
        "--location",
        "--fail",
        "--show-error",
        "--netrc-file",
        str(netrc_path),
        "--cookie-jar",
        str(cookie_path),
        "--cookie",
        str(cookie_path),
        "--continue-at",
        "-",
        "--retry",
        "5",
        "--retry-delay",
        "10",
        "--retry-all-errors",
        "--connect-timeout",
        "30",
        "--speed-time",
        "120",
        "--speed-limit",
        "1024",
        "--output",
        str(part_path),
        url,
    ]
    if insecure:
        command.insert(1, "--insecure")
    return command


def download_one(
    url: str,
    outdir: Path,
    cookie_path: Path,
    netrc_path: Path,
    min_size_mb: int,
    retries: int,
    retry_wait: int,
    force_redownload: bool,
    insecure: bool,
) -> bool:
    filename = product_filename(url)
    final_path = outdir / filename

    if force_redownload:
        part_path = final_path.with_name(final_path.name + ".part")
        for old_path in (final_path, part_path):
            if old_path.exists():
                print(f"[REDOWNLOAD] 删除 Run 1.2 判定失败的文件：{old_path}", flush=True)
                old_path.unlink()

    if zip_is_valid(final_path, min_size_mb):
        size_mb = final_path.stat().st_size / 1024 / 1024
        print(f"[SKIP] 已有有效 ZIP：{final_path}（{size_mb:.1f} MB）", flush=True)
        return True

    part_path = prepare_partial(final_path)

    command = curl_command(url, part_path, cookie_path, netrc_path, insecure)
    for attempt in range(1, retries + 1):
        print(f"[TRY {attempt}/{retries}] {filename}", flush=True)
        result = subprocess.run(command, check=False)
        if result.returncode == 0:
            if zip_is_valid(part_path, min_size_mb):
                part_path.replace(final_path)
                size_mb = final_path.stat().st_size / 1024 / 1024
                print(f"[OK] 下载完成：{final_path}（{size_mb:.1f} MB）", flush=True)
                return True
            print("[ERROR] curl 已结束，但结果不是有效的 Sentinel-1 ZIP。", flush=True)
        else:
            print(
                f"[WARNING] curl 返回 {result.returncode}；保留 {part_path.name} 以便续传。",
                flush=True,
            )
            if result.returncode == 33 and part_path.exists():
                print("[WARNING] 服务器拒绝续传；删除断点文件后从头重试。", flush=True)
                part_path.unlink()

        if attempt < retries:
            time.sleep(retry_wait)

    print(f"[FAIL] 下载失败，已保留断点文件：{part_path}", flush=True)
    return False


def main() -> int:
    args = parse_args()
    try:
        lock_handle = acquire_lock()
        netrc_path = check_environment()
        args.outdir.mkdir(parents=True, exist_ok=True)
        scripts = find_download_scripts(args.pattern)
        if not scripts:
            raise RuntimeError(f"当前目录没有匹配 {args.pattern!r} 的 ASF 下载脚本。")

        print("[INFO] ASF 下载脚本：", flush=True)
        all_urls = []
        for script in scripts:
            urls = extract_urls(script)
            print(f"  - {script}: {len(urls)} 个 ZIP URL", flush=True)
            all_urls.extend(urls)

        all_target_urls = sorted(set(all_urls))
        if not all_target_urls:
            raise RuntimeError("没有从 ASF 下载脚本中提取到 ZIP URL。")

        filenames = [product_filename(url) for url in all_target_urls]
        if len(filenames) != len(set(filenames)):
            raise RuntimeError("不同 URL 对应相同文件名；为避免覆盖，下载已停止。")

        DEFAULT_URL_LIST.write_text(
            "\n".join(all_target_urls) + "\n",
            encoding="utf-8",
        )

        force_redownload = args.failed is not None
        if force_redownload:
            failed_names = read_failed_zip_names(args.failed)
            url_by_name = {
                product_filename(url): url
                for url in all_target_urls
            }
            unknown_names = sorted(failed_names - set(url_by_name))
            if unknown_names:
                preview = ", ".join(unknown_names[:10])
                raise RuntimeError(
                    f"失败清单中有 {len(unknown_names)} 个文件无法在 download*.py 中匹配："
                    f"{preview}"
                )
            urls = [url_by_name[name] for name in sorted(failed_names)]
            print(f"[INFO] 补下载清单：{args.failed.resolve()}", flush=True)
            print(f"[INFO] 需要补下载：{len(urls)}", flush=True)
            if not urls:
                print("[OK] failed_zip.txt 为空，无需补下载。", flush=True)
                return 0
        else:
            urls = all_target_urls

        cookie_path = DEFAULT_COOKIE_FILE.resolve()
        cookie_path.touch(mode=0o600, exist_ok=True)
        cookie_path.chmod(0o600)
        print(f"[INFO] URL 总数：{len(urls)}", flush=True)
        print(f"[INFO] 输出目录：{args.outdir.resolve()}", flush=True)

        success_count = 0
        failed_urls = []
        for index, url in enumerate(urls, start=1):
            print(f"\n{'=' * 72}\n[{index}/{len(urls)}] {product_filename(url)}", flush=True)
            if download_one(
                url=url,
                outdir=args.outdir,
                cookie_path=cookie_path,
                netrc_path=netrc_path,
                min_size_mb=args.min_size_mb,
                retries=args.retries,
                retry_wait=args.retry_wait,
                force_redownload=force_redownload,
                insecure=args.insecure,
            ):
                success_count += 1
            else:
                failed_urls.append(url)

        print("\n" + "=" * 72, flush=True)
        print(f"[SUMMARY] 成功或跳过：{success_count}/{len(urls)}", flush=True)
        if failed_urls:
            print(f"[ERROR] 失败：{len(failed_urls)}；重新运行脚本即可续传。", flush=True)
            return 1
        print("[OK] 所有 Sentinel-1 ZIP 均已准备完成。", flush=True)
        return 0
    except KeyboardInterrupt:
        print("\n[INTERRUPTED] 用户中断；.part 文件已保留，可重新运行续传。", flush=True)
        return 130
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr, flush=True)
        return 1
    finally:
        if "lock_handle" in locals():
            lock_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
