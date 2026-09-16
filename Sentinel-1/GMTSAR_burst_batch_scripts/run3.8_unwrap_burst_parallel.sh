#!/usr/bin/env bash
# Run 3.8: validated, resumable parallel unwrapping for one burst stack.
# It operates directly in burst/intf_all; no merge/ directory is used.

set -euo pipefail

export LC_ALL=C
export LANG=C
export LANGUAGE=C

DEFAULT_JOBS="5"
DEFAULT_CORR_THRESHOLD="0.0001"
DEFAULT_MAX_DISCONTINUITY="0"
LOG_DIR_NAME="run3.8_unwrap_logs"
NOHUP_LOG_NAME="run3.8_unwrap_burst_parallel.nohup.log"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
========================================
Run 3.8: resumable parallel unwrapping for one burst stack (no merge)

Usage:
  ./run3.8_unwrap_burst_parallel.sh
  ./run3.8_unwrap_burst_parallel.sh 1 [CORR_THRESHOLD] [PAIR] [RADAR_REGION]
  ./run3.8_unwrap_burst_parallel.sh 2 JOBS [CORR_THRESHOLD] [RADAR_REGION]

No arguments:
  Check all finalized interferograms, common masks and existing unwrap results.
  No preview or unwrapping is started.

Mode 1 - preview one pre-SNAPHU input:
  ./run3.8_unwrap_burst_parallel.sh 1
  ./run3.8_unwrap_burst_parallel.sh 1 0.0001
  ./run3.8_unwrap_burst_parallel.sh 1 0.0001 2021051_2021063
  ./run3.8_unwrap_burst_parallel.sh 1 0.0001 2024067_2024079 0/24560/0/1396
  ./run3.8_unwrap_burst_parallel.sh 1 0.0001 0/24560/0/1396

  If PAIR is omitted, the middle pair in the sorted finalized list is used.
  RADAR_REGION has the form rng0/rngf/azi0/azif. It crops only temporary
  pre-SNAPHU inputs; original interferogram grids are not modified.
  Applied valid-pixel inputs:
    burst/intf_all/<pair>/corr.grd >= CORR_THRESHOLD
    burst/intf_all/<pair>/mask.grd
    burst/mask_def.grd
    burst/landmask_ra.grd

  Preview outputs:
    burst/run3.8_presnaphu_preview/<pair>_combined_mask_presnaphu.pdf
    burst/run3.8_presnaphu_preview/<pair>_phase_presnaphu.pdf

  Full-grid and cropped previews use the same two names. A later preview for
  the same pair replaces the preceding PDFs.

  Mode 1 does not run nearest_grid or SNAPHU and does not create unwrap.grd.

Mode 2 - formal resumable parallel unwrapping:
  ./run3.8_unwrap_burst_parallel.sh 2 5 0.0001
  ./run3.8_unwrap_burst_parallel.sh 2 20 0.0001 0/24560/0/1396

  JOBS            Maximum interferograms unwrapped concurrently.
                  Recommended: 5
  CORR_THRESHOLD  Correlation threshold passed to snaphu_interp.csh.
                  Default: 0.0001
  RADAR_REGION    Optional common crop: rng0/rngf/azi0/azif.
                  Use the same accepted region shown in Mode 1.
  Maximum discontinuity is fixed at 0 for continuous SBAS deformation.

  Mode 2 submits itself through nohup and returns the terminal immediately.
  Do not add nohup or & manually.

Formal processing:
  1. Use only the final pair list recorded by Run 3.5.
  2. Check corr.grd, mask.grd and phasefilt.grd for every finalized pair.
  3. Check burst/mask_def.grd and burst/landmask_ra.grd geometry.
  4. Skip pairs already containing non-empty unwrap.grd and unwrap.pdf.
  5. Run only incomplete pairs through GMTSAR unwrap_parallel.csh.
  6. Validate every finalized pair and write a failure report if needed.

Outputs in burst/intf_all/<pair>/:
  unwrap.grd
  unwrap.pdf
  conncomp.grd
  phasefilt_interp.grd
  landmask_ra.grd -> ../../landmask_ra.grd
  mask_def.grd    -> ../../mask_def.grd

Run-level files:
  burst/intf_all/intflist
  burst/intf_all/unwrap_pending_intflist
  burst/run3.8_unwrap_logs/<pair>.log
  burst/run3.8_failed_pairs.tsv       (only when failures exist)

Monitor mode 2:
  tail -f run3.8_unwrap_burst_parallel.nohup.log
  tail -f burst/run3.8_unwrap_logs/<pair>.log

No merge/ directory is read, created, moved or modified.
========================================
EOF
}

