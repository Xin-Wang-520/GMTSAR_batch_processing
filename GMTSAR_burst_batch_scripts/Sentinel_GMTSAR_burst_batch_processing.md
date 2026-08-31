# Sentinel-1 GMTSAR Burst Batch Processing Guide

Author: Xin Wang, University of Science and Technology of China (USTC), Hefei, China  
Workflow: Sentinel-1 single-burst/single-subswath preprocessing, interferometry, unwrapping and SBAS

## 1. Overview

This directory contains a batch workflow for processing one Sentinel-1 burst stack with GMTSAR. The scripts are designed to run from a track root directory whose name starts with `T`, for example:

```text
/data2/xinw/Huangshan_landsides/S1/T142A/
```

The default directory structure is:

```text
T142A/
├── data_burst/                 # SAFE products and orbit files
├── topo/                       # geographic DEM
├── burst/
│   ├── raw/                    # linked XML/TIFF/EOF and preprocessing products
│   ├── topo/                   # radar-coordinate topography products
│   └── intf_all/               # interferogram directories
├── sbas_burst/                 # direct SBAS products from unwrap.grd
└── sbas_burst_pin/             # optional DEM-corrected and reference-pinned SBAS products
```

All commands in this guide are run from the track root (`T*`), not from this script directory, unless explicitly stated otherwise.

## 2. Recommended workflow

The normal burst workflow is:

```text
Run 2.1  validate SAFE files and download orbit files
Run 2.2  determine the DEM region and generate dem.grd
Run 2.3  link burst inputs into burst/raw and burst/topo
Run 3.1  generate data.in and select the middle acquisition as master
Run 3.2  preprocess and align the burst stack
Run 3.3  select and confirm the interferogram network
Run 3.4  generate radar-coordinate topography
Run 3.5  generate interferograms
Run 3.6  generate the stack coherence mask
Run 3.7  generate the radar-coordinate land mask
Run 3.8  preview and unwrap interferograms
Run 3.9  align corr.grd geometry with unwrap.grd
Run 4.1  prepare the SBAS network
Run 4.2  generate SBAS tables and the SBAS command
Run 4.3  run SBAS
Run 4.4  geocode and plot the SBAS velocity
```

The direct SBAS route uses `burst/intf_all/<pair>/unwrap.grd`. Runs 3.10 and 3.11 are optional and are needed only for the DEM-corrected, reference-pinned route.

## 3. Software requirements

The workflow expects the following commands to be available in `PATH`:

```text
GMTSAR, GMT, tcsh, Python 3, GNU parallel, make_dem.csh,
download_sentinel_orbits_linux_new.csh,
preproc_batch_tops_parallel_new_wx.csh
```

Python scripts require the packages used by the local scripts, including NumPy and the NetCDF/GMT-compatible Python environment where applicable.

Make the scripts executable after copying them to a server:

```bash
chmod +x run*.sh run*.py select_pairs_regular.csh
```

## 4. Input preparation

Place the selected Sentinel-1 SAFE directories under `data_burst/`:

```text
T142A/
└── data_burst/
    ├── S1A_*.SAFE
    ├── S1A_*.SAFE
    └── ...
```

The SAFE products must describe the same burst stack, polarization and subswath. The default polarization is VV. The script can automatically identify a common `IW1`, `IW2` or `IW3` subswath.

## 5. Run 2: prepare inputs

### Run 2.1: validate SAFE products and obtain orbit files

Check only:

```bash
./run2.1_prepare_SAFE_orbits.sh
```

Formal run using precise POEORB files:

```bash
./run2.1_prepare_SAFE_orbits.sh 1
```

Use restituted RESORB files when precise files are unavailable:

```bash
./run2.1_prepare_SAFE_orbits.sh 1 --orbit-mode 2
```

Useful options:

```bash
--data-dir data_burst
--swath AUTO
--polarization vv
--downloader /path/to/download_sentinel_orbits_linux_new.csh
```

Main outputs:

