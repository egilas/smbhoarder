#!/usr/bin/env python3
import argparse
import base64
import io
import json
import heapq
from contextlib import nullcontext
from datetime import date
import csv
import os
import sys
import tempfile
import unicodedata
from collections import defaultdict


FIELDS = ["ID", "Host", "Share", "Path", "SizeMB", "SizeBytes", "Created"]


def row_to_dict(row):
    if len(row) < len(FIELDS):
        return None
    return dict(zip(FIELDS, row[:len(FIELDS)]))


def iter_rows(stream, strict=False):
    reader = csv.reader(stream, strict=strict)
    for row in reader:
        if not row:
            continue
        if row == FIELDS or (not strict and row[:len(FIELDS)] == FIELDS):
            continue
        if strict and len(row) != len(FIELDS):
            raise ValueError(f"CSV record ending on line {reader.line_num}: expected 7 fields, got {len(row)}")
        parsed = row_to_dict(row)
        if parsed:
            yield row[:len(FIELDS)], parsed


def display_cell(value):
    # Keep terminal controls and embedded line breaks out of the picker.
    return "".join(char if char.isprintable() else " " for char in value)


def cell_width(value):
    return sum(0 if unicodedata.combining(char) else
               2 if unicodedata.east_asian_width(char) in {"W", "F"} else 1
               for char in value)


def command_display(args):
    # Spool rows to disk so measuring large catalogs does not retain them in RAM.
    widths = [cell_width(field) for field in FIELDS]
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8", newline="") as spool:
        for row, _ in iter_rows(sys.stdin):
            buffer = io.StringIO()
            csv.writer(buffer, lineterminator="\r\n").writerow(row)
            payload = base64.b64encode(buffer.getvalue().encode()).decode()
            cells = [display_cell(cell) for cell in row]
            widths = [max(width, cell_width(cell)) for width, cell in zip(widths, cells)]
            spool.write("\t".join([*cells, payload]) + "\n")

        def emit(cells, payload):
            if args.aligned:
                cells = [cell + " " * (width - cell_width(cell) + args.space - 1)
                         for cell, width in zip(cells, widths)]
            print("\t".join([*cells, payload]))

        if args.header_file:
            indices = [int(value) - 1 for value in args.columns.split(",")]
            header = (" " * args.space).join(FIELDS[index] + " " * (widths[index] - cell_width(FIELDS[index]))
                              for index in indices).rstrip()
            with open(args.header_file, "w", encoding="utf-8") as handle:
                handle.write(header + "\n")
        if args.header:
            emit(FIELDS, "")
        spool.seek(0)
        for line in spool:
            *cells, payload = line.rstrip("\n").split("\t")
            emit(cells, payload)


def command_decode(args):
    for line in sys.stdin:
        fields = line.rstrip("\n").split("\t")
        if len(fields) != len(FIELDS) + 1:
            raise ValueError("Invalid picker row")
        sys.stdout.write(base64.b64decode(fields[-1], validate=True).decode())


def format_size(size_mb):
    if size_mb >= 1024:
        return f"{size_mb / 1024:.3f} GB"
    return f"{size_mb:.3f} MB"


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

    if args.include_all:
        count = sum(info["count"] for info in groups.values())
        size = sum(info["sizemb"] for info in groups.values())
        print(f"__all_files__\t[All files] ({count} files, {format_size(size)})")
    for key, info in sorted(groups.items(), key=lambda item: (-item[1]["count"], item[0])):
        label = f"{key} ({info['count']} files, {format_size(info['sizemb'])})"
        print(f"{key}\t{label}")


def command_filter(args):
    writer = csv.writer(sys.stdout, lineterminator="\n")
    for row, parsed in iter_rows(sys.stdin):
        if group_key(parsed, args.mode) == args.key:
            writer.writerow(row)


def command_id(args):
    writer = csv.writer(sys.stdout, lineterminator="\n")
    found = False
    for row, parsed in iter_rows(sys.stdin):
        if parsed["ID"] == args.id:
            writer.writerow(row)
            found = True
            if not args.all:
                break

    if not found:
        print(f"No row found with ID {args.id}.", file=sys.stderr)
        return 1
    return 0


