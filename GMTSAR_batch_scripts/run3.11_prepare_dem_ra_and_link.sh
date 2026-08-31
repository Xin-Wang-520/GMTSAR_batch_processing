#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: August 10, 2026
#
# Run 3.11: prepare a radar-coordinate DEM matching merged unwrap grids.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

MERGE_DIR="merge"
TRANS_MIN_BYTES=$((20 * 1024 * 1024))
MISSING_REPORT="merge/run3.11_missing_inputs.tsv"
MARKER="merge/run3.11_complete"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  ./run3.11_prepare_dem_ra_and_link.sh
  ./run3.11_prepare_dem_ra_and_link.sh 1

No arguments:
  Check all unwrap.grd files, merge/trans.dat, merge/dem.grd and existing
  radar-DEM products. No files are created, removed or modified.

Mode 1:
  1. Confirm every merge/20* pair has a non-empty unwrap.grd.
  2. Quickly check every unwrap.grd exists; compare grid geometry only for
     the first, middle and last interferograms.
  3. Generate merge/dem_ra.grd with proj_ll2ra.csh.
  4. Resample it exactly to the unwrap grid as merge/tmp_dem_ra.grd.
  5. Link ../tmp_dem_ra.grd into every interferogram directory.

Formal run:
  ./run3.11_prepare_dem_ra_and_link.sh 1

Outputs:
  merge/dem_ra.grd
  merge/tmp_dem_ra.grd
  merge/20*_<...>/tmp_dem_ra.grd -> ../tmp_dem_ra.grd
  merge/run3.11_complete
EOF
}

require_root() {
    local root track
    root="$(pwd -P)"; track="$(basename -- "$root")"
    [[ "$track" =~ ^T[0-9]+$ ]] || die "run this script in a T-number track directory (current: $root)"
    [[ -d "$MERGE_DIR" ]] || die "cannot find $MERGE_DIR/"
}

grid_signature() {
    gmt grdinfo "$1" -C | awk '{print $2,$3,$4,$5,$8,$9,$10,$11,$12}'
}