```text
data_burst/SAFE_filelist
data_burst/burst_SAFE_inventory.tsv
data_burst/*.EOF
data_burst/run2.1_orbit_download.log
```

The inventory records the acquisition date, satellite, subswath, polarization, SAFE directory and annotation XML used by later steps.

### Run 2.2: determine the DEM region and generate the DEM

Display the command guide:

```bash
./run2.2_prepare_topo_DEM_burst.py
```

Mode 1 calculates and saves the DEM bounds without downloading a DEM:

```bash
./run2.2_prepare_topo_DEM_burst.py 1
```

Inspect:

```text
topo/dem_region_actual.txt
topo/dem_region_margin.txt
topo/dem_region.txt
```

Mode 2 generates and plots the DEM:

```bash
./run2.2_prepare_topo_DEM_burst.py 2
```

Optional settings:

```bash
./run2.2_prepare_topo_DEM_burst.py 2 --margin 0.3 --resolution 1
```

Main outputs:

```text
topo/dem.grd
topo/dem.pdf
topo/make_dem.log
topo/plot_dem.log
```

The default margin is 0.2 degrees on every side. Mode 2 calls `make_dem.csh` with resolution mode 1 by default.

### Run 2.3: link the burst inputs

Show the guide:

```bash
./run2.3_link_burst_raw_topo.sh
```

Preview and validate all planned links:

```bash
./run2.3_link_burst_raw_topo.sh 1
```

Create the links:

```bash
./run2.3_link_burst_raw_topo.sh 2
```

Main outputs:

```text
burst/raw/*.xml
burst/raw/*.tiff
burst/raw/*.EOF
burst/raw/dem.grd
burst/topo/dem.grd
burst/burst_swath.txt
burst/run2.3_link_inventory.tsv
```

These are symbolic links. The original SAFE, TIFF, XML, EOF and DEM files are not copied or deleted.

## 6. Run 3: preprocessing and interferograms

### Run 3.1: generate `data.in`

Show the guide:

```bash
./run3.1_prep_data_burst.sh
```

Preview:

```bash
./run3.1_prep_data_burst.sh 1
```

Formal run:

```bash
./run3.1_prep_data_burst.sh 2
```

The script runs `prep_data_linux.csh`, resolves compatible orbit revisions when necessary, and moves the temporal-middle acquisition to the first line of `data.in`. For an even number of acquisitions, it uses the middle-front record.

Main outputs:

```text
burst/raw/data.in
burst/raw/data.in.from_prep_data
burst/raw/data.in.orig
burst/raw/data.in.before_middle_first
burst/raw/prep_data.log
```

### Run 3.2: preprocess the burst stack

Show the guide:

```bash
./run3.2_preproc_batch_tops_burst.sh
```

Recommended standard processing with five concurrent pair jobs:

```bash
./run3.2_preproc_batch_tops_burst.sh 5 1
```

ESD alternatives:

```bash
./run3.2_preproc_batch_tops_burst.sh 5 2 0   # average
./run3.2_preproc_batch_tops_burst.sh 5 2 1   # median, recommended ESD mode
./run3.2_preproc_batch_tops_burst.sh 5 2 2   # interpolation
```

The first value is the maximum number of concurrent pair jobs. Reduce it to 2 or 3 on a smaller computer.

Main outputs:

```text
burst/raw/*ALL*.PRM
burst/raw/*ALL*.LED
burst/raw/*ALL*.SLC
burst/raw/baseline_table.dat
burst/raw/baseline.ps
burst/raw/preproc_all.log
```

### Run 3.3: select the interferogram network

Show the guide:

```bash
./run3.3_make_intf_config_burst.sh
```

Mode 1 creates a preview using a 60-day temporal threshold and a 150 m spatial-baseline threshold:

```bash
./run3.3_make_intf_config_burst.sh 1 60 150
```

Inspect:

```text
burst/baseline.pdf
burst/intf.in.preview
```

If the network is suitable, finalize it:

```bash
./run3.3_make_intf_config_burst.sh 2
```

Mode 2 accepts the latest preview and generates the finalized `burst/intf.in` and `burst/batch_tops.config`. The `master_image` is derived from the first record of `burst/raw/data.in`.

### Run 3.4: generate radar-coordinate topography

Show and check the command:

```bash
./run3.4_dem2topo_ra_burst.sh
```

Formal run:

```bash
./run3.4_dem2topo_ra_burst.sh 1
```

Main outputs under `burst/topo/` include:

```text
topo_ra.grd
trans.dat
dem2topo_ra.log
```

The script links the selected master PRM/LED, runs the radar-coordinate topography workflow and validates the outputs.

### Run 3.5: generate burst interferograms

Show the guide:

```bash
./run3.5_intf_tops_parallel_burst.sh
```

Run with five concurrent interferogram jobs:

```bash
./run3.5_intf_tops_parallel_burst.sh 5
```

Main outputs:

```text
burst/intf_all/<pair>/corr.grd
burst/intf_all/<pair>/mask.grd
burst/intf_all/<pair>/phasefilt.grd
burst/run3.5_expected_pairs.tsv
burst/run3.5_failed_pairs.tsv
```

The script validates the expected pair list and reports incomplete pairs instead of silently accepting them.

### Run 3.6: generate a stack coherence mask

Example using a mean-coherence threshold of 0.075, batches of 50 grids and five parallel batch jobs:

```bash
./run3.6_stack_coherence_mask_parallel_burst.sh 0.075 50 5
```

The first parameter is the mean-coherence threshold. `BATCH=50` means that up to 50 correlation grids are summed in one batch; it is not the parallel-job count. The last value controls parallel batch jobs.

Main outputs under `burst/`:

```text
mean_corr.grd
mask_def.grd
mask_def.pdf
```

### Run 3.7: generate the radar-coordinate land mask

Check only:

```bash
./run3.7_make_landmask_ra_burst.sh
```

Formal run:

```bash
./run3.7_make_landmask_ra_burst.sh 1
```

Main outputs under `burst/`:

```text
landmask_ra.grd
landmask_ra.pdf
run3.7_complete
```

The final land mask is resampled to the exact interferogram-grid geometry.

### Run 3.8: preview and unwrap the interferograms

Check the inputs and display commands:

```bash
./run3.8_unwrap_burst_parallel.sh
```

Mode 1 previews one pre-SNAPHU input using the default correlation threshold:

```bash
./run3.8_unwrap_burst_parallel.sh 1
```

Specify a threshold, pair or radar crop when required:

```bash
./run3.8_unwrap_burst_parallel.sh 1 0.1
./run3.8_unwrap_burst_parallel.sh 1 0.1 2022005_2022017
./run3.8_unwrap_burst_parallel.sh 1 0.1 2022005_2022017 0/24560/0/1396
```

Mode 2 starts resumable parallel unwrapping through `nohup`:

```bash
./run3.8_unwrap_burst_parallel.sh 2 5 0.1
```

With an optional radar crop:

```bash
./run3.8_unwrap_burst_parallel.sh 2 5 0.1 0/24560/0/1396
```

Monitor:

```bash
tail -f burst/run3.8_unwrap_burst_parallel.nohup.log
```

Main outputs in every finalized pair directory:

```text
unwrap.grd
unwrap.pdf
run3.8_unwrap_parameters.txt
```

If processing is interrupted, rerun the same Mode 2 command. Completed pairs with matching parameters are skipped, and only incomplete pairs are processed.

### Run 3.9: align `corr.grd` with `unwrap.grd`

Preview five pairs across the full pair list:

```bash
./run3.9_match_corr_to_unwrap_burst.sh
```

Equivalent explicit preview with 20 workers and five sampled pairs:

```bash
./run3.9_match_corr_to_unwrap_burst.sh 0 20 5
```

Formally crop all correlation grids in parallel:

