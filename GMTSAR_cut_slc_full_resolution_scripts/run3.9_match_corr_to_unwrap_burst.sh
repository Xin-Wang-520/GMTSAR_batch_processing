#!/usr/bin/env bash
# Run 3.9: crop finalized burst grids to one common radar-coordinate region.
# Default target for the current full-resolution cut stack: 0/9008/0/1400.

set -euo pipefail
export LC_ALL=C LANG=C LANGUAGE=C

DEFAULT_REGION="0/9008/0/1400"
DEFAULT_TARGET_REGION="${RUN39_RADAR_REGION:-$DEFAULT_REGION}"
GRID_NAMES=(corr.grd unwrap.grd phasefilt.grd mask.grd)

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 3.9: crop finalized burst grids to one common region

Target grids in every burst/intf_all/<pair>/ directory:
  corr.grd
  unwrap.grd
  phasefilt.grd
  mask.grd

Default target region:
  0/9008/0/1400

Usage:
  ./run3.9_match_corr_to_unwrap_burst.sh
  ./run3.9_match_corr_to_unwrap_burst.sh 0 [JOBS] [PREVIEW_PAIRS] [RADAR_REGION]
  ./run3.9_match_corr_to_unwrap_burst.sh 1 [JOBS] [RADAR_REGION]

No arguments or mode 0:
  Crop 3 sampled pairs into burst/run3.9_crop_preview by default.
  Create cropped GRD previews and PDF/PNG plots; originals are unchanged.

Mode 1:
  Use gmt grdcut on all four grids for every finalized pair.
  Validate all temporary outputs before replacing the originals.
  Already-cropped grids are validated and left unchanged.
  JOBS defaults to 20.

RADAR_REGION:
  Format: range_min/range_max/azimuth_min/azimuth_max
  Default: 0/9008/0/1400

Examples:
  ./run3.9_match_corr_to_unwrap_burst.sh 0 20 3 0/9008/0/1400
  ./run3.9_match_corr_to_unwrap_burst.sh 1 20 0/9008/0/1400

WARNING:
  The four source grids are replaced in place without backups.
  Complete Run 3.8 before running formal mode.
========================================
EOF
}

grid_signature() {
    gmt grdinfo "$1" -C 2>/dev/null | awk 'NR == 1 {
        print $2, $3, $4, $5, $8, $9, $10, $11, $12
    }'
}