make_pairs() {
    local out="$1" path pair
    : > "$out"
    while IFS= read -r -d '' path; do
        pair="$(basename -- "$path")"
        [[ "$pair" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] && printf '%s\n' "$pair" >> "$out"
    done < <(find "$MERGE_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' -print0)
    sort -u -o "$out" "$out"
    [[ -s "$out" ]] || die "no merged interferogram directories found"
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then usage; exit 0; fi
(( $# <= 1 )) || die "use no arguments for checking, or mode 1 for processing"
[[ $# -eq 0 || "$1" == 1 ]] || die "MODE must be 1"

for c in awk basename find gmt head mktemp proj_ll2ra.csh sort wc; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
done
require_root
ROOT="$(pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/run3.11.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT INT TERM
PAIRS="$TMP/pairs.txt"; MISSING="$TMP/missing.tsv"
make_pairs "$PAIRS"

[[ -s "$MERGE_DIR/dem.grd" ]] || die "missing or empty: $MERGE_DIR/dem.grd"
[[ -s "$MERGE_DIR/trans.dat" ]] || die "missing or empty: $MERGE_DIR/trans.dat"
TRANS_BYTES="$(wc -c < "$MERGE_DIR/trans.dat" | awk '{print $1}')"
(( TRANS_BYTES > TRANS_MIN_BYTES )) || die "$MERGE_DIR/trans.dat must be larger than 20 MiB"

: > "$MISSING"
mapfile -t PAIR_ARRAY < "$PAIRS"
TOTAL=${#PAIR_ARRAY[@]}

# Fast full-stack check: file existence/non-empty only (no GMT process per pair).
for pair in "${PAIR_ARRAY[@]}"; do
    grid="$MERGE_DIR/$pair/unwrap.grd"
    [[ -s "$grid" ]] || printf "%s\tmissing_or_empty_unwrap.grd\n" "$pair" >> "$MISSING"
done

# Geometry sampling avoids launching gmt grdinfo hundreds or thousands of times.
TEMPLATE="$MERGE_DIR/${PAIR_ARRAY[0]}/unwrap.grd"
TEMPLATE_SIG=""
if [[ -s "$TEMPLATE" ]]; then
    TEMPLATE_SIG="$(grid_signature "$TEMPLATE")"
    [[ -n "$TEMPLATE_SIG" ]] || die "failed to read grid geometry: $TEMPLATE"

    MID_INDEX=$(( (TOTAL - 1) / 2 ))
    LAST_INDEX=$(( TOTAL - 1 ))
    SAMPLE_INDICES=(0 "$MID_INDEX" "$LAST_INDEX")
    declare -A SEEN_SAMPLE=()

    for idx in "${SAMPLE_INDICES[@]}"; do
        pair="${PAIR_ARRAY[$idx]}"
        [[ -n "${SEEN_SAMPLE[$pair]:-}" ]] && continue
        SEEN_SAMPLE[$pair]=1
        grid="$MERGE_DIR/$pair/unwrap.grd"
        [[ -s "$grid" ]] || continue
        sig="$(grid_signature "$grid")"
        [[ -n "$sig" ]] || die "failed to read grid geometry: $grid"
        if [[ "$sig" != "$TEMPLATE_SIG" ]]; then
            printf "%s\tsampled_unwrap_grid_geometry_mismatch\t%s\n" "$pair" "$sig" >> "$MISSING"
        fi
    done
fi

if [[ -s "$MISSING" ]]; then
    printf '%s\n' '[CHECK ERROR] Incomplete or inconsistent unwrap inputs:' >&2
    sed 's/^/  /' "$MISSING" >&2
    if (( $# == 1 )); then cp "$MISSING" "$MISSING_REPORT"; fi
    die "Run 3.11 was not started"
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.11 input check'
printf 'Track root          : %s\n' "$ROOT"
printf 'Interferogram pairs : %s\n' "$TOTAL"
printf 'Template unwrap     : %s\n' "$TEMPLATE"
printf 'Grid signature      : %s\n' "$TEMPLATE_SIG"
printf 'Geometry check      : first/middle/last (fast mode)\n'
printf 'trans.dat size      : %.2f MiB\n' "$(awk -v b="$TRANS_BYTES" 'BEGIN{print b/1024/1024}')"
printf 'Existing dem_ra     : %s\n' "$([[ -s $MERGE_DIR/dem_ra.grd ]] && echo yes || echo no)"
printf 'Existing tmp_dem_ra : %s\n' "$([[ -s $MERGE_DIR/tmp_dem_ra.grd ]] && echo yes || echo no)"
printf '%s\n' '========================================'

if (( $# == 0 )); then
    usage
    printf '%s\n' '[CHECK ONLY] No DEM projection or linking was started.'
    exit 0
fi

# Refuse to replace user-owned regular files inside pair directories.
while IFS= read -r pair; do
    link="$MERGE_DIR/$pair/tmp_dem_ra.grd"
    [[ ! -e "$link" || -L "$link" ]] || die "refusing to replace regular file: $link"
done < "$PAIRS"

XINC="$(awk '{print $5}' <<< "$TEMPLATE_SIG")"
YINC="$(awk '{print $6}' <<< "$TEMPLATE_SIG")"
[[ -n "$XINC" && -n "$YINC" ]] || die "failed to read unwrap increments"
DEM_TMP=".run3.11_dem_ra.$$.grd"
SAMPLED_TMP=".run3.11_tmp_dem_ra.$$.grd"
cleanup_merge_tmp() { rm -f -- "$ROOT/$MERGE_DIR/$DEM_TMP" "$ROOT/$MERGE_DIR/$SAMPLED_TMP"; }
trap 'cleanup_merge_tmp; rm -rf -- "$TMP"' EXIT INT TERM

cd "$MERGE_DIR"
TEMPLATE_REL="${TEMPLATE#${MERGE_DIR}/}"
printf '%s\n' '[STEP 1] Project geographic DEM to radar coordinates'
printf 'Command: proj_ll2ra.csh trans.dat dem.grd %s -I%s/%s\n' "$DEM_TMP" "$XINC" "$YINC"
proj_ll2ra.csh trans.dat dem.grd "$DEM_TMP" -I"${XINC}/${YINC}"
[[ -s "$DEM_TMP" ]] || die "proj_ll2ra.csh did not generate $DEM_TMP"

printf '%s\n' '[STEP 2] Resample DEM exactly to the unwrap grid'
gmt grdsample "$DEM_TMP" -R"$TEMPLATE_REL" -G"$SAMPLED_TMP"
[[ -s "$SAMPLED_TMP" ]] || die "GMT did not generate $SAMPLED_TMP"
OUT_SIG="$(grid_signature "$SAMPLED_TMP")"
[[ "$OUT_SIG" == "$TEMPLATE_SIG" ]] || die "tmp_dem_ra geometry does not match unwrap grid"

mv -f -- "$DEM_TMP" dem_ra.grd
mv -f -- "$SAMPLED_TMP" tmp_dem_ra.grd

printf '%s\n' '[STEP 3] Plot the radar-coordinate DEM as PDF'
rm -f -- tmp_dem_ra.cpt tmp_dem_ra.ps tmp_dem_ra.pdf
gmt grd2cpt tmp_dem_ra.grd -Cgeo -Z --COLOR_NAN=gray > tmp_dem_ra.cpt
gmt grdimage tmp_dem_ra.grd \
    -JX6.5i \
    -Ctmp_dem_ra.cpt \
    -Bxaf+lRange \
    -Byaf+lAzimuth \
    -BWSen+t"Radar-coordinate DEM" \
    -X1.2i -Y2.8i -P -K > tmp_dem_ra.ps
gmt psscale \
    -Rtmp_dem_ra.grd -J \
    -DJBC+w5.0i/0.25i+h+o0i/0.35i \
    -Ctmp_dem_ra.cpt \
    -Baf+l"Elevation (m)" \
    -O >> tmp_dem_ra.ps
gmt psconvert -Tf -P -A -Z tmp_dem_ra.ps
[[ -s tmp_dem_ra.pdf ]] || die "tmp_dem_ra.pdf was not generated"
rm -f -- tmp_dem_ra.cpt tmp_dem_ra.ps gmt.conf gmt.history .gmtcommands4

printf '%s\n' '[STEP 4] Link the common radar DEM into every pair'
while IFS= read -r pair; do
    ln -sfn ../tmp_dem_ra.grd "$pair/tmp_dem_ra.grd"
    [[ -s "$pair/tmp_dem_ra.grd" ]] || die "broken link: $pair/tmp_dem_ra.grd"
done < "$PAIRS"

{
    date '+completed=%Y-%m-%d %H:%M:%S'
    printf 'pairs=%s\n' "$TOTAL"
    printf 'template=%s\n' "$TEMPLATE_REL"
    printf 'signature=%s\n' "$TEMPLATE_SIG"
    printf 'figure=tmp_dem_ra.pdf\n'
} > run3.11_complete
rm -f -- run3.11_missing_inputs.tsv

printf '%s\n' '========================================'
printf '%s\n' '[DONE] Run 3.11 completed successfully.'
printf 'DEM radar grid : %s/merge/dem_ra.grd\n' "$ROOT"
printf 'Shared DEM     : %s/merge/tmp_dem_ra.grd\n' "$ROOT"
printf 'DEM figure     : %s/merge/tmp_dem_ra.pdf\n' "$ROOT"
printf 'Links created  : %s\n' "$TOTAL"
printf '%s\n' '========================================'
