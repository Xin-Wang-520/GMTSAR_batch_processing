#!/usr/bin/env bash
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: September 15, 2026

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
Usage:
  ./run3.1_prep_data_F123.sh
  ./run3.1_prep_data_F123.sh 1

No argument checks F1/F2/F3 inputs and prints the command guide only.
Mode 1 formally performs the following processing:
  1. validates F1/raw, F2/raw, and F3/raw links;
  2. builds orbits.list from the local F*/raw/*.EOF links;
  3. confirms every acquisition date has a matching local orbit;
  4. runs prep_data_linux.csh in each raw directory;
  5. saves the original data.in as data.in.orig;
  6. moves the middle (or middle-front) data.in record to line 1.
EOF
}

MODE="${1:-}"
(( $# <= 1 )) || { usage; die "too many arguments"; }
case "${MODE}" in
    "") CHECK_ONLY=1 ;;
    1) CHECK_ONLY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "use no argument for input check or mode 1 for formal processing" ;;
esac

command -v prep_data_linux.csh >/dev/null 2>&1 ||
    die "prep_data_linux.csh was not found in PATH"

ROOT_DIR="$(pwd -P)"
TRACK="$(basename -- "${ROOT_DIR}")"
[[ "${TRACK}" =~ ^T[0-9]+$ ]] ||
    die "run this script in a T-number directory (current: ${ROOT_DIR})"

FRAMES=(F1 F2 F3)

count_links() {
    local directory="$1"
    local pattern="$2"
    find "${directory}" -mindepth 1 -maxdepth 1 -type l -iname "${pattern}" -print |
        wc -l | awk '{print $1}'
}

validate_raw_links() {
    local frame="$1"
    local raw_dir="$2"
    local link
    local xml_count tiff_count eof_count dem_count broken_count=0

    shopt -s nullglob
    for link in "${raw_dir}"/*; do
        [[ -L "${link}" ]] || continue
        if [[ ! -e "${link}" ]]; then
            printf '[BROKEN] %s -> %s\n' "${link}" "$(readlink -- "${link}")" >&2
            broken_count=$((broken_count + 1))
        fi
    done
    shopt -u nullglob
    if (( broken_count > 0 )); then
        printf '[ERROR] %s/raw contains %d broken links\n' "${frame}" "${broken_count}" >&2
        return 1
    fi

    xml_count="$(count_links "${raw_dir}" '*iw*vv*.xml')"
    tiff_count="$(count_links "${raw_dir}" '*iw*vv*.tiff')"
    eof_count="$(count_links "${raw_dir}" '*.EOF')"
    dem_count="$(count_links "${raw_dir}" 'dem.grd')"

    printf 'XML links      : %d\n' "${xml_count}"
    printf 'TIFF links     : %d\n' "${tiff_count}"
    printf 'Orbit EOF links: %d\n' "${eof_count}"
    printf 'DEM links      : %d\n' "${dem_count}"

    local invalid=0
    if (( xml_count == 0 )); then
        printf '[ERROR] no VV XML links found in %s/raw\n' "${frame}" >&2
        invalid=1
    fi
    if [[ "${xml_count}" -ne "${tiff_count}" ]]; then
        printf '[ERROR] %s/raw XML/TIFF count mismatch: %s/%s\n' \
            "${frame}" "${xml_count}" "${tiff_count}" >&2
        invalid=1
    fi
    if (( eof_count == 0 )); then
        printf '[ERROR] no orbit EOF links found in %s/raw\n' "${frame}" >&2
        invalid=1
    fi
    if [[ "${dem_count}" -ne 1 ]]; then
        printf '[ERROR] %s/raw requires exactly one dem.grd link (found %s)\n' \
            "${frame}" "${dem_count}" >&2
        invalid=1
    fi
    (( invalid == 0 ))
}

process_frame() {
    local frame="$1"
    local raw_dir="${ROOT_DIR}/${frame}/raw"
    local nline mid expected_first actual_first reorder_tmp

    printf '\n========== Processing %s ==========\n' "${frame}"
    [[ -d "${raw_dir}" ]] || die "raw directory not found: ${raw_dir}; complete Run 2.4 first"

    printf '[1] Validate linked inputs: %s\n' "${raw_dir}"
    validate_raw_links "${frame}" "${raw_dir}" ||
        die "${frame}/raw input validation failed"

    (
        cd -- "${raw_dir}"

        printf '[2] Clean old prep_data outputs\n'
        rm -f -- \
            data.in \
            data.in.orig \
            data.in.before_middle_first \
            prep_data.log \
            run3.1_missing_orbits.tsv \
            orbit.list \
            orbits.list \
            SAFE.list \
            safe.list \
            raw.list

        printf '[3] Build orbits.list from local EOF links\n'
        shopt -s nullglob nocasematch
        xml_files=( *iw*vv*.xml )
        eof_files=( *.EOF )
        shopt -u nullglob

        (( ${#xml_files[@]} > 0 )) || {
            printf '[FAIL] no VV XML files found in %s\n' "${raw_dir}" >&2
            exit 1
        }
        (( ${#eof_files[@]} > 0 )) || {
            printf '[FAIL] no local EOF orbit files found in %s\n' "${raw_dir}" >&2
            exit 1
        }

        printf '%s\n' "${eof_files[@]}" | sort -u > orbits.list
        printf 'Local orbit filenames: %d\n' "$(wc -l < orbits.list | awk '{print $1}')"

        orbit_requirements="$(mktemp .run3.1_orbit_requirements.XXXXXX)"
        orbit_missing="$(mktemp .run3.1_missing_orbits.XXXXXX)"
        trap 'rm -f -- "${orbit_requirements:-}" "${orbit_missing:-}"' EXIT
        : > "${orbit_requirements}"
        : > "${orbit_missing}"

        for xml in "${xml_files[@]}"; do
            xml_name="$(basename -- "${xml}")"
            sat="${xml_name:0:3}"
            acquisition_date="${xml_name:15:8}"
            if [[ ! "${sat}" =~ ^s1[ab]$ || ! "${acquisition_date}" =~ ^[0-9]{8}$ ]]; then
                printf '%s\t%s\t%s\n' \
                    "INVALID_XML_NAME" "${xml_name}" "cannot parse satellite/date" \
                    >> "${orbit_missing}"
                continue
            fi
            printf '%s\t%s\n' "${sat^^}" "${acquisition_date}" >> "${orbit_requirements}"
        done
        sort -u -o "${orbit_requirements}" "${orbit_requirements}"

        while IFS=$'\t' read -r sat acquisition_date; do
            [[ -n "${sat}" && -n "${acquisition_date}" ]] || continue
            orbit_start="$(date --date="${acquisition_date} - 1 day" +%Y%m%d)"
            orbit_end="$(date --date="${acquisition_date} + 1 day" +%Y%m%d)"

            if ! awk -v sat="${sat}" -v start="${orbit_start}" -v end="${orbit_end}" '
                index($0, sat) && index($0, start) && index($0, end) { found=1; exit }
                END { exit !found }
            ' orbits.list; then
                printf '%s\t%s\tV%s*_%s*\n' \
                    "${acquisition_date}" "${sat}" "${orbit_start}" "${orbit_end}" \
                    >> "${orbit_missing}"
            fi
        done < "${orbit_requirements}"

        if [[ -s "${orbit_missing}" ]]; then
            {
                printf 'acquisition_date\tsatellite\texpected_orbit_validity_or_error\n'
                cat "${orbit_missing}"
            } > run3.1_missing_orbits.tsv
            printf '[FAIL] Local orbit validation failed in %s\n' "${raw_dir}" >&2
            printf '[FAIL] Report: %s/run3.1_missing_orbits.tsv\n' "${raw_dir}" >&2
            sed -n '1,21p' run3.1_missing_orbits.tsv >&2
            exit 1
        fi

        acquisition_count="$(wc -l < "${orbit_requirements}" | awk '{print $1}')"
        printf '[ORBIT OK] All %d acquisition dates match local EOF orbit files.\n' \
            "${acquisition_count}"

        printf '[4] Run prep_data_linux.csh with the local orbit list\n'
        if ! prep_data_linux.csh > prep_data.log 2>&1; then
            printf '[FAIL] prep_data_linux.csh failed in %s\n' "${raw_dir}" >&2
            printf '[FAIL] Last 30 log lines:\n' >&2
            tail -n 30 prep_data.log >&2 || true
            exit 1
        fi

        [[ -s data.in ]] || {
            printf '[FAIL] data.in was not generated or is empty in %s\n' "${raw_dir}" >&2
            exit 1
        }

        generated_records="$(wc -l < data.in | awk '{print $1}')"
        if [[ "${generated_records}" -ne "${acquisition_count}" ]]; then
            printf '[FAIL] data.in is incomplete in %s: expected %d records, found %d\n' \
                "${raw_dir}" "${acquisition_count}" "${generated_records}" >&2
            exit 1
        fi
        printf '[DATA OK] data.in contains all %d acquisition records.\n' \
            "${generated_records}"

        printf '[5] Back up original data.in\n'
        cp -p -- data.in data.in.orig

        nline="$(wc -l < data.in.orig | awk '{print $1}')"
        (( nline > 0 )) || {
            printf '[FAIL] data.in.orig contains no records\n' >&2
            exit 1
        }
        printf 'data.in records: %d\n' "${nline}"

        if (( nline < 3 )); then
            printf '[WARN] data.in has fewer than 3 records; keep its original order\n'
        else
            # Odd count: exact middle. Even count: middle-front record.
            mid=$(( (nline + 1) / 2 ))
            printf '[6] Move original line %d to the first line\n' "${mid}"

            cp -p -- data.in.orig data.in.before_middle_first
            reorder_tmp="$(mktemp data.in.tmp.XXXXXX)"
            awk -v mid="${mid}" '
                NR == mid { middle = $0; next }
                { lines[++count] = $0 }
                END {
                    print middle
                    for (i = 1; i <= count; i++) print lines[i]
                }
            ' data.in.orig > "${reorder_tmp}"
            mv -f -- "${reorder_tmp}" data.in

            expected_first="$(sed -n "${mid}p" data.in.orig)"
            actual_first="$(head -n 1 data.in)"
            [[ "${actual_first}" == "${expected_first}" ]] || {
                printf '[FAIL] reordered first record does not match original line %d\n' "${mid}" >&2
                exit 1
            }
            [[ "$(wc -l < data.in | awk '{print $1}')" -eq "${nline}" ]] || {
                printf '[FAIL] data.in record count changed after reordering\n' >&2
                exit 1
            }
        fi

        printf '[7] data.in first five records:\n'
        head -n 5 data.in
        printf '[DONE] %s completed; log: %s/prep_data.log\n' "${frame}" "${raw_dir}"
    )
}

printf '%s\n' '========================================'
printf 'Run 3.1: prepare GMTSAR data.in for F1/F2/F3\n'
printf 'Track root: %s\n' "${ROOT_DIR}"
printf 'Track     : %s\n' "${TRACK}"
printf '%s\n' '========================================'

if (( CHECK_ONLY == 1 )); then
    CHECK_FAILED=0
    for frame in "${FRAMES[@]}"; do
        RAW_DIR="${ROOT_DIR}/${frame}/raw"
        printf '\n========== Check %s ==========\n' "${frame}"
        if [[ ! -d "${RAW_DIR}" ]]; then
            printf '[NOT READY] raw directory not found: %s\n' "${RAW_DIR}" >&2
            CHECK_FAILED=1
            continue
        fi
        if validate_raw_links "${frame}" "${RAW_DIR}"; then
            printf '[READY] %s/raw inputs passed validation\n' "${frame}"
        else
            printf '[NOT READY] %s/raw input validation failed\n' "${frame}" >&2
            CHECK_FAILED=1
        fi
    done

    printf '\n%s\n' '========================================'
    printf 'Run 3.1 command guide (processing NOT started)\n\n'
    printf 'Formal run:\n'
    printf '  ./run3.1_prep_data_F123.sh 1\n\n'
    printf 'Mode 1 will, for each F1/F2/F3 raw directory:\n'
    printf '  1. remove old prep_data temporary outputs;\n'
    printf '  2. build orbits.list from local EOF links;\n'
    printf '  3. validate local orbit coverage for every acquisition date;\n'
    printf '  4. run prep_data_linux.csh;\n'
    printf '  5. create data.in and data.in.orig;\n'
    printf '  6. move the middle (or middle-front) acquisition to line 1.\n'
    printf '%s\n' '========================================'
    if (( CHECK_FAILED == 0 )); then
        printf '[CHECK OK] F1/F2/F3 inputs are ready.\n'
        printf '[INFO] No processing was started.\n'
        exit 0
    fi
    die "one or more frames are not ready; no processing was started"
fi

for frame in "${FRAMES[@]}"; do
    process_frame "${frame}"
done

printf '\n%s\n' '========================================'
printf '[DONE] Run 3.1 completed successfully.\n'
printf '%s\n' '========================================'