```bash
./run3.9_match_corr_to_unwrap_burst.sh 1 20
```

The formal mode crops or resamples each original `corr.grd` to match the corresponding `unwrap.grd` geometry. It does not modify `unwrap.grd`.

Main outputs:

```text
burst/run3.9_corr_alignment.tsv
burst/run3.9_failed_pairs.tsv
burst/run3.9_complete
```

## 7. Optional DEM and reference-point correction

Skip this section when direct SBAS from `unwrap.grd` is desired. Continue directly to Section 8.

### Run 3.10: correct residual DEM-related phase

Show the guide:

```bash
./run3.10_dem_correction_parallel_all_in_one.sh
```

Recommended example using 10 parallel interferograms and a six-parameter model:

```bash
./run3.10_dem_correction_parallel_all_in_one.sh 10 6
```

Allowed model sizes are 4, 6 and 9. The main output in each pair directory is:

```text
burst/intf_all/<pair>/unwrap_dem_correct.grd
```

### Run 3.11: apply a reference-area correction

Check the required command syntax:

```bash
./run3.11_reference_dem_correct_parallel.sh
```

The reference region is mandatory. Example:

```bash
./run3.11_reference_dem_correct_parallel.sh 10 10000/10096/5000/5024
```

The first parameter is the number of parallel jobs. The second parameter is the radar-coordinate reference region `xmin/xmax/ymin/ymax`.

Main output in each pair directory:

```text
burst/intf_all/<pair>/unwrap_dem_correct_pin_up.grd
```

Inspect the chosen reference region carefully before accepting these products.

## 8. Run 4: direct SBAS route

This is the recommended route when external DEM correction and reference-point correction are not required.

### Run 4.1: prepare the direct SBAS network

Check only:

```bash
./run4.1_prepare_sbas_network_burst.sh
```

Formal run:

```bash
./run4.1_prepare_sbas_network_burst.sh 1
```

Inputs are `unwrap.grd` and the geometry-matched `corr.grd` from every finalized pair.

Outputs:

```text
sbas_burst/intflist_new
sbas_burst/intf.in
sbas_burst/baseline_table.dat
sbas_burst/supermaster.PRM
sbas_burst/supermaster.LED
sbas_burst/run4.1_missing_pairs.tsv
sbas_burst/run4.1_complete
```

All finalized pairs must be complete. Incomplete pairs are reported and are not silently excluded.

### Run 4.2: generate SBAS tables and command

Check the inputs and calculated parameters:

```bash
./run4.2_generate_sbas_tables_burst.sh
```

Generate tables using the default 38-degree incidence angle and smoothing 1.0:

```bash
./run4.2_generate_sbas_tables_burst.sh 1
```

Specify the incidence angle and smoothing value explicitly:

```bash
./run4.2_generate_sbas_tables_burst.sh 1 38 1.0
```

Outputs:

```text
sbas_burst/intf.tab
sbas_burst/scene.tab
sbas_burst/prep_sbas.log
sbas_burst/range_check.log
sbas_burst/run_sbas_parallel.sh
sbas_burst/run4.2_complete
```

This step prepares the command but does not start `sbas_parallel`.

### Run 4.3: run SBAS

Check the inputs, table counts, command and PID state:

```bash
./run4.3_sbas_parallel_burst.sh
```

Submit SBAS through `nohup`:

```bash
./run4.3_sbas_parallel_burst.sh 1
```

Do not add another `nohup` or trailing `&`. Monitor with:

```bash
tail -f sbas_burst/run4.3_sbas_parallel.log
```

### Run 4.4: geocode and plot velocity

Check only:

```bash
./run4.4_geocode_sbas_velocity_burst.sh
```

Formal run:

```bash
./run4.4_geocode_sbas_velocity_burst.sh 1
```

Default settings:

```text
Spatial filter: 400 m
Color range: automatically determined from vel_ll.grd
```

Optional fixed color range:

