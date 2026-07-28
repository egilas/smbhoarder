#!/usr/bin/env python3
import argparse
import csv
import os
import sys


FIELDS = ["ID", "Host", "Share", "Path", "SizeMB", "SizeBytes", "Created"]


def warn(message):
    print(f"Warning: {message}", file=sys.stderr)


def safe_filename_component(value):
    return value.replace("/", "_").replace("\\", "_").replace("\x00", "").strip() or "_"


def section_from_filename(filename):
    stem = os.path.basename(filename)
    if stem.endswith(".csv"):
        stem = stem[:-4]
    if "-" not in stem:
        return "unknown"
    return stem.rsplit("-", 1)[1]


def fallback_key_from_filename(filename):
    stem = os.path.basename(filename)
    if stem.endswith(".csv"):
        stem = stem[:-4]
    if "-" not in stem:
        return stem, ""
    without_section = stem.rsplit("-", 1)[0]
    if "-" not in without_section:
        return without_section, ""
    host, share = without_section.split("-", 1)
    return host, share


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


def key_for_file(filename):
    for row in iter_csv_rows(filename):
        return row[1], row[2]
    return fallback_key_from_filename(filename)


def build_map(directory):
    mapping = {}
    for entry in sorted(os.listdir(directory)):
        if not entry.endswith(".csv"):
            continue
        path = os.path.join(directory, entry)
        if not os.path.isfile(path):
            continue

        key = key_for_file(path)
        if key in mapping:
            warn(f"Multiple CSV files for {key[0]}/{key[1]} in {directory}. Using first: {mapping[key]}")
            continue
        mapping[key] = path
    return mapping


def normalized(row):
    return tuple(row[1:len(FIELDS)])


def diff_files(file1, file2):
    baseline = {normalized(row) for row in iter_csv_rows(file1)}
    return [row for row in iter_csv_rows(file2) if normalized(row) not in baseline]


def main():
    parser = argparse.ArgumentParser(description="CSV delta extractor grouped by host and share")
    parser.add_argument("dir1")
    parser.add_argument("dir2")
    parser.add_argument("outdir")
    args = parser.parse_args()

    map1 = build_map(args.dir1)
    map2 = build_map(args.dir2)
    os.makedirs(args.outdir, exist_ok=True)

    written = 0
    for key in sorted(map1):
        file1 = map1[key]
        file2 = map2.get(key)
        if not file2:
            continue

        rows = diff_files(file1, file2)
        if not rows:
            continue

        label1 = section_from_filename(file1)
        label2 = section_from_filename(file2)
        host, share = key
        outname = "{}-{}-{}-{}.csv".format(
            safe_filename_component(host),
            safe_filename_component(share),
            safe_filename_component(label1),
            safe_filename_component(label2),
        )
        outpath = os.path.join(args.outdir, outname)
        with open(outpath, "w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(FIELDS)
            writer.writerows(rows)
        written += 1

    print(f"Done. Wrote {written} diff file(s) to: {args.outdir}")


if __name__ == "__main__":
    main()
