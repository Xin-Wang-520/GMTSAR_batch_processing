#!/bin/csh -f
# Select conventional small-baseline pairs and plot the network.
# This single-file version deliberately contains no annual-pair exception.

# Disable csh history expansion so AWK's logical-not operator is passed intact.
set histchars =

if ($#argv != 3) then
    echo ""
    echo "Usage: select_pairs_regular.csh baseline_table.dat threshold_time threshold_baseline"
    echo ""
    echo "Selection rules:"
    echo "  0 < temporal baseline < threshold_time"
    echo "  absolute perpendicular-baseline difference < threshold_baseline"
    echo "  annual-pair rule: disabled"
    echo ""
    echo "Outputs: intf.in baseline.ps baseline.pdf"
    echo ""
    exit 1
endif

set file = "$1"
set dt = "$2"
set db = "$3"

if (! -s "$file") then
    echo "[ERROR] baseline table missing or empty: $file"
    exit 1
endif

foreach command_name (awk gmt)
    which "$command_name" >& /dev/null
    if ($status != 0) then
        echo "[ERROR] required command not found: $command_name"
        exit 1
    endif
end

echo "$dt $db" | awk '{if ($1 !~ /^[0-9]+([.][0-9]+)?$/ || $1+0 <= 0 || $2 !~ /^[0-9]+([.][0-9]+)?$/ || $2+0 <= 0) exit 1}'
if ($status != 0) then
    echo "[ERROR] thresholds must be numbers greater than zero: time=$dt baseline=$db"
    exit 1
endif

rm -f intf.in tmp text text2 baseline.ps baseline.pdf

awk -v dt="$dt" -v db="$db" 'function is_number(v){return v~/^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/} function absolute(v){return v<0?-v:v} /^[[:space:]]*$/||/^[[:space:]]*#/{next} {if(NF<5||!is_number($3)||!is_number($5)){printf "[ERROR] malformed baseline line %d: %s\n",NR,$0>"/dev/stderr";bad=1;next} n++;image[n]=$1;t[n]=$3+0;b[n]=$5+0;if(seen[$1]++){printf "[ERROR] duplicate image in baseline table: %s\n",$1>"/dev/stderr";bad=1}} END{if(bad)exit 2;if(n<2){print "[ERROR] at least two baseline records are required">"/dev/stderr";exit 2} pairs=0;for(i=1;i<=n;i++){for(j=1;j<=n;j++){delta_time=t[j]-t[i];delta_baseline=absolute(b[j]-b[i]);if(delta_time>0&&delta_time<dt&&delta_baseline<db){print image[i]":"image[j]>"intf.in";print t[i]/365.25+2014,b[i]>"tmp";print t[j]/365.25+2014,b[j]>"tmp";print "NaN","NaN">"tmp";pairs++}}}if(pairs==0){printf "[ERROR] no pairs satisfy time<%g days and baseline<%g m\n",dt,db>"/dev/stderr";exit 3}printf "Acquisitions       : %d\n",n;printf "Selected pairs     : %d\n",pairs;printf "Time rule          : 0 < dt < %g days\n",dt;printf "Baseline rule      : |db| < %g m\n",db;print "Annual-pair rule   : disabled"}' "$file"
if ($status != 0) then
    echo "[ERROR] regular pair selection failed"
    exit 1
endif

if (! -s intf.in || ! -s tmp) then
    echo "[ERROR] pair selector did not generate non-empty intf.in and tmp"
    exit 1
endif

awk '{print 2014+$3/365.25, $5, $1}' "$file" > text
set region = `gmt gmtinfo text -C | awk '{print $1-0.5, $2+0.5, $3-50, $4+50}'`
if ($#region != 4) then
    echo "[ERROR] failed to determine baseline plot region"
    exit 1
endif

gmt pstext text -JX8.8i/6.8i \
    -R$region[1]/$region[2]/$region[3]/$region[4] \
    -D0.2/0.2 -X1.5i -Y1i -K -N -F+f8,Helvetica+j5 > baseline.ps
if ($status != 0) then
    echo "[ERROR] GMT pstext failed"
    exit 1
endif

gmt psxy tmp -R -J -K -O >> baseline.ps
if ($status != 0) then
    echo "[ERROR] GMT failed to draw pair-network lines"
    exit 1
endif

awk '{print $1,$2}' text > text2
gmt psxy text2 -Sp0.2c -G0 -R -JX \
    -Ba0.5:"year":/a50g00f25:"baseline (m)":WSen -O >> baseline.ps
if ($status != 0) then
    echo "[ERROR] GMT failed to draw acquisition points"
    exit 1
endif

gmt psconvert baseline.ps -Tf -A
if ($status != 0 || ! -s baseline.pdf) then
    echo "[ERROR] failed to generate baseline.pdf"
    exit 1
endif

rm -f tmp text text2
echo "[DONE] Conventional small-baseline network generated; annual pairs disabled."