region_is_valid() {
    local region="$1"
    [[ "$region" =~ ^[0-9]+([.][0-9]+)?/[0-9]+([.][0-9]+)?/[0-9]+([.][0-9]+)?/[0-9]+([.][0-9]+)?$ ]] ||
        return 1
    local x0 x1 y0 y1
    IFS=/ read -r x0 x1 y0 y1 <<< "$region"
    awk -v x0="$x0" -v x1="$x1" -v y0="$y0" -v y1="$y1"         'BEGIN {exit !(x0 < x1 && y0 < y1)}'
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
(( $# <= 4 )) ||
    die "usage: $0 0 [JOBS] [PREVIEW_PAIRS] [RADAR_REGION], or $0 1 [JOBS] [RADAR_REGION]"
MODE="${1:-0}"
JOBS="${2:-20}"

case "$MODE" in
    0)
        PREVIEW_PAIRS="${3:-3}"
        TARGET_REGION="${4:-$DEFAULT_TARGET_REGION}"
        ;;
    1)
        (( $# <= 3 )) ||
            die "mode 1 usage: $0 1 [JOBS] [RADAR_REGION]"
        PREVIEW_PAIRS=3
        TARGET_REGION="${3:-$DEFAULT_TARGET_REGION}"
        ;;
    *)
        die "MODE must be 0 or 1"
        ;;
esac

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
[[ "$PREVIEW_PAIRS" =~ ^[1-9][0-9]*$ ]] ||
    die "PREVIEW_PAIRS must be a positive integer"
region_is_valid "$TARGET_REGION" ||
    die "invalid radar region: $TARGET_REGION"

for command_name in awk basename date gmt head mkdir mktemp mv rm sort tr wc xargs; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

ROOT="$(pwd -P)"
TRACK="$(basename -- "$ROOT")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A"

BURST_DIR="$ROOT/burst"
PAIR_ROOT="$BURST_DIR/intf_all"
EXPECTED_FILE="$BURST_DIR/run3.5_expected_pairs.tsv"
FINAL_INFO="$BURST_DIR/run3.3_finalized.info"
RUN35_FAILED="$BURST_DIR/run3.5_failed_pairs.tsv"
RUN38_FAILED="$BURST_DIR/run3.8_failed_pairs.tsv"
RUN38_PID="$BURST_DIR/run3.8_unwrap.pid"
REPORT="$BURST_DIR/run3.9_crop_alignment.tsv"
FAILED_REPORT="$BURST_DIR/run3.9_failed_pairs.tsv"
COMPLETE_FILE="$BURST_DIR/run3.9_complete"

[[ -d "$PAIR_ROOT" ]] || die "missing $PAIR_ROOT"
[[ -s "$EXPECTED_FILE" ]] || die "missing $EXPECTED_FILE"
[[ -s "$FINAL_INFO" ]] || die "missing $FINAL_INFO"
[[ ! -s "$RUN35_FAILED" ]] || die "Run 3.5 failure report is not empty"
[[ ! -s "$RUN38_FAILED" ]] || die "Run 3.8 failure report is not empty"

if [[ -s "$RUN38_PID" ]]; then
    RUN38_PROCESS="$(awk 'NR == 1 {print $1; exit}' "$RUN38_PID")"
    if [[ "$RUN38_PROCESS" =~ ^[1-9][0-9]*$ ]] &&
        kill -0 "$RUN38_PROCESS" 2>/dev/null; then
        die "Run 3.8 is still running (PID $RUN38_PROCESS)"
    fi
fi

FINAL_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$FINAL_INFO")"
ACCEPTED_PAIRS="$(awk -F= '$1=="accepted_pair_count" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_STATUS" == FINALIZED ]] || die "Run 3.3 status is not FINALIZED"
[[ "$ACCEPTED_PAIRS" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid accepted_pair_count"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run3.9-burst.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT INT TERM
PAIR_LIST="$TMP/pairs.txt"
: > "$PAIR_LIST"

while IFS=$'\t' read -r source_pair pair pair_log extra; do
    [[ -n "$source_pair" && -n "$pair" && -n "$pair_log" &&
        -z "${extra:-}" ]] || die "invalid Run 3.5 manifest record"
    [[ "$pair" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] ||
        die "invalid pair directory: $pair"
    printf '%s\n' "$pair" >> "$PAIR_LIST"
done < "$EXPECTED_FILE"

sort -u -o "$PAIR_LIST" "$PAIR_LIST"
PAIR_COUNT="$(wc -l < "$PAIR_LIST" | tr -d ' ')"
[[ "$PAIR_COUNT" -eq "$ACCEPTED_PAIRS" ]] ||
    die "pair count=$PAIR_COUNT, accepted count=$ACCEPTED_PAIRS"

ACTIVE_LIST="$PAIR_LIST"
if [[ "$MODE" == 0 && "$PREVIEW_PAIRS" -lt "$PAIR_COUNT" ]]; then
    ACTIVE_LIST="$TMP/preview_pairs.txt"
    awk -v n="$PREVIEW_PAIRS" '
        {line[NR]=$0}
        END {
            if (n == 1) {
                print line[int((NR+1)/2)]
            } else {
                last=0
                for (i=0; i<n; i++) {
                    k=int(1+i*(NR-1)/(n-1)+0.5)
                    if (k != last) print line[k]
                    last=k
                }
            }
        }
    ' "$PAIR_LIST" > "$ACTIVE_LIST"
fi

read -r RX0 RX1 RY0 RY1 <<< "${TARGET_REGION//\// }"

check_grid_for_region() {
    local grid="$1" signature
    [[ -s "$grid" ]] || return 10
    signature="$(grid_signature "$grid")"
    [[ -n "$signature" ]] || return 11
    read -r x0 x1 y0 y1 dx dy nx ny reg <<< "$signature"
    awk -v rx0="$RX0" -v rx1="$RX1" -v ry0="$RY0" -v ry1="$RY1"         -v x0="$x0" -v x1="$x1" -v y0="$y0" -v y1="$y1"         -v dx="$dx" -v dy="$dy" '
        function aligned(v,o,d,q) {
            q=(v-o)/d
            return (q-int(q+0.5) < 1e-7 && int(q+0.5)-q < 1e-7)
        }
        BEGIN {
            if (rx0 < x0 || rx1 > x1 || ry0 < y0 || ry1 > y1) exit 1
            if (!aligned(rx0,x0,dx) || !aligned(rx1,x0,dx) ||
                !aligned(ry0,y0,dy) || !aligned(ry1,y0,dy)) exit 2
        }'
}

if [[ "$MODE" == 0 ]]; then
    PREVIEW_DIR="$BURST_DIR/run3.9_crop_preview"
    mkdir -p "$PREVIEW_DIR"

    plot_preview_grid() {
        local grid="$1"
        local name="$2"
        local output_base="$3"
        local title="$4"

        rm -f -- "${output_base}.pdf" "${output_base}.png"

        gmt begin "$output_base" pdf,png
            case "$name" in
                corr.grd)
                    gmt makecpt -Cgray -T0/0.8/0.05
                    ;;
                unwrap.grd)
                    gmt grd2cpt "$grid" -Cturbo -Z
                    ;;
                phasefilt.grd)
                    gmt makecpt -Crainbow -T-3.1416/3.1416/0.1 -Z
                    ;;
                mask.grd)
                    gmt makecpt -Cgray -T0/1/1
                    ;;
            esac
            gmt grdimage "$grid" -R"$grid" -JX18c/5c -C                 -Bxaaf+lRange -Byaaf+lAzimuth -BWSen+t"$title"
            gmt colorbar -DJBC+w14c/0.3c+h+o0c/1.0c -Baf
        gmt end
    }

    printf '%s\n' '========================================'
    printf '%s\n' 'Run 3.9 crop preview'
    printf 'Track root        : %s\n' "$ROOT"
    printf 'Finalized pairs   : %s\n' "$PAIR_COUNT"
    printf 'Preview pairs     : %s\n' "$(wc -l < "$ACTIVE_LIST" | tr -d ' ')"
    printf 'Target region     : %s\n' "$TARGET_REGION"
    printf 'Target grids      : %s\n' "${GRID_NAMES[*]}"
    printf 'Preview directory : %s\n' "$PREVIEW_DIR"
    printf 'Original grids    : unchanged\n'
    printf '%s\n' '========================================'

    FAIL=0
    GENERATED=0
    while IFS= read -r pair; do
        pair_preview="$PREVIEW_DIR/$pair"
        mkdir -p "$pair_preview"
        printf '[PAIR] %s\n' "$pair"

        for name in "${GRID_NAMES[@]}"; do
            source="$PAIR_ROOT/$pair/$name"
            preview_grid="$pair_preview/$name"
            output_base="$pair_preview/${name%.grd}_crop_preview"

            if ! check_grid_for_region "$source"; then
                printf '  [INVALID] %s\n' "$source"
                FAIL=$((FAIL + 1))
                continue
            fi

            rm -f -- "$preview_grid"
            if ! gmt grdcut "$source" -R"$TARGET_REGION"                 -G"$preview_grid" >/dev/null 2>&1 ||
                [[ ! -s "$preview_grid" ]]; then
                printf '  [FAILED] grdcut %s\n' "$source"
                FAIL=$((FAIL + 1))
                continue
            fi

            signature="$(grid_signature "$preview_grid")"
            read -r px0 px1 py0 py1 pdx pdy pnx pny preg <<< "$signature"
            if ! awk -v x0="$px0" -v x1="$px1" -v y0="$py0" -v y1="$py1"                 -v rx0="$RX0" -v rx1="$RX1" -v ry0="$RY0" -v ry1="$RY1"                 'BEGIN {exit !(x0==rx0 && x1==rx1 && y0==ry0 && y1==ry1)}'; then
                printf '  [FAILED] unexpected preview geometry: %s\n' "$signature"
                FAIL=$((FAIL + 1))
                continue
            fi

            plot_preview_grid "$preview_grid" "$name" "$output_base"                 "$pair  ${name%.grd}  R=$TARGET_REGION"
            printf '  %-14s %s\n' "$name" "$signature"
            GENERATED=$((GENERATED + 1))
        done

        {
            printf 'pair=%s\n' "$pair"
            printf 'target_region=%s\n' "$TARGET_REGION"
            printf 'grid_names=%s\n' "${GRID_NAMES[*]}"
            printf 'source_directory=%s\n' "$PAIR_ROOT/$pair"
            printf 'original_grids=unchanged\n'
        } > "$pair_preview/preview.info"
    done < "$ACTIVE_LIST"

    (( FAIL == 0 )) || die "$FAIL preview products failed"
    printf '%s\n' '========================================'
    printf '[PREVIEW DONE] Generated %s cropped grids plus PDF/PNG plots.\n' "$GENERATED"
    printf 'Preview directory : %s\n' "$PREVIEW_DIR"
    printf 'Original grids    : unchanged\n'
    printf '[NEXT FORMAL] ./run3.9_match_corr_to_unwrap_burst.sh 1 %s\n' "$JOBS"
    printf '%s\n' '========================================'
    exit 0
