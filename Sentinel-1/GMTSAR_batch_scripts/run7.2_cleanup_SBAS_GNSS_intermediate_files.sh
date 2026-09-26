#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Contact: xinw11@mail.ustc.edu.cn
# Citation: Xin Wang et al. (2026), Near instantaneously triggered Mw 5.9 aftershock during the 2025 Mw 7.1 Dingri earthquake revealed by radar interferometry, Earth and Planetary Science Letters, 686, 120070.
# Last updated: September 20, 2026
# Run 7.2: clean reproducible SBAS and GNSS intermediate files.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
SBAS_DIR="$ROOT/sbas_demcorr_pin"
GNSS_DIR="$ROOT/GNSS2LOS_correction"
MODE="PREVIEW"
VERBOSE="${VERBOSE:-0}"

SBAS_ITEMS=0 SBAS_BYTES=0
GNSS_ITEMS=0 GNSS_BYTES=0

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

verbose_printf() {
    [[ "$VERBOSE" == "1" ]] || return 0
    printf "$@"
}

usage() {
    cat <<'EOF'
Usage:
  ./run7.2_cleanup_SBAS_GNSS_intermediate_files.sh
  ./run7.2_cleanup_SBAS_GNSS_intermediate_files.sh 1

No arguments - PREVIEW ONLY:
  Check prerequisites, count cleanup targets and estimate released space.
  No file, directory or link is removed or modified.

Mode 1 - FORMAL CLEANUP:
  Delete only the reproducible SBAS/GNSS intermediate files listed below.

Concise output is the default. To print every matched path, use:
  VERBOSE=1 ./run7.2_cleanup_SBAS_GNSS_intermediate_files.sh
  VERBOSE=1 ./run7.2_cleanup_SBAS_GNSS_intermediate_files.sh 1

This script never touches F1/, F2/, F3/ or merge/.
It preserves all original, deseasoned and GNSS-corrected displacement grids.
EOF
}

