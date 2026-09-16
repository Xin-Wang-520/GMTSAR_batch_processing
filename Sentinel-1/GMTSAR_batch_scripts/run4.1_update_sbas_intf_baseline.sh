#!/usr/bin/env bash
# Run 4.1: update the SBAS interferogram network and baseline table.
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 11, 2026

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

MERGE_DIR="merge"
SBAS_DIR="sbas_demcorr_pin"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Run 4.1: update SBAS intf.in and baseline_table.dat

Check only (no files are created, removed or modified):
  ./run4.1_update_sbas_intf_baseline.sh

Formal run with the default frame F1:
  ./run4.1_update_sbas_intf_baseline.sh 1

Formal run with an explicitly selected frame:
  ./run4.1_update_sbas_intf_baseline.sh 1 F1

Required for every accepted merge/20*_* pair:
  corr.grd
  phasefilt.grd
  unwrap_dem_correct_pin_up.grd

Source baseline table:
  F1/baseline_table.dat

Outputs:
  sbas_demcorr_pin/intflist_new
  sbas_demcorr_pin/intf.in
  sbas_demcorr_pin/baseline_table.dat
  sbas_demcorr_pin/run4.1_missing_pairs.tsv
  sbas_demcorr_pin/run4.1_complete

Incomplete pairs are reported and excluded. This script never deletes merge data.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
(( $# <= 2 )) || die "expected no arguments, or: 1 [F1|F2|F3]"
[[ $# -eq 0 || "$1" == "1" ]] || die "MODE must be 1"
FRAME="${2:-F1}"
[[ "$FRAME" =~ ^F[123]$ ]] || die "FRAME must be F1, F2 or F3"

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+$ ]] || die "run this script in a T-number track directory (current: $ROOT)"
[[ -d "$MERGE_DIR" ]] || die "cannot find $MERGE_DIR/"
BASELINE_SRC="$FRAME/baseline_table.dat"
[[ -s "$BASELINE_SRC" ]] || die "missing or empty source baseline table: $BASELINE_SRC"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v awk >/dev/null 2>&1 || die "awk not found"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run4.1.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT INT TERM
ALL_LIST="$TMP/all_pairs.txt"
VALID_LIST="$TMP/valid_pairs.txt"
MISSING_LIST="$TMP/missing_pairs.tsv"
STAGE="$TMP/stage"
mkdir -p "$STAGE"
: > "$ALL_LIST"
: > "$VALID_LIST"
printf 'pair\tmissing_or_empty_files\n' > "$MISSING_LIST"

while IFS= read -r -d '' path; do
    pair="$(basename -- "$path")"
    [[ "$pair" =~ ^[0-9]{7}_[0-9]{7}$ ]] && printf '%s\n' "$pair" >> "$ALL_LIST"
done < <(find "$MERGE_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*_*' -print0)
sort -u -o "$ALL_LIST" "$ALL_LIST"
[[ -s "$ALL_LIST" ]] || die "no merge/20*_* interferogram directories found"

while IFS= read -r pair; do
    missing=()
    [[ -s "$MERGE_DIR/$pair/corr.grd" ]] || missing+=("corr.grd")
    [[ -s "$MERGE_DIR/$pair/phasefilt.grd" ]] || missing+=("phasefilt.grd")
    [[ -s "$MERGE_DIR/$pair/unwrap_dem_correct_pin_up.grd" ]] ||
        missing+=("unwrap_dem_correct_pin_up.grd")

    if (( ${#missing[@]} == 0 )); then
        printf '%s\n' "$pair" >> "$VALID_LIST"
    else
        joined="$(IFS=,; printf '%s' "${missing[*]}")"
        printf '%s\t%s\n' "$pair" "$joined" >> "$MISSING_LIST"
    fi
done < "$ALL_LIST"

TOTAL="$(wc -l < "$ALL_LIST" | tr -d ' ')"
VALID="$(wc -l < "$VALID_LIST" | tr -d ' ')"
MISSING="$((TOTAL - VALID))"
(( VALID > 0 )) || die "no complete interferogram pairs are available for SBAS"

python3 - "$FRAME" "$VALID_LIST" "$STAGE/intf.in" <<'PY'
from datetime import datetime, timedelta
from pathlib import Path
import re
import sys

frame, list_path, output_path = sys.argv[1:]
pattern = re.compile(r"^(\d{4})(\d{3})_(\d{4})(\d{3})$")

def gmtsar_day_to_date(year: str, day: str) -> str:
    # GMTSAR merge directory day codes are zero-based. For example,
    # 2021051 maps to 2021-02-21 by adding 51 days to January 1.
    value = int(day)
    if not 0 <= value <= 366:
        raise ValueError(f"invalid GMTSAR day code: {year}{day}")
    return (datetime(int(year), 1, 1) + timedelta(days=value)).strftime("%Y%m%d")

lines = []
for pair in Path(list_path).read_text().splitlines():
    match = pattern.fullmatch(pair.strip())
    if not match:
        raise ValueError(f"invalid pair directory name: {pair}")
    y1, d1, y2, d2 = match.groups()
    date1 = gmtsar_day_to_date(y1, d1)
    date2 = gmtsar_day_to_date(y2, d2)
    lines.append(f"S1_{date1}_ALL_{frame}:S1_{date2}_ALL_{frame}")

Path(output_path).write_text("\n".join(lines) + "\n")
PY

awk -F: 'NF>=2 {print $1; print $2}' "$STAGE/intf.in" | sort -u > "$STAGE/used_scenes.txt"

awk '
NR==FNR { available[$1]=1; next }
!($1 in available) { print $1 }
' "$BASELINE_SRC" "$STAGE/used_scenes.txt" > "$STAGE/missing_scenes.txt"

if [[ -s "$STAGE/missing_scenes.txt" ]]; then
    printf '[ERROR] These scenes are absent from %s:\n' "$BASELINE_SRC" >&2
    sed 's/^/  /' "$STAGE/missing_scenes.txt" >&2
    exit 1
fi

awk '
NR==FNR { used[$1]=1; next }
($1 in used)
' "$STAGE/used_scenes.txt" "$BASELINE_SRC" > "$STAGE/baseline_table.dat"

cp "$VALID_LIST" "$STAGE/intflist_new"
cp "$MISSING_LIST" "$STAGE/run4.1_missing_pairs.tsv"

PAIR_LINES="$(wc -l < "$STAGE/intf.in" | tr -d ' ')"
SCENE_LINES="$(wc -l < "$STAGE/used_scenes.txt" | tr -d ' ')"
BASELINE_LINES="$(wc -l < "$STAGE/baseline_table.dat" | tr -d ' ')"
[[ "$PAIR_LINES" == "$VALID" ]] || die "intf.in line count does not match valid pair count"
[[ "$BASELINE_LINES" == "$SCENE_LINES" ]] ||
    die "filtered baseline table does not contain every used scene"

echo "========================================"
echo "Run 4.1 input check"
echo "Track root               : $ROOT"
echo "Frame naming             : $FRAME"
echo "Merged interferograms    : $TOTAL"
echo "Accepted SBAS pairs      : $VALID"
echo "Excluded incomplete pairs: $MISSING"
echo "Unique acquisition scenes: $SCENE_LINES"
echo "Baseline source          : $BASELINE_SRC"
echo "SBAS directory           : $SBAS_DIR"
echo "========================================"

if (( MISSING > 0 )); then
    echo "[WARN] Incomplete pairs will be excluded; merge directories will not be deleted."
    sed -n '1,11p' "$MISSING_LIST"
    (( MISSING > 10 )) && echo "[INFO] Only the first 10 incomplete pairs are shown."
fi

if (( $# == 0 )); then
    usage
    echo "[CHECK ONLY] No SBAS files were created or modified."
    exit 0
fi

mkdir -p "$SBAS_DIR"
STAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_DIR="$SBAS_DIR/run4.1_backup_$STAMP"
backup_count=0
for name in intflist_new intf.in baseline_table.dat run4.1_missing_pairs.tsv run4.1_complete; do
    if [[ -e "$SBAS_DIR/$name" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$SBAS_DIR/$name" "$BACKUP_DIR/"
        ((backup_count+=1))
    fi
done
(( backup_count > 0 )) && echo "[BACKUP] Previous Run 4.1 files: $BACKUP_DIR"

for name in intflist_new intf.in baseline_table.dat run4.1_missing_pairs.tsv; do
    mv -f "$STAGE/$name" "$SBAS_DIR/$name"
done

{
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'frame=%s\n' "$FRAME"
    printf 'merge_pairs=%s\n' "$TOTAL"
    printf 'accepted_pairs=%s\n' "$VALID"
    printf 'excluded_pairs=%s\n' "$MISSING"
    printf 'unique_scenes=%s\n' "$SCENE_LINES"
    printf 'baseline_source=%s\n' "$BASELINE_SRC"
} > "$SBAS_DIR/run4.1_complete"

echo "========================================"
echo "[DONE] Run 4.1 completed successfully."
echo "Pair list      : $ROOT/$SBAS_DIR/intflist_new ($VALID)"
echo "SBAS intf.in   : $ROOT/$SBAS_DIR/intf.in ($PAIR_LINES)"
echo "Baseline table : $ROOT/$SBAS_DIR/baseline_table.dat ($BASELINE_LINES)"
echo "Missing report : $ROOT/$SBAS_DIR/run4.1_missing_pairs.tsv ($MISSING)"
echo "No merge interferogram directory was deleted."
echo "========================================"