fi

# Formal mode requires all four non-empty input grids for every finalized pair.
# Grid readability and geometry are validated again by each crop worker.
INCOMPLETE="$TMP/incomplete.tsv"
: > "$INCOMPLETE"
while IFS= read -r pair; do
    pair_dir="$PAIR_ROOT/$pair"
    for name in "${GRID_NAMES[@]}"; do
        [[ -s "$pair_dir/$name" ]] ||
            printf '%s\tmissing:%s\n' "$pair" "$name" >> "$INCOMPLETE"
    done
done < "$PAIR_LIST"
if [[ -s "$INCOMPLETE" ]]; then
    head -n 20 "$INCOMPLETE" >&2
    die "required Run 3.9 input grids are incomplete; processing was not started"
fi

WORKER="$TMP/crop_one.sh"
STATUS_DIR="$TMP/status"
mkdir -p "$STATUS_DIR"
cat > "$WORKER" <<'WORKER_EOF'
#!/usr/bin/env bash
set -u
pair_root="$1"
status_dir="$2"
region="$3"
pair="$4"
pair_dir="$pair_root/$pair"
result="$status_dir/$pair.tsv"
names=(corr.grd unwrap.grd phasefilt.grd mask.grd)
IFS=/ read -r rx0 rx1 ry0 ry1 <<< "$region"

