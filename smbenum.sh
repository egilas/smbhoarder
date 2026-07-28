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
  -skip-credcheck    Skip the preflight login check. Use only when you intentionally
                     want to try the credentials against every target.
  -cred-timeout <s>  Timeout for the preflight credential check (default: 10)

Optional Credential Parameters:
  -cfile <file>      Credential file with one or more sections. (default: ./creds.ini)
  -s <section>       Section name inside credential file to use. (default: DEFAULT)

Optional Paths and Output:
  -workers <dir>     Directory containing smbenum_worker.py (default: ./workers)
  -csvdir <dir>      Output directory for result CSVs (default: ./csv). Will be created if it doesn't exist.
  -sessiondir <dir>  Directory for resumable audit logs (default: ./sessionlogs).
                     Session log names are <hosts-file-md5>-<credential-section>.csv

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

cleanup() {
  rm -rf "$tmpdir"
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

host_marker() {
  printf '%s' "$1" | md5sum | awk '{print $1}'
}

write_audit() {
  local tmp_audit="${audit_file}.tmp.$$"
  : > "$tmp_audit"
  for target in "${targets[@]}"; do
    marker=$(host_marker "$target")
    if [[ -f "$marker_dir/$marker.done" ]]; then
      printf '%s,true\n' "$target" >> "$tmp_audit"
    else
      printf '%s,false\n' "$target" >> "$tmp_audit"
    fi
  done
  mv "$tmp_audit" "$audit_file"
}

handle_interrupt() {
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
  while IFS=, read -r target finished; do
    if [[ "$finished" == "true" ]]; then
      marker=$(host_marker "$target")
      printf '%s\n' "$target" > "$marker_dir/$marker.done"
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
  marker=$(host_marker "$target")
  if [[ ! -f "$marker_dir/$marker.done" ]]; then
    printf '%s\n' "$target" >> "$todo_file"
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

run_status=0
xargs -r -I{} -P "$threads" bash -c '
  target=$1
  csvdir=$2
  section=$3
  cfile=$4
  worker_script=$5
  marker_dir=$6
  use_proxychains=$7

  if [[ "$use_proxychains" == "true" ]]; then
    proxychains -q python3 "$worker_script" "$target" -o "$csvdir/${target}-${section}.csv" -c "$cfile" -s "$section"
  else
    python3 "$worker_script" "$target" -o "$csvdir/${target}-${section}.csv" -c "$cfile" -s "$section"
  fi
  status=$?

  if [[ "$status" -eq 0 ]]; then
    marker=$(printf "%s" "$target" | md5sum | awk "{print \$1}")
    printf "%s\n" "$target" > "$marker_dir/$marker.done"
  fi

  exit "$status"
' _ {} "$csvdir" "$section" "$cfile" "$worker_script" "$marker_dir" "$use_proxychains" < "$todo_file" || run_status=$?

write_audit

if [[ "$run_status" -ne 0 ]]; then
  echo "[!] One or more targets failed. Resume with the same hosts file and credential section to retry pending hosts."
  exit "$run_status"
fi

echo "[*] Enumeration complete. Session audit: $audit_file"