validate_threshold() {
    local value="$1"
    [[ "$value" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
        die "CORR_THRESHOLD must be numeric: $value"
    awk -v value="$value" 'BEGIN {exit !(value >= 0 && value <= 1)}' ||
        die "CORR_THRESHOLD must be between 0 and 1: $value"
}

validate_parameters() {
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer: $JOBS"
    validate_threshold "$CORR_THRESHOLD"
    [[ "$MAX_DISCONTINUITY" =~ ^[0-9]+([.][0-9]*)?$ ]] ||
        die "MAX_DISCONTINUITY must be zero or positive: $MAX_DISCONTINUITY"
}

validate_region_syntax() {
    local value="$1"
    [[ -z "$value" ]] && return 0
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?/[0-9]+([.][0-9]+)?/[0-9]+([.][0-9]+)?/[0-9]+([.][0-9]+)?$ ]] ||
        die "RADAR_REGION must be rng0/rngf/azi0/azif: $value"
}

validate_region_against_template() {
    local value="$1"
    local x0 x1 y0 y1 signature
    [[ -z "$value" ]] && return 0
    IFS=/ read -r x0 x1 y0 y1 <<< "$value"
    signature="$(gmt grdinfo "$TEMPLATE_GRID" -C | awk 'NR==1 {print $2, $3, $4, $5, $8, $9}')"
    awk -v r0="$x0" -v rf="$x1" -v a0="$y0" -v af="$y1" \
        -v signature="$signature" '
        BEGIN {
            split(signature, g, " ")
            xmin=g[1]; xmax=g[2]; ymin=g[3]; ymax=g[4]; dx=g[5]; dy=g[6]
            if (!(r0 < rf && a0 < af)) exit 1
            if (r0 < xmin || rf > xmax || a0 < ymin || af > ymax) exit 2
            q=(r0-xmin)/dx; if (q-int(q+0.5) > 1e-7 || int(q+0.5)-q > 1e-7) exit 3
            q=(rf-xmin)/dx; if (q-int(q+0.5) > 1e-7 || int(q+0.5)-q > 1e-7) exit 3
            q=(a0-ymin)/dy; if (q-int(q+0.5) > 1e-7 || int(q+0.5)-q > 1e-7) exit 3
            q=(af-ymin)/dy; if (q-int(q+0.5) > 1e-7 || int(q+0.5)-q > 1e-7) exit 3
        }
    ' || die "RADAR_REGION is outside the template or not aligned to its increments: $value"
}

grid_signature() {
    gmt grdinfo "$1" -C | awk 'NR == 1 {
        print $2, $3, $4, $5, $8, $9, $10, $11, $12
    }'
}

