#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Contact: xinw11@mail.ustc.edu.cn
# Citation: Xin Wang et al. (2026), Near instantaneously triggered Mw 5.9 aftershock during the 2025 Mw 7.1 Dingri earthquake revealed by radar interferometry, Earth and Planetary Science Letters, 686, 120070.
# Last updated: September 20, 2026
# Run 7.1: conservatively clean reproducible GMTSAR intermediate files.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
MODE="PREVIEW"
VERBOSE="${VERBOSE:-0}"

FRAME_FILES=0 FRAME_BYTES=0
RAW_FILES=0 RAW_BYTES=0
MERGE_FILES=0 MERGE_BYTES=0
ROOT_FILES=0 ROOT_BYTES=0
SKIPPED_RAW=0 SKIPPED_MERGE=0

FRAME_PATTERNS=(
    amp.grd amp1.grd amp2.grd corr.cpt corr.pdf 'display*'
    filtcorr.grd gmt.conf gmt.history ijdec imagfilt.grd
    phase.cpt phase.pdf phase.grd realfilt.grd phasefilt.pdf
)

MERGE_FILES_TO_DELETE=(
    gmt.history unwrap.cpt unwrap.pdf dem_correction.log
    merge_log merge_log_corr merge_log_mask
    tmp_masklist tmp_phaselist tmp.filelist tmp_corrlist
    landmask_ra_patch.grd mask_def_patch.grd mask2_patch.grd
    phasefilt_interp.grd unwrap_pin.grd
)

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

verbose_printf() {
    [[ "$VERBOSE" == "1" ]] || return 0
    printf "$@"
}

usage() {
    cat <<'EOF'
Usage:
  ./run7.1_cleanup_F1F2F3_merge_intermediate_files.sh
  ./run7.1_cleanup_F1F2F3_merge_intermediate_files.sh 1

No arguments - PREVIEW ONLY:
  Scan the files that would be deleted and summarize their disk usage.
  No file, directory, link, log or report is created, removed or modified.

Mode 1 - FORMAL CLEANUP:
  Delete only the files shown by preview mode.

Terminal output is concise by default. To print every matched file, use:
  VERBOSE=1 ./run7.1_cleanup_F1F2F3_merge_intermediate_files.sh
  VERBOSE=1 ./run7.1_cleanup_F1F2F3_merge_intermediate_files.sh 1

Cleanup scope:
  1. Reproducible files in F1/F2/F3/intf_all/20*_20*/.
  2. Non-ALL SLC/PRM/LED only when matching ALL SLC/PRM/LED exist.
  3. Temporary files in merge/20*_20*/ only when the final
     unwrap_dem_correct_pin_up.grd exists and is non-empty.
  4. Track-root gmt.history.

All gauss_400 files are kept because they are small and are still used by
the Run 4.4, Run 5.4 and Run 6.9 projection workflows.

No SBAS, deseasoned or GNSS-corrected time-series file is deleted.
ALL SLC/PRM/LED, core interferograms, trans.dat, DEMs and final products stay.
EOF
}

