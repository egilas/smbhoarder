# smbhoarder

smbhoarder is a small set of SMB enumeration and download helpers for pentest
assignments. It uses Impacket for SMB access, writes searchable CSV indexes, and
uses fzf as the interactive file picker.

## Install

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
./smbenum.sh -h hosts.txt -s DEFAULT -skip-credcheck
./smbenum.sh -h hosts.txt -s DEFAULT -sessiondir engagement-audit
```

## Search And Download

```bash
./smbdl.sh -csv csv -s DEFAULT -cfile creds.ini -out dl
```

fzf keybindings:

```text
TAB         select entry
CTRL-A      toggle all
CTRL-SPACE  download selected item(s)
```

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

Compare two enumeration directories and write rows that only the second account
can see:

```bash
./csvdiff.sh ./DEFAULT ./USER2 ./diff-DEFAULT-USER2
```

Diffing is grouped by `Host` and `Share`, and row comparison ignores the `ID`
column so post-run renumbering does not create false differences.
