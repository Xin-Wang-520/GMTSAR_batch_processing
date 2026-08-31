#!/bin/csh -f

setenv LC_ALL C
setenv LANG C
#       $Id$
#
# Xiaohua(Eric) Xu, Mar 20 2017
#
# Modified:
#   Add mode=1 summary statistics:
#     - number of re-organizable frame records
#     - number of re-organizable dates
#     - number of skipped dates
#     - skip reasons
#

  if ($#argv != 3 && $#argv != 4) then
    echo ""
    echo "Usage: organize_files_tops_linux.csh filelist pins.ll mode [observation_mode]"
    echo "  organize one track of S1A TOPS data, redefine frames, auto-download precise orbits"
    echo "    if restituted orbits are required, user must download separately"
    echo ""
    echo "filelist:"
    echo "    pth_filename1"
    echo "    pth_filename2"
    echo "    ......"
    echo ""
    echo "pins.ll:"
    echo "    lon1 lat1"
    echo "    lon2 lat2"
    echo "    ......"
    echo ""
    echo "Note: "
    echo "    files listed in filelist should be the .SAFE directory with absolute path."
    echo "    mode = 1 will tell how many records are gonna be generated. mode = 2 will do the organizing."
    exit 1
  endif

  
  set orb_dir = "Sentinel_Orbits"
 
  set ii = 0
  set mode = $3
  set org_mod = vv
  if ($#argv == 4) then
    set org_mod = $4
  endif

  # ============================================================
  # Statistics for mode = 1
  # ============================================================
  set n_good_frame = 0
  set n_good_date = 0
  set n_skip_date = 0
  set n_skip_gap = 0
  set n_skip_cover = 0

  if (-f organize_mode1_good_dates.txt) rm -f organize_mode1_good_dates.txt
  if (-f organize_mode1_skip_dates.txt) rm -f organize_mode1_skip_dates.txt
  if (-f organize_mode1_summary.txt) rm -f organize_mode1_summary.txt

  if (-f tmprecord) rm tmprecord

  # divide the list of files into sets, and create frames based on the given pins
  foreach line (`awk '{print $0}' $1`)
    set file1 = `echo $line | awk -F"," '{print $1}'`
    set date1 = `echo $file1 | awk '{print substr($1,length($1)-54,8)}'`
    set SAT1 = `echo $file1 | awk '{print substr($1,length($1)-71,3)}'`
    set orbittype="AUX_POEORB"
    
    if ($ii == 0) then
      set file0 = `echo $file1`
      set date0 = `echo $date1`
      set SAT0 = `echo $SAT1`
      echo $file1 > tmprecord
      set ii = 1
    else
      # gather files from the same date
      if ($date1 == $date0 && $SAT1 == $SAT0) then
        echo $file1 >> tmprecord
      else

        echo "" | awk '{printf("%s ","Combing")}' 
        set jj = 1
        set t2 = 9999999999

        # examining whether the frames are consecutive
        foreach line2 (`awk '{print $0}' tmprecord`)
          echo $line2 | awk '{printf("%s ",$1)}'

          set tt = `echo $line2 | awk '{print substr($1,length($1)-54,15)}'`
          set ss2 = `echo $tt|awk '{print substr($1,1,4)"/"substr($1,5,2)"/"substr($1,7,2)" "substr($1,10,2)":"substr($1,12,2)":"substr($1,14,2)}'`
          set t1 = `date --date="$ss2" +%s`

          set test = `echo $t1 $t2 | awk '{if ($1 > $2) print 1; else print 0}'`
          if ($test == 1) set jj = 0

          set tt = `echo $line2 | awk '{print substr($1,length($1)-38,15)}'`
          set ss2 = `echo $tt|awk '{print substr($1,1,4)"/"substr($1,5,2)"/"substr($1,7,2)" "substr($1,10,2)":"substr($1,12,2)":"substr($1,14,2)}'`
          set t2 = `date --date="$ss2" +%s`
        end
        echo "" | awk '{printf("%s\n","...")}'

        # get the orbit file names and download
        set n1 = ` date --date="$date0 - 1 day" +%Y%m%d `
        set n2 = ` date --date="$date0 + 1 day" +%Y%m%d `

        echo "Required orbit file dates: ${n1} to  ${n2}..."

        cat tmprecord | awk 'NR==1{print $1}' > tmp_safelist
        download_sentinel_orbits_linux.csh tmp_safelist 1
        set orbit = `ls *EOF | grep $n1 | grep $n2 | tail -1` 

        if ("x" == $orbit"x") then
          download_sentinel_orbits_linux.csh tmp_safelist 2 > tmp_download_log
          set orbit = `grep "restituted" tmp_download_log | awk '{print $4}'`
        endif

        echo "Downloaded orbit file $orbit"
        rm -f tmp_safelist tmp_download_log

        # compute azimuth for the start and end 
        set pin1 = `head -1 $2 | awk '{print $1,$2}'` 
        set f1 = `head -1 tmprecord`

        echo "make_s1a_tops $f1/annotation/*iw1*"$org_mod"*xml $f1/measurement/*iw1*"$org_mod"*tiff tmp2 0"
        make_s1a_tops $f1/annotation/*iw1*"$org_mod"*xml $f1/measurement/*iw1*"$org_mod"*tiff tmp2 0
        ext_orb_s1a tmp2.PRM $orbit tmp2

        set tmpazi = `echo $pin1 | awk '{print $1,$2,0}' | SAT_llt2rat tmp2.PRM 1 | awk '{printf("%d",$2+0.5)}'`

        # refine the calculation in case the pin is far away from the starting frame
        shift_atime_PRM.csh tmp2.PRM $tmpazi
        set azi1 = `echo $pin1 | awk '{print $1,$2,0}' | SAT_llt2rat tmp2.PRM 1 | awk '{printf("%d",$2+0.5 + '$tmpazi')}'`
        
        set pin2 = `tail -1 $2 | awk '{print $1,$2}'`
        set f2 = `tail -1 tmprecord`

        make_s1a_tops $f2/annotation/*iw1*"$org_mod"*xml $f2/measurement/*iw1*"$org_mod"*tiff tmp2 0
        ext_orb_s1a tmp2.PRM $orbit tmp2

        set tmpazi = `echo $pin2 | awk '{print $1,$2,0}' | SAT_llt2rat tmp2.PRM 1 | awk '{printf("%d",$2+0.5)}'`

        # refine the calculation in case the pin is far away from the starting frame
        shift_atime_PRM.csh tmp2.PRM $tmpazi
        set azi2 = `echo $pin2 | awk '{print $1,$2,0}' | SAT_llt2rat tmp2.PRM 1 | awk '{printf("%d",$2+0.5 + '$tmpazi')}'`

        set nl = `grep num_lines tmp2.PRM | awk '{print $3}'`

        if ($azi1 > 0 && $azi2 < $nl && $jj != 0) then  
          awk '{print $1","$2}' $2 > tmpllt
          set pin0 = `awk NR==1'{print $0}' tmpllt`

          foreach line2 (`awk '{print $0}' tmpllt`)
            if ($line2 != $pin0) then
              echo $pin0 | awk -F"," '{print $1,$2}' > tmp1llt
              echo $line2 | awk -F"," '{print $1,$2}' >> tmp1llt

              if ($mode != 1) then
                # create_frame_tops.csh expects a numeric polarization mode.
                # Mode 1 is VV; passing the string "vv" is interpreted as VH.
                create_frame_tops.csh tmprecord $orbit tmp1llt 1
                set newfile = `ls -t -d *.SAFE | awk NR==1'{print $0}'`

                set Frame1 = `grep azimuthAnxTime $newfile/annotation/*iw1*"$org_mod"*xml | head -1 | awk -F">" '{print $2}' | awk -F"<" '{printf("F%.4d", $1+0.5)}'`
                set Frame2 = `grep azimuthAnxTime $newfile/annotation/*iw1*"$org_mod"*xml | tail -1 | awk -F">" '{print $2}' | awk -F"<" '{printf("F%.4d", $1+0.5)}'` 

                set dirname = `echo $Frame1"_"$Frame2`

                echo "Created Frame $Frame1 - $Frame2 ..."
                echo ""

                if (! -d $dirname) mkdir $dirname
                mv $newfile $dirname
              else
                echo ""
                echo "Frames on date $date0 will be re-organized..."
                echo ""

                @ n_good_frame ++
                echo $date0 >> organize_mode1_good_dates.txt
              endif

              set pin0 = `echo $line2`
            endif
          end 
        else
          if ($jj == 0) then
            echo ""
            echo "SKIP $date0, as it stopped observation in the middle ..."
            echo ""

            @ n_skip_gap ++
            echo "$date0 stopped_observation_in_the_middle" >> organize_mode1_skip_dates.txt
          else
            echo ""
            echo "SKIP $date0, as it does not have enough scenes ..."
            echo ""

            @ n_skip_cover ++
            echo "$date0 not_enough_scenes_or_not_cover_pins" >> organize_mode1_skip_dates.txt
          endif
        endif

        echo $file1 > tmprecord
        set file0 = `echo $file1`
        set date0 = `echo $date1`
        set SAT0 = `echo $SAT1`
      endif

    endif
  end 

  # ============================================================
  # process the last set of files
  # ============================================================

  echo "" | awk '{printf("%s ","Combing")}' 
  set jj = 1
  set t2 = 9999999999

  foreach line2 (`awk '{print $0}' tmprecord`)
    echo $line2 | awk '{printf("%s ",$1)}'

    set tt = `echo $line2 | awk '{print substr($1,length($1)-54,15)}'`
    set ss2 = `echo $tt|awk '{print substr($1,1,4)"/"substr($1,5,2)"/"substr($1,7,2)" "substr($1,10,2)":"substr($1,12,2)":"substr($1,14,2)}'`
    set t1 = `date --date="$ss2" +%s`

    set test = `echo $t1 $t2 | awk '{if ($1 > $2) print 1; else print 0}'`
    if ($test == 1) set jj = 0

    set tt = `echo $line2 | awk '{print substr($1,length($1)-38,15)}'`
    set ss2 = `echo $tt|awk '{print substr($1,1,4)"/"substr($1,5,2)"/"substr($1,7,2)" "substr($1,10,2)":"substr($1,12,2)":"substr($1,14,2)}'`
    set t2 = `date --date="$ss2" +%s`
  end

  echo "" | awk '{printf("%s\n","...")}'

  # get the orbit file names and download
  set n1 = ` date --date="$date0 - 1 day" +%Y%m%d `
  set n2 = ` date --date="$date0 + 1 day" +%Y%m%d `

  echo "Required orbit file dates: ${n1} to  ${n2}..."

  cat tmprecord | awk 'NR==1{print $1}' > tmp_safelist
  download_sentinel_orbits_linux.csh tmp_safelist 1

  set orbit = `ls *EOF | grep $n1 | grep $n2 | tail -1` 

  if ("x" == $orbit"x") then
    download_sentinel_orbits_linux.csh tmp_safelist 2 > tmp_download_log
    set orbit = `grep "restituted" tmp_download_log | awk '{print $4}'`
  endif

  echo "Downloaded orbit file $orbit"
  rm -f tmp_safelist tmp_download_log

  # check the start and the end
  set pin1 = `head -1 $2 | awk '{print $1,$2}'` 
  set f1 = `head -1 tmprecord`

  make_s1a_tops $f1/annotation/*iw1*"$org_mod"*xml $f1/measurement/*iw1*"$org_mod"*tiff tmp2 0
  ext_orb_s1a tmp2.PRM $orbit tmp2

  set tmpazi = `echo $pin1 | awk '{print $1,$2,0}' | SAT_llt2rat tmp2.PRM 1 | awk '{printf("%d",$2+0.5)}'`

  shift_atime_PRM.csh tmp2.PRM $tmpazi
  set azi1 = `echo $pin1 | awk '{print $1,$2,0}' | SAT_llt2rat tmp2.PRM 1 | awk '{printf("%d",$2+0.5 + '$tmpazi')}'`

  set pin2 = `tail -1 $2 | awk '{print $1,$2}'` 
  set f2 = `tail -1 tmprecord`

  make_s1a_tops $f2/annotation/*iw1*"$org_mod"*xml $f2/measurement/*iw1*"$org_mod"*tiff tmp2 0
  ext_orb_s1a tmp2.PRM $orbit tmp2

  set tmpazi = `echo $pin2 | awk '{print $1,$2,0}' | SAT_llt2rat tmp2.PRM 1 | awk '{printf("%d",$2+0.5)}'`

  shift_atime_PRM.csh tmp2.PRM $tmpazi
  set azi2 = `echo $pin2 | awk '{print $1,$2,0}' | SAT_llt2rat tmp2.PRM 1 | awk '{printf("%d",$2+0.5 + '$tmpazi')}'`

  set nl = `grep num_lines tmp2.PRM | awk '{print $3}'`

  # do the assembling
  if ($azi1 >= 0 && $azi2 < $nl && $jj != 0) then  
    awk '{print $1","$2","$3","$4","$5","$6}' $2 > tmpllt
    set pin0 = `awk NR==1'{print $0}' tmpllt`

    foreach line2 (`awk '{print $0}' tmpllt`)
      if ($line2 != $pin0) then
        echo $pin0 | awk -F"," '{print $1,$2,$3,$4,$5,$6}' > tmp1llt
        echo $line2 | awk -F"," '{print $1,$2,$3,$4,$5,$6}' >> tmp1llt

        if ($mode != 1) then
          # create_frame_tops.csh expects a numeric polarization mode.
          # Mode 1 is VV; passing the string "vv" is interpreted as VH.
          create_frame_tops.csh tmprecord $orbit tmp1llt 1
          set newfile = `ls -t -d *.SAFE | awk NR==1'{print $0}'`

          set Frame1 = `grep azimuthAnxTime $newfile/annotation/*iw1*"$org_mod"*xml | head -1 | awk -F">" '{print $2}' | awk -F"<" '{printf("F%.4d", $1+0.5)}'`
          set Frame2 = `grep azimuthAnxTime $newfile/annotation/*iw1*"$org_mod"*xml | tail -1 | awk -F">" '{print $2}' | awk -F"<" '{printf("F%.4d", $1+0.5)}'` 

          set dirname = `echo $Frame1"_"$Frame2`

          echo "Created Frame $Frame1 - $Frame2 ..."
          echo ""

          if (! -d $dirname) mkdir $dirname
          mv $newfile $dirname
        else
          echo ""
          echo "Frames on date $date0 will be re-organized..."
          echo ""

          @ n_good_frame ++
          echo $date0 >> organize_mode1_good_dates.txt
        endif

        set pin0 = `echo $line2`
      endif
    end
  else 
    if ($jj == 0) then
      echo ""
      echo "SKIP $date0, as it stopped observation in the middle ..."
      echo ""

      @ n_skip_gap ++
      echo "$date0 stopped_observation_in_the_middle" >> organize_mode1_skip_dates.txt
    else
      echo ""
      echo "SKIP $date0, as it does not have enough scenes ..."
      echo ""

      @ n_skip_cover ++
      echo "$date0 not_enough_scenes_or_not_cover_pins" >> organize_mode1_skip_dates.txt
    endif
  endif   

  # ============================================================
  # Print summary for mode = 1
  # ============================================================
  if ($mode == 1) then

    if (-f organize_mode1_good_dates.txt) then
      set n_good_date = `sort -u organize_mode1_good_dates.txt | wc -l`
    else
      set n_good_date = 0
    endif

    if (-f organize_mode1_skip_dates.txt) then
      set n_skip_date = `awk '{print $1}' organize_mode1_skip_dates.txt | sort -u | wc -l`
    else
      set n_skip_date = 0
    endif

    echo ""
    echo "============================================================"
    echo " organize_files_tops_linux.csh mode=1 summary"
    echo "============================================================"
    echo " Re-organizable frame records : $n_good_frame"
    echo " Re-organizable dates         : $n_good_date"
    echo " Skipped dates                : $n_skip_date"
    echo "   - stopped in middle        : $n_skip_gap"
    echo "   - not enough scenes        : $n_skip_cover"
    echo "------------------------------------------------------------"

    echo " Good dates:"
    if (-f organize_mode1_good_dates.txt) then
      sort -u organize_mode1_good_dates.txt
    else
      echo " None"
    endif

    echo "------------------------------------------------------------"
    echo " Skipped dates and reasons:"
    if (-f organize_mode1_skip_dates.txt) then
      sort -u organize_mode1_skip_dates.txt
    else
      echo " None"
    endif

    echo "============================================================"

    echo "Re-organizable frame records : $n_good_frame" > organize_mode1_summary.txt
    echo "Re-organizable dates         : $n_good_date" >> organize_mode1_summary.txt
    echo "Skipped dates                : $n_skip_date" >> organize_mode1_summary.txt
    echo "Stopped in middle            : $n_skip_gap" >> organize_mode1_summary.txt
    echo "Not enough scenes            : $n_skip_cover" >> organize_mode1_summary.txt

  endif

  rm -f tmp*
  #rm *.EOF