grid_signature() {
    gmt grdinfo "$1" -C 2>/dev/null | awk 'NR == 1 {
        print $2, $3, $4, $5, $8, $9, $10, $11, $12
    }'
}

cleanup() {
    local name
    for name in "${names[@]}"; do
        rm -f -- "$pair_dir/.run3.9_${name}.tmp"
    done
}
trap cleanup EXIT INT TERM

methods=()
for name in "${names[@]}"; do
    source="$pair_dir/$name"
    temporary="$pair_dir/.run3.9_${name}.tmp"
    [[ -s "$source" ]] || {
        printf 'FAIL\tmissing:%s\n' "$name" > "$result"
        exit 0
    }
    source_sig="$(grid_signature "$source")"
    [[ -n "$source_sig" ]] || {
        printf 'FAIL\tunreadable:%s\n' "$name" > "$result"
        exit 0
    }
    read -r x0 x1 y0 y1 dx dy nx ny reg <<< "$source_sig"
    if ! awk -v rx0="$rx0" -v rx1="$rx1" -v ry0="$ry0" -v ry1="$ry1"         -v x0="$x0" -v x1="$x1" -v y0="$y0" -v y1="$y1"         -v dx="$dx" -v dy="$dy" '
        function aligned(v,o,d,q) {
            q=(v-o)/d
            return (q-int(q+0.5) < 1e-7 && int(q+0.5)-q < 1e-7)
        }
        BEGIN {
            if (rx0 < x0 || rx1 > x1 || ry0 < y0 || ry1 > y1) exit 1
            if (!aligned(rx0,x0,dx) || !aligned(rx1,x0,dx) ||
                !aligned(ry0,y0,dy) || !aligned(ry1,y0,dy)) exit 2
        }'; then
        printf 'FAIL\ttarget_outside_or_unaligned:%s:%s\n'             "$name" "$source_sig" > "$result"
        exit 0
    fi

    if awk -v x0="$x0" -v x1="$x1" -v y0="$y0" -v y1="$y1"         -v rx0="$rx0" -v rx1="$rx1" -v ry0="$ry0" -v ry1="$ry1"         'BEGIN {exit !(x0==rx0 && x1==rx1 && y0==ry0 && y1==ry1)}'; then
        methods+=("$name:unchanged")
        continue
    fi

    rm -f -- "$temporary"
    if ! gmt grdcut "$source" -R"$region" -G"$temporary" >/dev/null 2>&1 ||
        [[ ! -s "$temporary" ]]; then
        printf 'FAIL\tgrdcut_failed:%s\n' "$name" > "$result"
        exit 0
    fi
    output_sig="$(grid_signature "$temporary")"
    read -r ox0 ox1 oy0 oy1 odx ody onx ony oreg <<< "$output_sig"
    if ! awk -v x0="$ox0" -v x1="$ox1" -v y0="$oy0" -v y1="$oy1"         -v rx0="$rx0" -v rx1="$rx1" -v ry0="$ry0" -v ry1="$ry1"         -v dx="$dx" -v dy="$dy" -v odx="$odx" -v ody="$ody"         -v reg="$reg" -v oreg="$oreg" '
        BEGIN {
            exit !(x0==rx0 && x1==rx1 && y0==ry0 && y1==ry1 &&
                   dx==odx && dy==ody && reg==oreg)
        }'; then
        printf 'FAIL\toutput_geometry_invalid:%s:%s\n'             "$name" "$output_sig" > "$result"
        exit 0
    fi
    methods+=("$name:grdcut")
