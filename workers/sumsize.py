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
    print(f"Selected: {count} files, {total:.3f} MB")

if __name__ == "__main__":
    main()