check_existing_process() {
    local old_pid
    if [[ -s "$PID_FILE" ]]; then
        old_pid="$(awk 'NR == 1 {print $1; exit}' "$PID_FILE")"
        if [[ "$old_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            die "another Run 3.8 job is running (PID $old_pid, file $PID_FILE)"
        fi
    fi
}

make_pair_list() {
    local output_file="$1"
    local raw_file="$TEMP_DIR/pairs.raw"
    local pair pair_dir pair_log extra
    : > "$raw_file"

    while IFS=$'\t' read -r pair pair_dir pair_log extra; do
        [[ -n "$pair" && -n "$pair_dir" && -n "$pair_log" && -z "${extra:-}" ]] ||
            die "invalid record in $EXPECTED_FILE: ${pair:-empty}"
        [[ "$pair" =~ ^S1_[0-9]{8}_ALL_F[123]:S1_[0-9]{8}_ALL_F[123]$ ]] ||
            die "invalid pair name in $EXPECTED_FILE: $pair"
        [[ "$pair_dir" =~ ^20[0-9]{5,7}_20[0-9]{5,7}$ ]] ||
            die "invalid output directory in $EXPECTED_FILE: $pair_dir"
        printf '%s\n' "$pair_dir" >> "$raw_file"
    done < "$EXPECTED_FILE"

    sort "$raw_file" > "$output_file"
    PAIR_COUNT="$(wc -l < "$output_file" | awk '{print $1}')"
    DUPLICATE_COUNT="$(uniq -d "$output_file" | wc -l | awk '{print $1}')"
    [[ "$PAIR_COUNT" -eq "$ACCEPTED_PAIRS" ]] ||
        die "Run 3.5 manifest count=$PAIR_COUNT, Run 3.3 accepted count=$ACCEPTED_PAIRS"
    (( DUPLICATE_COUNT == 0 )) ||
        die "Run 3.5 manifest contains $DUPLICATE_COUNT duplicate output directories"
}

check_inputs_and_outputs() {
    local pair_list="$1" missing_report="$2" pending_list="$3"
    local pair grid missing_csv parameter_file parameter_region parameter_threshold parameter_discontinuity
    local total=0 corr_count=0 mask_count=0 phase_count=0
    local unwrap_count=0 pdf_count=0 complete_count=0

    : > "$missing_report"
    : > "$pending_list"
    [[ -s "$LANDMASK" ]] || die "missing $LANDMASK; complete Run 3.7 first"
    [[ -s "$MASK_DEF" ]] || die "missing $MASK_DEF; complete Run 3.6 first"

    TEMPLATE_PAIR="$(head -n 1 "$pair_list")"
    TEMPLATE_GRID="$INTF_ALL_DIR/$TEMPLATE_PAIR/phasefilt.grd"
    [[ -n "$TEMPLATE_PAIR" && -s "$TEMPLATE_GRID" ]] ||
        die "cannot find the first finalized phasefilt.grd template"

    TEMPLATE_SIGNATURE="$(grid_signature "$TEMPLATE_GRID")"
    LANDMASK_SIGNATURE="$(grid_signature "$LANDMASK")"
    MASKDEF_SIGNATURE="$(grid_signature "$MASK_DEF")"
    [[ -n "$TEMPLATE_SIGNATURE" && -n "$LANDMASK_SIGNATURE" && -n "$MASKDEF_SIGNATURE" ]] ||
        die "failed to read grid geometry"
    [[ "$LANDMASK_SIGNATURE" == "$TEMPLATE_SIGNATURE" ]] ||
        die "burst/landmask_ra.grd geometry does not match $TEMPLATE_GRID"
    [[ "$MASKDEF_SIGNATURE" == "$TEMPLATE_SIGNATURE" ]] ||
        die "burst/mask_def.grd geometry does not match $TEMPLATE_GRID"

    while IFS= read -r pair; do
        [[ -n "$pair" ]] || continue
        total=$((total + 1))
        missing_csv=""
        [[ -d "$INTF_ALL_DIR/$pair" ]] || missing_csv="pair_directory"

        for grid in corr.grd mask.grd phasefilt.grd; do
            if [[ -s "$INTF_ALL_DIR/$pair/$grid" ]]; then
                case "$grid" in
                    corr.grd) corr_count=$((corr_count + 1)) ;;
                    mask.grd) mask_count=$((mask_count + 1)) ;;
                    phasefilt.grd) phase_count=$((phase_count + 1)) ;;
                esac
            else
                [[ -z "$missing_csv" ]] || missing_csv+=","
                missing_csv+="$grid"
            fi
        done

        if [[ -n "$missing_csv" ]]; then
            printf '%s\t%s\n' "$pair" "$missing_csv" >> "$missing_report"
            continue
        fi

        [[ -s "$INTF_ALL_DIR/$pair/unwrap.grd" ]] && unwrap_count=$((unwrap_count + 1))
        [[ -s "$INTF_ALL_DIR/$pair/unwrap.pdf" ]] && pdf_count=$((pdf_count + 1))
        if [[ -s "$INTF_ALL_DIR/$pair/unwrap.grd" && -s "$INTF_ALL_DIR/$pair/unwrap.pdf" ]]; then
            if [[ -n "$RADAR_REGION" && ( "$ACTION" == submit || "$ACTION" == process ) ]]; then
                parameter_file="$INTF_ALL_DIR/$pair/run3.8_unwrap_parameters.txt"
                parameter_region=''
                parameter_threshold=''
                parameter_discontinuity=''
                if [[ -s "$parameter_file" ]]; then
                    parameter_region="$(awk -F= '$1=="radar_region" {print $2; exit}' "$parameter_file")"
                    parameter_threshold="$(awk -F= '$1=="correlation_threshold" {print $2; exit}' "$parameter_file")"
                    parameter_discontinuity="$(awk -F= '$1=="maximum_discontinuity" {print $2; exit}' "$parameter_file")"
                fi
                if [[ "$parameter_region" == "$RADAR_REGION" &&
                      "$parameter_threshold" == "$CORR_THRESHOLD" &&
                      "$parameter_discontinuity" == "$MAX_DISCONTINUITY" ]]; then
                    complete_count=$((complete_count + 1))
                else
                    printf '%s\n' "$pair" >> "$pending_list"
                fi
            else
                complete_count=$((complete_count + 1))
            fi
        else
            printf '%s\n' "$pair" >> "$pending_list"
        fi
    done < "$pair_list"

    printf '%s\n' '========================================'
    printf '%s\n' 'Run 3.8 burst unwrap input/output check (no merge)'
    printf 'Finalized pairs        : %d\n' "$total"
    printf 'Non-empty corr.grd     : %d\n' "$corr_count"
    printf 'Non-empty mask.grd     : %d\n' "$mask_count"
    printf 'Non-empty phasefilt.grd: %d\n' "$phase_count"
    printf 'Existing unwrap.grd    : %d\n' "$unwrap_count"
    printf 'Existing unwrap.pdf    : %d\n' "$pdf_count"
    printf 'Completed pairs        : %d\n' "$complete_count"
    printf 'Pending pairs          : %d\n' "$((total - complete_count))"
    printf 'Template pair          : %s\n' "$TEMPLATE_PAIR"
    printf 'Template signature     : %s\n' "$TEMPLATE_SIGNATURE"
    printf '%s\n' '========================================'

    if [[ -s "$missing_report" ]]; then
        printf '%s\n' '[CHECK ERROR] Missing or empty required inputs:' >&2
        while IFS=$'\t' read -r pair missing_csv; do
            printf '  %s  missing: %s\n' "$pair" "$missing_csv" >&2
        done < "$missing_report"
        return 1
    fi

    printf '[CHECK OK] All %d finalized pairs have corr.grd, mask.grd and phasefilt.grd.\n' "$total"
    printf '%s\n' '[CHECK OK] burst/landmask_ra.grd and mask_def.grd match the phase grid.'
}