def command_shares(args):
    groups = defaultdict(lambda: {"count": 0, "sizemb": 0.0})
    for _, row in iter_rows(sys.stdin):
        key = (row["Host"], row["Share"])
        groups[key]["count"] += 1
        try:
            groups[key]["sizemb"] += float(row["SizeMB"])
        except ValueError:
            pass

    headers = ["Host", "Share", "Files", "SizeMB"]
    rows = [
        [host, share, str(info["count"]), f"{info['sizemb']:.3f}"]
        for (host, share), info in sorted(groups.items(), reverse=args.sort == "desc")
    ]

    widths = [len(header) for header in headers]
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))

    print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    for row in rows:
        print("  ".join(cell.ljust(widths[index]) for index, cell in enumerate(row)))


def extension_label(path):
    _, ext = os.path.splitext(path)
    if not ext:
        return "[no extension]"
    return f"*{ext.lower()}"


def command_extensions(args):
    groups = defaultdict(lambda: {"count": 0, "sizemb": 0.0})

    for _, row in iter_rows(sys.stdin):
        key = extension_label(row["Path"])
        groups[key]["count"] += 1
        try:
            groups[key]["sizemb"] += float(row["SizeMB"])
        except ValueError:
            pass

    headers = ["Extension", "Files", "SizeMB"]
    rows = [
        [extension, str(info["count"]), f"{info['sizemb']:.3f}"]
        for extension, info in sorted(
            groups.items(),
            key=lambda item: (
                -item[1]["count"] if args.sort == "desc" else item[1]["count"],
                item[0],
            ),
        )
    ]

    widths = [len(header) for header in headers]
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))

    print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    for row in rows:
        print("  ".join(cell.ljust(widths[index]) for index, cell in enumerate(row)))


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


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return number


def iso_date(value):
    try:
        parsed = date.fromisoformat(value).isoformat()
        if parsed != value:
            raise ValueError("non-canonical date")
        return parsed
    except ValueError:
        raise argparse.ArgumentTypeError("must be a date in YYYY-MM-DD format")


def input_rows(args):
    """Stream one source at a time; directory discovery avoids shell glob limits."""
    if args.csv_dir:
        files = sorted(entry.path for entry in os.scandir(args.csv_dir)
                       if entry.is_file() and entry.name.endswith(f"-{args.section}.csv"))
        if not files:
            raise ValueError(f"no CSV files for section {args.section!r} in {args.csv_dir!r}")
    else:
        files = args.files or ["-"]
    for filename in files:
        context = nullcontext(sys.stdin) if filename == "-" else open(
            filename, newline="", encoding="utf-8-sig")
        with context as handle:
            try:
                yield from iter_rows(handle, strict=True)
            except (ValueError, csv.Error) as exc:
                raise ValueError(f"{filename}: {exc}") from exc


def normalized_path(value):
    return value.replace("\\", "/").casefold()


def size_bytes(row):
    size = int(row["SizeBytes"])
    if size < 0:
        raise ValueError("SizeBytes must be non-negative")
    return size


def matching_rows(args):
    ids = set(args.id or [])
    extensions = {value.casefold() if value.startswith(".") else "." + value.casefold()
                  for value in args.extension or []}
    prefix = normalized_path(args.path_prefix).rstrip("/") if args.path_prefix else None
    for values, row in input_rows(args):
        if ids and row["ID"] not in ids:
            continue
        if args.host and row["Host"].casefold() != args.host.casefold():
            continue
        if args.share and row["Share"].casefold() != args.share.casefold():
            continue
        path = normalized_path(row["Path"])
        if prefix and path != prefix and not path.startswith(prefix + "/"):
            continue
        if extensions and os.path.splitext(path)[1] not in extensions:
            continue
        haystack = "/".join((row["Host"], row["Share"], row["Path"])).casefold()
        if any(value.casefold() not in haystack for value in args.contains):
            continue
        if args.min_bytes is not None or args.max_bytes is not None:
            size = size_bytes(row)
            if args.min_bytes is not None and size < args.min_bytes:
                continue
            if args.max_bytes is not None and size > args.max_bytes:
                continue
        if args.created_after or args.created_before:
            created = date.fromisoformat(row["Created"]).isoformat()
            if args.created_after and created < args.created_after:
                continue
            if args.created_before and created > args.created_before:
                continue
        yield values, row


