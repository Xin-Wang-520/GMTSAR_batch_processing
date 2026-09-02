#!/usr/bin/env bash
# Run 3.1: generate burst/raw/data.in and put the temporal-middle acquisition first.

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
========================================
Run 3.1: prepare GMTSAR data.in for one burst stack

Usage:
  ./run3.1_prep_data_burst.sh
  ./run3.1_prep_data_burst.sh 1
  ./run3.1_prep_data_burst.sh 2

No arguments:
  Show this guide only. Nothing is checked, deleted or generated.

Mode 1 - preview:
  1. Validate the XML, TIFF, EOF and DEM links created by Run 2.3.
  2. Detect the real burst subswath (IW1, IW2 or IW3).
  3. Show the prep_data command and expected temporal-middle master position.
  4. Do not run prep_data_linux.csh and do not modify burst/raw.

Mode 2 - formal processing:
  1. Run prep_data_linux.csh inside burst/raw.
  2. If prep_data names an unavailable orbit revision, replace it with an
     existing EOF having the same satellite, orbit type and validity window.
  3. Save the resolved original order as burst/raw/data.in.orig.
  4. For three or more acquisitions, move the original middle record to line 1.
     For an even number, use the middle-front record.

Input from Run 2.3:
  burst/raw/*.xml
  burst/raw/*.tiff
  burst/raw/*.EOF
  burst/raw/dem.grd
  burst/burst_swath.txt

Outputs:
  burst/raw/data.in
  burst/raw/data.in.from_prep_data
  burst/raw/data.in.orig
  burst/raw/data.in.before_middle_first
  burst/raw/prep_data.log

Recommended:
  ./run3.1_prep_data_burst.sh 1
  ./run3.1_prep_data_burst.sh 2
========================================
EOF
}

if (( $# == 0 )); then
    usage
    printf '[INFO] Nothing was checked or changed.\n'
    exit 0
fi

[[ $# -eq 1 ]] || die "this script accepts only MODE 1 or 2"
case "$1" in
    1|2) MODE="$1" ;;
    -h|--help)
        usage
        exit 0
        ;;
    *) die "MODE must be 1 (preview) or 2 (formal)" ;;
esac

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "$ROOT_DIR")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT_DIR)"

UNIT_DIR="$ROOT_DIR/burst"
RAW_DIR="$UNIT_DIR/raw"
SWATH_FILE="$UNIT_DIR/burst_swath.txt"

[[ -d "$RAW_DIR" ]] || die "missing $RAW_DIR; complete Run 2.3 formal mode first"
[[ -s "$SWATH_FILE" ]] || die "missing $SWATH_FILE; complete Run 2.3 formal mode first"

SWATH="$(tr -d '[:space:]' < "$SWATH_FILE" | tr '[:lower:]' '[:upper:]')"
[[ "$SWATH" =~ ^IW[123]$ ]] || die "invalid burst subswath in $SWATH_FILE: $SWATH"
SWATH_LOWER="$(printf '%s' "$SWATH" | tr '[:upper:]' '[:lower:]')"

BROKEN_COUNT=0
while IFS= read -r -d '' link; do
    if [[ ! -e "$link" ]]; then
        printf '[BROKEN] %s -> %s\n' "$link" "$(readlink -- "$link")" >&2
        BROKEN_COUNT=$((BROKEN_COUNT + 1))
    fi
done < <(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type l -print0)
(( BROKEN_COUNT == 0 )) || die "$RAW_DIR contains $BROKEN_COUNT broken links"

count_links() {
    find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type l "$@" -print |
        wc -l | awk '{print $1}'
}

XML_COUNT="$(count_links -iname "*-${SWATH_LOWER}-slc-*.xml")"
TIFF_COUNT="$(count_links \( -iname "*-${SWATH_LOWER}-slc-*.tif" -o -iname "*-${SWATH_LOWER}-slc-*.tiff" \))"
EOF_COUNT="$(count_links -iname '*.EOF')"
DEM_COUNT="$(count_links -name 'dem.grd')"

(( XML_COUNT >= 2 )) || die "at least two $SWATH XML links are required in $RAW_DIR"
[[ "$XML_COUNT" -eq "$TIFF_COUNT" ]] ||
    die "XML/TIFF count mismatch in $RAW_DIR: $XML_COUNT/$TIFF_COUNT"
(( EOF_COUNT > 0 )) || die "no orbit EOF links found in $RAW_DIR"
[[ "$DEM_COUNT" -eq 1 ]] || die "$RAW_DIR requires exactly one dem.grd link"

MID=$(( (XML_COUNT + 1) / 2 ))

printf '%s\n' '========================================'
printf 'Run 3.1: prepare burst/raw/data.in\n'
printf 'Mode           : %s\n' "$([[ "$MODE" == 1 ]] && printf PREVIEW || printf FORMAL)"
printf 'Track root     : %s\n' "$ROOT_DIR"
printf 'Burst raw      : %s\n' "$RAW_DIR"
printf 'Detected swath : %s\n' "$SWATH"
printf 'XML links      : %s\n' "$XML_COUNT"
printf 'TIFF links     : %s\n' "$TIFF_COUNT"
printf 'Orbit EOF links: %s\n' "$EOF_COUNT"
printf 'DEM links      : %s\n' "$DEM_COUNT"
if (( XML_COUNT < 3 )); then
    printf 'Master rule    : keep original first record (fewer than 3 acquisitions)\n'
else
    printf 'Master rule    : move original data.in line %s to line 1\n' "$MID"
fi
printf '%s\n' '========================================'

printf '[COMMAND PREVIEW] cd %q && prep_data_linux.csh > prep_data.log 2>&1\n' "$RAW_DIR"
if [[ "$MODE" == 1 ]]; then
    if command -v prep_data_linux.csh >/dev/null 2>&1; then
        printf '[FOUND] %s\n' "$(command -v prep_data_linux.csh)"
    else
        printf '[WARN] prep_data_linux.csh is not currently available in PATH.\n'
    fi
    printf '[NOT RUN] prep_data_linux.csh was displayed only.\n'
    printf '[DONE] Input links passed the Run 3.1 preview checks.\n'
    exit 0
fi

command -v prep_data_linux.csh >/dev/null 2>&1 ||
    die "prep_data_linux.csh was not found in PATH"

(
    cd -- "$RAW_DIR"

    printf '[1] Clean old prep_data outputs\n'
    rm -f -- \
        data.in \
        data.in.from_prep_data \
        data.in.orig \
        data.in.before_middle_first \
        prep_data.log \
        orbit.list \
        orbits.list \
        SAFE.list \
        safe.list \
        raw.list

    printf '[2] Run prep_data_linux.csh\n'
    if ! prep_data_linux.csh > prep_data.log 2>&1; then
        printf '[FAIL] prep_data_linux.csh failed in %s\n' "$RAW_DIR" >&2
        printf '[FAIL] Last 30 log lines:\n' >&2
        tail -n 30 prep_data.log >&2 || true
        exit 1
    fi

    [[ -s data.in ]] || {
        printf '[FAIL] data.in was not generated or is empty in %s\n' "$RAW_DIR" >&2
        exit 1
    }

    printf '[3] Resolve orbit revisions named by prep_data\n'
    cp -p -- data.in data.in.from_prep_data
    RESOLVED_TMP="$(mktemp data.in.resolved.XXXXXX)"
    ORBIT_REMAP_COUNT=0
    while IFS=: read -r slc orbit extra; do
        [[ -n "$slc" && -n "$orbit" && -z "${extra:-}" ]] || {
            printf '[FAIL] malformed data.in record: %s:%s%s\n' \
                "$slc" "$orbit" "${extra:+:$extra}" >&2
            exit 1
        }
        selected_orbit="$orbit"
        if [[ ! -e "$selected_orbit" ]]; then
            if [[ "$orbit" =~ ^(S1[ABC])_OPER_AUX_(POEORB|RESORB)_.*_(V[0-9]{8}T[0-9]{6}_[0-9]{8}T[0-9]{6})[.]EOF$ ]]; then
                satellite="${BASH_REMATCH[1]}"
                orbit_type="${BASH_REMATCH[2]}"
                validity="${BASH_REMATCH[3]}"
            else
                printf '[FAIL] missing orbit has an unrecognized filename: %s\n' "$orbit" >&2
                exit 1
            fi

            orbit_candidates=()
            while IFS= read -r -d '' candidate; do
                [[ -e "$candidate" ]] && orbit_candidates+=("$candidate")
            done < <(
                find . -mindepth 1 -maxdepth 1 \
                    \( -type f -o -type l \) \
                    -name "${satellite}_OPER_AUX_${orbit_type}_*_${validity}.EOF" \
                    -print0
            )
            (( ${#orbit_candidates[@]} > 0 )) || {
                printf '[FAIL] no local %s orbit covers %s for %s\n' \
                    "$orbit_type" "$validity" "$slc" >&2
                exit 1
            }
            mapfile -t sorted_candidates < <(printf '%s\n' "${orbit_candidates[@]}" | sort)
            selected_orbit="$(basename -- "${sorted_candidates[${#sorted_candidates[@]} - 1]}")"
            printf '[ORBIT REMAP] %s\n' "$orbit"
            printf '           -> %s\n' "$selected_orbit"
            ORBIT_REMAP_COUNT=$((ORBIT_REMAP_COUNT + 1))
        fi
        printf '%s:%s\n' "$slc" "$selected_orbit" >> "$RESOLVED_TMP"
    done < data.in
    mv -f -- "$RESOLVED_TMP" data.in
    printf '[ORBIT CHECK] remapped=%s, all data.in orbit files exist\n' "$ORBIT_REMAP_COUNT"

    printf '[4] Back up resolved original data.in\n'
    cp -p -- data.in data.in.orig
    NLINE="$(wc -l < data.in.orig | awk '{print $1}')"
    [[ "$NLINE" -eq "$XML_COUNT" ]] || {
        printf '[FAIL] data.in/XML count mismatch: %s/%s\n' "$NLINE" "$XML_COUNT" >&2
        exit 1
    }

    if (( NLINE < 3 )); then
        printf '[5] Fewer than 3 records; keep original data.in order\n'
    else
        MID=$(( (NLINE + 1) / 2 ))
        printf '[5] Move original line %s to the first line\n' "$MID"
        cp -p -- data.in.orig data.in.before_middle_first
        REORDER_TMP="$(mktemp data.in.tmp.XXXXXX)"
        awk -v mid="$MID" '
            NR == mid { middle = $0; next }
            { lines[++count] = $0 }
            END {
                print middle
                for (i = 1; i <= count; i++) print lines[i]
            }
        ' data.in.orig > "$REORDER_TMP"
        mv -f -- "$REORDER_TMP" data.in

        EXPECTED_FIRST="$(sed -n "${MID}p" data.in.orig)"
        ACTUAL_FIRST="$(head -n 1 data.in)"
        [[ "$ACTUAL_FIRST" == "$EXPECTED_FIRST" ]] || {
            printf '[FAIL] reordered first record does not match original line %s\n' "$MID" >&2
            exit 1
        }
        [[ "$(wc -l < data.in | awk '{print $1}')" -eq "$NLINE" ]] || {
            printf '[FAIL] data.in record count changed after reordering\n' >&2
            exit 1
        }
    fi

    printf '[6] data.in first five records:\n'
    head -n 5 data.in
    printf '[DONE] data.in=%s records; log=%s/prep_data.log\n' "$NLINE" "$RAW_DIR"
)
