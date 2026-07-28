import csv
import subprocess
import sys
from termcolor import colored
import os
import argparse
import configparser
from impacket.smbconnection import SMBConnection

def error_donotexit(message):
    """Print an error message and exit."""
    print(colored(message,'red'), file=sys.stderr)

def error_exit(message):
    """Print an error message and exit."""
    print(colored(message,'red'), file=sys.stderr)
    sys.exit(1)

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

def smb_download(domain, username, password, smb_path, output_file):
    """Download a file via SMB."""
    try:
        smbserver, sharename, path = smb_path.split('/', 2)
    except ValueError:
        error_donotexit("Invalid SMB path format. Expected HOST/SHARE/path/to/file")
        return False

    os.makedirs(os.path.dirname(output_file) or ".", exist_ok=True)
    conn = SMBConnection(smbserver, smbserver)
    try:
        conn.login(username, password, domain)
        with open(output_file, 'wb') as f:
            print(f"Trying to download {path}")
            conn.getFile(sharename, path, f.write)
    except Exception as e:
        error_donotexit(f"SMB download failed: {e}")
        return False
    finally:
        conn.close()

    return True

def main():
    parser = argparse.ArgumentParser(description="SMB file downloader")

    parser.add_argument('-c', '--config', type=str, default='./creds.ini',
                        help='Specify the configuration file (default: ./creds.ini)')
    parser.add_argument('-rf', '--runfile', dest='runfile', action='store_true', default=True,
                        help='Run the downloaded file through the unix file command (default: enabled)')
    parser.add_argument('--no-runfile', dest='runfile', action='store_false',
                        help='Do not run the downloaded file through the unix file command')
    parser.add_argument('-s', '--section', type=str, default='DEFAULT',
                        help='Specify what creds to use in the configuration file (default: DEFAULT)')
    parser.add_argument('-o', '--out', type=str, default='.',
                        help='Specify directory where files should be downloaded to. (default: ./)')

    args = parser.parse_args()

    config_file = args.config
    section = args.section
    out = args.out

   
    domain, username, password = read_config(config_file, section)
    reader = csv.reader(sys.stdin)
    failed = False

    for fields in reader:
        if fields[:7] == ["ID", "Host", "Share", "Path", "SizeMB", "SizeBytes", "Created"]:
            continue
        if len(fields) < 7:
            error_donotexit("Invalid input format. Expected at least 7 fields in the CSV line.")
            failed = True
            continue

        id_ = fields[0].strip()
        smb_host= fields[1].strip()
        smb_share= fields[2].strip()
        smb_path = fields[3].strip()
        # Other fields (SizeMB, SizeBytes, Created) can be used if needed

        file_name = os.path.basename(smb_path)
        output_file = os.path.join(out,f"{id_}-{smb_host}__{smb_share}__{smb_path.replace('/', '__')}")
        output_file_nopathprefix = os.path.join(f"{id_}-{smb_host}__{smb_share}__{file_name}")


     
        try:
            if smb_download(domain, username, password, os.path.join(smb_host,smb_share,smb_path), output_file):
                fileprefix = ""
                fileresult = ""
                if args.runfile:
                    result = subprocess.run(['file', '-b', output_file], stdout=subprocess.PIPE)
                    fileprefix = "File info:"
                    fileresult = result.stdout.decode('utf-8').strip()
                print("File downloaded as", colored(output_file_nopathprefix, 'green'), fileprefix, colored(fileresult, "blue"))
                windows_path = r"\\" + os.path.join(smb_host,smb_share,smb_path).replace("/", "\\")
                print("Share url:", colored(windows_path, 'yellow'))
            else:
                failed = True
        except Exception as e:
            error_donotexit(f"SMB download main error: {e}")
            failed = True

    if failed:
        sys.exit(1)

if __name__ == "__main__":
    main()
