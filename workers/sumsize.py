import sys
import csv

def main():
    total = 0.0
    count = 0
    csv_reader = csv.reader(sys.stdin)
    for row in csv_reader:
        if not row or row[0] == "ID":
            continue
        try:
            total += float(row[4])
            count += 1
        except ValueError:
            continue
        except IndexError:
            continue
    size = f"{total / 1024:.3f} GB" if total >= 1024 else f"{total:.3f} MB"
    print(f"Selected: {count} files, {size}")

if __name__ == "__main__":
    main()