if (( $# > 1 )); then usage; die "too many arguments"; fi
if (( $# == 1 )); then
    [[ "$1" == "1" ]] || { usage; die "the only formal mode is 1"; }
    MODE="DELETE"
fi
[[ "$VERBOSE" == "0" || "$VERBOSE" == "1" ]] || die "VERBOSE must be 0 or 1"

[[ "$TRACK" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number track directory (current: $ROOT)"
[[ -d "$SBAS_DIR" ]] || die "missing directory: $SBAS_DIR"
[[ -d "$GNSS_DIR" ]] || die "missing directory: $GNSS_DIR"
[[ -d "$SBAS_DIR/disp_deseason" ]] || die "missing directory: $SBAS_DIR/disp_deseason"
[[ -d "$GNSS_DIR/GNSS_LOS_timeseries" ]] ||
    die "missing directory: $GNSS_DIR/GNSS_LOS_timeseries"
[[ -d "$GNSS_DIR/GNSS_corrected_displacement" ]] ||
    die "missing directory: $GNSS_DIR/GNSS_corrected_displacement"

for marker in run6.7_complete run6.8_complete run6.9_complete; do
    [[ -s "$GNSS_DIR/$marker" ]] ||
        die "missing or empty $GNSS_DIR/$marker; Run 7.2 cleanup is blocked"
done

count_files() {
    local directory="$1" pattern="$2"
    find "$directory" -maxdepth 1 -type f -name "$pattern" -print 2>/dev/null |
        wc -l | awk '{print $1}'
}

DESEASON_COUNT="$(count_files "$SBAS_DIR/disp_deseason" 'disp_[0-9]*.grd')"
GNSS_TS_COUNT="$(count_files "$GNSS_DIR/GNSS_LOS_timeseries" 'gnss_LOS_[0-9]*.grd')"
CORRECTED_COUNT="$(count_files "$GNSS_DIR/GNSS_corrected_displacement" 'disp_[0-9]*_gnssref_5km_80km.grd')"
DIFF_COUNT="$(count_files "$GNSS_DIR/GNSS_corrected_displacement" 'diff_[0-9]*_smooth80km_full.grd')"

[[ "$CORRECTED_COUNT" =~ ^[1-9][0-9]*$ ]] ||
    die "no final GNSS-corrected displacement grids were found"
[[ "$DESEASON_COUNT" == "$CORRECTED_COUNT" ]] ||
    die "epoch mismatch: deseasoned=$DESEASON_COUNT, corrected=$CORRECTED_COUNT"
if (( GNSS_TS_COUNT != 0 && GNSS_TS_COUNT != CORRECTED_COUNT )); then
    die "epoch mismatch: GNSS LOS=$GNSS_TS_COUNT, corrected=$CORRECTED_COUNT"
fi
if (( DIFF_COUNT != 0 && DIFF_COUNT != CORRECTED_COUNT )); then
    die "epoch mismatch: long-wave corrections=$DIFF_COUNT, corrected=$CORRECTED_COUNT"
fi

check_live_pid_files() {
    local pid_file pid
    while IFS= read -r -d '' pid_file; do
        pid="$(awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$pid_file" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            die "active process PID $pid found in $pid_file; cleanup refused"
        fi
    done < <(find "$SBAS_DIR" "$GNSS_DIR" -type f -name '*.pid' -print0 2>/dev/null)
}

directory_bytes() {
    du -sk -- "$1" 2>/dev/null | awk 'NR == 1 {print $1 * 1024; exit}'
}

path_bytes() {
    local path="$1"
    if [[ -d "$path" && ! -L "$path" ]]; then
        directory_bytes "$path"
    else
        stat -c '%s' -- "$path" 2>/dev/null || wc -c < "$path" | awk '{print $1}'
    fi
}

human_bytes() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes"
    else
        awk -v b="$bytes" 'BEGIN {split("B KiB MiB GiB TiB",u," "); i=1; while(b>=1024&&i<5){b/=1024;i++}; printf "%.2f %s",b,u[i]}'
    fi
}

mib_value() {
    awk -v bytes="$1" 'BEGIN {printf "%.2f", bytes / 1048576}'
}

add_count() {
    local category="$1" bytes="$2"
    case "$category" in
        SBAS) SBAS_ITEMS=$((SBAS_ITEMS+1)); SBAS_BYTES=$((SBAS_BYTES+bytes)) ;;
        GNSS) GNSS_ITEMS=$((GNSS_ITEMS+1)); GNSS_BYTES=$((GNSS_BYTES+bytes)) ;;
        *) die "internal unknown cleanup category: $category" ;;
    esac
}

process_path() {
    local category="$1" path="$2" bytes
    [[ -e "$path" || -L "$path" ]] || return 0
    bytes="$(path_bytes "$path")"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    add_count "$category" "$bytes"
    if [[ "$MODE" == "DELETE" ]]; then
        if [[ -d "$path" && ! -L "$path" ]]; then rm -rf -- "$path"; else rm -f -- "$path"; fi
        verbose_printf '[DEL %-4s] %s\n' "$category" "$path"
    else
        verbose_printf '[DRY %-4s] %s\n' "$category" "$path"
    fi
}

clean_common_files() {
    local category="$1" base="$2" path
    while IFS= read -r -d '' path; do
        process_path "$category" "$path"
    done < <(
        find "$base" -type f \
            \( -name '*.log' -o -name '*.ps' -o -name '*.pid' -o \
               -name '*.pyc' -o -name 'gmt.history' \) \
            ! -path '*/.run*/*' ! -path '*/__pycache__/*' \
            -print0 2>/dev/null | sort -z
    )
}

clean_temporary_directories() {
    local category="$1" base="$2" path
    while IFS= read -r -d '' path; do
        process_path "$category" "$path"
    done < <(
        find "$base" -mindepth 1 -type d \
            \( -name '.run*_tmp*' -o -name '.run*_work*' -o \
               -name '.run*_plot*' -o -name '.run*_timeseries*' -o \
               -name '.run*_chunks_tmp*' -o -name '.run*_output_tmp*' -o \
               -name '.run*_old*' -o -name '__pycache__' \) \
            -prune -print0 2>/dev/null | sort -z
    )
}

SBAS_BEFORE="$(directory_bytes "$SBAS_DIR")"
GNSS_BEFORE="$(directory_bytes "$GNSS_DIR")"
[[ "$SBAS_BEFORE" =~ ^[0-9]+$ && "$GNSS_BEFORE" =~ ^[0-9]+$ ]] ||
    die "cannot determine SBAS/GNSS directory sizes"

printf '%s\n' '========================================'
printf 'Run 7.2: clean SBAS and GNSS intermediate files\n'
printf 'Mode                 : %s\n' "$MODE"
printf 'Track root           : %s\n' "$ROOT"
printf 'Verbose              : %s\n' "$VERBOSE"
printf 'Deseasoned epochs    : %s\n' "$DESEASON_COUNT"
printf 'Corrected epochs     : %s\n' "$CORRECTED_COUNT"
printf 'GNSS model epochs    : %s\n' "$GNSS_TS_COUNT"
printf 'Correction epochs    : %s\n' "$DIFF_COUNT"
printf 'SBAS size before     : %s (%s MiB)\n' "$(human_bytes "$SBAS_BEFORE")" "$(mib_value "$SBAS_BEFORE")"
printf 'GNSS size before     : %s (%s MiB)\n' "$(human_bytes "$GNSS_BEFORE")" "$(mib_value "$GNSS_BEFORE")"
printf '%s\n' '========================================'

[[ "$MODE" == "PREVIEW" ]] || check_live_pid_files

printf '\n========== SBAS cleanup types ==========\n'
printf '  raln.grd\n  ralt.grd\n  nobs_deseason.grd\n'
printf '  *.log  *.ps  stale *.pid  gmt.history  *.pyc\n'
printf '  temporary .run* directories and __pycache__/\n'
printf '[SCAN] %s\n' "$SBAS_DIR"
process_path SBAS "$SBAS_DIR/raln.grd"
process_path SBAS "$SBAS_DIR/ralt.grd"
process_path SBAS "$SBAS_DIR/nobs_deseason.grd"
process_path SBAS "$SBAS_DIR/disp_deseason/nobs_deseason.grd"
clean_common_files SBAS "$SBAS_DIR"
clean_temporary_directories SBAS "$SBAS_DIR"

printf '\n========== GNSS cleanup types ==========\n'
printf '  GNSS_E.grd\n  GNSS_N.grd\n'
printf '  GNSS_LOS_timeseries/gnss_LOS_*.grd\n'
printf '  GNSS_corrected_displacement/diff_*_smooth80km_full.grd\n'
printf '  *.log  *.ps  stale *.pid  gmt.history  *.pyc\n'
printf '  temporary .run* directories and __pycache__/\n'
printf '[SCAN] %s\n' "$GNSS_DIR"
process_path GNSS "$GNSS_DIR/GNSS_E.grd"
process_path GNSS "$GNSS_DIR/GNSS_N.grd"
while IFS= read -r -d '' path; do process_path GNSS "$path"; done < <(
    find "$GNSS_DIR/GNSS_LOS_timeseries" -maxdepth 1 -type f \
        -name 'gnss_LOS_[0-9]*.grd' -print0 2>/dev/null | sort -z
)
while IFS= read -r -d '' path; do process_path GNSS "$path"; done < <(
    find "$GNSS_DIR/GNSS_corrected_displacement" -maxdepth 1 -type f \
        -name 'diff_[0-9]*_smooth80km_full.grd' -print0 2>/dev/null | sort -z
)
clean_common_files GNSS "$GNSS_DIR"
clean_temporary_directories GNSS "$GNSS_DIR"

SBAS_AFTER="$(directory_bytes "$SBAS_DIR")"
GNSS_AFTER="$(directory_bytes "$GNSS_DIR")"
TOTAL_ITEMS=$((SBAS_ITEMS+GNSS_ITEMS))
TOTAL_BYTES=$((SBAS_BYTES+GNSS_BYTES))
TOTAL_BEFORE=$((SBAS_BEFORE+GNSS_BEFORE))
TOTAL_AFTER=$((SBAS_AFTER+GNSS_AFTER))
if [[ "$MODE" == "DELETE" ]]; then
    ACTUAL_RELEASED=$((TOTAL_BEFORE-TOTAL_AFTER))
    if (( ACTUAL_RELEASED < 0 )); then ACTUAL_RELEASED=0; fi
else
    ACTUAL_RELEASED=0
fi

printf '\n%s\n' '========================================'
printf 'Run 7.2 cleanup summary\n'
printf 'Mode                         : %s\n' "$MODE"
printf 'SBAS cleanup targets         : %8d items  %s\n' "$SBAS_ITEMS" "$(human_bytes "$SBAS_BYTES")"
printf 'GNSS cleanup targets         : %8d items  %s\n' "$GNSS_ITEMS" "$(human_bytes "$GNSS_BYTES")"
printf 'TOTAL cleanup targets        : %8d items  %s (%s MiB)\n' "$TOTAL_ITEMS" "$(human_bytes "$TOTAL_BYTES")" "$(mib_value "$TOTAL_BYTES")"
printf 'SBAS size before / after     : %s / %s\n' "$(human_bytes "$SBAS_BEFORE")" "$(human_bytes "$SBAS_AFTER")"
printf 'GNSS size before / after     : %s / %s\n' "$(human_bytes "$GNSS_BEFORE")" "$(human_bytes "$GNSS_AFTER")"
printf 'Combined size before / after : %s / %s\n' "$(human_bytes "$TOTAL_BEFORE")" "$(human_bytes "$TOTAL_AFTER")"
printf 'Actual disk space released   : %s (%s MiB)\n' "$(human_bytes "$ACTUAL_RELEASED")" "$(mib_value "$ACTUAL_RELEASED")"
printf '%s\n' '========================================'

if [[ "$MODE" == "PREVIEW" ]]; then
    printf '[CHECK ONLY] Nothing was deleted or modified.\n'
    printf '[KEEP] All displacement time series and final velocity products are preserved.\n'
    printf '[NEXT] Review the summary, then run:\n'
    printf '  ./run7.2_cleanup_SBAS_GNSS_intermediate_files.sh 1\n'
else
    printf '[DONE] Run 7.2 formal cleanup completed.\n'
    printf '[KEEP] F1/F2/F3, merge and all final displacement grids were untouched.\n'
fi