done

# Replace only after all four temporary grids have passed validation.
for name in "${names[@]}"; do
    temporary="$pair_dir/.run3.9_${name}.tmp"
    [[ -s "$temporary" ]] && mv -f -- "$temporary" "$pair_dir/$name"
done

{
    printf 'OK'
    for method in "${methods[@]}"; do
        printf '\t%s' "$method"
    done
    printf '\n'
} > "$result"
WORKER_EOF
chmod +x "$WORKER"

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.9 formal common-region crop'
printf 'Track root        : %s\n' "$ROOT"
printf 'Finalized pairs   : %s\n' "$PAIR_COUNT"
printf 'Parallel jobs     : %s\n' "$JOBS"
printf 'Target region     : %s\n' "$TARGET_REGION"
printf 'Target grids      : %s\n' "${GRID_NAMES[*]}"
printf 'Replacement       : in place, no backup\n'
printf '%s\n' '========================================'

xargs -P "$JOBS" -n 1 "$WORKER" "$PAIR_ROOT" "$STATUS_DIR" "$TARGET_REGION"     < "$PAIR_LIST"

printf 'pair\tstatus\tdetails\n' > "$REPORT.tmp"
printf 'pair\tproblem\n' > "$FAILED_REPORT.tmp"
SUCCESS=0
while IFS= read -r pair; do
    result="$STATUS_DIR/$pair.tsv"
    if [[ ! -s "$result" ]]; then
        printf '%s\tworker_produced_no_result\n' "$pair" >> "$FAILED_REPORT.tmp"
        continue
    fi
    IFS=$'\t' read -r state details < "$result"
    if [[ "$state" == OK ]]; then
        printf '%s\tOK\t%s\n' "$pair" "${details:-completed}" >> "$REPORT.tmp"
        SUCCESS=$((SUCCESS + 1))
    else
        printf '%s\t%s\n' "$pair" "${details:-unknown_failure}"             >> "$FAILED_REPORT.tmp"
    fi
done < "$PAIR_LIST"

FAILED=$(( $(wc -l < "$FAILED_REPORT.tmp" | tr -d ' ') - 1 ))
mv -f -- "$REPORT.tmp" "$REPORT"
if (( FAILED > 0 )); then
    mv -f -- "$FAILED_REPORT.tmp" "$FAILED_REPORT"
    rm -f -- "$COMPLETE_FILE"
    printf '[FAILED] success=%s, failed=%s\n' "$SUCCESS" "$FAILED" >&2
    head -n 21 "$FAILED_REPORT" >&2
    exit 1
fi

rm -f -- "$FAILED_REPORT.tmp" "$FAILED_REPORT"
[[ "$SUCCESS" -eq "$PAIR_COUNT" ]] ||
    die "successful pairs=$SUCCESS, expected=$PAIR_COUNT"

{
    printf 'status=COMPLETE\n'
    printf 'completed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'track=%s\n' "$TRACK"
    printf 'pairs=%s\n' "$PAIR_COUNT"
    printf 'parallel_jobs=%s\n' "$JOBS"
    printf 'target_region=%s\n' "$TARGET_REGION"
    printf 'grid_names=%s\n' "${GRID_NAMES[*]}"
    printf 'replacement=in_place_no_backup\n'
    printf 'interpolation=disabled\n'
} > "$COMPLETE_FILE"

printf '%s\n' '========================================'
printf '[DONE] Cropped and validated %s pairs.\n' "$SUCCESS"
printf 'Target region     : %s\n' "$TARGET_REGION"
printf 'Target grids      : %s\n' "${GRID_NAMES[*]}"
printf 'Report            : %s\n' "$REPORT"
printf '%s\n' 'Original grids were replaced without backups.'
printf '%s\n' '[NEXT] ./run4.1_prepare_sbas_network_burst.sh'
printf '%s\n' '========================================'
