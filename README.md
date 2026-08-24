
# smbhoarder

smbhoarder is a small set of SMB enumeration and download helpers for pentest
assignments. It uses Impacket for SMB access, writes searchable CSV indexes, and
uses fzf as the interactive file picker.

## Install
Kali/Debian/Ubuntu:
```bash
sudo apt-get install fzf file python3-termcolor python3-impacket
```

The pip-way:
```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
sudo apt-get install fzf file
```

If you want SOCKS-aware execution, install and configure `proxychains` separately
and pass `-proxychains` to the scripts.

## Credentials

Put credentials in `creds.ini` sections:

```ini
[DEFAULT]
DOMAIN=
USERNAME=user1
PASSWORD=pass1

[USER2]
DOMAIN=
USERNAME=user2
PASSWORD=pass2
```

`DOMAIN` may be empty for local accounts. `USERNAME` and `PASSWORD` are required.

## Workflow
This is how you use the tools:

<img width="1489" height="658" alt="workflow" src="https://github.com/egilas/smbhoarder/blob/main/workflow.png" />

## Enumerate Shares

```bash
./smbenum.sh -h hosts.txt -s DEFAULT -cfile creds.ini -csvdir csv
```

`hosts.txt` can be a plain list of hosts/IPs or an Nmap gnmap file; if it
contains `445/open`, smbhoarder extracts those hosts automatically.

Before threaded enumeration starts, `smbenum.sh` validates the credentials
against one reachable target. If the password is wrong, it stops instead of
trying the same bad password against every host.

Enumeration writes one CSV per host/share:

```text
csv/
  192.0.2.10-myshare-DEFAULT.csv
  192.0.2.10-SYSVOL-DEFAULT.csv
```

Each CSV still includes the `Share` column. A host is processed by one worker at
a time; the per-share CSV split does not create multiple simultaneous SMB
workers against the same host.

Resume/audit state is written to `sessionlogs/` by default. The session filename
is based on the MD5 of the hosts file and the credential section, and each audit
line is:

```text
192.0.2.10,myshare,true
192.0.2.10,SYSVOL,false
```

Run the same command again to skip completed host/share pairs and retry only
pending shares. Resume is share-granular, not file-granular: if a scan is
interrupted inside a very large share, that share is retried from the beginning.

After a successful run, IDs in the first CSV column are renumbered globally
across the output directory for that credential section, so IDs are unique across
hosts and shares in the run.

Useful options:

```bash
./smbenum.sh -h hosts.gnmap -s USER2 -t 50
./smbenum.sh -h hosts.txt -s DEFAULT -verbose
./smbenum.sh -h hosts.txt -s DEFAULT -skip-credcheck
./smbenum.sh -h hosts.txt -s DEFAULT -sessiondir engagement-audit
```

Enumeration prints a 5 second start notice before the threaded scan starts. By
default it keeps worker output quiet and prints a simple ASCII progress line with
host, share, thread, and file counters. Use `-verbose` to print every discovered
file instead.

## Search And Download

```bash
./smbdl.sh -csv csv -s DEFAULT -cfile creds.ini -out dl
```

fzf keybindings:

```text
ENTER      download current entry and view it when supported
TAB         select entry
CTRL-A      toggle all
CTRL-S      show host/share summary, sorted ascending
ALT-S       show host/share summary, sorted descending
CTRL-F      show extension statistics, sorted ascending by count
ALT-F       show extension statistics, sorted descending by count
CTRL-SPACE  download selected item(s)
```

`CTRL-S`, `ALT-S`, and the extension statistics open scrollable fzf views. Many terminals
do not expose `CTRL-SHIFT-F` as a distinct key from `CTRL-F`, so descending
extension sort is bound to `ALT-F`.

You can also download one row directly by ID:

```bash
./smbdl.sh -csv csv -s DEFAULT -cfile creds.ini -out dl -id 1234
./smbdl.sh -csv csv -s DEFAULT -cfile creds.ini -out dl -id 1234 -view
```

`-view` opens supported text-like files with `cat <file> | fzf`.

Large selections are passed to the downloader through a temporary file, avoiding
shell argument-list limits. For large CSV indexes, `smbdl.sh` first asks you to
select a smaller chunk before loading fzf:

```bash
./smbdl.sh -csv csv -s DEFAULT -chunk-threshold 100000 -chunk-mode host-share
./smbdl.sh -csv csv -s DEFAULT -chunk-mode extension
./smbdl.sh -csv csv -s DEFAULT -no-chunk
```

Chunk modes are `host-share`, `host`, `extension`, and `none`.

## Diff Access Between Users

Put all users' enumeration CSV files in the same directory, then show per-user
file counts per host/share:

```bash
./smbdiff.py -csv csv
```

Rows where the user counts differ are highlighted when color output is available.
To write files that are unique to one user compared to another:

```bash
./smbdiff.py -csv csv --unique USER2 DEFAULT
./smbdiff.py -csv csv --unique USER2 DEFAULT --outdir unique-user2-default
```

The default output directory is `unique-to-USER1-vs-USER2`. Output files follow
the normal `<host>-<share>-<user>.csv` naming convention and row comparison
ignores the `ID` column so post-run renumbering does not create false
differences.

`csvdiff.sh` is still present for older two-directory workflows, but
`smbdiff.py` is the preferred interface.
