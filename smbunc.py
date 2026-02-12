import sys

def konverter(sti):
    if '-' not in sti:
        raise ValueError("Strengen må inneholde '-' som skiller ID fra sti.")

    id_del, path_del = sti.split('-', 1)
    if not id_del.isdigit():
        raise ValueError("ID-delen før '-' må bestå av siffer.")

    deler = path_del.split('__')
    if len(deler) < 2:
        raise ValueError("Strengen må inneholde minst ett '__'.")

    filnavn = deler[-1]
    mapper = deler[:-1]
    nettverkssti = "\\\\" + "\\".join(mapper) + "\\" + filnavn

    return f"{nettverkssti} ({id_del})"

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Bruk: python3 konverter.py 123-mappe__under__fil.txt")
        sys.exit(1)

    try:
        print(konverter(sys.argv[1]))
    except ValueError as e:
        print("Feil:", e)
        sys.exit(2)