def command_search(args):
    writer = csv.writer(sys.stdout) if args.format == "csv" else None
    if writer and not args.count:
        writer.writerow(FIELDS)
    matched = emitted = 0
    for values, row in matching_rows(args):
        matched += 1
        if args.count or matched <= args.offset:
            continue
        if writer:
            writer.writerow(values)
        else:
            print(json.dumps(row, ensure_ascii=True))
        emitted += 1
        if args.limit and emitted >= args.limit:
            break
    if args.count:
        print(matched)
    return 0


def command_summary(args):
    groups = {}
    count = total = 0
    for _, row in matching_rows(args):
        size = size_bytes(row)
        count += 1
        total += size
        if args.group_by == "host-share":
            key = (row["Host"], row["Share"])
            labels = {"Host": key[0], "Share": key[1]}
        elif args.group_by == "host":
            key = (row["Host"],)
            labels = {"Host": key[0]}
        else:
            key = (os.path.splitext(normalized_path(row["Path"]))[1] or "[no extension]",)
            labels = {"Extension": key[0]}
        group = groups.setdefault(key, {**labels, "files": 0, "size_bytes": 0})
        group["files"] += 1
        group["size_bytes"] += size
    # Only retain the requested top groups in the output ordering step.
    ordered = heapq.nsmallest(args.limit, groups.items(),
                             key=lambda item: (-item[1]["files"], item[0]))
    print(json.dumps({"files": count, "size_bytes": total, "group_by": args.group_by,
                      "group_count": len(groups), "groups": [group for _, group in ordered]},
                     ensure_ascii=True))
    return 0


def command_validate(args):
    """The shell spools this output completely before starting any downloads."""
    writer = csv.writer(sys.stdout)
    count = 0
    for values, row in input_rows(args):
        if not row["ID"].isascii() or not row["ID"].isdigit():
            raise ValueError("download ID must contain only ASCII digits")
        for field in ("Host", "Share"):
            value = row[field]
            if not value or value != value.strip() or any(c in value for c in "/\\\x00\r\n"):
                raise ValueError(f"invalid download {field}")
        path = row["Path"].replace("\\", "/")
        if (not path or path != path.strip() or path.startswith("/") or
                ".." in path.split("/") or "\x00" in path):
            raise ValueError("download Path must be a relative path without '..' components")
        writer.writerow(values)
        count += 1
    if not count:
        raise ValueError("selection contains no downloadable rows")
    return 0


def add_input_options(parser):
    parser.add_argument("files", nargs="*", help="CSV files; default or '-' reads stdin")
    parser.add_argument("--csv-dir", help="Read *-SECTION.csv from a directory without shell globbing")
    parser.add_argument("--section", default="DEFAULT", help="Directory filename suffix (default: DEFAULT)")


def add_search_options(parser):
    add_input_options(parser)
    parser.add_argument("--host", help="Exact host, case-insensitive")
    parser.add_argument("--share", help="Exact share, case-insensitive")
    parser.add_argument("--path-prefix", help="Directory or path prefix, on component boundaries")
    parser.add_argument("--contains", action="append", default=[],
                        help="Literal substring of host/share/path; repeat for AND matching")
    parser.add_argument("--extension", action="append", help="Suffix such as .ps1; repeat for OR matching")
    parser.add_argument("--id", action="append", help="Exact ID; repeat for OR matching")
    parser.add_argument("--min-bytes", type=nonnegative)
    parser.add_argument("--max-bytes", type=nonnegative)
    parser.add_argument("--created-after", type=iso_date, help="Inclusive creation date, YYYY-MM-DD")
    parser.add_argument("--created-before", type=iso_date, help="Inclusive creation date, YYYY-MM-DD")


