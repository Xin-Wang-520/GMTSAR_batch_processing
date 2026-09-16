#!/usr/bin/env bash
# Run 3.3: calculate LT-1 baselines and select interferogram pairs.
# Preview is the default. Add positional argument 1 to write the output files.
# Recommended defaults are 60 days and 200 m; both can be overridden explicitly
# on the command line so that the processing choice remains visible.
set -euo pipefail

usage() {
    cat <<'HELP'
Run 3.3: calculate LT-1 baselines and select interferogram pairs

Usage:
  run3.3_select_pairs_LT1.sh --master YYYYMMDD [--max-days DAYS] [--max-baseline METERS]
  run3.3_select_pairs_LT1.sh 1 --master YYYYMMDD [--max-days DAYS] [--max-baseline METERS]
  run3.3_select_pairs_LT1.sh [1] --master YYYYMMDD [options]

Example:
  ./run3.3_select_pairs_LT1.sh --master 20250423 --max-days 60 --max-baseline 200
  ./run3.3_select_pairs_LT1.sh 1 --master 20250423 --max-days 60 --max-baseline 200

Required options:
  --master DATE          Master date in YYYYMMDD format.

Optional thresholds:
  --max-days DAYS        Maximum absolute temporal separation (default: 60 days).
  --max-baseline METERS  Maximum absolute perpendicular-baseline separation (default: 200 m).

Optional files:
  --input FILE           Acquisition list (default: data.list).
  --pairs FILE           Pair-list output (default: intf.list).
  --baseline FILE        Baseline-table output (default: baseline_table.LT1.dat).
  --plot-prefix PREFIX   Plot filename prefix (default: baseline_LT1).

Pair format:
  LT1_YYYYMMDD:LT1_YYYYMMDD

Formal mode writes the baseline table and pair list. Existing files with the
same names are backed up under archive_run3.3/TIMESTAMP/.

Baselines are calculated from the final aligned/cropped files in SLC/:
  SLC/LT1_YYYYMMDD.PRM
  SLC/LT1_YYYYMMDD.LED
Files ending in .PRM0 or .PRMresamp are intermediate products and are ignored.

The example thresholds are only an example, not a mandatory scientific choice.
Preview the selected pairs and network connectivity before formal writing.
HELP
}

die() { echo "[ERROR] $*" >&2; exit 1; }

is_positive_number() {
    awk -v value="$1" 'BEGIN {exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0)}'
}