if (( $# > 1 )); then usage; die "too many arguments"; fi
if (( $# == 1 )); then
    [[ "$1" == "1" ]] || { usage; die "the only formal mode is 1"; }
    MODE="DELETE"
fi
[[ "$VERBOSE" == "0" || "$VERBOSE" == "1" ]] ||
    die "VERBOSE must be 0 or 1"

[[ "$TRACK" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number track directory (current: $ROOT)"
for frame in F1 F2 F3; do
    [[ -d "$frame" ]] || die "missing frame directory: $ROOT/$frame"
done
[[ -d merge ]] || die "missing merge directory: $ROOT/merge"

file_bytes() {
    local path="$1"
    if [[ -L "$path" ]]; then
        stat -c '%s' -- "$path" 2>/dev/null || printf '0\n'
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

directory_bytes() {
    # Use allocated disk usage so the formal-run difference reflects the
    # storage space actually reclaimed from this track directory.
    du -sk -- "$ROOT" 2>/dev/null | awk 'NR == 1 {print $1 * 1024; exit}'
}

mib_value() {
    awk -v bytes="$1" 'BEGIN {printf "%.2f", bytes / 1048576}'
}

add_count() {
    local category="$1" bytes="$2"
    case "$category" in
        FRAME) FRAME_FILES=$((FRAME_FILES+1)); FRAME_BYTES=$((FRAME_BYTES+bytes)) ;;
        RAW) RAW_FILES=$((RAW_FILES+1)); RAW_BYTES=$((RAW_BYTES+bytes)) ;;
        MERGE) MERGE_FILES=$((MERGE_FILES+1)); MERGE_BYTES=$((MERGE_BYTES+bytes)) ;;
        ROOT) ROOT_FILES=$((ROOT_FILES+1)); ROOT_BYTES=$((ROOT_BYTES+bytes)) ;;
        *) die "internal unknown cleanup category: $category" ;;
    esac
}

process_file() {
    local category="$1" path="$2" bytes
    [[ -f "$path" || -L "$path" ]] || return 0
    if [[ -d "$path" ]]; then
        verbose_printf '[SKIP DIR] %s\n' "$path"
        return 0
    fi
    bytes="$(file_bytes "$path")"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    add_count "$category" "$bytes"
    if [[ "$MODE" == "DELETE" ]]; then
        rm -f -- "$path"
        verbose_printf '[DEL %-5s] %s\n' "$category" "$path"
    else
        verbose_printf '[DRY %-5s] %s\n' "$category" "$path"
    fi
}

clean_frame_interferograms() {
    local frame pair_dir pattern candidate
    printf '\n========== F1/F2/F3 intf_all cleanup types =========='
    printf '\n  %s' "${FRAME_PATTERNS[@]}"
    printf '\n'
    for frame in F1 F2 F3; do
        printf '[SCAN] %s/intf_all\n' "$frame"
        if [[ ! -d "$frame/intf_all" ]]; then
            printf '[SKIP] Directory not found: %s/intf_all\n' "$frame"
            continue
        fi
        while IFS= read -r -d '' pair_dir; do
            for pattern in "${FRAME_PATTERNS[@]}"; do
                shopt -s nullglob
                for candidate in "$pair_dir"/$pattern; do process_file FRAME "$candidate"; done
                shopt -u nullglob
            done
        done < <(find "$frame/intf_all" -mindepth 1 -maxdepth 1 \
            -type d -name '20*_*' -print0 | sort -z)
    done
}

clean_non_all_raw() {
    local frame raw_dir slc name stem satellite date third remainder
    local all_stem extension candidate valid
    printf '\n========== F1/F2/F3 raw cleanup types ==========\n'
    printf '  non-ALL *.SLC\n  matching non-ALL *.PRM\n  matching non-ALL *.LED\n'
    for frame in F1 F2 F3; do
        raw_dir="$frame/raw"
        printf '[SCAN] %s\n' "$raw_dir"
        [[ -d "$raw_dir" ]] || { printf '[SKIP] Directory not found: %s\n' "$raw_dir"; continue; }
        while IFS= read -r -d '' slc; do
            name="$(basename -- "$slc")"; stem="${name%.SLC}"
            IFS=_ read -r satellite date third remainder <<< "$stem"
            [[ "$third" != "ALL" ]] || continue
            if [[ "$satellite" != "S1" || ! "$date" =~ ^[0-9]{8}$ ]]; then
                verbose_printf '[SKIP RAW] Unrecognized SLC name: %s\n' "$slc"
                SKIPPED_RAW=$((SKIPPED_RAW+1)); continue
            fi
            all_stem="$raw_dir/S1_${date}_ALL_${frame}"; valid=1
            for extension in SLC PRM LED; do [[ -s "${all_stem}.${extension}" ]] || valid=0; done
            if (( valid == 0 )); then
                verbose_printf '[SKIP RAW] Matching ALL SLC/PRM/LED incomplete for %s\n' "$slc"
                SKIPPED_RAW=$((SKIPPED_RAW+1)); continue
            fi
            process_file RAW "$slc"
            for extension in PRM LED; do
                candidate="$raw_dir/${stem}.${extension}"; process_file RAW "$candidate"
            done
        done < <(find "$raw_dir" -mindepth 1 -maxdepth 1 \
            \( -type f -o -type l \) -name '*.SLC' -print0 | sort -z)
    done
}

clean_merge_pairs() {
    local pair_dir final_grid name candidate
    printf '\n========== merge/20*_20* cleanup types =========='
    printf '\n  %s' "${MERGE_FILES_TO_DELETE[@]}"
    printf '\n[SCAN] merge/20*_20*\n'
    while IFS= read -r -d '' pair_dir; do
        final_grid="$pair_dir/unwrap_dem_correct_pin_up.grd"
        if [[ ! -s "$final_grid" ]]; then
            verbose_printf '[SKIP MERGE] Final grid missing or empty: %s\n' "$final_grid"
            SKIPPED_MERGE=$((SKIPPED_MERGE+1)); continue
        fi
        for name in "${MERGE_FILES_TO_DELETE[@]}"; do
            candidate="$pair_dir/$name"; process_file MERGE "$candidate"
        done
    done < <(find merge -mindepth 1 -maxdepth 1 \
        -type d -name '20*_*' -print0 | sort -z)
}

check_running_pid_files() {
    local pid_file pid
    local -a pid_files=(merge/unwrap_parallel.pid merge/merge_batch.pid sbas_demcorr_pin/run4.3_sbas_parallel.pid)
    for pid_file in "${pid_files[@]}"; do
        [[ -s "$pid_file" ]] || continue
        pid="$(awk 'NR==1{print $1}' "$pid_file")"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            die "active processing PID $pid found in $pid_file; cleanup refused"
        fi
    done
}

print_summary() {
    local total_files total_bytes track_before track_after actual_freed
    total_files=$((FRAME_FILES+RAW_FILES+MERGE_FILES+ROOT_FILES))
    total_bytes=$((FRAME_BYTES+RAW_BYTES+MERGE_BYTES+ROOT_BYTES))
    track_before="$SIZE_BEFORE"
    track_after="$(directory_bytes)"
    if [[ "$MODE" == "DELETE" ]]; then
        actual_freed=$((track_before-track_after))
        if (( actual_freed < 0 )); then actual_freed=0; fi
    else
        actual_freed=0
    fi
    printf '\n%s\n' '========================================'
    printf 'Run 7.1 cleanup summary\nMode: %s\n' "$MODE"
    printf 'F?/intf_all intermediate     : %8d files  %s\n' "$FRAME_FILES" "$(human_bytes "$FRAME_BYTES")"
    printf 'Validated non-ALL raw        : %8d files  %s\n' "$RAW_FILES" "$(human_bytes "$RAW_BYTES")"
    printf 'merge pair temporary         : %8d files  %s\n' "$MERGE_FILES" "$(human_bytes "$MERGE_BYTES")"
    printf 'Track-root temporary         : %8d files  %s\n' "$ROOT_FILES" "$(human_bytes "$ROOT_BYTES")"
    printf 'TOTAL                        : %8d files  %s\n' "$total_files" "$(human_bytes "$total_bytes")"
    printf 'Track size before            : %s (%s MiB)\n' "$(human_bytes "$track_before")" "$(mib_value "$track_before")"
    printf 'Track size after             : %s (%s MiB)\n' "$(human_bytes "$track_after")" "$(mib_value "$track_after")"
    printf 'Estimated file release       : %s (%s MiB)\n' "$(human_bytes "$total_bytes")" "$(mib_value "$total_bytes")"
    printf 'Actual disk space released   : %s (%s MiB)\n' "$(human_bytes "$actual_freed")" "$(mib_value "$actual_freed")"
    printf 'Skipped non-ALL SLC          : %d\n' "$SKIPPED_RAW"
    printf 'Skipped incomplete merge pair: %d\n' "$SKIPPED_MERGE"
    printf '%s\n' '========================================'
    if [[ "$MODE" == "PREVIEW" ]]; then
        printf '[CHECK ONLY] Nothing was deleted or modified.\n'
        printf '[NEXT] Review the cleanup summary, then run:\n  ./run7.1_cleanup_F1F2F3_merge_intermediate_files.sh 1\n'
    else
        printf '[DONE] Formal cleanup completed.\n'
    fi
}

printf '%s\n' '========================================'
printf 'Run 7.1: clean F1/F2/F3 and merge intermediate files\n'
printf 'Mode       : %s\nTrack root : %s\nTrack      : %s\nVerbose    : %s\n' "$MODE" "$ROOT" "$TRACK" "$VERBOSE"
SIZE_BEFORE="$(directory_bytes)"
[[ "$SIZE_BEFORE" =~ ^[0-9]+$ ]] || die "cannot determine track directory size"
printf 'Track size before : %s (%s MiB)\n' "$(human_bytes "$SIZE_BEFORE")" "$(mib_value "$SIZE_BEFORE")"
printf '%s\n' '========================================'

[[ "$MODE" == "PREVIEW" ]] || check_running_pid_files
clean_frame_interferograms
clean_non_all_raw
clean_merge_pairs
printf '\n========== Track-root cleanup types ==========\n'
printf '  gmt.history\n'
printf '[SCAN] Track root\n'
process_file ROOT gmt.history
print_summary
