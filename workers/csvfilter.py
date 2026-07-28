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

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
