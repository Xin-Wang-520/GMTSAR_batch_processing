#!/usr/bin/env bash
# Run 3.9: crop corr.grd in place to the final burst unwrap grid.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 3.9: crop corr.grd to burst unwrap.grd (in-place replacement)

Usage:
  ./run3.9_match_corr_to_unwrap_burst.sh
  ./run3.9_match_corr_to_unwrap_burst.sh 0 [JOBS] [PREVIEW_PAIRS]
  ./run3.9_match_corr_to_unwrap_burst.sh 1 [JOBS]

No arguments or mode 0:
  Sample finalized corr.grd and unwrap.grd geometries.
  PREVIEW_PAIRS defaults to 5 and samples across the full pair list.
  No grid is generated or replaced.

Mode 1:
  Crop and replace for every finalized pair:
    burst/intf_all/<pair>/corr.grd

Rules:
  - Same geometry: leave corr.grd unchanged.
  - Same increments/registration, smaller unwrap extent: use gmt grdcut.
  - Different increments or registration: stop; do not interpolate.
  - Validate every replaced corr.grd against its unwrap.grd afterward.
  - JOBS defaults to 20; processing is parallel between pairs.

WARNING:
  The original full-grid corr.grd is replaced without a backup.
  unwrap.grd is never modified.

Run-level outputs:
  burst/run3.9_corr_alignment.tsv
  burst/run3.9_failed_pairs.tsv       (only when failures occur)
  burst/run3.9_complete
========================================
EOF
}

