#!/usr/bin/env bash
# Run 3.3: select and confirm an interferogram network for one burst stack.

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
Run 3.3: select the burst interferogram network

Usage:
  ./run3.3_make_intf_config_burst.sh
  ./run3.3_make_intf_config_burst.sh 1 [TIME_DAYS] [BASELINE_METERS]
  ./run3.3_make_intf_config_burst.sh 2

No arguments:
  Show this guide only. No pair selection is started.

Mode 1 - preview/select pairs:
  1. Copy Run 3.1/3.2 data.in and baseline_table.dat into burst/.
  2. Set master_image from the first record of burst/raw/data.in.
  3. Run select_pairs_regular.csh and generate the pair-network PDF.
  4. Validate pair format, product suffix, duplicate/self pairs and PRM dates.

  Defaults:
    TIME_DAYS       = 60 days
    BASELINE_METERS = 150 m

Mode 2 - finalize:
  Accept and revalidate the latest Mode 1 result. Before Mode 2, you may
  manually delete unwanted lines from burst/intf.in. New or modified pairs
  that were not selected in Mode 1 are rejected.
  Mode 2 does not rerun pair selection.

Recommended workflow:
  ./run3.3_make_intf_config_burst.sh 1 60 150
  # Inspect burst/baseline.pdf. Change thresholds and rerun Mode 1 if needed.
  # Optionally delete unwanted lines from burst/intf.in (do not add new ones).
  ./run3.3_make_intf_config_burst.sh 2

Main outputs:
  burst/intf.in
  burst/intf.in.preview          (unaltered Mode 1 snapshot)
  burst/batch_tops.config
  burst/baseline.pdf
  burst/select_pairs_regular.log
  burst/run3.3_preview.info
  burst/run3.3_finalized.info    (after Mode 2)

Override external files if needed:
  CONFIG_SRC=/path/batch_tops.config \
  SELECT_SCRIPT=/path/select_pairs_regular.csh \
  ./run3.3_make_intf_config_burst.sh 1 60 150
========================================
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
if (( $# == 0 )); then
    usage
    printf '[INFO] No pair selection was started.\n'
    exit 0
fi

MODE="$1"
[[ "$MODE" == 1 || "$MODE" == 2 ]] || die "MODE must be 1 (preview) or 2 (finalize)"

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "$ROOT_DIR")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT_DIR)"

UNIT_DIR="$ROOT_DIR/burst"
RAW_DIR="$UNIT_DIR/raw"
SWATH_FILE="$UNIT_DIR/burst_swath.txt"
PREVIEW_INFO="$UNIT_DIR/run3.3_preview.info"
FINAL_INFO="$UNIT_DIR/run3.3_finalized.info"
CONFIG_SRC="${CONFIG_SRC:-/home/xinw/bin/own/batch_tops.config}"
SELECT_SCRIPT="${SELECT_SCRIPT:-/home/xinw/bin/own/select_pairs_regular.csh}"

[[ -d "$UNIT_DIR" ]] || die "missing $UNIT_DIR; complete Run 2.3 first"
[[ -d "$RAW_DIR" ]] || die "missing $RAW_DIR; complete Run 2.3 first"
[[ -s "$SWATH_FILE" ]] || die "missing $SWATH_FILE; complete Run 2.3 first"
SWATH="$(tr -d '[:space:]' < "$SWATH_FILE" | tr '[:lower:]' '[:upper:]')"
[[ "$SWATH" =~ ^IW([123])$ ]] || die "invalid subswath in $SWATH_FILE: $SWATH"
PRODUCT_SUFFIX="F${BASH_REMATCH[1]}"

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

info_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' \
        "$PREVIEW_INFO"
}

extract_master_date() {
    local data_file="$1"
    local token
    token="$(
        head -n 1 "$data_file" |
            grep -oE '[0-9]{8}[tT][0-9]{6}' |
            head -n 1 || true
    )"
    [[ "$token" =~ ^[0-9]{8}[tT][0-9]{6}$ ]] ||
        die "failed to extract master date from the first line of $data_file"
    printf '%s\n' "${token:0:8}"
}

