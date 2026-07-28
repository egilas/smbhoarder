#!/usr/bin/env python3
import argparse
import csv
import os
import sys
from collections import defaultdict


FIELDS = ["ID", "Host", "Share", "Path", "SizeMB", "SizeBytes", "Created"]


def safe_filename_component(value):
    return value.replace("/", "_").replace("\\", "_").replace("\x00", "").strip() or "_"


def section_from_filename(filename):
    stem = os.path.basename(filename)
    if stem.endswith(".csv"):
        stem = stem[:-4]
    if "-" not in stem:
        return "unknown"
    return stem.rsplit("-", 1)[1]


def iter_csv_rows(filename):
    with open(filename, newline="") as handle:
        reader = csv.reader(handle)
        for row in reader:
            if not row:
                continue
            row = [field.rstrip("\r") for field in row]
            if row[:len(FIELDS)] == FIELDS:
                continue
            if len(row) < len(FIELDS):
                continue
            yield row[:len(FIELDS)]


def load_csvdir(csvdir):
    data = defaultdict(list)
    users = set()

    for entry in sorted(os.listdir(csvdir)):
        if not entry.endswith(".csv"):
            continue
        filename = os.path.join(csvdir, entry)
        if not os.path.isfile(filename):
            continue

        user = section_from_filename(entry)
        users.add(user)
        for row in iter_csv_rows(filename):
            host = row[1]
            share = row[2]
            data[(user, host, share)].append(row)

    return sorted(users), data


def should_color(mode):
    if mode == "always":
        return True
    if mode == "never":
        return False
    return sys.stdout.isatty() and os.environ.get("TERM", "") != "dumb"


def colorize(text, color_enabled, code):
    if not color_enabled:
        return text
    return f"\033[{code}m{text}\033[0m"


def table_rows(users, data):
    keys = sorted({(host, share) for _, host, share in data})
    rows = []
    for host, share in keys:
        counts = [len(data.get((user, host, share), [])) for user in users]
        rows.append((host, share, counts))
    return rows


def print_stats(users, rows, color_enabled):
    if not users:
        print("No CSV files with data found.")
        return

    headers = ["Host", "Share"] + users
    rendered = []
    for host, share, counts in rows:
        rendered.append([host, share] + [str(count) for count in counts])

    widths = [len(header) for header in headers]
    for row in rendered:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))

    header_line = "  ".join(header.ljust(widths[index]) for index, header in enumerate(headers))
    separator = "  ".join("-" * width for width in widths)
    print(colorize(header_line, color_enabled, "1;36"))
    print(separator)

    for row, (_, _, counts) in zip(rendered, rows):
        line = "  ".join(cell.ljust(widths[index]) for index, cell in enumerate(row))
        if len(set(counts)) > 1:
            line = colorize(line, color_enabled, "1;33")
        print(line)


def normalized(row):
    return tuple(row[1:len(FIELDS)])


def write_unique(data, user1, user2, outdir):
    users = {user for user, _, _ in data}
    missing = [user for user in (user1, user2) if user not in users]
    if missing:
        print(f"Error: user(s) not found in CSV directory: {', '.join(missing)}", file=sys.stderr)
        return 2

    os.makedirs(outdir, exist_ok=True)
    written_files = 0
    written_rows = 0

    pairs = sorted({(host, share) for user, host, share in data if user == user1})
    for host, share in pairs:
        rows1 = data.get((user1, host, share), [])
        rows2 = data.get((user2, host, share), [])
        baseline = {normalized(row) for row in rows2}
        unique_rows = [row for row in rows1 if normalized(row) not in baseline]
        if not unique_rows:
            continue

        outname = "{}-{}-{}.csv".format(
            safe_filename_component(host),
            safe_filename_component(share),
            safe_filename_component(user1),
        )
        outpath = os.path.join(outdir, outname)
        with open(outpath, "w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(FIELDS)
            writer.writerows(unique_rows)
        written_files += 1
        written_rows += len(unique_rows)

    print(f"Wrote {written_rows} unique row(s) across {written_files} file(s) to: {outdir}")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        description="Show SMB CSV access statistics and optionally write files unique to one user."
    )
    parser.add_argument("csvdir", nargs="?", default=None, help="CSV directory, default: ./csv")
    parser.add_argument("-csv", "--csvdir", dest="csvdir_option", help="CSV directory, default: ./csv")
    parser.add_argument(
        "--unique",
        nargs=2,
        metavar=("USER1", "USER2"),
        help="Write CSV rows unique to USER1 compared to USER2.",
    )
    parser.add_argument("--outdir", help="Output directory for --unique. Default: unique-to-USER1-vs-USER2")
    parser.add_argument("--color", choices=["auto", "always", "never"], default="auto")
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    csvdir = args.csvdir_option or args.csvdir or "csv"

    if not os.path.isdir(csvdir):
        print(f"Error: CSV directory not found: {csvdir}", file=sys.stderr)
        return 1

    users, data = load_csvdir(csvdir)
    rows = table_rows(users, data)
    print_stats(users, rows, should_color(args.color))

    if args.unique:
        user1, user2 = args.unique
        outdir = args.outdir or f"unique-to-{safe_filename_component(user1)}-vs-{safe_filename_component(user2)}"
        return write_unique(data, user1, user2, outdir)

    return 0


if __name__ == "__main__":
    sys.exit(main())