grid_signature() {
    gmt grdinfo "$1" -C | awk 'NR==1 {
        print $2, $3, $4, $5, $8, $9, $10, $11, $12
    }'
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
(( $# <= 3 )) || die "usage: $0 0 [JOBS] [PREVIEW_PAIRS], or $0 1 [JOBS]"
MODE="${1:-0}"
JOBS="${2:-20}"
PREVIEW_PAIRS="${3:-5}"
[[ "$MODE" == 0 || "$MODE" == 1 ]] || die "MODE must be 0 (check) or 1 (formal)"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
[[ "$PREVIEW_PAIRS" =~ ^[1-9][0-9]*$ ]] || die "PREVIEW_PAIRS must be a positive integer"
if [[ "$MODE" == 1 && $# -gt 2 ]]; then
    die "mode 1 usage: $0 1 [JOBS]"
fi

for command_name in awk basename date gmt head mktemp mv sort tr uniq wc xargs; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT)"

BURST_DIR="$ROOT/burst"
PAIR_ROOT="$BURST_DIR/intf_all"
EXPECTED_FILE="$BURST_DIR/run3.5_expected_pairs.tsv"
FINAL_INFO="$BURST_DIR/run3.3_finalized.info"
RUN35_FAILED="$BURST_DIR/run3.5_failed_pairs.tsv"
RUN38_FAILED="$BURST_DIR/run3.8_failed_pairs.tsv"
RUN38_PID="$BURST_DIR/run3.8_unwrap.pid"
REPORT="$BURST_DIR/run3.9_corr_alignment.tsv"
FAILED_REPORT="$BURST_DIR/run3.9_failed_pairs.tsv"
COMPLETE_FILE="$BURST_DIR/run3.9_complete"

[[ -d "$PAIR_ROOT" ]] || die "missing $PAIR_ROOT; complete Run 3.5 first"
[[ -s "$EXPECTED_FILE" ]] || die "missing $EXPECTED_FILE"
[[ -s "$FINAL_INFO" ]] || die "missing $FINAL_INFO"
[[ ! -s "$RUN35_FAILED" ]] || die "Run 3.5 failure report is not empty"
[[ ! -s "$RUN38_FAILED" ]] || die "Run 3.8 failure report is not empty"

if [[ -s "$RUN38_PID" ]]; then
    RUN38_PROCESS="$(awk 'NR==1 {print $1; exit}' "$RUN38_PID")"
    if [[ "$RUN38_PROCESS" =~ ^[1-9][0-9]*$ ]] && kill -0 "$RUN38_PROCESS" 2>/dev/null; then
        die "Run 3.8 is still running (PID $RUN38_PROCESS); wait for it to finish"
    fi
fi

FINAL_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$FINAL_INFO")"
ACCEPTED_PAIRS="$(awk -F= '$1=="accepted_pair_count" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_STATUS" == FINALIZED ]] || die "Run 3.3 status is not FINALIZED"
[[ "$ACCEPTED_PAIRS" =~ ^[1-9][0-9]*$ ]] || die "invalid accepted_pair_count"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run3.9-burst.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT INT TERM
PAIR_LIST="$TMP/pairs.txt"
INPUT_REPORT="$TMP/input.tsv"
INPUT_FAILURES="$TMP/input_failures.tsv"
: > "$PAIR_LIST"
printf 'pair\tmethod\tcorr_signature\tunwrap_signature\n' > "$INPUT_REPORT"
printf 'pair\tproblem\n' > "$INPUT_FAILURES"

while IFS=$'\t' read -r source_pair pair pair_log extra; do
    [[ -n "$source_pair" && -n "$pair" && -n "$pair_log" && -z "${extra:-}" ]] ||
        die "invalid Run 3.5 manifest record: ${source_pair:-empty}"
    [[ "$pair" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] ||
        die "invalid pair directory: $pair"
    printf '%s\n' "$pair" >> "$PAIR_LIST"
done < "$EXPECTED_FILE"
sort -u -o "$PAIR_LIST" "$PAIR_LIST"
PAIR_COUNT="$(wc -l < "$PAIR_LIST" | tr -d ' ')"
[[ "$PAIR_COUNT" -eq "$ACCEPTED_PAIRS" ]] ||
    die "Run 3.5 pair count=$PAIR_COUNT, accepted count=$ACCEPTED_PAIRS"

ACTIVE_PAIR_LIST="$PAIR_LIST"
if [[ "$MODE" == 0 && "$PREVIEW_PAIRS" -lt "$PAIR_COUNT" ]]; then
    ACTIVE_PAIR_LIST="$TMP/preview_pairs.txt"
    awk -v n="$PREVIEW_PAIRS" '
        { line[NR]=$0 }
        END {
            if (n == 1) {
                print line[int((NR + 1) / 2)]
            } else {
                last=0
                for (i=0; i<n; i++) {
                    idx=int(1 + i * (NR - 1) / (n - 1) + 0.5)
                    if (idx != last) print line[idx]
                    last=idx
                }
            }
        }
    ' "$PAIR_LIST" > "$ACTIVE_PAIR_LIST"
fi
INSPECT_PAIR_COUNT="$(wc -l < "$ACTIVE_PAIR_LIST" | tr -d ' ')"

UNCHANGED_COUNT=0
CUT_COUNT=0
COMMON_UNWRAP_SIGNATURE=''

# Inspect independent pairs concurrently.  Each worker writes its own result
# file, so no two processes append to the same report.
INSPECT_STATUS="$TMP/inspect_status"
INSPECT_WORKER="$TMP/inspect_one.sh"
mkdir -p "$INSPECT_STATUS"
cat > "$INSPECT_WORKER" <<'INSPECT_EOF'
#!/usr/bin/env bash
set -u
pair_root="$1"
status_dir="$2"
pair="$3"
pair_dir="$pair_root/$pair"
corr="$pair_dir/corr.grd"
unwrap="$pair_dir/unwrap.grd"
result="$status_dir/$pair.tsv"
grid_signature() {
    gmt grdinfo "$1" -C 2>/dev/null | awk 'NR==1 {
        print $2, $3, $4, $5, $8, $9, $10, $11, $12
    }'
}
if [[ ! -s "$corr" || ! -s "$unwrap" ]]; then
    problem=''
    [[ -s "$corr" ]] || problem='corr.grd'
    if [[ ! -s "$unwrap" ]]; then
        [[ -z "$problem" ]] || problem+=','
        problem+='unwrap.grd'
    fi
    printf 'FAIL\tmissing:%s\n' "$problem" > "$result"
    exit 0
fi
corr_sig="$(grid_signature "$corr")"
unwrap_sig="$(grid_signature "$unwrap")"
if [[ -z "$corr_sig" || -z "$unwrap_sig" ]]; then
    printf 'FAIL\tfailed_to_read_grid_signature\n' > "$result"
    exit 0
fi
read -r cx0 cx1 cy0 cy1 cdx cdy cnx cny creg <<< "$corr_sig"
read -r ux0 ux1 uy0 uy1 udx udy unx uny ureg <<< "$unwrap_sig"
if ! awk -v cx0="$cx0" -v cx1="$cx1" -v cy0="$cy0" -v cy1="$cy1" \
    -v ux0="$ux0" -v ux1="$ux1" -v uy0="$uy0" -v uy1="$uy1" \
    'BEGIN {exit !(ux0 >= cx0 && ux1 <= cx1 && uy0 >= cy0 && uy1 <= cy1)}'; then
    printf 'FAIL\tunwrap_extent_outside_corr_extent\n' > "$result"
elif [[ "$corr_sig" == "$unwrap_sig" ]]; then
    printf 'OK\tunchanged\t%s\t%s\n' "$corr_sig" "$unwrap_sig" > "$result"
elif [[ "$cdx" == "$udx" && "$cdy" == "$udy" && "$creg" == "$ureg" ]]; then
    printf 'OK\tgrdcut\t%s\t%s\n' "$corr_sig" "$unwrap_sig" > "$result"
else
    printf 'FAIL\tincrements_or_registration_differ\n' > "$result"
fi
INSPECT_EOF
chmod +x "$INSPECT_WORKER"

xargs -P "$JOBS" -n 1 "$INSPECT_WORKER" "$PAIR_ROOT" "$INSPECT_STATUS" \
    < "$ACTIVE_PAIR_LIST"

while IFS= read -r pair; do
    result="$INSPECT_STATUS/$pair.tsv"
    if [[ ! -s "$result" ]]; then
        printf '%s\tinspection_worker_produced_no_result\n' "$pair" >> "$INPUT_FAILURES"
        continue
    fi
    IFS=$'\t' read -r state field2 corr_sig unwrap_sig extra < "$result"
    if [[ "$state" != OK ]]; then
        printf '%s\t%s\n' "$pair" "${field2:-unknown_inspection_failure}" \
            >> "$INPUT_FAILURES"
        continue
    fi
    method="$field2"
    if [[ -z "$COMMON_UNWRAP_SIGNATURE" ]]; then
        COMMON_UNWRAP_SIGNATURE="$unwrap_sig"
    elif [[ "$unwrap_sig" != "$COMMON_UNWRAP_SIGNATURE" ]]; then
        printf '%s\tunwrap_geometry_differs\n' "$pair" >> "$INPUT_FAILURES"
        continue
    fi
    if [[ "$method" == unchanged ]]; then
        UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
    elif [[ "$method" == grdcut ]]; then
        CUT_COUNT=$((CUT_COUNT + 1))
    else
        printf '%s\tunknown_method:%s\n' "$pair" "$method" >> "$INPUT_FAILURES"
        continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$pair" "$method" "$corr_sig" "$unwrap_sig" \
        >> "$INPUT_REPORT"
done < "$ACTIVE_PAIR_LIST"

INPUT_FAILURE_COUNT="$(( $(wc -l < "$INPUT_FAILURES" | tr -d ' ') - 1 ))"
if (( INPUT_FAILURE_COUNT > 0 )); then
    printf '[ERROR] %s pair inputs cannot be aligned:\n' "$INPUT_FAILURE_COUNT" >&2
    head -n 21 "$INPUT_FAILURES" >&2
    die "Run 3.9 was not started"
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.9 correlation/unwrap geometry check'
printf 'Track root               : %s\n' "$ROOT"
printf 'Finalized pairs          : %s\n' "$PAIR_COUNT"
printf 'Pairs inspected now      : %s\n' "$INSPECT_PAIR_COUNT"
printf 'Parallel jobs            : %s\n' "$JOBS"
printf 'Already same geometry    : %s (unchanged)\n' "$UNCHANGED_COUNT"
printf 'Extent-only differences  : %s (grdcut)\n' "$CUT_COUNT"
printf 'Interpolation            : disabled\n'
printf 'Final unwrap signature   : %s\n' "$COMMON_UNWRAP_SIGNATURE"
printf '%s\n' '========================================'

if [[ "$MODE" == 0 ]]; then
    usage
    printf '%s\n' '[CHECK ONLY] No correlation grid was generated or replaced.'
    printf '[NEXT] ./run3.9_match_corr_to_unwrap_burst.sh 1 %s\n' "$JOBS"
    exit 0
fi

printf '%s\n' '[STEP 1] Crop and replace corr.grd where its extent differs'
printf 'pair\tmethod\tstatus\toutput_signature\n' > "$REPORT.tmp"
printf 'pair\tmethod\tproblem\n' > "$FAILED_REPORT.tmp"
GENERATED=0

CUT_STATUS="$TMP/cut_status"
CUT_JOBS="$TMP/cut_jobs.txt"
CUT_WORKER="$TMP/cut_one.sh"
mkdir -p "$CUT_STATUS"
awk -F '\t' 'NR > 1 {print $1, $2}' "$INPUT_REPORT" > "$CUT_JOBS"
cat > "$CUT_WORKER" <<'CUT_EOF'
#!/usr/bin/env bash
set -u
pair_root="$1"
status_dir="$2"
pair="$3"
method="$4"
pair_dir="$pair_root/$pair"
source="$pair_dir/corr.grd"
unwrap="$pair_dir/unwrap.grd"
temporary="$pair_dir/.run3.9_corr.tmp.grd"
result="$status_dir/$pair.tsv"
grid_signature() {
    gmt grdinfo "$1" -C 2>/dev/null | awk 'NR==1 {
        print $2, $3, $4, $5, $8, $9, $10, $11, $12
    }'
}
unwrap_sig="$(grid_signature "$unwrap")"
if [[ "$method" == unchanged ]]; then
    output_sig="$(grid_signature "$source")"
    if [[ -n "$output_sig" && "$output_sig" == "$unwrap_sig" ]]; then
        printf 'OK\t%s\t%s\n' "$method" "$output_sig" > "$result"
    else
        printf 'FAIL\t%s\tunchanged_geometry_mismatch:%s\n' \
            "$method" "$output_sig" > "$result"
    fi
    exit 0
