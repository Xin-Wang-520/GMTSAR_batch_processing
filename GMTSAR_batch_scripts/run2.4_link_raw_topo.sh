#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 21, 2026

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./run2.4_link_raw_topo.sh [--frame F2399_F2449] [--polarization vv]

Run this script from a T-number processing directory, for example:
  /data2/xinw/InSAR_processing/Descending/T34

The script creates:
  F1/raw  -> IW1 XML/TIFF, all organized/*.EOF, topo/dem.grd
  F2/raw  -> IW2 XML/TIFF, all organized/*.EOF, topo/dem.grd
  F3/raw  -> IW3 XML/TIFF, all organized/*.EOF, topo/dem.grd
  F1/topo, F2/topo, F3/topo -> topo/dem.grd

Options:
  --frame NAME          Select organized/NAME when multiple frames exist.
  --polarization POL    vv, vh, hh, or hv (default: vv).
  -h, --help            Show this help.
EOF
}

FRAME_NAME=""
POLARIZATION="vv"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --frame)
            [[ "$#" -ge 2 ]] || die "--frame requires Fxxxx_Fxxxx"
            FRAME_NAME="$2"
            shift 2
            ;;
        --polarization)
            [[ "$#" -ge 2 ]] || die "--polarization requires a value"
            POLARIZATION="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

case "${POLARIZATION}" in
    vv|vh|hh|hv) ;;
    *) die "polarization must be vv, vh, hh, or hv" ;;
esac

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number directory (current: ${ROOT_DIR})"

ORGANIZED_DIR="${ROOT_DIR}/organized"
DEM_SOURCE="${ROOT_DIR}/topo/dem.grd"

[[ -d "${ORGANIZED_DIR}" ]] || die "organized directory not found: ${ORGANIZED_DIR}"
[[ -s "${DEM_SOURCE}" ]] || die "DEM not found or empty: ${DEM_SOURCE}; complete Run 2.3 first"

if [[ -n "${FRAME_NAME}" ]]; then
    [[ "${FRAME_NAME}" =~ ^F[0-9]{4}_F[0-9]{4}$ ]] ||
        die "--frame must look like F2399_F2449"
    FRAME_SOURCE="${ORGANIZED_DIR}/${FRAME_NAME}"
    [[ -d "${FRAME_SOURCE}" ]] || die "frame directory not found: ${FRAME_SOURCE}"
else
    FRAME_DIRS=()
    while IFS= read -r -d '' path; do
        [[ "$(basename -- "${path}")" =~ ^F[0-9]{4}_F[0-9]{4}$ ]] || continue
        FRAME_DIRS+=("${path}")
    done < <(find "${ORGANIZED_DIR}" -mindepth 1 -maxdepth 1 -type d -print0)

    if (( ${#FRAME_DIRS[@]} == 0 )); then
        die "no F????_F???? directory found in ${ORGANIZED_DIR}"
    elif (( ${#FRAME_DIRS[@]} > 1 )); then
        printf '[ERROR] multiple frame directories found; use --frame:\n' >&2
        printf '  %s\n' "${FRAME_DIRS[@]##*/}" >&2
        exit 1
    fi
    FRAME_SOURCE="${FRAME_DIRS[0]}"
    FRAME_NAME="$(basename -- "${FRAME_SOURCE}")"
fi

SAFE_DIRS=()
while IFS= read -r -d '' path; do
    SAFE_DIRS+=("${path}")
done < <(find "${FRAME_SOURCE}" -mindepth 1 -maxdepth 1 -type d -name '*.SAFE' -print0)
SAFE_COUNT="${#SAFE_DIRS[@]}"
(( SAFE_COUNT > 0 )) || die "no .SAFE directories found in ${FRAME_SOURCE}"

EOF_FILES=()
while IFS= read -r -d '' path; do
    EOF_FILES+=("${path}")
done < <(find "${ORGANIZED_DIR}" -mindepth 1 -maxdepth 1 -type f -iname '*.EOF' -print0)
EOF_COUNT="${#EOF_FILES[@]}"
(( EOF_COUNT > 0 )) || die "no orbit EOF files found in ${ORGANIZED_DIR}"

relative_from_product_dir() {
    local source="$1"
    [[ "${source}" == "${ROOT_DIR}/"* ]] || die "source is outside the track root: ${source}"
    printf '../../%s\n' "${source#"${ROOT_DIR}/"}"
}

