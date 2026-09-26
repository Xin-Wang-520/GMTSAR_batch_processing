#!/bin/csh -f

# Select interferometric pairs using temporal and perpendicular-baseline limits.
#
# Original workflow: Zhao Xuan, Nov 16 2023
# Updated plotting: Xin Wang, Sep 26 2026

if ($#argv != 3) then
    echo ""
    echo "Usage: select_pairs_new.csh baseline_table.dat threshold_time threshold_baseline"
    echo ""
    echo "  Generate intf.in and a time-baseline network plot."
    echo ""
    echo "  Outputs:"
    echo "    intf.in"
    echo "    baseline.ps"
    echo "    baseline.pdf"
    echo ""
    exit 1
endif

set file = "$1"
set dt = "$2"
set db = "$3"
set pygmtsar = "/home/xinw/bin/own"
set python = "/home/xinw/.conda/envs/xinw_insar/bin/python"

if (! -s "$file") then
    echo "[ERROR] baseline table not found or empty: $file"
    exit 1
endif

if (! -x "$python") then
    echo "[ERROR] Python interpreter not executable: $python"
    exit 1
endif

if (! -f "$pygmtsar/select_pairs.py") then
    echo "[ERROR] pair-selection program not found: $pygmtsar/select_pairs.py"
    exit 1
endif

if (! -s batch_tops.config) then
    echo "[ERROR] configuration file not found or empty: batch_tops.config"
    exit 1
endif

rm -f intf.in baseline.ps baseline.pdf tmp text text2

# Read the authoritative master selected by Run 3.3 from batch_tops.config.
set master = `awk -F= '/^[[:space:]]*master_image[[:space:]]*=/ {value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit}' batch_tops.config`

if ("$master" == "") then
    echo "[ERROR] master_image was not found in batch_tops.config"
    exit 1
endif

echo "[MASTER] batch_tops.config: master_image = $master"

# Generate intf.in and the line-segment file tmp first, so the pair count can
# be included in the plot title.
"$python" "$pygmtsar/select_pairs.py" "$file" "$dt" "$db"
if ($status != 0) then
    echo "[ERROR] select_pairs.py failed"
    exit 1
endif

if (! -s intf.in) then
    echo "[ERROR] intf.in was not generated or contains no pairs"
    exit 1
endif

if (! -s tmp) then
    echo "[ERROR] temporary network line file was not generated: tmp"
    exit 1
endif

set pair_count = `awk 'END {print NR + 0}' intf.in`
set master_date = `echo "$master" | sed -n 's/^S1_\([0-9][0-9]*\)_ALL_F[123]$/\1/p'`
if ("$master_date" == "") set master_date = "$master"
set title = "SBAS network | Time <= $dt d | Bperp <= $db m | Pairs = $pair_count | Master = $master_date"

# x = decimal year; y = perpendicular baseline; third field = image name.
awk '{print 2014 + $3 / 365.25, $5, $1}' "$file" > text
set region = `gmt info text -C | awk '{print $1-0.5, $2+0.5, $3-50, $4+50}'`

# Keep the original labelled-node style.
gmt pstext text -JX8.8i/6.8i \
    -R$region[1]/$region[2]/$region[3]/$region[4] \
    -D0.2/0.2 -X1.5i -Y1i -K -N \
    -F+f8,Helvetica+j5 > baseline.ps

gmt psxy tmp -R -J -K -O >> baseline.ps

awk '{print $1, $2}' text > text2
gmt psxy text2 -R -J \
    -Sp0.2c -G0 \
    -Bxa1f1+l"Year" \
    -Bya50f25+l"Perpendicular baseline (m)" \
    -BWSen+t"$title" \
    --FONT_TITLE=9p --MAP_TITLE_OFFSET=8p \
    -O >> baseline.ps

gmt psconvert baseline.ps -Tf -A
if ($status != 0 || ! -s baseline.pdf) then
    echo "[ERROR] failed to create baseline.pdf"
    exit 1
endif

rm -f tmp text text2

echo "[DONE] Selected pairs : $pair_count"
echo "[DONE] Master image   : $master"
echo "[DONE] Plot           : baseline.pdf"
