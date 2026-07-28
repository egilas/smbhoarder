#!/usr/bin/env python3
import argparse
import configparser
import socket
import sys

from impacket import nt_errors
from impacket.smbconnection import SMBConnection, SessionError
from termcolor import colored


AUTH_ERROR_CODES = {
    nt_errors.STATUS_LOGON_FAILURE,
    nt_errors.STATUS_ACCOUNT_RESTRICTION,
    nt_errors.STATUS_INVALID_LOGON_HOURS,
    nt_errors.STATUS_INVALID_WORKSTATION,
    nt_errors.STATUS_PASSWORD_EXPIRED,
    nt_errors.STATUS_ACCOUNT_DISABLED,
    nt_errors.STATUS_ACCOUNT_LOCKED_OUT,
    nt_errors.STATUS_ACCOUNT_EXPIRED,
    nt_errors.STATUS_PASSWORD_MUST_CHANGE,
}


def error_exit(message, exit_code=1):
    print(colored(message, "red"), file=sys.stderr)
    sys.exit(exit_code)


def read_config(config_file, section):
    config = configparser.ConfigParser(interpolation=None)
    if not config.read(config_file):
        error_exit(f"Configuration file {config_file} does not exist.")

    if section not in config:
        error_exit(f"Section {section} not found in the configuration file {config_file}.")

    domain = config[section].get("DOMAIN", fallback="")
    username = config[section].get("USERNAME")
    password = config[section].get("PASSWORD")

    if not username or password is None:
        error_exit(f"USERNAME or PASSWORD is missing in the {section} section.")

    return domain, username, password


def is_auth_error(exc):
    try:
        return exc.getErrorCode() in AUTH_ERROR_CODES
    except Exception:
        return any(name in str(exc) for name in (
            "STATUS_LOGON_FAILURE",
            "STATUS_ACCOUNT_RESTRICTION",
            "STATUS_INVALID_LOGON_HOURS",
            "STATUS_INVALID_WORKSTATION",
            "STATUS_PASSWORD_EXPIRED",
            "STATUS_ACCOUNT_DISABLED",
            "STATUS_ACCOUNT_LOCKED_OUT",
            "STATUS_ACCOUNT_EXPIRED",
            "STATUS_PASSWORD_MUST_CHANGE",
        ))


def check_host(host, domain, username, password, timeout):
    conn = None
    try:
        conn = SMBConnection(host, host, sess_port=445, timeout=timeout)
        conn.login(username, password, domain)
        conn.logoff()
        return "ok", None
    except SessionError as exc:
        if is_auth_error(exc):
            return "auth_error", exc
        return "smb_error", exc
    except (OSError, socket.timeout, TimeoutError) as exc:
        return "network_error", exc
    except Exception as exc:
        return "unknown_error", exc
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser(
        description="Validate SMB credentials against one reachable target before threaded enumeration"
    )
    parser.add_argument("-c", "--config", default="./creds.ini")
    parser.add_argument("-s", "--section", default="DEFAULT")
    parser.add_argument("--timeout", type=int, default=10)
    args = parser.parse_args()

    domain, username, password = read_config(args.config, args.section)
    hosts = [line.strip() for line in sys.stdin if line.strip() and not line.lstrip().startswith("#")]

    if not hosts:
        error_exit("No targets available for credential check.", 3)

    for host in hosts:
        status, detail = check_host(host, domain, username, password, args.timeout)
        if status == "ok":
            print(colored(f"[*] Credential check succeeded against {host}.", "green"), file=sys.stderr)
            return
        if status == "auth_error":
            error_exit(f"[!] Credential check failed against {host}: {detail}", 2)

        print(colored(f"[*] Could not validate against {host}: {detail}", "yellow"), file=sys.stderr)

    error_exit(
        "[!] Could not validate credentials against any target. "
        "Enumeration was not started; use -skip-credcheck if you intentionally want to proceed.",
        3,
    )


if __name__ == "__main__":
    main()
