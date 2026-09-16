#!/bin/csh -f
# by xinw 2025.7.21 in USTC
# tcsh preproc_batch_tops_parallel_new_wx.csh data.in dem.grd 5 1

if ($#argv < 4 || $#argv > 5) then
  echo "tcsh preproc_batch_tops_parallel_new_wx.csh data.in dem.grd 5 1"
  echo "Usage: preproc_batch_tops_parallel_new_wx.csh data.in dem.grd n_threads mode [esd_mode]"
  echo "  preprocess and align a set of TOPS images in data.in; precise orbits required"
  echo ""
  echo "  format of data.in:"
  echo "    image_name:orbit_name"
  echo ""
  echo "  outputs:"
  echo "    baseline_table.dat *.PRM *.LED *.SLC"
  echo "    baseline.ps baseline.pdf (standard mode only)"
  echo ""
  exit 1
endif

set file = $1
set dem = $2
set ncores = $3
set mode = $4
set esd = 1
if ($#argv == 5) then
  set esd = $5
endif

set masterline = `awk 'NR==1{print $1}' $file`
set dmaster = `echo $masterline | awk -F: '{print substr($1,16,8)}'`
set omaster = `echo $masterline | awk -F: '{print $NF}'`

# Clean old command files.
rm -f preproc.cmd tmp_dirlist

# Loop over data.in, skipping the master line.
foreach line (`awk 'NR>1{print $1}' $file`)
  set daligned = `echo $line | awk -F: '{print substr($1,16,8)}'`
  set oaligned = `echo $line | awk -F: '{print $NF}'`
  set dirname = ${dmaster}_${daligned}
  set script = ${dirname}.csh

  # Check orbit files.
  if (! -f $omaster || ! -f $oaligned) then
    echo "[ERROR] Orbit file missing: $omaster or $oaligned; skipping $dirname"
    continue
  endif

  # Build one master-slave processing directory.
  rm -rf $dirname
  mkdir $dirname
  echo $dirname >> tmp_dirlist
  cd $dirname

  # Link input files.
  ln -s ../*$dmaster*xml .
  ln -s ../*$dmaster*tiff .
  ln -s ../$omaster .
  ln -s ../*$daligned*xml .
  ln -s ../*$daligned*tiff .
  ln -s ../$oaligned .
  ln -s ../$dem .

  # Write the two-record local data.in.
  echo $masterline > data.in
  echo $line >> data.in

  cd ..

  # Write the pair job script.
  rm -f $script
  echo "cd $dirname" >> $script
  if ($mode == 1) then
    echo "preproc_batch_tops.csh data.in $dem 2 >& log" >> $script
  else
    echo "preproc_batch_tops_esd.csh data.in $dem 2 $esd >& log" >> $script
  endif
  echo "mv *${daligned}*ALL*PRM .." >> $script
  echo "mv *${daligned}*ALL*LED .." >> $script
  echo "mv *${daligned}*ALL*SLC .." >> $script
  echo "cd .." >> $script
  chmod +x $script

  # Register the pair job for GNU Parallel.
  echo "tcsh $script > log_${dirname}" >> preproc.cmd
end

# Run master-slave pairs in parallel.
parallel --jobs $ncores < preproc.cmd

# Collect master PRM/LED/SLC from pair directories.
foreach d (`cat tmp_dirlist`)
  mv $d/*${dmaster}*ALL*PRM . >& /dev/null
  mv $d/*${dmaster}*ALL*LED . >& /dev/null
  mv $d/*${dmaster}*ALL*SLC . >& /dev/null
end

# Remove pair directories and temporary job scripts.
foreach d (`cat tmp_dirlist`)
  rm -rf $d
  rm -f ${d}.csh log_${d}
end

# Build the baseline tables.
set masterPRM = `ls *ALL*PRM | grep $dmaster`
ls *ALL*PRM > prmlist
rm -f baseline_table.dat table.gmt
foreach prm (`cat prmlist`)
  baseline_table.csh $masterPRM $prm >> baseline_table.dat
  baseline_table.csh $masterPRM $prm GMT >> table.gmt
end

# Plot the standard-mode time-baseline distribution and create a PDF.
if ($mode == 1) then
  awk '{print 2014+$1/365.25,$2,$7}' table.gmt > text
  set region = `gmt gmtinfo text -C | awk '{print $1-0.5, $2+0.5, $3-50, $4+50}'`
  gmt pstext text -JX8.8i/6.8i -R$region[1]/$region[2]/$region[3]/$region[4] -D0.2/0.2 -X1.5i -Y1i -K -N -F+f8,Helvetica+j5 > baseline.ps
  awk '{print $1,$2}' text > text2
  gmt psxy text2 -Sp0.2c -G0 -R -JX -Ba0.5:"year":/a50g00f25:"baseline (m)":WSen -O >> baseline.ps

  rm -f baseline.pdf
  gmt psconvert baseline.ps -Tf -A
  if ($status != 0) then
    echo "[ERROR] gmt psconvert failed for baseline.ps"
    exit 1
  endif
  if (! -e baseline.pdf) then
    echo "[ERROR] baseline.pdf was not created"
    exit 1
  endif
  echo "[OK] Created baseline.pdf"

  rm -f text text2 table.gmt
endif
