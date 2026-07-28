#!/bin/bash
set -uo pipefail

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
  -verbose           Print every discovered file. By default, smbenum shows only
                     a compact progress line.
  -skip-credcheck    Skip the preflight login check. Use only when you intentionally
                     want to try the credentials against every target.
  -cred-timeout <s>  Timeout for the preflight credential check (default: 10)

Optional Credential Parameters:
  -cfile <file>      Credential file with one or more sections. (default: ./creds.ini)
  -s <section>       Section name inside credential file to use. (default: DEFAULT)

Optional Paths and Output:
  -workers <dir>     Directory containing smbenum_worker.py (default: ./workers)
  -csvdir <dir>      Output directory for result CSVs (default: ./csv). Will be created if it doesn't exist.
                     Enumeration writes one CSV per host/share:
                     <host>-<share>-<section>.csv
  -sessiondir <dir>  Directory for resumable audit logs (default: ./sessionlogs).
                     Session log names are <hosts-file-md5>-<credential-section>.csv
                     Audit rows are host,share,finished.

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
verbose=false
skip_credcheck=false
cred_timeout=10
sessiondir="./sessionlogs"

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
    -verbose)
      verbose=true
      shift
      ;;
    -skip-credcheck)
      skip_credcheck=true
      shift
      ;;
    -cred-timeout)
      cred_timeout="$2"
      shift 2
      ;;
    -sessiondir)
      sessiondir="$2"
      shift 2
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

credcheck_script="$workers/smbcredcheck.py"
if [[ ! -f "$credcheck_script" ]]; then
  echo "Error: '$credcheck_script' not found."
  exit 1
fi

csvfilter_script="$workers/csvfilter.py"
if [[ ! -f "$csvfilter_script" ]]; then
  echo "Error: '$csvfilter_script' not found."
  exit 1
fi

# Check creds file
if [[ ! -f "$cfile" ]]; then
  echo "Error: Credential file '$cfile' not found."
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

if ! command -v md5sum &>/dev/null; then
  echo "Error: md5sum not found in PATH."
  exit 1
fi

if ! [[ "$threads" =~ ^[0-9]+$ && "$threads" -gt 0 ]]; then
  echo "Error: -t must be a positive integer."
  exit 1
fi

if ! [[ "$cred_timeout" =~ ^[0-9]+$ && "$cred_timeout" -gt 0 ]]; then
  echo "Error: -cred-timeout must be a positive integer."
  exit 1
fi

# Ensure output directory exists
mkdir -p "$csvdir"
mkdir -p "$sessiondir"

tmpdir=$(mktemp -d)
audit_initialized=false
targets_file="$tmpdir/targets.txt"
todo_file="$tmpdir/todo.txt"
progress_stop_file="$tmpdir/progress.stop"
progress_pid=""

cleanup() {
  rm -rf "$tmpdir"
}

kill_descendants() {
  local parent="$1"
  local child

  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    kill_descendants "$child"
    kill -TERM "$child" 2>/dev/null || true
  done < <(pgrep -P "$parent" 2>/dev/null || true)
}

# Parse hosts from gnmap if applicable
if grep -q "445/open" "$hosts_file"; then
  echo "[*] Detected gnmap format. Extracting hosts with 445/open..."
  mapfile -t targets < <(grep "445/open" "$hosts_file" | cut -d " " -f2 | sed 's/\r$//' | sort -u)
else
  echo "[*] Using hosts directly from input file."
  mapfile -t targets < <(sed 's/\r$//' "$hosts_file" | awk 'NF && $1 !~ /^#/')
fi

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "Error: no targets found in '$hosts_file'."
  cleanup
  exit 1
fi

host_hash=$(md5sum "$hosts_file" | awk '{print $1}')
safe_section=$(printf '%s' "$section" | tr -c 'A-Za-z0-9_.-' '_')
session_id="${host_hash}-${safe_section}"
audit_file="$sessiondir/${session_id}.csv"
marker_dir="$sessiondir/${session_id}.done"
mkdir -p "$marker_dir"

share_marker() {
  printf '%s||%s' "$1" "$2" | md5sum | awk '{print $1}'
}

host_marker() {
  printf '%s||__host__' "$1" | md5sum | awk '{print $1}'
}

write_marker() {
  local target="$1"
  local share="$2"
  local suffix="$3"
  local marker
  marker=$(share_marker "$target" "$share")
  printf '%s\t%s\n' "$target" "$share" > "$marker_dir/$marker.$suffix"
}

write_host_done() {
  local target="$1"
  local marker
  marker=$(host_marker "$target")
  printf '%s\n' "$target" > "$marker_dir/$marker.hostdone"
}