link_file_safely() {
    local source="$1"
    local destination_dir="$2"
    local destination="${destination_dir}/$(basename -- "${source}")"
    local target

    if [[ -e "${destination}" && ! -L "${destination}" ]]; then
        die "refusing to replace a regular file: ${destination}"
    fi
    target="$(relative_from_product_dir "${source}")"
    ln -sfn -- "${target}" "${destination}"
}

verify_directory_links() {
    local directory="$1"
    local link broken=0
    shopt -s nullglob
    for link in "${directory}"/*; do
        [[ -L "${link}" ]] || continue
        if [[ ! -e "${link}" ]]; then
            printf '[BROKEN] %s -> %s\n' "${link}" "$(readlink -- "${link}")" >&2
            broken=$((broken + 1))
        fi
    done
    shopt -u nullglob
    (( broken == 0 )) || die "${broken} broken links found in ${directory}"
}

link_one_subswath() {
    local product_dir="$1"
    local iw_number="$2"
    local iw="iw${iw_number}"
    local iw_label="IW${iw_number}"
    local polarization_label
    local raw_dir="${ROOT_DIR}/${product_dir}/raw"
    local topo_dir="${ROOT_DIR}/${product_dir}/topo"
    local source
    local -a xml_files=()
    local -a tiff_files=()

    polarization_label="$(printf '%s' "${POLARIZATION}" | tr '[:lower:]' '[:upper:]')"

    while IFS= read -r -d '' source; do
        xml_files+=("${source}")
    done < <(find "${FRAME_SOURCE}" -mindepth 3 -maxdepth 3 -type f \
        -path '*/annotation/*' -iname "*${iw}*${POLARIZATION}*.xml" -print0)

    while IFS= read -r -d '' source; do
        tiff_files+=("${source}")
    done < <(find "${FRAME_SOURCE}" -mindepth 3 -maxdepth 3 -type f \
        -path '*/measurement/*' -iname "*${iw}*${POLARIZATION}*.tiff" -print0)

    [[ "${#xml_files[@]}" -eq "${SAFE_COUNT}" ]] ||
        die "${FRAME_NAME} ${iw_label} XML count=${#xml_files[@]}, expected=${SAFE_COUNT}"
    [[ "${#tiff_files[@]}" -eq "${SAFE_COUNT}" ]] ||
        die "${FRAME_NAME} ${iw_label} TIFF count=${#tiff_files[@]}, expected=${SAFE_COUNT}"

    printf '\n========== %s: %s %s ==========\n' \
        "${product_dir}" "${iw_label}" "${polarization_label}"
    mkdir -p -- "${raw_dir}" "${topo_dir}"

    link_file_safely "${DEM_SOURCE}" "${topo_dir}"
    link_file_safely "${DEM_SOURCE}" "${raw_dir}"

    for source in "${xml_files[@]}" "${tiff_files[@]}"; do
        link_file_safely "${source}" "${raw_dir}"
    done
    for source in "${EOF_FILES[@]}"; do
        link_file_safely "${source}" "${raw_dir}"
    done

    verify_directory_links "${raw_dir}"
    verify_directory_links "${topo_dir}"

    printf '[DONE] %-2s raw XML/TIFF : %d + %d\n' \
        "${product_dir}" "${#xml_files[@]}" "${#tiff_files[@]}"
    printf '[DONE] %-2s raw EOF      : %d\n' "${product_dir}" "${EOF_COUNT}"
    printf '[DONE] %-2s DEM links    : raw/dem.grd and topo/dem.grd\n' "${product_dir}"
}

printf '%s\n' '========================================'
printf 'Run 2.4: link raw TOPS inputs and DEM\n'
printf 'Track root     : %s\n' "${ROOT_DIR}"
printf 'Track          : %s\n' "${TRACK}"
printf 'Source frame   : %s\n' "${FRAME_SOURCE}"
printf 'SAFE total     : %d\n' "${SAFE_COUNT}"
printf 'Orbit EOF total: %d\n' "${EOF_COUNT}"
printf 'Polarization   : %s\n' "${POLARIZATION}"
printf '%s\n' '========================================'

link_one_subswath "F1" 1
link_one_subswath "F2" 2
link_one_subswath "F3" 3

printf '\n%s\n' '========================================'
printf '[DONE] Run 2.4 completed successfully.\n'
printf '%s\n' '========================================'