fi
if [[ "$method" != grdcut ]]; then
    printf 'FAIL\t%s\tunknown_method\n' "$method" > "$result"
    exit 0
fi
rm -f -- "$temporary"
status=0
gmt grdcut "$source" -R"$unwrap" -G"$temporary" >/dev/null 2>&1 || status=$?
if (( status != 0 )) || [[ ! -s "$temporary" ]]; then
    rm -f -- "$temporary"
    printf 'FAIL\t%s\tcommand_failed_%s\n' "$method" "$status" > "$result"
    exit 0
fi
output_sig="$(grid_signature "$temporary")"
if [[ -z "$output_sig" || "$output_sig" != "$unwrap_sig" ]]; then
    rm -f -- "$temporary"
    printf 'FAIL\t%s\tgeometry_mismatch:%s\n' "$method" "$output_sig" > "$result"
    exit 0
fi
# Atomic in-directory replacement after successful geometry validation.
mv -f -- "$temporary" "$source"
printf 'OK\t%s\t%s\n' "$method" "$output_sig" > "$result"
CUT_EOF
chmod +x "$CUT_WORKER"

xargs -P "$JOBS" -n 2 "$CUT_WORKER" "$PAIR_ROOT" "$CUT_STATUS" \
    < "$CUT_JOBS"

