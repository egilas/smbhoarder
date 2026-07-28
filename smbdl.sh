#!/bin/bash
set -euo pipefail

show_help() {
  cat <<EOF
Usage:
  $0 [-csv <csv_directory>] [-workers <dir_with_worker_script>] [-cfile <credential_file>] [-s <section>] [-out <output_dir>] [-chunk-threshold <rows>] [-chunk-mode <mode>] [-proxychains] [-help]

Parameters:
  -csv           Directory containing one or more CSV files (*.csv). Default: ./csv
  -workers       Directory containing 'smbdl_worker.py'. Default: ./workers
  -cfile         Credential file containing one or more credential sections. Default: ./creds.ini
  -s             Section name in credential file to use (e.g., DEFAULT, User2). Default: DEFAULT
  -out           Output directory for downloaded files. Default: ./dl. Will be created if it doesn't exist.
  -chunk-threshold
                 If more rows than this are available, select a smaller chunk before opening fzf.
                 Default: 100000
  -chunk-mode    How to split large result sets: host-share, host, extension, or none.
                 Default: host-share
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
chunk_threshold=100000
chunk_mode="host-share"

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
    -chunk-threshold)
      chunk_threshold="$2"
      shift 2
      ;;
    -chunk-mode)
      chunk_mode="$2"
      shift 2
      ;;
    -no-chunk)
      chunk_mode="none"
      shift
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

if [[ ! -f "$workers/csvfilter.py" ]]; then
  echo "Error: '$workers/csvfilter.py' not found."
  exit 1
fi

if [[ ! -f "$workers/sumsize.py" ]]; then
  echo "Error: '$workers/sumsize.py' not found."
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

if $use_proxychains && ! command -v proxychains &>/dev/null; then
  echo "Error: proxychains not found in PATH."
  exit 1
fi

# Check CSV directory
if [[ ! -d "$csvdir" ]]; then
  echo "Error: CSV directory '$csvdir' not found."
  exit 1
fi

# Create output directory
mkdir -p "$out"

case "$chunk_mode" in
  host-share|host|extension|none) ;;
  *)
    echo "Error: -chunk-mode must be host-share, host, extension, or none."
    exit 1
    ;;
esac

if ! [[ "$chunk_threshold" =~ ^[0-9]+$ ]]; then
  echo "Error: -chunk-threshold must be a non-negative integer."
  exit 1
fi

shopt -s nullglob
csv_files=("$csvdir"/*-"$section".csv)
shopt -u nullglob

if [[ ${#csv_files[@]} -eq 0 ]]; then
  echo "Error: no CSV files matching '$csvdir/*-$section.csv'."
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

catalog="$tmpdir/catalog.csv"
python3 "$workers/csvfilter.py" catalog "${csv_files[@]}" > "$catalog"
row_count=$(wc -l < "$catalog" | tr -d ' ')

if [[ "$row_count" -eq 0 ]]; then
  echo "Error: matching CSV files did not contain any downloadable rows."
  exit 1
fi

# Build command strings for fzf. Selected rows are passed via {+f}, so large
# selections do not become oversized shell argument lists.
worker_q=$(printf '%q' "$workers/smbdl_worker.py")
cfile_q=$(printf '%q' "$cfile")
section_q=$(printf '%q' "$section")
out_q=$(printf '%q' "$out")
sumsize_q=$(printf '%q' "$workers/sumsize.py")

if $use_proxychains; then
  dl_cmd="proxychains -q python3 $worker_q -rf -c $cfile_q -s $section_q -o $out_q"
else
  dl_cmd="python3 $worker_q -rf -c $cfile_q -s $section_q -o $out_q"
fi

run_file_picker() {
  local input_file="$1"
  local prompt="$2"

  fzf -e -m \
    --prompt "$prompt > " \
    --bind 'ctrl-a:toggle-all' \
    --bind "ctrl-space:execute($dl_cmd < {+f}; printf '\nPress ENTER to return to search'; read -r _)+deselect-all" \
    --preview "python3 $sumsize_q < {+f}" \
    --preview-window=up,2 \
    < "$input_file" || true
}

if [[ "$chunk_mode" != "none" && "$row_count" -gt "$chunk_threshold" ]]; then
  echo "[*] Loaded $row_count rows. Chunking by $chunk_mode before opening fzf."
  while true; do
    group_line=$(
      python3 "$workers/csvfilter.py" groups --mode "$chunk_mode" < "$catalog" |
        fzf --delimiter=$'\t' --with-nth=2 --prompt "Choose chunk > " \
          --preview 'printf "%s\n" {2}' \
          --preview-window=up,1
    ) || break

    group_key=${group_line%%$'\t'*}
    group_label=${group_line#*$'\t'}
    chunk_file="$tmpdir/chunk.csv"
    python3 "$workers/csvfilter.py" filter --mode "$chunk_mode" --key "$group_key" < "$catalog" > "$chunk_file"
    run_file_picker "$chunk_file" "$group_key"

    echo "[*] Finished chunk: $group_label"
    echo "[*] Pick another chunk, or press ESC/CTRL-C in the chunk selector to quit."
  done
else
  run_file_picker "$catalog" "smbhoarder"
fi