formal=0
master_date=""
max_days="60"
max_baseline="200"
input_file="data.list"
pairs_file="intf.list"
baseline_file="baseline_table.LT1.dat"
plot_prefix="baseline_LT1"

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        1) formal=1; shift ;;
        --master)
            [[ $# -ge 2 ]] || die "--master requires YYYYMMDD"
            master_date="$2"
            shift 2
            ;;
        --max-days)
            [[ $# -ge 2 ]] || die "--max-days requires a number"
            max_days="$2"
            shift 2
            ;;
        --max-baseline)
            [[ $# -ge 2 ]] || die "--max-baseline requires a number"
            max_baseline="$2"
            shift 2
            ;;
        --input)
            [[ $# -ge 2 ]] || die "--input requires a file"
            input_file="$2"
            shift 2
            ;;
        --pairs)
            [[ $# -ge 2 ]] || die "--pairs requires a file"
            pairs_file="$2"
            shift 2
            ;;
        --baseline)
            [[ $# -ge 2 ]] || die "--baseline requires a file"
            baseline_file="$2"
            shift 2
            ;;
        --plot-prefix)
            [[ $# -ge 2 ]] || die "--plot-prefix requires a filename prefix"
            plot_prefix="$2"
            shift 2
            ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ "$master_date" =~ ^[0-9]{8}$ ]] || die "--master must be YYYYMMDD"
is_positive_number "$max_days" || die "--max-days must be a positive number"
is_positive_number "$max_baseline" || die "--max-baseline must be a positive number"

master_stem="LT1_${master_date}"
root_dir="$(pwd -P)"
raw_dir="$root_dir/raw"
slc_dir="$root_dir/SLC"
topo_dir="$root_dir/topo"

[[ -f "$input_file" ]] || die "input list not found: $input_file"
[[ -f "$slc_dir/${master_stem}.PRM" ]] || die "aligned/cropped master PRM not found: $slc_dir/${master_stem}.PRM"
[[ -e "$slc_dir/${master_stem}.SLC" ]] || die "aligned/cropped master SLC not found: $slc_dir/${master_stem}.SLC"
[[ -e "$slc_dir/${master_stem}.LED" ]] || die "aligned master LED not found: $slc_dir/${master_stem}.LED"
[[ -s "$topo_dir/topo_ra.grd" ]] || die "topo/topo_ra.grd not found; complete Run 3.2 first"

first_record="$(awk 'NF && $1 !~ /^#/ {print $1; exit}' "$input_file")"
[[ "$first_record" == "$master_stem" ]] || die "first data.list record is '$first_record', expected '$master_stem'"

baseline_cmd="$(command -v SAT_baseline || true)"
[[ -n "$baseline_cmd" ]] || die "SAT_baseline was not found in PATH"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/run3.3_lt1.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
normalized_list="$tmp_dir/data.list"
baseline_tmp="$tmp_dir/baseline_table.LT1.dat"
pairs_tmp="$tmp_dir/intf.list"

# Return a monotonically increasing Gregorian day number for YYYYMMDD. This
# is used only to place the master record in the same time-day system as the
# baseline_table.csh records from the other acquisitions.
calendar_day() {
    awk -v s="$1" 'BEGIN {
        y=substr(s,1,4)+0; m=substr(s,5,2)+0; d=substr(s,7,2)+0
        a=int((14-m)/12); yy=y+4800-a; mm=m+12*a-3
        print d+int((153*mm+2)/5)+365*yy+int(yy/4)-int(yy/100)+int(yy/400)-32045
    }'
}

awk 'NF && $1 !~ /^#/ {print $1}' "$input_file" > "$normalized_list"
scene_count="$(wc -l < "$normalized_list" | awk '{print $1}')"
[[ "$scene_count" -ge 2 ]] || die "at least two acquisitions are required"

# SAT_baseline opens the LED filename stored inside each PRM as a relative
# filename, so expose the final SLC/ orbit links in the private directory.
while IFS= read -r stem; do
    [[ "$stem" =~ ^LT1_[0-9]{8}$ ]] || die "invalid acquisition name in $input_file: $stem"
    # baseline_table.csh cannot produce a useful self-baseline record. The
    # master (zero temporal and perpendicular baseline) is added below.
    if [[ "$stem" == "$master_stem" ]]; then
        continue
    fi
    [[ -f "$slc_dir/${stem}.PRM" ]] || die "missing SLC/${stem}.PRM; Run 3.1 may be incomplete"
    [[ -e "$slc_dir/${stem}.SLC" ]] || die "missing SLC/${stem}.SLC; Run 3.1 may be incomplete"
    [[ -e "$slc_dir/${stem}.LED" ]] || die "missing SLC/${stem}.LED; Run 3.1 may be incomplete"

    ln -sfn "$slc_dir/${master_stem}.LED" "$tmp_dir/${master_stem}.LED"
    ln -sfn "$slc_dir/${stem}.LED" "$tmp_dir/${stem}.LED"

    set +e
    baseline_output="$(cd "$tmp_dir" && "$baseline_cmd" "$slc_dir/${master_stem}.PRM" "$slc_dir/${stem}.PRM" 2>&1)"
    baseline_status=$?
    set -e
    if [[ "$baseline_status" -ne 0 ]]; then
        echo "[DETAIL] SAT_baseline exited with status $baseline_status for $stem:" >&2
        printf '%s\n' "$baseline_output" | tail -30 >&2
        die "failed to calculate baseline for $stem"
    fi
    bparallel="$(printf '%s\n' "$baseline_output" | awk -F= '/^[[:space:]]*B_parallel[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    bperp="$(printf '%s\n' "$baseline_output" | awk -F= '/^[[:space:]]*B_perpendicular[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    xshift="$(printf '%s\n' "$baseline_output" | awk -F= '/^[[:space:]]*rshift[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    yshift="$(printf '%s\n' "$baseline_output" | awk -F= '/^[[:space:]]*ashift[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    st0="$(awk '$1=="SC_clock_start" && $2=="=" {print $3; exit}' "$slc_dir/${stem}.PRM")"
    day="$(calendar_day "${stem#LT1_}")"
    [[ "$bperp" =~ ^[-+]?[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$ ]] || {
        echo "[DETAIL] SAT_baseline output for $stem:" >&2
        printf '%s\n' "$baseline_output" | tail -30 >&2
        die "failed to parse B_perpendicular for $stem"
    }
    [[ "$bparallel" =~ ^[-+]?[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$ ]] || bparallel=0
    [[ "$xshift" =~ ^[-+]?[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$ ]] || xshift=0
    [[ "$yshift" =~ ^[-+]?[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$ ]] || yshift=0
    [[ -n "$st0" ]] || st0=0
    normalized_line="$stem $st0 $day $bparallel $bperp $xshift $yshift"
    printf '%s\n' "$normalized_line" >> "$baseline_tmp.unsorted"
done < "$normalized_list"

[[ -s "$baseline_tmp.unsorted" ]] || die "no secondary acquisitions available for baseline calculation"

# Add the master as the zero-baseline reference. All days use the same
# Gregorian-day system derived from the acquisition date in the filename.
master_calendar_day="$(calendar_day "$master_date")"
master_st0="$(awk '$1=="SC_clock_start" && $2=="=" {print $3; exit}' "$slc_dir/${master_stem}.PRM")"
[[ -n "$master_st0" ]] || master_st0=0
printf '%s %s %s 0 0 0 0\n' "$master_stem" "$master_st0" "$master_calendar_day" >> "$baseline_tmp.unsorted"

sort -k3,3n "$baseline_tmp.unsorted" > "$baseline_tmp"

# Select every chronological pair satisfying both thresholds. Column 3 is
# acquisition time in days; column 5 is perpendicular baseline in metres.
awk -v max_days="$max_days" -v max_baseline="$max_baseline" '
    BEGIN { count=0 }
    {
        name[count]=$1
        day[count]=$3
        bperp[count]=$5
        count++
    }
    END {
        # Arrays are zero-based because the first input record is stored at
        # index 0.  Starting at i=1 would silently drop the earliest scene
        # (for example LT1_20250101) from every possible interferogram.
        for (i=0; i<=count-2; i++) {
            for (j=i+1; j<=count-1; j++) {
                # Never create a self-interferogram, even if duplicate records
                # accidentally occur in the acquisition list.
                if (name[i] == name[j]) continue
                dt=day[j]-day[i]
                if (dt < 0) dt=-dt
                db=bperp[j]-bperp[i]
                if (db < 0) db=-db
                if (dt <= max_days && db <= max_baseline)
                    print name[i] ":" name[j]
            }
        }
    }
' "$baseline_tmp" > "$pairs_tmp"

pair_count="$(wc -l < "$pairs_tmp" | awk '{print $1}')"
[[ "$pair_count" -gt 0 ]] || die "no pairs satisfy max_days=$max_days and max_baseline=$max_baseline"
if awk -F: '$1 == $2 {bad=1} END {exit bad ? 0 : 1}' "$pairs_tmp"; then
    die "self-interferogram detected in generated pair list"
fi

# Report acquisitions that are absent from the selected network.
awk -F: 'NR==FNR {scene[$1]=1; next} {used[$1]=1; used[$2]=1} END {for (s in scene) if (!(s in used)) print s}' \
    "$normalized_list" "$pairs_tmp" | sort > "$tmp_dir/disconnected.list"
disconnected_count="$(wc -l < "$tmp_dir/disconnected.list" | awk '{print $1}')"

echo "========================================================================"
echo "LT-1 Run 3.3 Select interferogram pairs"
echo "Mode:                  $([[ "$formal" -eq 1 ]] && echo FORMAL || echo PREVIEW)"
echo "Working dir:           $root_dir"
echo "Master:                $master_stem"
echo "Acquisition list:      $input_file"
echo "Acquisitions:          $scene_count"
echo "Maximum time span:     $max_days days"
echo "Maximum baseline span: $max_baseline m"
echo "Selected pairs:        $pair_count"
echo "Pair-list output:      $pairs_file"
echo "Baseline output:       $baseline_file"
echo "Baseline plot:         ${plot_prefix}.ps / ${plot_prefix}.pdf / ${plot_prefix}.png"
echo "------------------------------------------------------------------------"
echo "Baseline table (relative to $master_stem):"
awk '{printf "  %-12s time_day=%-10.3f Bperp=%10.3f m\n",$1,$3,$5}' "$baseline_tmp"
echo "------------------------------------------------------------------------"
echo "Selected pairs:"
sed 's/^/  /' "$pairs_tmp"
echo "------------------------------------------------------------------------"
if [[ "$disconnected_count" -eq 0 ]]; then
    echo "Network coverage: all $scene_count acquisitions occur in at least one pair"
else
    echo "[WARNING] $disconnected_count acquisition(s) do not occur in any selected pair:"
    sed 's/^/  /' "$tmp_dir/disconnected.list"
fi
echo "========================================================================"

if [[ "$formal" -eq 0 ]]; then
    echo "[PREVIEW] No output file was written."
    echo "[NEXT]    $0 1 --master $master_date --max-days $max_days --max-baseline $max_baseline"
    exit 0
fi

timestamp="$(date +%Y%m%dT%H%M%S)"
archive_dir="$root_dir/archive_run3.3/$timestamp"
archive_count=0
for old_file in "$pairs_file" "$baseline_file" "${plot_prefix}.ps" "${plot_prefix}.png" "${plot_prefix}.pdf"; do
    if [[ -e "$old_file" ]]; then
        mkdir -p "$archive_dir"
        cp -a "$old_file" "$archive_dir/"
        archive_count=$((archive_count + 1))
    fi
done

cp "$pairs_tmp" "$pairs_file"
cp "$baseline_tmp" "$baseline_file"

# Draw a time-versus-perpendicular-baseline network plot using the classic GMT
# psxy/pstext workflow used by get_baseline_table.csh. Pair lines are read from
# the final intf.list, and labels come from the generated baseline table.
command -v gmt >/dev/null 2>&1 || die "GMT was not found in PATH; pair files were written but the plot was not generated"
plot_points="$tmp_dir/baseline_points.xy"
plot_master="$tmp_dir/master_point.xy"
plot_lines="$tmp_dir/pair_lines.xy"
plot_labels="$tmp_dir/baseline_labels.txt"
awk '
    function leap(y) { return (y%400==0 || (y%4==0 && y%100!=0)) }
    function doy(y,m,d, i,n,a) {
        n=0; for (i=1; i<m; i++) { a=(i==2 ? 28 : (i==4 || i==6 || i==9 || i==11 ? 30 : 31)); if (i==2 && leap(y)) a=29; n+=a }
        return n+d
    }
    {
        y=substr($1,5,4)+0; m=substr($1,9,2)+0; d=substr($1,11,2)+0
        x=y+(doy(y,m,d)-1)/(leap(y) ? 366 : 365)
        printf "%.8f %.12g %s\n", x,$5,$1
    }
' "$baseline_tmp" > "$plot_points"
cp "$plot_points" "$plot_labels"
awk -v master="$master_stem" '$3 == master {print $1,$2}' "$plot_points" > "$plot_master"
awk 'NR==FNR {x[$3]=$1; b[$3]=$2; next} {
    split($1,p,":")
    if ((p[1] in x) && (p[2] in x)) {
        print "> " p[1] ":" p[2]
        print x[p[1]],b[p[1]]
        print x[p[2]],b[p[2]]
    }
}' "$plot_points" "$pairs_file" > "$plot_lines"

plot_line_count="$(awk '/^>/ {n++} END {print n+0}' "$plot_lines")"
if [[ "$plot_line_count" -ne "$pair_count" ]]; then
    echo "[WARNING] Plot matched $plot_line_count/$pair_count pairs from $pairs_file"
fi

plot_bounds="$(gmt info "$plot_points" -C | awk '{print $1,$2,$3,$4}')"
read -r xmin xmax ymin ymax <<< "$plot_bounds"
xpad="$(awk -v a="$xmin" -v b="$xmax" 'BEGIN {p=(b-a)*0.05; if (p<0.01) p=0.01; print p}')"
yrange="$(awk -v a="$ymin" -v b="$ymax" 'BEGIN {print b-a}')"
ypad="$(awk -v r="$yrange" 'BEGIN {p=r*0.12; if (p<10) p=10; print p}')"
plot_region="$(awk -v a="$xmin" -v b="$xmax" -v c="$ymin" -v d="$ymax" -v xp="$xpad" -v yp="$ypad" 'BEGIN {printf "%.8f/%.8f/%.8f/%.8f",a-xp,b+xp,c-yp,d+yp}')"
plot_ps="${plot_prefix}.ps"
plot_title="LT-1 Baseline Network (${max_days} d, ${max_baseline} m, ${pair_count} pairs)"
# Show numeric year ticks every 0.3 year and perpendicular-baseline ticks
# every 100 m. The title records the thresholds and selected-pair count.
# Each selected pair is drawn as one line segment below.
gmt psbasemap -R"$plot_region" -JX15c/9c -Bxa0.3f0.3+l"Acquisition year" -Bya100f100+l"Perpendicular baseline (m)" -BWSen+t"$plot_title" -K > "$plot_ps"
gmt psxy "$plot_lines" -R -J -W0.7p,gray -K -O >> "$plot_ps"
gmt psxy "$plot_points" -R -J -Sc0.16c -Gsteelblue -W0.25p,black -K -O >> "$plot_ps"
if [[ -s "$plot_master" ]]; then
    gmt psxy "$plot_master" -R -J -Sa0.34c -Gred -W0.3p,black -K -O >> "$plot_ps"
fi
# Place acquisition labels below each point so they do not cover the marker.
gmt pstext "$plot_labels" -R -J -F+f6p,Helvetica+jTC -D0/-0.22c -O >> "$plot_ps"
gmt psconvert "$plot_ps" -Tf -A -P
gmt psconvert "$plot_ps" -Tg -A -P

if [[ "$archive_count" -gt 0 ]]; then
    echo "[ARCHIVE] Backed up $archive_count previous output file(s) to $archive_dir"
fi
echo "[SUCCESS] Wrote $pair_count pairs to $pairs_file"
echo "[SUCCESS] Wrote $scene_count baseline records to $baseline_file"
echo "[SUCCESS] Wrote baseline network plot: ${plot_prefix}.ps, ${plot_prefix}.pdf and ${plot_prefix}.png"
echo "[NEXT]    batch_processing.csh LT1 $master_stem $pairs_file 4 config.LT1.txt"