write_audit() {
  local tmp_audit="${audit_file}.tmp.$$"
  local seen_files=()
  local seen_file marker done_file target share

  : > "$tmp_audit"

  shopt -s nullglob
  seen_files=("$marker_dir"/*.seen)
  shopt -u nullglob

  for seen_file in "${seen_files[@]}"; do
    IFS=$'\t' read -r target share < "$seen_file" || continue
    marker=${seen_file##*/}
    done_file="$marker_dir/${marker%.seen}.done"
    if [[ -f "$done_file" ]]; then
      printf '%s,%s,true\n' "$target" "$share" >> "$tmp_audit"
    else
      printf '%s,%s,false\n' "$target" "$share" >> "$tmp_audit"
    fi
  done

  if [[ -s "$tmp_audit" ]]; then
    sort -t, -k1,1 -k2,2 "$tmp_audit" -o "$tmp_audit"
  fi
  mv "$tmp_audit" "$audit_file"
}

count_marker_suffix() {
  local suffix="$1"
  local files=()

  shopt -s nullglob
  files=("$marker_dir"/*"$suffix")
  shopt -u nullglob
  printf '%s' "${#files[@]}"
}

sum_count_markers() {
  local total=0
  local value count_file
  local count_files=()

  shopt -s nullglob
  count_files=("$marker_dir"/*.count)
  shopt -u nullglob

  for count_file in "${count_files[@]}"; do
    IFS= read -r value < "$count_file" || value=0
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      total=$((total + value))
    fi
  done

  printf '%s' "$total"
}

progress_bar() {
  local done="$1"
  local total="$2"
  local width=28
  local filled=0
  local empty=0
  local bar=""
  local empty_bar=""

  if [[ "$total" -gt 0 ]]; then
    filled=$((done * width / total))
  fi
  empty=$((width - filled))
  printf -v bar '%*s' "$filled" ''
  bar=${bar// /#}
  printf -v empty_bar '%*s' "$empty" ''
  empty_bar=${empty_bar// /-}
  printf '[%s%s]' "$bar" "$empty_bar"
}

print_progress_line() {
  local completed_hosts active_threads shares_seen shares_done files_seen bar percent line

  completed_hosts=$(count_marker_suffix ".hostdone")
  active_threads=$(count_marker_suffix ".active")
  shares_seen=$(count_marker_suffix ".seen")
  shares_done=$(count_marker_suffix ".done")
  files_seen=$(sum_count_markers)
  bar=$(progress_bar "$completed_hosts" "${#targets[@]}")
  percent=0
  if [[ "${#targets[@]}" -gt 0 ]]; then
    percent=$((completed_hosts * 100 / ${#targets[@]}))
  fi

  line=$(printf '[*] %s %3d%% | hosts %d/%d | shares %d/%d | threads %d/%d | files %d' \
    "$bar" "$percent" "$completed_hosts" "${#targets[@]}" "$shares_done" "$shares_seen" "$active_threads" "$threads" "$files_seen")

  if [[ -t 2 && "${TERM:-}" != "dumb" ]]; then
    printf '\r%-120s' "$line" >&2
  else
    printf '%s\n' "$line" >&2
  fi
}

progress_monitor() {
  local sleep_time=5
  if [[ -t 2 && "${TERM:-}" != "dumb" ]]; then
    sleep_time=1
  fi

  while [[ ! -f "$progress_stop_file" ]]; do
    print_progress_line
    sleep "$sleep_time"
  done
  print_progress_line
  if [[ -t 2 && "${TERM:-}" != "dumb" ]]; then
    printf '\n' >&2
  fi
}

start_progress_monitor() {
  if $verbose; then
    return
  fi
  rm -f "$progress_stop_file"
  progress_monitor &
  progress_pid=$!
}

stop_progress_monitor() {
  if [[ -n "${progress_pid:-}" ]]; then
    : > "$progress_stop_file"
    wait "$progress_pid" 2>/dev/null || true
    progress_pid=""
  fi
}

countdown() {
  local seconds=5
  local current

  echo "[*] Enumeration starts in $seconds seconds. Press Ctrl-C to abort."
  for ((current=seconds; current>=1; current--)); do
    printf '    %d...\n' "$current"
    sleep 1
  done
}

handle_interrupt() {
  stop_progress_monitor
  kill_descendants "$$"
  if $audit_initialized; then
    write_audit
    echo
    echo "[*] Interrupted. Session audit updated at $audit_file"
  fi
  cleanup
  exit 130
}

trap handle_interrupt INT TERM
trap cleanup EXIT

if [[ -f "$audit_file" ]]; then
  echo "[*] Resuming session: $audit_file"
  while IFS=, read -r target share finished extra; do
    if [[ -n "${extra:-}" || -z "${target:-}" || -z "${share:-}" || -z "${finished:-}" ]]; then
      echo "Warning: ignoring invalid audit line: ${target:-},${share:-},${finished:-}${extra:+,$extra}" >&2
      continue
    fi

    write_marker "$target" "$share" "seen"
    if [[ "$finished" == "true" ]]; then
      write_marker "$target" "$share" "done"
    fi
  done < "$audit_file"
else
  echo "[*] Creating session audit: $audit_file"
fi

write_audit
audit_initialized=true

: > "$targets_file"
: > "$todo_file"
for target in "${targets[@]}"; do
  printf '%s\n' "$target" >> "$targets_file"
  seen_count=0
  pending_count=0

  shopt -s nullglob
  seen_files=("$marker_dir"/*.seen)
  shopt -u nullglob
  for seen_file in "${seen_files[@]}"; do
    IFS=$'\t' read -r seen_target seen_share < "$seen_file" || continue
    [[ "$seen_target" != "$target" ]] && continue
    seen_count=$((seen_count + 1))
    marker=${seen_file##*/}
    if [[ ! -f "$marker_dir/${marker%.seen}.done" ]]; then
      pending_count=$((pending_count + 1))
    fi
  done

  if [[ "$seen_count" -eq 0 || "$pending_count" -gt 0 ]]; then
    printf '%s\n' "$target" >> "$todo_file"
  else
    write_host_done "$target"
  fi
done

todo_count=$(wc -l < "$todo_file" | tr -d ' ')
done_count=$((${#targets[@]} - todo_count))
echo "[*] Targets: ${#targets[@]} total, $done_count already finished, $todo_count pending."

if [[ "$todo_count" -eq 0 ]]; then
  echo "[*] Nothing to do. Session is complete."
  exit 0
fi

if ! $skip_credcheck; then
  echo "[*] Running credential preflight check before threaded enumeration..."
  cred_status=0
  if $use_proxychains; then
    proxychains -q python3 "$credcheck_script" -c "$cfile" -s "$section" --timeout "$cred_timeout" < "$todo_file" || cred_status=$?
  else
    python3 "$credcheck_script" -c "$cfile" -s "$section" --timeout "$cred_timeout" < "$todo_file" || cred_status=$?
  fi

  if [[ "$cred_status" -ne 0 ]]; then
    echo "[!] Credential preflight failed. Enumeration was not started."
    exit "$cred_status"
  fi
else
  echo "[*] Skipping credential preflight check."
fi

rm -f "$marker_dir"/*.active
countdown

run_status=0
start_progress_monitor
xargs -r -I{} -P "$threads" bash -c '
  target=$1
  csvdir=$2
  section=$3
  cfile=$4
  worker_script=$5
  marker_dir=$6
  use_proxychains=$7
  verbose=$8

  host_hash=$(printf "%s||__host__" "$target" | md5sum | awk "{print \$1}")
  active_file="$marker_dir/$host_hash.active"
  : > "$active_file"
  trap "rm -f \"$active_file\"" EXIT

  verbose_args=()
  if [[ "$verbose" == "true" ]]; then
    verbose_args=(--verbose)
  fi

  if [[ "$use_proxychains" == "true" ]]; then
    proxychains -q python3 "$worker_script" "$target" --output-dir "$csvdir" --marker-dir "$marker_dir" -c "$cfile" -s "$section" "${verbose_args[@]}"
  else
    python3 "$worker_script" "$target" --output-dir "$csvdir" --marker-dir "$marker_dir" -c "$cfile" -s "$section" "${verbose_args[@]}"
  fi
  status=$?

  if [[ "$status" -eq 0 ]]; then
    printf "%s\n" "$target" > "$marker_dir/$host_hash.hostdone"
  fi

  exit "$status"
' _ {} "$csvdir" "$section" "$cfile" "$worker_script" "$marker_dir" "$use_proxychains" "$verbose" < "$todo_file" || run_status=$?
stop_progress_monitor

write_audit

if [[ "$run_status" -ne 0 ]]; then
  echo "[!] One or more targets failed. Resume with the same hosts file and credential section to retry pending hosts."
  exit "$run_status"
fi

shopt -s nullglob
csv_files=("$csvdir"/*-"$section".csv)
shopt -u nullglob
if [[ ${#csv_files[@]} -gt 0 ]]; then
  echo "[*] Renumbering CSV IDs across ${#csv_files[@]} file(s)..."
  python3 "$csvfilter_script" renumber "${csv_files[@]}"
fi

echo "[*] Enumeration complete. Session audit: $audit_file"
