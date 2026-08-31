#!/usr/bin/env bash
# Run 2.1: validate downloaded Sentinel-1 burst SAFEs, create SAFE_filelist,
# and download precise/restituted orbit files.
#
# Intended server layout:
#   /data2/xinw/Huangshan_landsides/S1/T142A/
#   └── data_burst/*.SAFE

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
  ./run2.1_prepare_SAFE_orbits.sh [options]       # preflight only
  ./run2.1_prepare_SAFE_orbits.sh 1 [options]     # write lists and download orbits

Run from the T142A processing directory containing data_burst/.

Default input/output:
  Burst SAFEs : data_burst/*.SAFE
  SAFE list   : data_burst/SAFE_filelist
  Inventory   : data_burst/burst_SAFE_inventory.tsv
  Orbit files : data_burst/*.EOF
  Orbit log   : data_burst/run2.1_orbit_download.log

Options:
  --data-dir DIR       SAFE and orbit directory (default: data_burst)
  --swath AUTO|IW1|IW2|IW3
                       Auto-detect one common subswath (default: AUTO), or
                       require the specified subswath
  --polarization POL   vv, vh, hh or hv (default: vv)
  --orbit-mode 1|2     1=POEORB precise (default), 2=RESORB restituted
  --downloader FILE    Orbit downloader path/command
                       (default: download_sentinel_orbits_linux_new.csh)
  -h, --help           Show this help

Examples:
  ./run2.1_prepare_SAFE_orbits.sh
  ./run2.1_prepare_SAFE_orbits.sh 1
  ./run2.1_prepare_SAFE_orbits.sh 1 --orbit-mode 2
EOF
}

FORMAL=0
DATA_DIR="data_burst"
SWATH="AUTO"
POLARIZATION="vv"
ORBIT_MODE=1
DOWNLOADER="download_sentinel_orbits_linux_new.csh"

while (( $# > 0 )); do
    case "$1" in
        1)
            (( FORMAL == 0 )) || die "formal mode was specified more than once"
            FORMAL=1
            shift
            ;;
        --data-dir)
            [[ $# -ge 2 ]] || die "--data-dir requires a directory"
            DATA_DIR="$2"
            shift 2
            ;;
        --swath)
            [[ $# -ge 2 ]] || die "--swath requires AUTO, IW1, IW2 or IW3"
            SWATH="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
            shift 2
            ;;
        --polarization)
            [[ $# -ge 2 ]] || die "--polarization requires vv, vh, hh or hv"
            POLARIZATION="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        --orbit-mode)
            [[ $# -ge 2 ]] || die "--orbit-mode requires 1 or 2"
            ORBIT_MODE="$2"
            shift 2
            ;;
        --downloader)
            [[ $# -ge 2 ]] || die "--downloader requires a file or command"
            DOWNLOADER="$2"
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

[[ "$SWATH" =~ ^(AUTO|IW[123])$ ]] || die "--swath must be AUTO, IW1, IW2 or IW3"
case "$POLARIZATION" in vv|vh|hh|hv) ;; *) die "invalid polarization: $POLARIZATION" ;; esac
[[ "$ORBIT_MODE" == 1 || "$ORBIT_MODE" == 2 ]] || die "--orbit-mode must be 1 or 2"

for command_name in awk cut date find grep head mktemp sort tee tr uniq wc; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT)"

if [[ "$DATA_DIR" = /* ]]; then
    DATA_ABS="$DATA_DIR"
else
    DATA_ABS="$ROOT/$DATA_DIR"
fi
[[ -d "$DATA_ABS" ]] || die "burst data directory not found: $DATA_ABS"
DATA_ABS="$(cd -- "$DATA_ABS" && pwd -P)"

if [[ -x "$DOWNLOADER" ]]; then
    DOWNLOADER_PATH="$(cd -- "$(dirname -- "$DOWNLOADER")" && pwd -P)/$(basename -- "$DOWNLOADER")"
elif DOWNLOADER_PATH="$(command -v "$DOWNLOADER" 2>/dev/null)"; then
    :
else
    die "orbit downloader not found or not executable: $DOWNLOADER"
fi

SAFE_LIST="$DATA_ABS/SAFE_filelist"
INVENTORY="$DATA_ABS/burst_SAFE_inventory.tsv"
ORBIT_LOG="$DATA_ABS/run2.1_orbit_download.log"
SUMMARY_LOG="$ROOT/run2.1_prepare_SAFE_orbits.log"
POL_LABEL="$(printf '%s' "$POLARIZATION" | tr '[:lower:]' '[:upper:]')"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run2.1-burst.XXXXXX")"
LOCK_DIR=""
cleanup() {
    rm -rf -- "$TMP"
    [[ -z "$LOCK_DIR" ]] || rmdir -- "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

RAW_LIST="$TMP/SAFE_filelist"
RAW_INVENTORY="$TMP/burst_SAFE_inventory.tsv"
ERRORS="$TMP/input_errors.tsv"
: > "$RAW_LIST"
: > "$RAW_INVENTORY"
: > "$ERRORS"

while IFS= read -r -d '' safe; do
    safe_name="$(basename -- "$safe")"
    satellite=""
    safe_date=""

    if [[ "$safe_name" =~ ^(S1[ABC])_IW_SLC__1SSV_([0-9]{8})T([0-9]{6})_.*[.]SAFE$ ]]; then
        satellite="${BASH_REMATCH[1]}"
        safe_date="${BASH_REMATCH[2]}"
    else
        printf 'SAFE_NAME\t%s\n' "$safe" >> "$ERRORS"
        continue
    fi

    [[ -s "$safe/manifest.safe" ]] || {
        printf 'MANIFEST_MISSING\t%s\n' "$safe" >> "$ERRORS"
        continue
    }

    xml_files=()
    tiff_files=()
    while IFS= read -r -d '' path; do xml_files+=("$path"); done < <(
        find "$safe/annotation" -mindepth 1 -maxdepth 1 -type f \
            -iname "*-iw[123]-slc-${POLARIZATION}-*.xml" -print0 2>/dev/null
    )
    while IFS= read -r -d '' path; do tiff_files+=("$path"); done < <(
        find "$safe/measurement" -mindepth 1 -maxdepth 1 -type f \
            \( -iname "*-iw[123]-slc-${POLARIZATION}-*.tiff" \
               -o -iname "*-iw[123]-slc-${POLARIZATION}-*.tif" \) -print0 2>/dev/null
    )

    if (( ${#xml_files[@]} != 1 || ${#tiff_files[@]} != 1 )); then
        printf 'XML_TIFF_COUNT\t%s\tXML=%s\tTIFF=%s\n' \
            "$safe" "${#xml_files[@]}" "${#tiff_files[@]}" >> "$ERRORS"
        continue
    fi
    [[ -s "${xml_files[0]}" && -s "${tiff_files[0]}" ]] || {
        printf 'XML_TIFF_EMPTY\t%s\n' "$safe" >> "$ERRORS"
        continue
    }

    xml_name="$(basename -- "${xml_files[0]}")"
    tiff_name="$(basename -- "${tiff_files[0]}")"
    xml_satellite="$(printf '%s' "$xml_name" | cut -d- -f1 | tr '[:lower:]' '[:upper:]')"
    tiff_satellite="$(printf '%s' "$tiff_name" | cut -d- -f1 | tr '[:lower:]' '[:upper:]')"
    xml_date=""
    xml_swath=""
    if [[ "$xml_name" =~ -iw([123])-slc-${POLARIZATION}-([0-9]{8})t[0-9]{6}- ]]; then
        xml_swath="IW${BASH_REMATCH[1]}"
        xml_date="${BASH_REMATCH[2]}"
    fi
    tiff_date=""
    tiff_swath=""
    if [[ "$tiff_name" =~ -iw([123])-slc-${POLARIZATION}-([0-9]{8})t[0-9]{6}- ]]; then
        tiff_swath="IW${BASH_REMATCH[1]}"
        tiff_date="${BASH_REMATCH[2]}"
    fi
    if [[ "$xml_satellite" != "$satellite" || "$tiff_satellite" != "$satellite" ||
          "$xml_date" != "$safe_date" || "$tiff_date" != "$safe_date" ||
          -z "$xml_swath" || "$xml_swath" != "$tiff_swath" ]]; then
        printf 'SAFE_XML_TIFF_MISMATCH\t%s\t%s\t%s\n' \
            "$safe_name" "$xml_name" "$tiff_name" >> "$ERRORS"
        continue
    fi

    printf '%s\n' "$safe" >> "$RAW_LIST"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$safe_date" "$satellite" "$xml_swath" "$POL_LABEL" \
        "$safe" "${xml_files[0]}" >> "$RAW_INVENTORY"
done < <(find "$DATA_ABS" -mindepth 1 -maxdepth 1 -type d -name '*.SAFE' -print0)

sort -o "$RAW_LIST" "$RAW_LIST"
sort -o "$RAW_INVENTORY" "$RAW_INVENTORY"

if [[ -s "$ERRORS" ]]; then
    printf '[INPUT ERRORS]\n' >&2
    cat "$ERRORS" >&2
    die "burst SAFE validation failed"
fi

SAFE_TOTAL="$(wc -l < "$RAW_LIST" | awk '{print $1}')"
(( SAFE_TOTAL >= 2 )) || die "at least two valid burst SAFEs are required"
DUPLICATE_DATE="$(cut -f1 "$RAW_INVENTORY" | uniq -d | head -n 1)"
[[ -z "$DUPLICATE_DATE" ]] || die "duplicate acquisition date: $DUPLICATE_DATE"
UNIQUE_SWATHS="$(cut -f3 "$RAW_INVENTORY" | sort -u)"
SWATH_COUNT="$(printf '%s\n' "$UNIQUE_SWATHS" | awk 'NF{n++} END{print n+0}')"
(( SWATH_COUNT == 1 )) || die "burst directory mixes different subswaths: $(printf '%s' "$UNIQUE_SWATHS" | tr '\n' ' ')"
DETECTED_SWATH="$(printf '%s\n' "$UNIQUE_SWATHS" | head -n 1)"
if [[ "$SWATH" != AUTO && "$SWATH" != "$DETECTED_SWATH" ]]; then
    die "detected $DETECTED_SWATH, but --swath requires $SWATH"
fi

S1A_COUNT="$(awk -F'\t' '$2=="S1A"{n++} END{print n+0}' "$RAW_INVENTORY")"
S1B_COUNT="$(awk -F'\t' '$2=="S1B"{n++} END{print n+0}' "$RAW_INVENTORY")"
S1C_COUNT="$(awk -F'\t' '$2=="S1C"{n++} END{print n+0}' "$RAW_INVENTORY")"
FIRST_DATE="$(head -n 1 "$RAW_INVENTORY" | cut -f1)"
LAST_DATE="$(tail -n 1 "$RAW_INVENTORY" | cut -f1)"
EXISTING_EOF="$(find "$DATA_ABS" -mindepth 1 -maxdepth 1 -type f -iname '*.EOF' | wc -l | awk '{print $1}')"

printf '%s\n' '========================================'
printf 'Run 2.1: burst SAFE list and Sentinel-1 orbits\n'
printf 'Mode           : %s\n' "$([[ $FORMAL -eq 1 ]] && printf FORMAL || printf 'PREFLIGHT ONLY')"
printf 'Track root     : %s\n' "$ROOT"
printf 'Track          : %s\n' "$TRACK"
printf 'Burst data     : %s\n' "$DATA_ABS"
printf 'Detected input : %s %s\n' "$DETECTED_SWATH" "$POL_LABEL"
printf 'Swath check    : %s\n' "$SWATH"
printf 'Valid SAFEs    : %s\n' "$SAFE_TOTAL"
printf 'Satellites     : S1A=%s, S1B=%s, S1C=%s\n' "$S1A_COUNT" "$S1B_COUNT" "$S1C_COUNT"
printf 'Date range     : %s -> %s\n' "$FIRST_DATE" "$LAST_DATE"
printf 'Existing EOF   : %s\n' "$EXISTING_EOF"
printf 'SAFE list      : %s\n' "$SAFE_LIST"
printf 'Orbit mode     : %s (%s)\n' "$ORBIT_MODE" "$([[ $ORBIT_MODE == 1 ]] && printf POEORB || printf RESORB)"
printf 'Downloader     : %s\n' "$DOWNLOADER_PATH"
printf '%s\n' '========================================'

if (( FORMAL == 0 )); then
    printf '[CHECK OK] All burst SAFEs passed the input checks.\n'
    printf '[CHECK ONLY] No SAFE list, inventory, log or orbit was modified.\n'
    printf '[NEXT] ./run2.1_prepare_SAFE_orbits.sh 1\n'
    exit 0
fi

if command -v flock >/dev/null 2>&1; then
    exec 9> "$ROOT/.run2.1_burst_orbits.lock"
    flock -n 9 || die "another Run 2.1 process is running"
else
    LOCK_DIR="$ROOT/.run2.1_burst_orbits.lock.d"
    mkdir "$LOCK_DIR" 2>/dev/null || die "another Run 2.1 process may be running"
fi

cp "$RAW_LIST" "$SAFE_LIST.tmp.$$"
mv -f "$SAFE_LIST.tmp.$$" "$SAFE_LIST"
{
    printf 'date\tsatellite\tswath\tpolarization\tsafe\txml\n'
    cat "$RAW_INVENTORY"
} > "$INVENTORY.tmp.$$"
mv -f "$INVENTORY.tmp.$$" "$INVENTORY"

{
    printf 'Run 2.1 start: %s\n' "$(date '+%F %T')"
    printf 'Track: %s\nSAFEs: %s\nS1A: %s\nS1B: %s\nS1C: %s\n' \
        "$TRACK" "$SAFE_TOTAL" "$S1A_COUNT" "$S1B_COUNT" "$S1C_COUNT"
    printf 'Orbit mode: %s\nDownloader: %s\n' "$ORBIT_MODE" "$DOWNLOADER_PATH"
} | tee "$SUMMARY_LOG"

set +e
(
    cd "$DATA_ABS"
    "$DOWNLOADER_PATH" SAFE_filelist "$ORBIT_MODE"
) > "$ORBIT_LOG" 2>&1
DOWNLOAD_STATUS=$?
set -e

cat "$ORBIT_LOG"
EOF_TOTAL="$(find "$DATA_ABS" -mindepth 1 -maxdepth 1 -type f -iname '*.EOF' | wc -l | awk '{print $1}')"
CRITICAL_COUNT="$(grep -Eic '\[ERROR\]|Traceback|Segmentation fault|No space left|download failed|could not download|cannot download' "$ORBIT_LOG" || true)"

{
    printf 'Run 2.1 finish: %s\n' "$(date '+%F %T')"
    printf 'Downloader exit: %s\nEOF files: %s\nCritical log lines: %s\n' \
        "$DOWNLOAD_STATUS" "$EOF_TOTAL" "$CRITICAL_COUNT"
    printf 'SAFE list: %s\nInventory: %s\nOrbit log: %s\n' \
        "$SAFE_LIST" "$INVENTORY" "$ORBIT_LOG"
} | tee -a "$SUMMARY_LOG"

(( DOWNLOAD_STATUS == 0 )) || die "orbit downloader exited with status $DOWNLOAD_STATUS"
(( EOF_TOTAL > 0 )) || die "no EOF orbit files were produced in $DATA_ABS"
(( CRITICAL_COUNT == 0 )) || die "orbit log contains $CRITICAL_COUNT critical line(s); inspect $ORBIT_LOG"

printf '[DONE] Run 2.1 completed: SAFEs=%s, EOF=%s\n' "$SAFE_TOTAL" "$EOF_TOTAL"
