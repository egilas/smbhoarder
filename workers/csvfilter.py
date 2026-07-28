#!/usr/bin/env python3
import argparse
import csv
import os
import sys
from collections import defaultdict


FIELDS = ["ID", "Host", "Share", "Path", "SizeMB", "SizeBytes", "Created"]


def row_to_dict(row):
    if len(row) < len(FIELDS):
        return None
    return dict(zip(FIELDS, row[:len(FIELDS)]))


def iter_rows(stream):
    reader = csv.reader(stream)
    for row in reader:
        if not row:
            continue
        if row[:len(FIELDS)] == FIELDS:
            continue
        parsed = row_to_dict(row)
        if parsed:
            yield row[:len(FIELDS)], parsed


def group_key(row, mode):
    host = row["Host"]
    share = row["Share"]
    path = row["Path"]

    if mode == "host":
        return host
    if mode == "host-share":
        return f"{host}/{share}"
    if mode == "extension":
        _, ext = os.path.splitext(path)
        return ext.lower() or "[no extension]"

    raise ValueError(f"Unsupported chunk mode: {mode}")


def command_catalog(args):
    writer = csv.writer(sys.stdout, lineterminator="\n")
    for filename in args.files:
        with open(filename, newline="") as handle:
            for row, _ in iter_rows(handle):
                writer.writerow(row)


def command_groups(args):
    groups = defaultdict(lambda: {"count": 0, "sizemb": 0.0})
    for _, row in iter_rows(sys.stdin):
        key = group_key(row, args.mode)
        groups[key]["count"] += 1
        try:
            groups[key]["sizemb"] += float(row["SizeMB"])
        except ValueError:
            pass

    for key, info in sorted(groups.items(), key=lambda item: (-item[1]["count"], item[0])):
        label = f"{key} ({info['count']} files, {info['sizemb']:.3f} MB)"
        print(f"{key}\t{label}")


def command_filter(args):
    writer = csv.writer(sys.stdout, lineterminator="\n")
    for row, parsed in iter_rows(sys.stdin):
        if group_key(parsed, args.mode) == args.key:
            writer.writerow(row)


def command_renumber(args):
    next_id = args.start

    for filename in sorted(args.files):
        rows = []
        with open(filename, newline="") as handle:
            reader = csv.reader(handle)
            for row in reader:
                if not row:
                    continue
                if row[:len(FIELDS)] == FIELDS:
                    continue
                if len(row) < len(FIELDS):
                    continue
                row = row[:len(FIELDS)]
                row[0] = str(next_id)
                next_id += 1
                rows.append(row)

        tmp_filename = f"{filename}.tmp"
        with open(tmp_filename, "w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(FIELDS)
            writer.writerows(rows)
        os.replace(tmp_filename, filename)

    print(f"Renumbered {next_id - args.start} rows across {len(args.files)} files.", file=sys.stderr)


def build_parser():
    parser = argparse.ArgumentParser(description="CSV helpers for smbhoarder shell wrappers")
    subparsers = parser.add_subparsers(dest="command", required=True)

    catalog = subparsers.add_parser("catalog", help="Merge SMB CSV files without repeated headers")
    catalog.add_argument("files", nargs="+")
    catalog.set_defaults(func=command_catalog)

    groups = subparsers.add_parser("groups", help="Print fzf-selectable CSV chunks")
    groups.add_argument("--mode", choices=["host", "host-share", "extension"], required=True)
    groups.set_defaults(func=command_groups)

    filter_parser = subparsers.add_parser("filter", help="Filter CSV rows to one chunk")
    filter_parser.add_argument("--mode", choices=["host", "host-share", "extension"], required=True)
    filter_parser.add_argument("--key", required=True)
    filter_parser.set_defaults(func=command_filter)

    renumber = subparsers.add_parser("renumber", help="Rewrite CSV IDs globally across files")
    renumber.add_argument("--start", type=int, default=1)
    renumber.add_argument("files", nargs="+")
    renumber.set_defaults(func=command_renumber)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