while IFS= read -r pair; do
    result="$CUT_STATUS/$pair.tsv"
    if [[ ! -s "$result" ]]; then
        printf '%s\tunknown\tworker_produced_no_result\n' "$pair" \
            >> "$FAILED_REPORT.tmp"
        continue
    fi
    IFS=$'\t' read -r state method detail extra < "$result"
    if [[ "$state" == OK ]]; then
        printf '%s\t%s\tOK\t%s\n' "$pair" "$method" "$detail" >> "$REPORT.tmp"
        GENERATED=$((GENERATED + 1))
    else
        printf '%s\t%s\t%s\n' "$pair" "${method:-unknown}" \
            "${detail:-unknown_worker_failure}" >> "$FAILED_REPORT.tmp"
    fi
done < "$PAIR_LIST"

FAILED_COUNT="$(( $(wc -l < "$FAILED_REPORT.tmp" | tr -d ' ') - 1 ))"
mv -f -- "$REPORT.tmp" "$REPORT"
if (( FAILED_COUNT > 0 )); then
    mv -f -- "$FAILED_REPORT.tmp" "$FAILED_REPORT"
    rm -f -- "$COMPLETE_FILE"
    printf '[FAILED] corr.grd validated/replaced=%s, failed=%s\n' "$GENERATED" "$FAILED_COUNT" >&2
    printf 'Failure report: %s\n' "$FAILED_REPORT" >&2
    head -n 21 "$FAILED_REPORT" >&2
    exit 1
fi
rm -f -- "$FAILED_REPORT.tmp" "$FAILED_REPORT"
[[ "$GENERATED" -eq "$PAIR_COUNT" ]] ||
    die "validated/replaced corr.grd=$GENERATED, expected=$PAIR_COUNT"

{
    printf 'status=COMPLETE\n'
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'pairs=%s\n' "$PAIR_COUNT"
    printf 'parallel_jobs=%s\n' "$JOBS"
    printf 'grid_name=corr.grd\n'
    printf 'replacement=in_place_no_backup\n'
    printf 'unchanged_count=%s\n' "$UNCHANGED_COUNT"
    printf 'grdcut_count=%s\n' "$CUT_COUNT"
    printf 'interpolation=disabled\n'
    printf 'unwrap_signature=%s\n' "$COMMON_UNWRAP_SIGNATURE"
} > "$COMPLETE_FILE"

printf '%s\n' '========================================'
printf '[DONE] Validated %s corr.grd files against unwrap.grd.\n' "$GENERATED"
printf 'Already unchanged        : %s\n' "$UNCHANGED_COUNT"
printf 'Replaced using grdcut    : %s\n' "$CUT_COUNT"
printf 'Parallel jobs            : %s\n' "$JOBS"
printf 'Interpolation            : disabled\n'
printf 'Alignment report         : %s\n' "$REPORT"
printf '%s\n' 'Original full-grid corr.grd files were replaced without backups.'
printf '%s\n' 'unwrap.grd files were not modified.'
printf '%s\n' '[NEXT] ./run4.1_prepare_sbas_network_burst.sh'
printf '%s\n' '========================================'
