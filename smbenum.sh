#!/bin/bash

show_help() {
  cat <<EOF
Usage:
  $0 -h <hosts_file> [options]

Required:
  -h <hosts_file>    File with IPs or hostnames to scan.
                     If the file is in gnmap format and contains "445/open", it will be parsed automatically.

Optional Execution Settings:
  -t <threads>       Number of parallel threads (default: 30)
  -proxychains       Use proxychains -q when running smbenum_worker.py

Optional Credential Parameters:
  -cfile <file>      Credential file with one or more sections. (default: ./creds.ini)
  -s <section>       Section name inside credential file to use. (default: DEFAULT)

Optional Paths and Output:
  -workers <dir>     Directory containing smbenum_worker.py (default: ./workers)
  -csvdir <dir>      Output directory for result CSVs (default: ./csv). Will be created if it doesn't exist.

Other:
  -help              Show this help message
EOF
}


# Default values
threads=30
csvdir="./csv"
cfile="./creds.ini"
section="DEFAULT"
workers="./workers"
hosts_file=""
use_proxychains=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h)
      hosts_file="$2"
      shift 2
      ;;
    -t)
      threads="$2"
      shift 2
      ;;
    -csvdir)
      csvdir="$2"
      shift 2
      ;;
    -cfile)
      cfile="$2"
      shift 2
      ;;
    -s)
      section="$2"
      shift 2
      ;;
    -workers)
      workers="$2"
      shift 2
      ;;
    -proxychains)
      use_proxychains=true
      shift
      ;;
    -help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      show_help
      exit 1
      ;;
  esac
done

if [[  -f "$workers/logo.txt" ]]; then
  cat "$workers/logo.txt" 
fi
# Validate input file
if [[ -z "$hosts_file" || ! -f "$hosts_file" ]]; then
  echo "Error: You must provide a valid -h <hosts_file>"
  show_help
  exit 1
fi

# Check workers and script exists
worker_script="$workers/smbenum_worker.py"
if [[ ! -f "$worker_script" ]]; then
  echo "Error: '$worker_script' not found."
  exit 1
fi

# Check creds file
if [[ ! -f "$cfile" ]]; then
  echo "Error: Credential file '$cfile' not found."
  exit 1
fi

# Ensure output directory exists
mkdir -p "$csvdir"

# Parse hosts from gnmap if applicable
if grep -q "445/open" "$hosts_file"; then
  echo "[*] Detected gnmap format. Extracting hosts with 445/open..."
  mapfile -t targets < <(grep "445/open" "$hosts_file" | cut -d " " -f2 | sort -u)
else
  echo "[*] Using hosts directly from input file."
  mapfile -t targets < "$hosts_file"
fi

# Build base command
if $use_proxychains; then
  run_cmd="proxychains -q python3 $worker_script"
else
  run_cmd="python3 $worker_script"
fi

# Run in parallel
printf "%s\n" "${targets[@]}" | xargs -I{} -P "$threads" sh -c "$run_cmd {} -o $csvdir/{}-$section.csv -c $cfile -s $section"
