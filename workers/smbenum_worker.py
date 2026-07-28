import configparser
import csv
import argparse
from impacket.smbconnection import SMBConnection
from termcolor import colored
import os
from datetime import datetime
import traceback
import sys
import hashlib


CSV_FIELDS = ["ID", "Host", "Share", "Path", "SizeMB", "SizeBytes", "Created"]
SKIP_SHARES = ("print$", "ipc$", "admin$")


def error_exit(message, exit_code=1):
    print(colored(message, 'red'), file=sys.stderr)
    sys.exit(exit_code)


def read_config(config_file, section):
    """Read domain, username, and password from a specified section in the configuration file."""
    config = configparser.ConfigParser(interpolation=None)
    if not config.read(config_file):
        error_exit(f"Configuration file {config_file} does not exist.")
    
    if section not in config:
        error_exit(f"Section {section} not found in the configuration file {config_file}.")
    
    domain = config[section].get('DOMAIN', fallback='')
    username = config[section].get('USERNAME')
    password = config[section].get('PASSWORD')
    
    if not username or password is None:
        error_exit(f"USERNAME or PASSWORD is missing in the {section} section.")
    
    return domain, username, password


def safe_filename_component(value):
    return value.replace("/", "_").replace("\\", "_").replace("\x00", "").strip() or "_"


def share_csv_path(output_dir, host, share, section):
    filename = "{}-{}-{}.csv".format(
        safe_filename_component(host),
        safe_filename_component(share),
        safe_filename_component(section),
    )
    return os.path.join(output_dir, filename)


def marker_name(host, share):
    return hashlib.md5(f"{host}||{share}".encode("utf-8")).hexdigest()


def marker_path(marker_dir, host, share, suffix):
    return os.path.join(marker_dir, f"{marker_name(host, share)}.{suffix}")


def write_marker(marker_dir, host, share, suffix):
    if not marker_dir:
        return
    os.makedirs(marker_dir, exist_ok=True)
    with open(marker_path(marker_dir, host, share, suffix), "w", encoding="utf-8") as handle:
        handle.write(f"{host}\t{share}\n")


def is_done(marker_dir, host, share):
    return bool(marker_dir and os.path.exists(marker_path(marker_dir, host, share, "done")))

def list_files(smb, csvwriter, hosten, share, counter: int = 0, subfolder="") -> int:
    try:
        files = smb.listPath(share, subfolder + '\\*')
    except Exception as e:
        print(f"{colored('Failed to list path','red')} \\\\{hosten}\\{share}\\{subfolder}: {e}")
        return counter

    try:
        for file in files:
            if file.is_directory():
                if file.get_longname() not in [".", ".."]:
                    counter=list_files(smb, csvwriter,hosten, share, counter,os.path.join(subfolder, file.get_longname()))

            else:
                file_size_mb = round(file.get_filesize() / (1024 * 1024),3)
                creation_time = datetime.fromtimestamp(file.get_ctime_epoch()).strftime('%Y-%m-%d')
                counter=counter+1
                counterhost=str(counter)+"-"+hosten;
                #csvwriter.writerow({"ID":counter, "Host":hosten,"Share":share,"Path":os.path.join(hosten,share,subfolder, file.get_longname()), "SizeMB":file_size_mb, "SizeBytes":file.get_filesize(), "Created":creation_time, "CreatedCtime":file.get_ctime_epoch()})
                csvwriter.writerow({"ID":counter, "Host":hosten,"Share":share,"Path":os.path.join(subfolder, file.get_longname()), "SizeMB":file_size_mb, "SizeBytes":file.get_filesize(), "Created":creation_time})
                print(f"{counter}, {hosten}, {share}, {os.path.join(subfolder, file.get_longname())}, {file_size_mb}, {file.get_filesize()}, {creation_time}")

    except Exception as e:
        print(f"Failed while processing {file}: {e}")
        traceback.print_exc()
        return counter
    return counter

def main():
    parser = argparse.ArgumentParser(description="SMB share file lister using Impacket")
    parser.add_argument("host", nargs='?', help="Hostname")
    parser.add_argument("-u", "--username", required=False, help="Username - if specified, config file is not read")
    parser.add_argument("-p", "--password", required=False, help="Password - if specified, config file is not read")
    parser.add_argument("-d", "--domain", required=False, help="Domain - if specified, config file is not read")
    parser.add_argument("-o", "--output", required=False, help="Output CSV file for legacy all-shares mode")
    parser.add_argument("--output-dir", required=False, help="Output directory for per-share CSV files")
    parser.add_argument("--marker-dir", required=False, help="Directory for per-share seen/done marker files")
    parser.add_argument('-c', '--config', type=str, default='creds.ini', help='Specify the configuration file (default: creds.ini)')
    parser.add_argument('-s', '--section', type=str, default='DEFAULT', help='Specify the section in the configuration file (default: DEFAULT)')

    args = parser.parse_args()
    host = args.host
    if not host:
        print("You gotta specify the host!")
        exit(1)

    if not args.output and not args.output_dir:
        error_exit("Specify either --output-dir for per-share CSV files or -o/--output for legacy all-shares output.")

    if args.username or args.password or args.domain:
        if not args.username or args.password is None:
            error_exit("When using command-line credentials, both --username and --password are required.")
        username = args.username
        password = args.password
        domain = args.domain or ""
    else:
        domain,username,password=read_config(args.config,args.section)


    counter=0
    try:
        smb = SMBConnection(host, host)
        smb.login(username, password, domain)
        shares = smb.listShares()
        print(f"Connected to {host}. Listing files...")

        if args.output_dir:
            os.makedirs(args.output_dir, exist_ok=True)
            for share in shares:
                share_name = share['shi1_netname'].strip().rstrip('\x00')
                if share_name.lower() in SKIP_SHARES:
                    print(f"Skipping share because {share_name}")
                    continue

                write_marker(args.marker_dir, host, share_name, "seen")
                if is_done(args.marker_dir, host, share_name):
                    print(f"Skipping completed share: {share_name}")
                    continue

                output = share_csv_path(args.output_dir, host, share_name, args.section)
                print(f"Share: {share_name}")
                with open(output, mode='w', newline='') as csvfile:
                    writer = csv.DictWriter(csvfile, fieldnames=CSV_FIELDS)
                    writer.writeheader()
                    list_files(smb, writer, host, share_name, 0)
                write_marker(args.marker_dir, host, share_name, "done")
        else:
            os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
            with open(args.output, mode='w', newline='') as csvfile:
                writer = csv.DictWriter(csvfile, fieldnames=CSV_FIELDS)
                writer.writeheader()
                for share in shares:
                    share_name = share['shi1_netname'].strip().rstrip('\x00')
                    if share_name.lower() in SKIP_SHARES:
                        print(f"Skipping share because {share_name}")
                    else:
                        print(f"Share: {share_name}")
                        counter=list_files(smb, writer, host, share_name, counter)

        smb.logoff()
    except Exception as e:
        error_exit(f"Failed to connect to {host}: {e}")

if __name__ == "__main__":
    main()