def build_parser():
    parser = argparse.ArgumentParser(description="CSV helpers for smbhoarder shell wrappers")
    subparsers = parser.add_subparsers(dest="command", required=True)

    search = subparsers.add_parser("search", help="Stream filtered CSV/JSONL rows (default limit: 100)")
    add_search_options(search)
    search.add_argument("--limit", type=nonnegative, default=100, help="Maximum rows; 0 explicitly exports all")
    search.add_argument("--offset", type=nonnegative, default=0, help="Skip this many matching rows")
    search.add_argument("--format", choices=["csv", "jsonl"], default="csv")
    search.add_argument("--count", action="store_true", help="Print only total matching count; ignores limit/offset")
    search.set_defaults(func=command_search)

    summary = subparsers.add_parser("summary", help="JSON totals and top groups; scans all matching rows")
    add_search_options(summary)
    summary.add_argument("--group-by", choices=["host", "host-share", "extension"], default="host-share")
    summary.add_argument("--limit", type=nonnegative, default=20, help="Maximum groups to show (default: 20)")
    summary.set_defaults(func=command_summary)

    validate = subparsers.add_parser("validate", help="Validate explicit download selection and emit CSV")
    add_input_options(validate)
    validate.set_defaults(func=command_validate)

    display = subparsers.add_parser("display", help="Render CSV as readable picker rows")
    display.add_argument("--aligned", action="store_true")
    display.add_argument("--space", type=int, default=1)
    display.add_argument("--header", action="store_true")
    display.add_argument("--header-file", help="Write a space-aligned header separately")
    display.add_argument("--columns", default="1,2,3,4,5,6,7",
                         help="Field order for the separate header")
    display.set_defaults(func=command_display)
    decode = subparsers.add_parser("decode", help="Restore selected picker rows to CSV")
    decode.set_defaults(func=command_decode)

    catalog = subparsers.add_parser("catalog", help="Merge SMB CSV files without repeated headers")
    catalog.add_argument("files", nargs="+")
    catalog.set_defaults(func=command_catalog)

    groups = subparsers.add_parser("groups", help="Print fzf-selectable CSV chunks")
    groups.add_argument("--mode", choices=["host", "host-share", "extension"], required=True)
    groups.add_argument("--include-all", action="store_true")
    groups.set_defaults(func=command_groups)

    filter_parser = subparsers.add_parser("filter", help="Filter CSV rows to one chunk")
    filter_parser.add_argument("--mode", choices=["host", "host-share", "extension"], required=True)
    filter_parser.add_argument("--key", required=True)
    filter_parser.set_defaults(func=command_filter)

    id_parser = subparsers.add_parser("id", help="Print the CSV row matching one ID")
    id_parser.add_argument("--id", required=True)
    id_parser.add_argument("--all", action="store_true", help="Print all rows with the ID instead of the first")
    id_parser.set_defaults(func=command_id)

    shares = subparsers.add_parser("shares", help="Print host/share summary for a catalog")
    shares.add_argument("--sort", choices=["asc", "desc"], default="asc")
    shares.set_defaults(func=command_shares)

    extensions = subparsers.add_parser("extensions", help="Print file extension statistics for a catalog")
    extensions.add_argument("--sort", choices=["asc", "desc"], default="asc")
    extensions.set_defaults(func=command_extensions)

    renumber = subparsers.add_parser("renumber", help="Rewrite CSV IDs globally across files")
    renumber.add_argument("--start", type=int, default=1)
    renumber.add_argument("files", nargs="+")
    renumber.set_defaults(func=command_renumber)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "csv_dir", None) and args.files:
        parser.error("use either --csv-dir or input files, not both")
    if (getattr(args, "min_bytes", None) is not None and
            getattr(args, "max_bytes", None) is not None and args.min_bytes > args.max_bytes):
        parser.error("--min-bytes must not exceed --max-bytes")
    if (getattr(args, "created_after", None) and getattr(args, "created_before", None)
            and args.created_after > args.created_before):
        parser.error("--created-after must not exceed --created-before")
    try:
        result = args.func(args)
    except (OSError, ValueError, csv.Error) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    if isinstance(result, int):
        return result


if __name__ == "__main__":
    sys.exit(main())
