#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
csvdiff.sh — CSV delta extractor (USER2 minus USER1), grouped by host/share

This tool compares two directories containing CSV files named:

  <HOST>-<SHARE>-<USER>.csv
  e.g. 10.193.20.166-myshare-DEFAULT.csv
       10.193.20.166-myshare-USER2.csv

For every host/share pair that exists in BOTH directories, it produces an output
file in a third directory (created automatically) with the name:

  <HOST>-<SHARE>-<USER1>-<USER2>.csv

The output file always includes the CSV header, and then only the rows that exist
in USER2's CSV but NOT in USER1's CSV.

Important behavior / assumptions:
  - Rows are compared without the ID column, because IDs are assigned after
    threaded enumeration and may differ between credential sets.
  - Pairing is based on the Host and Share CSV fields where possible.
  - It assumes at most one CSV per host/share per directory. If multiple files for
    the same host/share are found, the first one encountered is used and a warning
    is printed.

Usage:
  csvdiff.sh <dir1> <dir2> [outdir]

Arguments:
  dir1    Directory for USER1 CSV files (baseline)
  dir2    Directory for USER2 CSV files (candidate)
  outdir  Optional output directory. If omitted, defaults to:
          csv-diff-<basename(dir1)>-<basename(dir2)>

Examples:
  ./csvdiff.sh ./DEFAULT ./USER2
  ./csvdiff.sh /data/runA /data/runB /tmp/diffs

Notes:
  - Input CSVs are expected to have a header as the first line.
  - CRLF line endings are handled (trailing '\r' is removed).

EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Error: invalid arguments." >&2
  echo >&2
  usage >&2
  exit 1
fi

DIR1=$1
DIR2=$2

if [[ ! -d "$DIR1" || ! -d "$DIR2" ]]; then
  echo "Error: Both arguments must be existing directories." >&2
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKER="$SCRIPT_DIR/workers/csvdiff_worker.py"

if [[ ! -f "$WORKER" ]]; then
  echo "Error: '$WORKER' not found." >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 not found in PATH." >&2
  exit 1
fi

LABEL1=$(basename "$DIR1")
LABEL2=$(basename "$DIR2")

OUTDIR=${3:-"csv-diff-${LABEL1}-${LABEL2}"}
python3 "$WORKER" "$DIR1" "$DIR2" "$OUTDIR"