validate_pair_list() {
    local pair_file="$1"
    local expected_count="$2"
    local pair_count=0
    local duplicate_count
    local line left right left_date right_date
    local malformed=0 missing_prm=0 self_pair=0

    [[ -s "$pair_file" ]] || die "pair list missing or empty: $pair_file"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        IFS=: read -r left right extra <<< "$line"
        if [[ -n "${extra:-}" ||
              ! "$left" =~ ^S1_([0-9]{8})_ALL_${PRODUCT_SUFFIX}$ ||
              ! "$right" =~ ^S1_([0-9]{8})_ALL_${PRODUCT_SUFFIX}$ ]]; then
            printf '[BAD PAIR] %s\n' "$line" >&2
            malformed=$((malformed + 1))
            continue
        fi
        left_date="${left:3:8}"
        right_date="${right:3:8}"
        if [[ "$left" == "$right" ]]; then
            printf '[SELF PAIR] %s\n' "$line" >&2
            self_pair=$((self_pair + 1))
        fi
        if [[ ! -s "$RAW_DIR/S1_${left_date}_ALL_${PRODUCT_SUFFIX}.PRM" ]]; then
            printf '[MISSING PRM] %s\n' "$RAW_DIR/S1_${left_date}_ALL_${PRODUCT_SUFFIX}.PRM" >&2
            missing_prm=$((missing_prm + 1))
        fi
        if [[ ! -s "$RAW_DIR/S1_${right_date}_ALL_${PRODUCT_SUFFIX}.PRM" ]]; then
            printf '[MISSING PRM] %s\n' "$RAW_DIR/S1_${right_date}_ALL_${PRODUCT_SUFFIX}.PRM" >&2
            missing_prm=$((missing_prm + 1))
        fi
        pair_count=$((pair_count + 1))
    done < "$pair_file"

    (( malformed == 0 )) || die "$pair_file contains $malformed malformed pair(s)"
    (( self_pair == 0 )) || die "$pair_file contains $self_pair self pair(s)"
    (( missing_prm == 0 )) || die "$pair_file references $missing_prm unavailable PRM endpoint(s)"
    (( pair_count > 0 )) || die "$pair_file contains no interferogram pairs"
    if [[ "$expected_count" != 0 ]]; then
        [[ "$pair_count" -eq "$expected_count" ]] ||
            die "pair count changed: current=$pair_count, preview=$expected_count"
    fi
    duplicate_count="$(
        awk 'NF && $0 !~ /^[[:space:]]*#/ {print}' "$pair_file" |
            sort | uniq -d | wc -l | awk '{print $1}'
    )"
    (( duplicate_count == 0 )) || die "$pair_file contains $duplicate_count duplicate pair(s)"
    printf '%s\n' "$pair_count"
}

