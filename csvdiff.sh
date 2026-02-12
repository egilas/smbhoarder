#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
csvdiff.sh — CSV delta extractor (USER2 minus USER1), grouped by IP

This tool compares two directories containing CSV files named:

  <IP>-<USER>.csv
  e.g. 10.193.20.166-DEFAULT.csv
       10.193.20.166-USER2.csv

For every IP that exists in BOTH directories, it produces an output file in a third
directory (created automatically) with the name:

  <IP>-<USER1>-<USER2>.csv

The output file always includes the CSV header, and then only the rows that exist
in USER2's CSV but NOT in USER1's CSV (line-by-line comparison).

Important behavior / assumptions:
  - Files are compared as raw lines (excluding the header row). A row must match
    exactly to be considered "present in both".
  - If a file pair has the same byte size, the tool assumes they are identical and
    skips processing (no output file created for that IP).
  - It assumes at most one CSV per IP per directory. If multiple files for the same
    IP are found, the first one encountered is used and a warning is printed.

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

LABEL1=$(basename "$DIR1")
LABEL2=$(basename "$DIR2")

OUTDIR=${3:-"csv-diff-${LABEL1}-${LABEL2}"}
mkdir -p "$OUTDIR"

# Maps: IP -> file path (assumes max 1 file per IP per directory)
declare -A MAP1 MAP2

while IFS= read -r -d '' f; do
  b=$(basename "$f")
  ip=${b%%-*}
  if [[ -n "${MAP1[$ip]:-}" ]]; then
    echo "Warning: Multiple files for IP $ip in $DIR1. Using first: ${MAP1[$ip]}" >&2
    continue
  fi
  MAP1["$ip"]="$f"
done < <(find "$DIR1" -maxdepth 1 -type f -name '*.csv' -print0)

while IFS= read -r -d '' f; do
  b=$(basename "$f")
  ip=${b%%-*}
  if [[ -n "${MAP2[$ip]:-}" ]]; then
    echo "Warning: Multiple files for IP $ip in $DIR2. Using first: ${MAP2[$ip]}" >&2
    continue
  fi
  MAP2["$ip"]="$f"
done < <(find "$DIR2" -maxdepth 1 -type f -name '*.csv' -print0)

# Diff for IPs that exist in both
for ip in "${!MAP1[@]}"; do
  f1="${MAP1[$ip]}"
  f2="${MAP2[$ip]:-}"
  [[ -z "$f2" ]] && continue

  # Skip if same size (assume identical)
  s1=$(stat -c '%s' "$f1")
  s2=$(stat -c '%s' "$f2")
  if [[ "$s1" -eq "$s2" ]]; then
    continue
  fi

  b1=$(basename "$f1")
  b2=$(basename "$f2")

  user1=${b1#*-}; user1=${user1%.csv}
  user2=${b2#*-}; user2=${user2%.csv}

  out="${OUTDIR}/${ip}-${user1}-${user2}.csv"

  # Header from USER2 (f2), then rows only in USER2
  header=$(head -n 1 "$f2" | tr -d '\r')
  {
    echo "$header"
    awk '
      { sub(/\r$/, "") }        # handle CRLF
      FNR==1 { next }           # skip header in both files
      FNR==NR { a[$0]=1; next } # load all data rows from file1
      !a[$0] { print }          # print rows only found in file2
    ' "$f1" "$f2"
  } > "$out"
done

echo "Done. Output in: $OUTDIR"

