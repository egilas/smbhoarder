#!/bin/bash

show_help() {
  cat <<EOF
Usage:
  $0 [-csv <csv_directory>] [-workers <dir_with_worker_script>] [-cfile <credential_file>] [-s <section>] [-out <output_dir>] [-proxychains] [-help]

Parameters:
  -csv           Directory containing one or more CSV files (*.csv). Default: ./csv
  -workers       Directory containing 'smbdl_worker.py'. Default: ./workers
  -cfile         Credential file containing one or more credential sections. Default: ./creds.ini
  -s             Section name in credential file to use (e.g., DEFAULT, User2). Default: DEFAULT
  -out           Output directory for downloaded files. Default: ./dl. Will be created if it doesn't exist.
  -proxychains   Use proxychains -q when calling the Python downloader
  -help          Show this help text

FZF Keybindings:
  TAB           = Select entry
  CTRL-A        = Toggle all
  CTRL-SPACE    = Download selected item(s)
EOF
}

# Default values
csvdir="./csv"
workers="./workers"
cfile="./creds.ini"
section="DEFAULT"
out="./dl"
use_proxychains=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -csv)
      csvdir="$2"
      shift 2
      ;;
    -workers)
      workers="$2"
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
    -out)
      out="$2"
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
# Check necessary files
if [[ ! -f "$workers/smbdl_worker.py" ]]; then
  echo "Error: '$workers/smbdl_worker.py' not found."
  exit 1
fi

if [[ ! -f "$cfile" ]]; then
  echo "Error: credential file '$cfile' not found."
  exit 1
fi

# Check for tools
if ! command -v fzf &>/dev/null; then
  echo "Error: fzf not found in PATH."
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 not found in PATH."
  exit 1
fi

# Check CSV directory
if [[ ! -d "$csvdir" ]]; then
  echo "Error: CSV directory '$csvdir' not found."
  exit 1
fi

# Create output directory
mkdir -p "$out"

# Build command string
if $use_proxychains; then
  dl_cmd="proxychains -q python3 $workers/smbdl_worker.py -rf -c $cfile -s $section -o $out"
else
  dl_cmd="python3 $workers/smbdl_worker.py -rf -c $cfile -s $section -o $out"
fi

# Launch FZF with files from CSV directory
cat "$csvdir"/*-$section.csv | grep -v "ID,Host,Share,Path,SizeMB,SizeBytes,Created" | fzf -e -m \
  --bind 'ctrl-a:toggle-all' \
  --bind "ctrl-space:execute(cat {+f} | $dl_cmd; echo 'Press ENTER to return to search'; read;)+deselect-all" \
  --preview 'printf "%s\n" {+} | awk -F, '\''{sum += $3} END {print "MB selected: " sum}'\''' \
  --preview-window=up,1
