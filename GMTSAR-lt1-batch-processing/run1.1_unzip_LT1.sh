#!/usr/bin/env bash
# LT-1 SLC tar.gz batch extractor for GMTSAR data preparation.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: September 6, 2026

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

MARKER_NAME=".run1.1_unzip_LT1_complete"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：
  ./run1.1_unzip_LT1.sh [1] [--jobs N]

运行模式：
  无参数             只读预览，不解压、不修改任何数据
  1                  正式解压 data/zip/*.tar.gz 到 data/ 目录

选项：
  --jobs N           并行解压任务数（默认：5）
  -h, --help         显示帮助

要求的目录结构：
  Ascending/                         # 或 Descending/
  ├── run1.1_unzip_LT1.sh       # 在这个目录中运行脚本
  └── data/
      ├── zip/                   # 把所有 LT1*.tar.gz 放在这里
      │   ├── LT1A_...tar.gz
      │   └── LT1B_...tar.gz
      ├── orbit/                 # 把精密轨道 txt 文件放在这里
      │   ├── LT1A_GpsData_...txt
      │   └── LT1B_SAR_....scie.gps.txt
      └── LT1A_MONO_.../         # 脚本生成：一个压缩包一个同名目录

本脚本只读取 data/zip/ 并在 data/ 下生成产品目录。
本脚本不会移动、修改或删除 data/zip/ 和 data/orbit/ 中的文件。

推荐在服务器上执行：
  cd /data2/xinw/Huangshan_landsides/LT1/Ascending
  ./run1.1_unzip_LT1.sh
  ./run1.1_unzip_LT1.sh 1

降轨目录使用方法相同。
EOF
}

file_size() {
    local size
    if size="$(stat -c '%s' "$1" 2>/dev/null)"; then
        :
    else
        size="$(stat -f '%z' "$1" 2>/dev/null)" || return 1
    fi
    [[ "${size}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${size}"
}

product_name_from_archive() {
    local name
    name="$(basename -- "$1")"
    [[ "${name}" == *.tar.gz ]] || return 1
    printf '%s\n' "${name%.tar.gz}"
}

product_is_valid() {
    local product_dir="$1" product_name="$2"
    [[ -d "${product_dir}" ]] || return 1
    [[ -s "${product_dir}/${product_name}.meta.xml" ]] || return 1
    [[ -s "${product_dir}/${product_name}.tiff" ]] || return 1
}

archive_paths_are_safe() {
    local archive="$1"
    # 拒绝绝对路径和 .. 路径分量，防止文件被解压到目标目录之外。
    tar -tzf "${archive}" | awk '
        BEGIN { bad = 0; count = 0 }
        {
            count++
            path = $0
            sub(/^\.\//, "", path)
            if (path ~ /^\// || path == ".." || path ~ /(^|\/)\.\.($|\/)/) {
                print "unsafe archive member: " $0 > "/dev/stderr"
                bad = 1
            }
        }
        END { exit (bad || count == 0) ? 1 : 0 }
    '
}

archive_layout() {
    local archive="$1" product_name="$2"
    tar -tzf "${archive}" | awk -v product="${product_name}" '
        BEGIN { wrapped = 0; flat = 0 }
        {
            path = $0
            sub(/^\.\//, "", path)
            if (path == product || index(path, product "/") == 1) {
                wrapped++
            } else {
                flat++
            }
        }
        END {
            if (wrapped > 0 && flat == 0) {
                print "wrapped"
                exit 0
            }
            if (flat > 0 && wrapped == 0) {
                print "flat"
                exit 0
            }
            exit 1
        }
    '
}

write_marker() {
    local product_dir="$1" archive="$2" marker_tmp
    marker_tmp="${product_dir}/${MARKER_NAME}.tmp.$$"
    {
        printf 'source_archive=%s\n' "$(basename -- "${archive}")"
        printf 'source_size=%s\n' "$(file_size "${archive}")"
        printf 'completed_at=%s\n' "$(date '+%F %T %z')"
    } > "${marker_tmp}"
    mv -f -- "${marker_tmp}" "${product_dir}/${MARKER_NAME}"
}

run_worker() {
    local output_dir="$1" temp_root="$2" archive="$3"
    local product_name final_dir job_tmp extracted_dir extract_target layout

    product_name="$(product_name_from_archive "${archive}")" || {
        printf '[FAILED] 不是 .tar.gz 文件：%s\n' "${archive}" >&2
        return 1
    }
    final_dir="${output_dir}/${product_name}"

    if product_is_valid "${final_dir}" "${product_name}"; then
        printf '[SKIP] 已完整解压：%s\n' "${product_name}"
        return 0
    fi

    if [[ -e "${final_dir}" ]]; then
        printf '[FAILED] 目标已存在但不完整，请人工检查：%s\n' "${final_dir}" >&2
        return 1
    fi

    printf '[CHECK] %s\n' "${archive}"
    if ! gzip -t -- "${archive}"; then
        printf '[FAILED] gzip 完整性检查失败：%s\n' "${archive}" >&2
        return 1
    fi
    if ! archive_paths_are_safe "${archive}"; then
        printf '[FAILED] 压缩包为空、目录不安全或无法读取：%s\n' "${archive}" >&2
        return 1
    fi
    if ! layout="$(archive_layout "${archive}" "${product_name}")"; then
        printf '[FAILED] 压缩包同时包含带顶层目录和平铺内容，无法安全判定结构：%s\n' \
            "${archive}" >&2
        return 1
    fi

    job_tmp="${temp_root}/${product_name}.$$"
    rm -rf -- "${job_tmp}"
    mkdir -p -- "${job_tmp}"

    extracted_dir="${job_tmp}/${product_name}"
    if [[ "${layout}" == "flat" ]]; then
        # LT-1 原始包通常是平铺结构；先建立产品目录，避免文件散落到 data/ 中。
        mkdir -p -- "${extracted_dir}"
        extract_target="${extracted_dir}"
    else
        extract_target="${job_tmp}"
    fi

    printf '[START] %s  layout=%s\n' "${archive}" "${layout}"
    if ! tar -xzf "${archive}" -C "${extract_target}"; then
        printf '[FAILED] 解压失败：%s\n' "${archive}" >&2
        rm -rf -- "${job_tmp}"
        return 1
    fi

    if ! product_is_valid "${extracted_dir}" "${product_name}"; then
        printf '[FAILED] 解压结果缺少 .meta.xml 或 .tiff：%s\n' "${archive}" >&2
        rm -rf -- "${job_tmp}"
        return 1
    fi

    write_marker "${extracted_dir}" "${archive}"
    # 临时目录与目标在同一文件系统，mv 可原子地提交完整产品。
    mv -- "${extracted_dir}" "${final_dir}"
    rmdir -- "${job_tmp}" 2>/dev/null || true
    printf '[DONE] %s\n' "${product_name}"
}

if [[ "${1:-}" == "--worker" ]]; then
    [[ "$#" -eq 4 ]] || die "invalid internal worker arguments"
    run_worker "$2" "$3" "$4"
    exit $?
fi

MODE="PREVIEW"
if [[ "${1:-}" == "1" ]]; then
    MODE="FORMAL"
    shift
elif [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    die "模式只能是 1，或不加模式参数进行预览"
fi

JOBS=5
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --jobs)
            [[ "$#" -ge 2 ]] || die "--jobs 需要一个整数"
            JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知参数：$1"
            ;;
    esac
done

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "--jobs 必须是正整数"

for command_name in find sort tar gzip awk stat tee wc; do
    command -v "${command_name}" >/dev/null 2>&1 || die "找不到命令：${command_name}"
done

WORK_DIR="$(pwd -P)"
DATA_DIR="${WORK_DIR}/data"
ZIP_DIR="${DATA_DIR}/zip"
ORBIT_DIR="${DATA_DIR}/orbit"
OUTPUT_DIR="${DATA_DIR}"
TEMP_ROOT="${DATA_DIR}/.run1.1_unzip_LT1_tmp"
LOG_FILE="${WORK_DIR}/run1.1_unzip_LT1.log"
JOB_LOG="${WORK_DIR}/run1.1_unzip_LT1_parallel_joblog.txt"
FAILED_FILE="${WORK_DIR}/failed_tar_gz.txt"
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

printf '%s\n' '============================================================'
printf 'LT-1 Run 1.1 数据放置说明\n'
printf '当前轨道方向目录：%s\n' "${WORK_DIR}"
printf '当前 data 目录：%s\n' "${DATA_DIR}"
printf '① SLC 压缩包放到：%s/\n' "${ZIP_DIR}"
printf '   文件类型：LT1*.tar.gz\n'
printf '② 精密轨道文件放到：%s/\n' "${ORBIT_DIR}"
printf '   文件类型：LT1*_GpsData_*.txt 或 LT1*_SAR_*.scie.gps.txt\n'
printf '③ 解压产品将生成在：%s/LT1A_MONO_.../\n' "${OUTPUT_DIR}"
printf '④ zip/ 和 orbit/ 中的原文件会保留不变\n'
printf '%s\n' '============================================================'

if [[ ! -d "${ZIP_DIR}" ]]; then
    printf '[ERROR] 找不到压缩包目录：%s/\n' "${ZIP_DIR}" >&2
    printf '[HINT]  请先执行 mkdir -p data/zip data/orbit，再将数据放入对应目录。\n' >&2
    exit 1
fi

if [[ -d "${ORBIT_DIR}" ]]; then
    ORBIT_COUNT="$(find "${ORBIT_DIR}" -maxdepth 1 -type f -name 'LT1*.txt' | wc -l | awk '{print $1}')"
    printf '[INFO] orbit/ 中发现 %s 个 LT-1 精密轨道文件。\n' "${ORBIT_COUNT}"
else
    printf '[WARNING] 找不到 orbit/；这不影响解压，但后续处理前需将精密轨道文件放入该目录。\n' >&2
fi

mapfile -d '' ARCHIVES < <(
    find "${ZIP_DIR}" -maxdepth 1 -type f -name 'LT1*.tar.gz' -print0 | sort -z
)
TOTAL=${#ARCHIVES[@]}
(( TOTAL > 0 )) || die "zip/ 中没有 LT1*.tar.gz"

VALID=0
PENDING=0
INCOMPLETE=0

printf '\n%s\n' '============================================================'
printf 'LT-1 tar.gz 批量解压  模式：%s\n' "${MODE}"
printf '工作目录：%s\n' "${WORK_DIR}"
printf '压缩包目录：%s\n' "${ZIP_DIR}"
printf '压缩包数量：%s\n' "${TOTAL}"
printf '%s\n' '============================================================'

for archive in "${ARCHIVES[@]}"; do
    product_name="$(product_name_from_archive "${archive}")"
    product_dir="${OUTPUT_DIR}/${product_name}"
    if product_is_valid "${product_dir}" "${product_name}"; then
        printf '[READY]   %s/\n' "${product_dir}"
        VALID=$((VALID + 1))
    elif [[ -e "${product_dir}" ]]; then
        printf '[BROKEN]  %s/  目标已存在但缺少 meta.xml/tiff\n' "${product_dir}"
        INCOMPLETE=$((INCOMPLETE + 1))
    else
        printf '[PENDING] %s\n' "$(basename -- "${archive}")"
        printf '          → %s/\n' "${product_dir}"
        PENDING=$((PENDING + 1))
    fi
done

printf '%s\n' '------------------------------------------------------------'
printf '已完成：%s  待解压：%s  异常目录：%s  总数：%s\n' \
    "${VALID}" "${PENDING}" "${INCOMPLETE}" "${TOTAL}"

if [[ "${MODE}" == "PREVIEW" ]]; then
    (( INCOMPLETE == 0 )) || printf '[WARNING] 请先人工检查 [BROKEN] 目录。\n' >&2
    printf '\n预览完成，未修改任何数据。\n'
    if (( PENDING > 0 )); then
        printf '确认无误后执行：%s 1 --jobs %s\n' "${SCRIPT_PATH}" "${JOBS}"
    fi
    exit 0
fi

(( INCOMPLETE == 0 )) || die "存在 ${INCOMPLETE} 个不完整的目标目录，未开始解压"

if (( PENDING == 0 )); then
    printf '所有产品均已完整解压，无需执行。\n'
    : > "${FAILED_FILE}"
    exit 0
fi

command -v parallel >/dev/null 2>&1 || die "正式并行模式需要 GNU Parallel"
mkdir -p -- "${TEMP_ROOT}"
: > "${FAILED_FILE}"

PENDING_LIST="${TEMP_ROOT}/pending_archives.$$.txt"
: > "${PENDING_LIST}"
for archive in "${ARCHIVES[@]}"; do
    product_name="$(product_name_from_archive "${archive}")"
    if [[ ! -e "${OUTPUT_DIR}/${product_name}" ]]; then
        printf '%s\n' "${archive}" >> "${PENDING_LIST}"
    fi
done

printf '\n[INFO] 开始并行解压，任务数：%s\n' "${JOBS}"
set +e
parallel \
    --jobs "${JOBS}" \
    --line-buffer \
    --joblog "${JOB_LOG}" \
    --results "${TEMP_ROOT}/parallel_results" \
    "${SCRIPT_PATH}" --worker "${OUTPUT_DIR}" "${TEMP_ROOT}" {} \
    :::: "${PENDING_LIST}" 2>&1 | tee "${LOG_FILE}"
parallel_status=${PIPESTATUS[0]}
set -e

rm -f -- "${PENDING_LIST}"

# 以实际产品完整性为最终判据，同时生成可直接检查的失败清单。
FINAL_VALID=0
for archive in "${ARCHIVES[@]}"; do
    product_name="$(product_name_from_archive "${archive}")"
    if product_is_valid "${OUTPUT_DIR}/${product_name}" "${product_name}"; then
        FINAL_VALID=$((FINAL_VALID + 1))
    else
        printf '%s\n' "$(basename -- "${archive}")" >> "${FAILED_FILE}"
    fi
done

FAILED_COUNT=$((TOTAL - FINAL_VALID))
printf '\n%s\n' '============================================================'
printf '解压后完整产品：%s/%s\n' "${FINAL_VALID}" "${TOTAL}"
printf '失败数量：%s\n' "${FAILED_COUNT}"
printf '运行日志：%s\n' "${LOG_FILE}"
printf '任务日志：%s\n' "${JOB_LOG}"
printf '失败清单：%s\n' "${FAILED_FILE}"
printf '%s\n' '============================================================'

if (( FAILED_COUNT > 0 )) || (( parallel_status != 0 )); then
    die "存在解压失败产品，请检查 failed_tar_gz.txt 和日志"
fi

printf '[SUCCESS] 全部 LT-1 产品解压完成；zip/ 和 orbit/ 未被删除或移动。\n'
