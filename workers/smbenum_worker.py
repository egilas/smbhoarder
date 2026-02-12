import configparser
import csv
import argparse
from impacket.smbconnection import SMBConnection
from termcolor import colored
import os
from datetime import datetime
import traceback


def read_config(config_file, section):
    """Read domain, username, and password from a specified section in the configuration file."""
    config = configparser.ConfigParser(interpolation=None)
    if not config.read(config_file):
        error_exit(f"Configuration file {config_file} does not exist.")
    
    if section not in config:
        error_exit(f"Section {section} not found in the configuration file {config_file}.")
    
    domain = config[section].get('DOMAIN')
    username = config[section].get('USERNAME')
    password = config[section].get('PASSWORD')
    
    if not domain or not username or not password:
        error_exit(f"DOMAIN, USERNAME, or PASSWORD is missing in the {section} section.")
    
    return domain, username, password

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
        print(f"Failet her da, på filen {file} med exception {e}")
        traceback.print_exc()
        return counter
    return counter

def main():
    parser = argparse.ArgumentParser(description="SMB share file lister using Impacket")
    parser.add_argument("host", nargs='?', help="Hostname")
    parser.add_argument("-u", "--username", required=False, help="Username - if specified, config file is not read")
    parser.add_argument("-p", "--password", required=False, help="Password - if specified, config file is not read")
    parser.add_argument("-d", "--domain", required=False, help="Domain - if specified, config file is not read")
    parser.add_argument("-o", "--output", required=True, help="Output CSV file")
    parser.add_argument('-c', '--config', type=str, default='creds.ini', help='Specify the configuration file (default: creds.ini)')
    parser.add_argument('-s', '--section', type=str, default='DEFAULT', help='Specify the section in the configuration file (default: DEFAULT)')

    args = parser.parse_args()
    host = args.host
    username = args.username
    password = args.password
    domain = args.domain
    if not host:
        print("You gotta specify the host!")
        exit(1)

    if not (username or password or domain):
        domain,username,password=read_config(args.config,args.section)


    counter=0
    try:
        smb = SMBConnection(host, host)
        smb.login(username, password, domain)
        shares = smb.listShares()
        print(f"Connected to {host}. Listing files...")
        with open(args.output, mode='w', newline='') as csvfile:
            writer = csv.DictWriter(csvfile, fieldnames=["ID", "Host","Share","Path","SizeMB","SizeBytes","Created"])
            writer.writeheader()
            for share in shares:
                share_name = share['shi1_netname'].strip().rstrip('\x00')
                if share_name.lower() in ('print$','ipc$','admin$'):
                    print(f"Skipping share because {share_name}")
                else:
                    print(f"Share: {share_name}")
                    counter=list_files(smb, writer, host, share_name, counter)

        smb.logoff()
    except Exception as e:
        print(f"Failed to connect to {host}: {e}")

if __name__ == "__main__":
    main()