make_presnaphu_preview() {
    local pair_list="$1" requested_pair="$2" threshold="$3" radar_region="$4"
    local pair pair_count middle_line pair_source pair_dir output_dir
    local mask_output_base phase_output_base preview_tmp
    local mask_all mask_tmp phase_preview mask_cpt phase_cpt
    local corr_input mask_input phase_input maskdef_input landmask_input

    validate_threshold "$threshold"
    if [[ -n "$requested_pair" ]]; then
        grep -Fxq -- "$requested_pair" "$pair_list" ||
            die "preview pair is not in the finalized Run 3.5 list: $requested_pair"
        pair="$requested_pair"
        pair_source='user selected'
    else
        pair_count="$(wc -l < "$pair_list" | awk '{print $1}')"
        middle_line=$(( (pair_count + 1) / 2 ))
        pair="$(sed -n "${middle_line}p" "$pair_list")"
        pair_source='automatic middle pair'
    fi

    pair_dir="$INTF_ALL_DIR/$pair"
    output_dir="$BURST_DIR/run3.8_presnaphu_preview"
    # Full-grid and cropped previews intentionally use the same names.
    # A new preview for the same pair replaces the preceding preview.
    mask_output_base="$output_dir/${pair}_combined_mask_presnaphu"
    phase_output_base="$output_dir/${pair}_phase_presnaphu"
    mkdir -p "$output_dir"
    preview_tmp="$(mktemp -d "$TEMP_DIR/preview.XXXXXX")"
    mask_all="$preview_tmp/mask_all.grd"
    mask_tmp="$preview_tmp/mask_tmp.grd"
    phase_preview="$preview_tmp/phase_presnaphu.grd"
    mask_cpt="$preview_tmp/mask.cpt"
    phase_cpt="$preview_tmp/phase.cpt"

    corr_input="$pair_dir/corr.grd"
    mask_input="$pair_dir/mask.grd"
    phase_input="$pair_dir/phasefilt.grd"
    maskdef_input="$MASK_DEF"
    landmask_input="$LANDMASK"
    if [[ -n "$radar_region" ]]; then
        printf '%s\n' '[PREVIEW CROP] Create temporary grids for the requested radar region'
        gmt grdcut "$corr_input" -R"$radar_region" -G"$preview_tmp/corr_patch.grd"
        gmt grdcut "$mask_input" -R"$radar_region" -G"$preview_tmp/mask_patch.grd"
        gmt grdcut "$phase_input" -R"$radar_region" -G"$preview_tmp/phase_patch.grd"
        gmt grdcut "$maskdef_input" -R"$radar_region" -G"$preview_tmp/mask_def_patch.grd"
        gmt grdcut "$landmask_input" -R"$radar_region" -G"$preview_tmp/landmask_ra_patch.grd"
        corr_input="$preview_tmp/corr_patch.grd"
        mask_input="$preview_tmp/mask_patch.grd"
        phase_input="$preview_tmp/phase_patch.grd"
        maskdef_input="$preview_tmp/mask_def_patch.grd"
        landmask_input="$preview_tmp/landmask_ra_patch.grd"
    fi

    printf '%s\n' '========================================'
    printf '%s\n' 'Run 3.8 mode 1: preview burst pre-SNAPHU input'
    printf 'Interferogram pair     : %s (%s)\n' "$pair" "$pair_source"
    printf 'Correlation threshold  : %s\n' "$threshold"
    printf 'Radar crop             : %s\n' "${radar_region:-full grid}"
    printf '%s\n' 'Applied inputs:'
    printf '  burst/intf_all/%s/phasefilt.grd\n' "$pair"
    printf '  burst/intf_all/%s/corr.grd >= %s\n' "$pair" "$threshold"
    printf '  burst/intf_all/%s/mask.grd\n' "$pair"
    printf '%s\n' '  burst/mask_def.grd'
    printf '%s\n' '  burst/landmask_ra.grd'
    printf '%s\n' '========================================'

    printf '%s\n' '[STEP 1] Build the combined valid-pixel mask'
    gmt grdmath "$corr_input" "$threshold" GE 0 NAN \
        "$mask_input" 0 GT 0 NAN MUL = "$mask_all"
    gmt grdmath "$mask_all" "$maskdef_input" 0 GT 0 NAN MUL = "$mask_tmp"
    mv -f -- "$mask_tmp" "$mask_all"
    gmt grdmath "$mask_all" "$landmask_input" 0 GT 0 NAN MUL = "$mask_tmp"
    mv -f -- "$mask_tmp" "$mask_all"

    printf '%s\n' '[STEP 2] Plot the combined mask without phasefilt.grd'
    gmt makecpt -Cgray -T0/1/0.05 -Z > "$mask_cpt"
    rm -f -- "${mask_output_base}.pdf"
    gmt begin "$mask_output_base" pdf
        gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 10p \
            FONT_LABEL 11p FONT_TITLE 13p COLOR_NAN gray
        gmt grdimage "$mask_all" -JX7i -C"$mask_cpt" \
            -Bxaf+l"Range" -Byaf+l"Azimuth" \
            -BWSen+t"Combined pre-SNAPHU mask: ${pair}, corr >= ${threshold}"
    gmt end

    printf '%s\n' '[STEP 3] Apply the combined mask to phasefilt.grd'
    gmt grdmath "$phase_input" "$mask_all" MUL = "$phase_preview"

    printf '%s\n' '[STEP 4] Plot the masked wrapped phase'
    gmt makecpt -Ccyclic -T-3.141592653589793/3.141592653589793/0.02 -Z > "$phase_cpt"
    rm -f -- "${phase_output_base}.pdf"
    gmt begin "$phase_output_base" pdf
        gmt set MAP_FRAME_TYPE plain FONT_ANNOT_PRIMARY 10p \
            FONT_LABEL 11p FONT_TITLE 13p COLOR_NAN gray
        gmt grdimage "$phase_preview" -JX7i -C"$phase_cpt" \
            -Bxaf+l"Range" -Byaf+l"Azimuth" \
            -BWSen+t"Pre-SNAPHU wrapped phase: ${pair}, corr >= ${threshold}"
        gmt colorbar -DJTC+w5.5i/0.2i+h -C"$phase_cpt" \
            -Bxa1.57f0.785+l"Wrapped phase" -By+l"rad"
    gmt end

    [[ -s "${mask_output_base}.pdf" ]] || die "combined-mask preview PDF was not generated"
    [[ -s "${phase_output_base}.pdf" ]] || die "phase preview PDF was not generated"
    printf '%s\n' '========================================'
    printf '%s\n' '[PREVIEW DONE] No unwrapping was started.'
    printf 'Combined-mask PDF: %s.pdf\n' "$mask_output_base"
    printf 'Masked-phase PDF : %s.pdf\n' "$phase_output_base"
    if [[ -n "$radar_region" ]]; then
        printf '[NEXT] ./run3.8_unwrap_burst_parallel.sh 2 5 %s %s\n' \
            "$threshold" "$radar_region"
    else
        printf '[NEXT] ./run3.8_unwrap_burst_parallel.sh 2 5 %s\n' "$threshold"
    fi
    printf '%s\n' '========================================'
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi

ACTION='check'
PREVIEW_PAIR=''
PREVIEW_THRESHOLD="$DEFAULT_CORR_THRESHOLD"
RADAR_REGION=''
INTERNAL_RUN=0
JOBS=''
CORR_THRESHOLD="$DEFAULT_CORR_THRESHOLD"
MAX_DISCONTINUITY="$DEFAULT_MAX_DISCONTINUITY"

if [[ "${1:-}" == --internal-run ]]; then
    INTERNAL_RUN=1
    ACTION='process'
    shift
    (( $# >= 1 && $# <= 4 )) || die "invalid internal mode arguments"
    JOBS="$1"
    CORR_THRESHOLD="${2:-$DEFAULT_CORR_THRESHOLD}"
    MAX_DISCONTINUITY="${3:-$DEFAULT_MAX_DISCONTINUITY}"
    RADAR_REGION="${4:-}"
    validate_parameters
    validate_region_syntax "$RADAR_REGION"
elif (( $# > 0 )); then
    case "$1" in
        1)
            ACTION='preview'
            shift
            (( $# <= 3 )) ||
                die "mode 1 usage: $0 1 [CORR_THRESHOLD] [PAIR] [RADAR_REGION]"
            if (( $# == 0 )); then
                :
            elif [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
                PREVIEW_THRESHOLD="$1"
                shift
                if (( $# > 0 )); then
                    if [[ "$1" == */*/*/* ]]; then
                        RADAR_REGION="$1"
                        shift
                    else
                        PREVIEW_PAIR="$1"
                        shift
                        if (( $# > 0 )); then
                            RADAR_REGION="$1"
                            shift
                        fi
                    fi
                fi
            else
                PREVIEW_PAIR="$1"
                shift
                if (( $# > 0 )); then
                    if [[ "$1" == */*/*/* ]]; then
                        RADAR_REGION="$1"
                        shift
                    else
                        PREVIEW_THRESHOLD="$1"
                        shift
                        if (( $# > 0 )); then
                            RADAR_REGION="$1"
                            shift
                        fi
                    fi
                fi
            fi
            (( $# == 0 )) || die "could not parse extra Mode 1 arguments"
            validate_threshold "$PREVIEW_THRESHOLD"
            validate_region_syntax "$RADAR_REGION"
            ;;
        2)
            ACTION='submit'
            shift
            (( $# >= 1 && $# <= 3 )) ||
                die "mode 2 usage: $0 2 JOBS [CORR_THRESHOLD] [RADAR_REGION]"
            JOBS="$1"
            CORR_THRESHOLD="${2:-$DEFAULT_CORR_THRESHOLD}"
            RADAR_REGION="${3:-}"
            MAX_DISCONTINUITY="$DEFAULT_MAX_DISCONTINUITY"
            validate_parameters
            validate_region_syntax "$RADAR_REGION"
            ;;
        *)
            die "first argument must be mode 1 (preview) or mode 2 (formal unwrapping)"
            ;;
    esac
fi

for command_name in awk basename cp dirname gmt grep head mkdir mktemp mv sed sort tail uniq wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "$ROOT_DIR")"
[[ "$TRACK" =~ ^T[0-9]+[A-Za-z]?$ ]] ||
    die "run in a T-number track directory such as T142A (current: $ROOT_DIR)"

BURST_DIR="$ROOT_DIR/burst"
INTF_ALL_DIR="$BURST_DIR/intf_all"
EXPECTED_FILE="$BURST_DIR/run3.5_expected_pairs.tsv"
RUN35_FAILED="$BURST_DIR/run3.5_failed_pairs.tsv"
FINAL_INFO="$BURST_DIR/run3.3_finalized.info"
MASK_DEF="$BURST_DIR/mask_def.grd"
LANDMASK="$BURST_DIR/landmask_ra.grd"
PID_FILE="$BURST_DIR/run3.8_unwrap.pid"
FAILED_REPORT="$BURST_DIR/run3.8_failed_pairs.tsv"
MISSING_INPUT_REPORT="$BURST_DIR/run3.8_missing_inputs.tsv"
LOG_DIR="$BURST_DIR/$LOG_DIR_NAME"
NOHUP_LOG="$ROOT_DIR/$NOHUP_LOG_NAME"

[[ -d "$BURST_DIR" ]] || die "missing $BURST_DIR"
[[ -d "$INTF_ALL_DIR" ]] || die "missing $INTF_ALL_DIR; complete Run 3.5 first"
[[ -s "$EXPECTED_FILE" ]] || die "missing $EXPECTED_FILE; complete Run 3.5 first"
[[ -s "$FINAL_INFO" ]] || die "missing $FINAL_INFO; complete Run 3.3 Mode 2 first"
if [[ -s "$RUN35_FAILED" ]]; then
    die "Run 3.5 has failed pairs listed in $RUN35_FAILED; resolve them first"
fi

FINAL_STATUS="$(awk -F= '$1=="status" {print $2; exit}' "$FINAL_INFO")"
ACCEPTED_PAIRS="$(awk -F= '$1=="accepted_pair_count" {print $2; exit}' "$FINAL_INFO")"
[[ "$FINAL_STATUS" == FINALIZED ]] || die "Run 3.3 status is not FINALIZED"
[[ "$ACCEPTED_PAIRS" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid accepted_pair_count in $FINAL_INFO"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run3.8-burst.XXXXXX")"
PROCESS_STARTED=0
cleanup_exit() {
    rm -rf -- "$TEMP_DIR"
    if (( PROCESS_STARTED == 1 )); then
        rm -f -- "$PID_FILE"
    fi
}
trap cleanup_exit EXIT INT TERM

PAIR_LIST="$TEMP_DIR/all_pairs.txt"
MISSING_TEMP="$TEMP_DIR/missing.tsv"
PENDING_TEMP="$TEMP_DIR/pending.txt"
PAIR_COUNT=0
TEMPLATE_PAIR=''
TEMPLATE_GRID=''
TEMPLATE_SIGNATURE=''
make_pair_list "$PAIR_LIST"

if ! check_inputs_and_outputs "$PAIR_LIST" "$MISSING_TEMP" "$PENDING_TEMP"; then
    if [[ "$ACTION" != check ]]; then
        cp "$MISSING_TEMP" "$MISSING_INPUT_REPORT"
        printf 'Missing-input report: %s\n' "$MISSING_INPUT_REPORT" >&2
    fi
    die "unwrapping was not started"
fi
validate_region_against_template "$RADAR_REGION"

case "$ACTION" in
    check)
        usage
        printf '%s\n' '[CHECK ONLY] No preview or unwrapping was started.'
        if [[ -s "$PENDING_TEMP" ]]; then
            printf 'Pending pairs: %s\n' "$(wc -l < "$PENDING_TEMP" | awk '{print $1}')"
            printf '%s\n' '[NEXT PREVIEW] ./run3.8_unwrap_burst_parallel.sh 1'
            printf '%s\n' '[NEXT FORMAL]  ./run3.8_unwrap_burst_parallel.sh 2 5 0.0001'
        else
            printf '%s\n' '[COMPLETE] Every finalized pair already has unwrap.grd and unwrap.pdf.'
        fi
        exit 0
        ;;
    preview)
        make_presnaphu_preview "$PAIR_LIST" "$PREVIEW_PAIR" "$PREVIEW_THRESHOLD" "$RADAR_REGION"
        exit 0
        ;;
    submit)
        command -v nohup >/dev/null 2>&1 || die "required command not found: nohup"
        check_existing_process
        SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
        SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "$0")"
        nohup "$SCRIPT_PATH" --internal-run "$JOBS" "$CORR_THRESHOLD" "$MAX_DISCONTINUITY" "$RADAR_REGION" \
            > "$NOHUP_LOG" 2>&1 < /dev/null &
        BACKGROUND_PID=$!
        printf '%s\n' '========================================'
        printf '%s\n' 'Run 3.8 mode 2 submitted through nohup'
        printf 'Background PID         : %s\n' "$BACKGROUND_PID"
        printf 'Finalized pairs        : %s\n' "$PAIR_COUNT"
        printf 'Pending pairs          : %s\n' "$(wc -l < "$PENDING_TEMP" | awk '{print $1}')"
        printf 'Parallel unwrap jobs   : %s\n' "$JOBS"
        printf 'Correlation threshold  : %s\n' "$CORR_THRESHOLD"
        printf 'Radar crop             : %s\n' "${RADAR_REGION:-full grid}"
        printf 'Maximum discontinuity  : %s (fixed SBAS default)\n' "$MAX_DISCONTINUITY"
        printf 'Main log               : %s\n' "$NOHUP_LOG"
        printf '%s\n' 'The terminal may now be closed safely.'
        printf 'Monitor: tail -f %s\n' "$NOHUP_LOG_NAME"
        printf '%s\n' '========================================'
        exit 0
        ;;
    process)
        ;;
    *)
        die "internal action error: $ACTION"
        ;;
esac

(( INTERNAL_RUN == 1 )) || die "formal processing must use mode 2"
for command_name in parallel snaphu_interp.csh tcsh unwrap_parallel.csh; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

check_existing_process
printf '%s\n' "$$" > "$PID_FILE"
PROCESS_STARTED=1
rm -f -- "$MISSING_INPUT_REPORT" "$FAILED_REPORT"
mkdir -p "$LOG_DIR"

cp "$PAIR_LIST" "$INTF_ALL_DIR/intflist"
cp "$PENDING_TEMP" "$INTF_ALL_DIR/unwrap_pending_intflist"
PENDING_COUNT="$(wc -l < "$PENDING_TEMP" | awk '{print $1}')"
TOTAL_COUNT="$(wc -l < "$PAIR_LIST" | awk '{print $1}')"

if (( PENDING_COUNT == 0 )); then
    printf '%s\n' '[COMPLETE] Every finalized pair already has unwrap.grd and unwrap.pdf.'
    exit 0
fi

printf '%s\n' '========================================'
printf '%s\n' 'Run 3.8 mode 2: resumable parallel burst unwrapping'
printf 'Track root             : %s\n' "$ROOT_DIR"
printf 'Working directory      : %s\n' "$INTF_ALL_DIR"
printf 'Total finalized pairs  : %s\n' "$TOTAL_COUNT"
printf 'Previously complete    : %s\n' "$((TOTAL_COUNT - PENDING_COUNT))"
printf 'Pending pairs          : %s\n' "$PENDING_COUNT"
printf 'Parallel unwrap jobs   : %s\n' "$JOBS"
printf 'Correlation threshold  : %s\n' "$CORR_THRESHOLD"
printf 'Maximum discontinuity  : %s (fixed SBAS default)\n' "$MAX_DISCONTINUITY"
printf 'Radar crop             : %s\n' "${RADAR_REGION:-full grid}"
printf 'Unwrap driver          : %s\n' "$(command -v unwrap_parallel.csh)"
printf 'SNAPHU wrapper         : %s\n' "$(command -v snaphu_interp.csh)"
printf '%s\n' 'No merge/ directory is used.'
printf '%s\n' '========================================'

cd "$INTF_ALL_DIR"
# GMTSAR unwrap_parallel.csh invokes unwrap_intf.csh without ./.
export PATH="$(pwd -P):$PATH"

printf '%s\n' '[STEP 1] Generate the per-pair burst unwrap worker'
cat > unwrap_intf.csh <<EOF_WORKER
#!/bin/csh -f

set pair = \$1
set pair_log = "../../${LOG_DIR_NAME}/\${pair}.log"
set radar_region = "${RADAR_REGION}"

cd \$pair
ln -sfn ../../landmask_ra.grd .
ln -sfn ../../mask_def.grd .

# Remove temporary products left by an interrupted attempt.
rm -f mask_patch.grd corr_patch.grd phase_patch.grd landmask_ra_patch.grd
rm -f mask_def_patch.grd mask2_patch.grd corr_tmp.grd phase_tmp.grd
rm -f phase.in corr.in unwrap.out conncomp.out tmp.grd unwrap_grad.grd
rm -f unwrap.grd unwrap.pdf unwrap.ps unwrap.cpt conncomp.grd phasefilt_interp.grd
rm -f run3.8_unwrap_parameters.txt

if ("\$radar_region" == "") then
    snaphu_interp.csh ${CORR_THRESHOLD} ${MAX_DISCONTINUITY} >& \$pair_log
else
    snaphu_interp.csh ${CORR_THRESHOLD} ${MAX_DISCONTINUITY} "\$radar_region" >& \$pair_log
endif
set unwrap_status = \$status

# Some snaphu_interp.csh variants return a non-zero final cleanup status even
# after both validated products have been generated. Record parameters from
# the actual products, while preserving the wrapper status for the driver.
if (-s unwrap.grd && -s unwrap.pdf) then
    echo "correlation_threshold=${CORR_THRESHOLD}" >! run3.8_unwrap_parameters.txt
    echo "maximum_discontinuity=${MAX_DISCONTINUITY}" >> run3.8_unwrap_parameters.txt
    echo "radar_region=${RADAR_REGION}" >> run3.8_unwrap_parameters.txt
endif

cd ..
exit \$unwrap_status
EOF_WORKER
chmod +x unwrap_intf.csh

printf '%s\n' '[STEP 2] Remove stale command files and pending-pair logs'
rm -f -- unwrap.cmd
while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    rm -f -- "$LOG_DIR/$pair.log" "log_${pair}.txt"
done < unwrap_pending_intflist

printf '%s\n' '[STEP 3] Run GMTSAR unwrap_parallel.csh and wait for completion'
printf 'Command: unwrap_parallel.csh unwrap_pending_intflist %s\n' "$JOBS"
set +e
unwrap_parallel.csh unwrap_pending_intflist "$JOBS"
DRIVER_STATUS=$?
set -e
printf 'unwrap_parallel.csh exit status: %s\n' "$DRIVER_STATUS"
rm -f -- unwrap.cmd log_*.txt

printf '%s\n' '[STEP 4] Validate unwrap.grd and unwrap.pdf for every finalized pair'
: > "$FAILED_REPORT"
SUCCESS_COUNT=0
while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    missing_csv=""
    [[ -s "$pair/unwrap.grd" ]] || missing_csv='unwrap.grd'
    if [[ ! -s "$pair/unwrap.pdf" ]]; then
        [[ -z "$missing_csv" ]] || missing_csv+=","
        missing_csv+='unwrap.pdf'
    fi
    if [[ -n "$RADAR_REGION" ]]; then
        parameter_region=''
        parameter_threshold=''
        parameter_discontinuity=''
        if [[ -s "$pair/run3.8_unwrap_parameters.txt" ]]; then
            parameter_region="$(awk -F= '$1=="radar_region" {print $2; exit}' \
                "$pair/run3.8_unwrap_parameters.txt")"
            parameter_threshold="$(awk -F= '$1=="correlation_threshold" {print $2; exit}' \
                "$pair/run3.8_unwrap_parameters.txt")"
            parameter_discontinuity="$(awk -F= '$1=="maximum_discontinuity" {print $2; exit}' \
                "$pair/run3.8_unwrap_parameters.txt")"
        fi
        if [[ "$parameter_region" != "$RADAR_REGION" ||
              "$parameter_threshold" != "$CORR_THRESHOLD" ||
              "$parameter_discontinuity" != "$MAX_DISCONTINUITY" ]]; then
            [[ -z "$missing_csv" ]] || missing_csv+=","
            missing_csv+='parameters'
        fi
    fi
    if [[ -n "$missing_csv" ]]; then
        printf '%s\t%s\t%s/%s.log\n' "$pair" "$missing_csv" "$LOG_DIR" "$pair" \
            >> "$FAILED_REPORT"
    else
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
done < intflist

if [[ -s "$FAILED_REPORT" ]]; then
    FAILED_COUNT="$(wc -l < "$FAILED_REPORT" | awk '{print $1}')"
    printf '%s\n' '========================================' >&2
    printf '[FAILED] %s/%s finalized pairs are incomplete.\n' "$FAILED_COUNT" "$TOTAL_COUNT" >&2
    printf 'Driver exit status: %s\n' "$DRIVER_STATUS" >&2
    printf 'Failure report: %s\n' "$FAILED_REPORT" >&2
    printf '%s\n' 'First failures:' >&2
    head -n 20 "$FAILED_REPORT" | sed 's/^/  /' >&2
    printf '%s\n' 'Rerun the same mode 2 command to process only incomplete pairs.' >&2
    printf '%s\n' '========================================' >&2
    exit 1
fi

rm -f -- "$FAILED_REPORT"
printf '%s\n' '========================================'
printf '[DONE] All %s finalized burst pairs contain unwrap.grd and unwrap.pdf.\n' "$TOTAL_COUNT"
printf 'Newly submitted pairs : %s\n' "$PENDING_COUNT"
printf 'Previously complete   : %s\n' "$((TOTAL_COUNT - PENDING_COUNT))"
printf 'Per-pair logs         : %s/\n' "$LOG_DIR"
printf '%s\n' 'No merge/ directory was used.'
printf '%s\n' '========================================'
