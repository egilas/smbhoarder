import sys
import csv

def main():
    total = 0.0
    # Reading CSV from standard input
    csv_reader = csv.reader(sys.stdin)
    for row in csv_reader:
        try:
            # Summing up the third field
            total += float(row[2])
        except ValueError:
            # Ignore rows where the third field is not a number
            continue
        except IndexError:
            # Ignore rows that don't have a third field
            continue
    print(f"Total sum of field 3: {total}")

if __name__ == "__main__":
    main()