```bash
VEL_CPT_MIN=-20 VEL_CPT_MAX=20 VEL_CPT_STEP=2 \
./run4.4_geocode_sbas_velocity_burst.sh 1
```

Outputs in `sbas_burst/`:

```text
vel_ll.grd
vel_ll.cpt
vel_ll.pdf
vel_ll KML/KMZ image products
run4.4_complete
```

## 9. Run 4: optional DEM-corrected and reference-pinned SBAS route

Use this route only after Runs 3.10 and 3.11 have successfully generated `unwrap_dem_correct_pin_up.grd` for every accepted pair.

```bash
./run4.1_prepare_sbas_network_pin_burst.sh
./run4.1_prepare_sbas_network_pin_burst.sh 1

./run4.2_generate_sbas_tables_pin_burst.sh
./run4.2_generate_sbas_tables_pin_burst.sh 1 38 1.0

./run4.3_sbas_parallel_pin_burst.sh
./run4.3_sbas_parallel_pin_burst.sh 1

./run4.4_geocode_sbas_velocity_pin_burst.sh
./run4.4_geocode_sbas_velocity_pin_burst.sh 1
```

The corresponding output directory is:

```text
sbas_burst_pin/
```

The pin workflow uses:

```text
burst/intf_all/<pair>/unwrap_dem_correct_pin_up.grd
```

Do not mix files from `sbas_burst/` and `sbas_burst_pin/` in one inversion.

## 10. Compact command sequence

The following sequence shows the normal direct-SBAS workflow. Adjust thresholds, job counts and paths for the server.

```bash
# Run 2
./run2.1_prepare_SAFE_orbits.sh
./run2.1_prepare_SAFE_orbits.sh 1
./run2.2_prepare_topo_DEM_burst.py 1
./run2.2_prepare_topo_DEM_burst.py 2
./run2.3_link_burst_raw_topo.sh 1
./run2.3_link_burst_raw_topo.sh 2

# Run 3
./run3.1_prep_data_burst.sh 1
./run3.1_prep_data_burst.sh 2
./run3.2_preproc_batch_tops_burst.sh 5 1
./run3.3_make_intf_config_burst.sh 1 60 150
./run3.3_make_intf_config_burst.sh 2
./run3.4_dem2topo_ra_burst.sh 1
./run3.5_intf_tops_parallel_burst.sh 5
./run3.6_stack_coherence_mask_parallel_burst.sh 0.075 50 5
./run3.7_make_landmask_ra_burst.sh
./run3.7_make_landmask_ra_burst.sh 1
./run3.8_unwrap_burst_parallel.sh 1 0.1
./run3.8_unwrap_burst_parallel.sh 2 5 0.1
./run3.9_match_corr_to_unwrap_burst.sh 0 20 5
./run3.9_match_corr_to_unwrap_burst.sh 1 20

# Run 4: direct SBAS
./run4.1_prepare_sbas_network_burst.sh
./run4.1_prepare_sbas_network_burst.sh 1
./run4.2_generate_sbas_tables_burst.sh
./run4.2_generate_sbas_tables_burst.sh 1 38 1.0
./run4.3_sbas_parallel_burst.sh
./run4.3_sbas_parallel_burst.sh 1
./run4.4_geocode_sbas_velocity_burst.sh
./run4.4_geocode_sbas_velocity_burst.sh 1
```

## 11. General safety rules

- Always run a script without arguments or in preview/check mode first when that mode is available.
- Inspect `baseline.pdf`, DEM bounds, pre-SNAPHU previews and failure reports before continuing.
- Do not start the next step while a previous `nohup` process is still running.
- Rerun Run 3.8 with exactly the same parameters to resume interrupted unwrapping.
- Treat a non-empty `run*_failed_pairs.tsv` as an unresolved error.
- Adjust parallel job counts to available CPU, memory and disk I/O capacity.
- Preserve `run*.complete`, inventory and manifest files because later scripts use them for validation.
- Use either the direct SBAS route or the pin-corrected route consistently.

