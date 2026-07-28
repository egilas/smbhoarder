#!/bin/bash
set -euo pipefail

show_help() {
  cat <<EOF
Usage:
  $0 [-csv <csv_directory>] [-workers <dir_with_worker_script>] [-cfile <credential_file>] [-s <section>] [-out <output_dir>] [-chunk-threshold <rows>] [-chunk-mode <mode>] [-id <csv_id>] [-view] [-proxychains] [-help]

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
  -id            Download a single row by CSV ID and exit.
  -view          After a single-ID download, open supported text-like files with cat <file> | fzf.
  -proxychains   Use proxychains -q when calling the Python downloader
  -help          Show this help text

FZF Keybindings:
  ENTER         = Download current entry and view it when supported
  TAB           = Select entry
  CTRL-A        = Toggle all
  CTRL-S        = Show host/share summary, sorted ascending
  ALT-S         = Show host/share summary, sorted descending
  CTRL-F        = Show extension statistics, sorted ascending by file count
  ALT-F         = Show extension statistics, sorted descending by file count
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
download_id=""
view_after_download=false

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
    -id)
      download_id="$2"
      shift 2
      ;;
    -view)
      view_after_download=true
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

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"

if [[ -z "$download_id" && -f "$workers/logo.txt" ]]; then
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
if [[ -z "$download_id" || "$view_after_download" == "true" ]] && ! command -v fzf &>/dev/null; then
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
stty_state=""

restore_terminal() {
  if [[ -n "$stty_state" ]]; then
    stty "$stty_state" < /dev/tty 2>/dev/null || true
  fi
}

cleanup() {
  restore_terminal
  rm -rf "$tmpdir"
}

trap cleanup EXIT

if [[ -z "$download_id" ]] && stty_state=$({ stty -g < /dev/tty; } 2>/dev/null); then
  stty -ixon < /dev/tty 2>/dev/null || true
fi

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
csvfilter_q=$(printf '%q' "$workers/csvfilter.py")
script_q=$(printf '%q' "$SCRIPT_PATH")
csvdir_q=$(printf '%q' "$csvdir")
workers_q=$(printf '%q' "$workers")
catalog_q=$(printf '%q' "$catalog")
proxy_arg=""
if $use_proxychains; then
  proxy_arg="-proxychains"
fi

if $use_proxychains; then
  dl_cmd="proxychains -q python3 $worker_q -rf -c $cfile_q -s $section_q -o $out_q"
else
  dl_cmd="python3 $worker_q -rf -c $cfile_q -s $section_q -o $out_q"
fi

single_cmd="$script_q -csv $csvdir_q -workers $workers_q -cfile $cfile_q -s $section_q -out $out_q $proxy_arg -id {1} -view"
shares_asc="$tmpdir/shares-asc.txt"
shares_desc="$tmpdir/shares-desc.txt"
shares_asc_q=$(printf '%q' "$shares_asc")
shares_desc_q=$(printf '%q' "$shares_desc")
share_header_asc_q=$(printf '%q' "Host/share summary for $section, ascending. ESC or ENTER returns to search.")
share_header_desc_q=$(printf '%q' "Host/share summary for $section, descending. ESC or ENTER returns to search.")
shares_asc_cmd="test -s $shares_asc_q || python3 $csvfilter_q shares --sort asc < $catalog_q > $shares_asc_q; fzf --no-sort --header-lines=1 --prompt 'shares asc > ' --header $share_header_asc_q < $shares_asc_q >/dev/null"
shares_desc_cmd="test -s $shares_desc_q || python3 $csvfilter_q shares --sort desc < $catalog_q > $shares_desc_q; fzf --no-sort --header-lines=1 --prompt 'shares desc > ' --header $share_header_desc_q < $shares_desc_q >/dev/null"

extensions_asc="$tmpdir/extensions-asc.txt"
extensions_desc="$tmpdir/extensions-desc.txt"
extensions_asc_q=$(printf '%q' "$extensions_asc")
extensions_desc_q=$(printf '%q' "$extensions_desc")
ext_header_asc_q=$(printf '%q' "$section extension statistics, ascending by count. ESC or ENTER returns to search.")
ext_header_desc_q=$(printf '%q' "$section extension statistics, descending by count. ESC or ENTER returns to search.")
extensions_asc_cmd="test -s $extensions_asc_q || python3 $csvfilter_q extensions --sort asc < $catalog_q > $extensions_asc_q; fzf --no-sort --header-lines=1 --prompt 'extensions asc > ' --header $ext_header_asc_q < $extensions_asc_q >/dev/null"
extensions_desc_cmd="test -s $extensions_desc_q || python3 $csvfilter_q extensions --sort desc < $catalog_q > $extensions_desc_q; fzf --no-sort --header-lines=1 --prompt 'extensions desc > ' --header $ext_header_desc_q < $extensions_desc_q >/dev/null"

can_cat_view() {
  local file="$1"
  local ext mime

  ext="${file##*.}"
  ext="${ext,,}"
  case "$ext" in
    bat|cmd|conf|config|csv|htm|html|ini|js|json|log|md|ps1|reg|rtf|sql|txt|vbs|xml|yaml|yml)
      return 0
      ;;
  esac

  if command -v file &>/dev/null; then
    mime=$(file -b --mime-type "$file" 2>/dev/null || true)
    [[ "$mime" == text/* ]] && return 0
  fi

  return 1
}

view_downloaded_file() {
  local file="$1"
  local base

  if [[ ! -f "$file" ]]; then
    echo "Downloaded file not found: $file" >&2
    return 1
  fi

  if ! can_cat_view "$file"; then
    echo "No viewer configured for this file type: $file"
    return 0
  fi

  base=$(basename -- "$file")
  cat "$file" | fzf --no-sort --prompt "view $base > " --header "$file" || true
}

download_single_id() {
  local selected_row="$tmpdir/selected.csv"
  local downloaded_paths="$tmpdir/downloaded-paths.txt"
  local status=0
  local file

  python3 "$workers/csvfilter.py" id --id "$download_id" < "$catalog" > "$selected_row"

  if $use_proxychains; then
    proxychains -q python3 "$workers/smbdl_worker.py" --quiet --print-paths -rf -c "$cfile" -s "$section" -o "$out" < "$selected_row" > "$downloaded_paths"
  else
    python3 "$workers/smbdl_worker.py" --quiet --print-paths -rf -c "$cfile" -s "$section" -o "$out" < "$selected_row" > "$downloaded_paths"
  fi
  status=$?
  if [[ "$status" -ne 0 ]]; then
    return "$status"
  fi

  if $view_after_download; then
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      view_downloaded_file "$file"
    done < "$downloaded_paths"
  else
    cat "$downloaded_paths"
  fi
}

if [[ -n "$download_id" ]]; then
  download_single_id
  exit $?
fi

run_file_picker() {
  local input_file="$1"
  local prompt="$2"

  fzf -e -m \
    --delimiter=',' \
    --prompt "$prompt > " \
    --bind 'ctrl-a:toggle-all' \
    --bind "ctrl-s:execute($shares_asc_cmd)" \
    --bind "alt-s:execute($shares_desc_cmd)" \
    --bind "ctrl-f:execute($extensions_asc_cmd)" \
    --bind "alt-f:execute($extensions_desc_cmd)" \
    --bind "enter:execute($single_cmd)" \
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