if [[ "$MODE" == 1 ]]; then
    (( $# <= 3 )) ||
        die "mode 1 usage: ./run3.3_make_intf_config_burst.sh 1 [TIME_DAYS] [BASELINE_METERS]"
    THRESHOLD_TIME="${2:-60}"
    THRESHOLD_BASELINE="${3:-150}"
    is_number "$THRESHOLD_TIME" || die "TIME_DAYS must be a non-negative number"
    is_number "$THRESHOLD_BASELINE" || die "BASELINE_METERS must be a non-negative number"

    for command_name in awk cp grep head sed sort tcsh tee uniq wc; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "required command not found: $command_name"
    done
    [[ -s "$RAW_DIR/data.in" ]] || die "missing $RAW_DIR/data.in; complete Run 3.1 first"
    [[ -s "$RAW_DIR/baseline_table.dat" ]] ||
        die "missing $RAW_DIR/baseline_table.dat; complete Run 3.2 first"
    [[ -f "$CONFIG_SRC" ]] || die "configuration template not found: $CONFIG_SRC"
    [[ -f "$SELECT_SCRIPT" ]] || die "pair-selection script not found: $SELECT_SCRIPT"

    DATA_COUNT="$(wc -l < "$RAW_DIR/data.in" | awk '{print $1}')"
    BASELINE_COUNT="$(wc -l < "$RAW_DIR/baseline_table.dat" | awk '{print $1}')"
    (( DATA_COUNT >= 2 )) || die "$RAW_DIR/data.in requires at least two records"
    [[ "$BASELINE_COUNT" -eq "$DATA_COUNT" ]] ||
        die "baseline/data.in count mismatch: $BASELINE_COUNT/$DATA_COUNT"
    MASTER_DATE="$(extract_master_date "$RAW_DIR/data.in")"
    MASTER_IMAGE="S1_${MASTER_DATE}_ALL_${PRODUCT_SUFFIX}"
    [[ -s "$RAW_DIR/${MASTER_IMAGE}.PRM" ]] ||
        die "master PRM missing: $RAW_DIR/${MASTER_IMAGE}.PRM"

    printf '%s\n' '========================================'
    printf 'Run 3.3 mode 1: preview burst pair network\n'
    printf 'Track root       : %s\n' "$ROOT_DIR"
    printf 'Burst unit       : %s\n' "$UNIT_DIR"
    printf 'Detected swath   : %s -> %s\n' "$SWATH" "$PRODUCT_SUFFIX"
    printf 'Acquisitions     : %s\n' "$DATA_COUNT"
    printf 'Master image     : %s\n' "$MASTER_IMAGE"
    printf 'Time threshold   : %s days\n' "$THRESHOLD_TIME"
    printf 'Spatial baseline : %s m\n' "$THRESHOLD_BASELINE"
    printf 'Pair selector    : %s\n' "$SELECT_SCRIPT"
    printf 'Preview PDF      : %s/baseline.pdf\n' "$UNIT_DIR"
    printf '%s\n' '========================================'

    cp -- "$RAW_DIR/data.in" "$UNIT_DIR/data.in"
    cp -- "$RAW_DIR/baseline_table.dat" "$UNIT_DIR/baseline_table.dat"
    cp -- "$CONFIG_SRC" "$UNIT_DIR/batch_tops.config"

    if grep -qE '^[[:space:]]*master_image[[:space:]]*=' "$UNIT_DIR/batch_tops.config"; then
        sed -i.bak -E \
            "s|^[[:space:]]*master_image[[:space:]]*=.*|master_image = ${MASTER_IMAGE}|" \
            "$UNIT_DIR/batch_tops.config"
    else
        cp -- "$UNIT_DIR/batch_tops.config" "$UNIT_DIR/batch_tops.config.bak"
        printf 'master_image = %s\n' "$MASTER_IMAGE" >> "$UNIT_DIR/batch_tops.config"
    fi
    grep -qE \
        "^[[:space:]]*master_image[[:space:]]*=[[:space:]]*${MASTER_IMAGE}[[:space:]]*$" \
        "$UNIT_DIR/batch_tops.config" || die "failed to set master_image in batch_tops.config"

    rm -f -- \
        "$UNIT_DIR/intf.in" \
        "$UNIT_DIR/intf.in.preview" \
        "$UNIT_DIR/baseline.ps" \
        "$UNIT_DIR/baseline.jpg" \
        "$UNIT_DIR/baseline.jpeg" \
        "$UNIT_DIR/baseline.pdf" \
        "$UNIT_DIR/tmp" \
        "$UNIT_DIR/select_pairs_new.log" \
        "$UNIT_DIR/select_pairs_regular.log" \
        "$UNIT_DIR/run3.3_removed_pairs.txt" \
        "$PREVIEW_INFO" \
        "$FINAL_INFO"

    printf '[RUN] tcsh %s baseline_table.dat %s %s\n' \
        "$SELECT_SCRIPT" "$THRESHOLD_TIME" "$THRESHOLD_BASELINE"
    (
        cd -- "$UNIT_DIR"
        tcsh "$SELECT_SCRIPT" baseline_table.dat \
            "$THRESHOLD_TIME" "$THRESHOLD_BASELINE" \
            2>&1 | tee select_pairs_regular.log
    )

    [[ -s "$UNIT_DIR/intf.in" ]] || die "intf.in was not generated or is empty"
    [[ -s "$UNIT_DIR/baseline.ps" ]] || die "baseline.ps was not generated or is empty"
    if [[ ! -s "$UNIT_DIR/baseline.pdf" ]]; then
        command -v gmt >/dev/null 2>&1 ||
            die "baseline.pdf was not generated and GMT is unavailable for conversion"
        printf '[PDF] Convert baseline.ps with GMT psconvert\n'
        (cd -- "$UNIT_DIR" && gmt psconvert baseline.ps -Tf -A)
    fi
    [[ -s "$UNIT_DIR/baseline.pdf" ]] || die "baseline.pdf was not generated"

    PAIR_COUNT="$(validate_pair_list "$UNIT_DIR/intf.in" 0)"
    cp -- "$UNIT_DIR/intf.in" "$UNIT_DIR/intf.in.preview"
    {
        printf 'threshold_time=%s\n' "$THRESHOLD_TIME"
        printf 'threshold_baseline=%s\n' "$THRESHOLD_BASELINE"
        printf 'master_date=%s\n' "$MASTER_DATE"
        printf 'master_image=%s\n' "$MASTER_IMAGE"
        printf 'swath=%s\n' "$SWATH"
        printf 'product_suffix=%s\n' "$PRODUCT_SUFFIX"
        printf 'data_count=%s\n' "$DATA_COUNT"
        printf 'pair_count=%s\n' "$PAIR_COUNT"
        printf 'plot=burst/baseline.pdf\n'
    } > "$PREVIEW_INFO"

    printf '\n%s\n' '========================================'
    printf '[PREVIEW DONE] Selected pairs: %s\n' "$PAIR_COUNT"
    printf '[MASTER IMAGE] %s\n' "$MASTER_IMAGE"
    printf '[PAIR LIST] %s/intf.in\n' "$UNIT_DIR"
    printf '[PAIR SNAPSHOT] %s/intf.in.preview\n' "$UNIT_DIR"
    printf '[PREVIEW PDF] %s/baseline.pdf\n' "$UNIT_DIR"
    printf '[CONFIG] %s/batch_tops.config\n' "$UNIT_DIR"
    printf '[NEXT] Inspect the PDF. If accepted, run:\n'
    printf '       ./run3.3_make_intf_config_burst.sh 2\n'
    printf '%s\n' '========================================'
    exit 0
fi

(( $# == 1 )) || die "mode 2 takes no threshold arguments"
for command_name in awk cp grep wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done
[[ -s "$PREVIEW_INFO" ]] || die "missing $PREVIEW_INFO; run Mode 1 first"
[[ -s "$UNIT_DIR/intf.in" ]] || die "missing burst/intf.in; rerun Mode 1"
[[ -s "$UNIT_DIR/intf.in.preview" ]] || die "missing intf.in.preview; rerun Mode 1"
[[ -s "$UNIT_DIR/batch_tops.config" ]] || die "missing batch_tops.config; rerun Mode 1"
[[ -s "$UNIT_DIR/baseline.pdf" ]] || die "missing baseline.pdf; rerun Mode 1"

PREVIEW_TIME="$(info_value threshold_time)"
PREVIEW_BASELINE="$(info_value threshold_baseline)"
PREVIEW_MASTER_DATE="$(info_value master_date)"
PREVIEW_MASTER="$(info_value master_image)"
PREVIEW_SWATH="$(info_value swath)"
PREVIEW_SUFFIX="$(info_value product_suffix)"
PREVIEW_DATA_COUNT="$(info_value data_count)"
PREVIEW_PAIR_COUNT="$(info_value pair_count)"

[[ "$PREVIEW_SWATH" == "$SWATH" && "$PREVIEW_SUFFIX" == "$PRODUCT_SUFFIX" ]] ||
    die "burst swath changed after preview; rerun Mode 1"
[[ "$PREVIEW_MASTER_DATE" =~ ^[0-9]{8}$ ]] || die "invalid preview master date"
[[ "$PREVIEW_MASTER" == "S1_${PREVIEW_MASTER_DATE}_ALL_${PRODUCT_SUFFIX}" ]] ||
    die "invalid preview master image: $PREVIEW_MASTER"
[[ "$PREVIEW_DATA_COUNT" =~ ^[1-9][0-9]*$ ]] || die "invalid preview data count"
[[ "$PREVIEW_PAIR_COUNT" =~ ^[1-9][0-9]*$ ]] || die "invalid preview pair count"
[[ "$(wc -l < "$RAW_DIR/data.in" | awk '{print $1}')" -eq "$PREVIEW_DATA_COUNT" ]] ||
    die "raw data.in count changed after preview; rerun Mode 1"
CURRENT_MASTER_DATE="$(extract_master_date "$RAW_DIR/data.in")"
[[ "$CURRENT_MASTER_DATE" == "$PREVIEW_MASTER_DATE" ]] ||
    die "master date changed after preview; rerun Mode 1"
grep -qE \
    "^[[:space:]]*master_image[[:space:]]*=[[:space:]]*${PREVIEW_MASTER}[[:space:]]*$" \
    "$UNIT_DIR/batch_tops.config" || die "batch_tops.config changed after preview"

SNAPSHOT_PAIR_COUNT="$(validate_pair_list "$UNIT_DIR/intf.in.preview" "$PREVIEW_PAIR_COUNT")"
CURRENT_PAIR_COUNT="$(validate_pair_list "$UNIT_DIR/intf.in" 0)"
(( CURRENT_PAIR_COUNT <= SNAPSHOT_PAIR_COUNT )) ||
    die "current intf.in has more pairs than the Mode 1 preview"

UNSELECTED_PAIR="$(
    awk '
        NR == FNR {
            if (NF && $0 !~ /^[[:space:]]*#/) preview[$0] = 1
            next
        }
        NF && $0 !~ /^[[:space:]]*#/ && !($0 in preview) {print; exit}
    ' "$UNIT_DIR/intf.in.preview" "$UNIT_DIR/intf.in"
)"
[[ -z "$UNSELECTED_PAIR" ]] ||
    die "intf.in contains a pair not present in the Mode 1 preview: $UNSELECTED_PAIR"

REMOVED_LIST="$UNIT_DIR/run3.3_removed_pairs.txt"
awk '
    NR == FNR {
        if (NF && $0 !~ /^[[:space:]]*#/) accepted[$0] = 1
        next
    }
    NF && $0 !~ /^[[:space:]]*#/ && !($0 in accepted) {print}
' "$UNIT_DIR/intf.in" "$UNIT_DIR/intf.in.preview" > "$REMOVED_LIST"
REMOVED_PAIR_COUNT="$(wc -l < "$REMOVED_LIST" | awk '{print $1}')"
[[ $((CURRENT_PAIR_COUNT + REMOVED_PAIR_COUNT)) -eq "$SNAPSHOT_PAIR_COUNT" ]] ||
    die "accepted/removed pair accounting does not match the Mode 1 snapshot"
{
    cat "$PREVIEW_INFO"
    printf 'status=FINALIZED\n'
    printf 'accepted_pair_count=%s\n' "$CURRENT_PAIR_COUNT"
    printf 'removed_pair_count=%s\n' "$REMOVED_PAIR_COUNT"
    printf 'accepted_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
} > "$FINAL_INFO"

printf '%s\n' '========================================'
printf 'Run 3.3 mode 2: burst pair network accepted\n'
printf 'Track root       : %s\n' "$ROOT_DIR"
printf 'Detected swath   : %s -> %s\n' "$SWATH" "$PRODUCT_SUFFIX"
printf 'Master image     : %s\n' "$PREVIEW_MASTER"
printf 'Acquisitions     : %s\n' "$PREVIEW_DATA_COUNT"
printf 'Accepted pairs   : %s\n' "$CURRENT_PAIR_COUNT"
printf 'Manually removed : %s\n' "$REMOVED_PAIR_COUNT"
printf 'Time threshold   : %s days\n' "$PREVIEW_TIME"
printf 'Spatial baseline : %s m\n' "$PREVIEW_BASELINE"
printf 'Preview PDF      : %s/baseline.pdf\n' "$UNIT_DIR"
printf 'Removed list     : %s\n' "$REMOVED_LIST"
printf '[DONE] Final record: %s\n' "$FINAL_INFO"
printf '%s\n' '========================================'
