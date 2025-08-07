#!/usr/bin/env python3
"""
Enhanced Python script to copy TwinCAT boot folder to TcBSD over SSH
Handles various source folder names and provides optional restart control
Works on both Windows and Linux
"""

import argparse
import sys
import subprocess
from pathlib import Path
import platform


def show_usage():
    print("\nUsage Examples:")
    print("  python CopyToTcBSDBootFolder.py --source-path 'C:\\Path\\To\\TwinCAT OS (x64)' --remote-host 192.168.1.100")
    print("  python CopyToTcBSDBootFolder.py --source-path '/path/to/Boot' --remote-host 192.168.1.100 --restart")
    print("  python CopyToTcBSDBootFolder.py --source-path './xyz' --remote-host tcbsd.local --username myuser --restart")
    print()


def run_command(command, shell=False, capture_output=False):
    try:
        if capture_output:
            result = subprocess.run(
                command, shell=shell,
                capture_output=True, text=True, check=False
            )
            return result.returncode, result.stdout, result.stderr
        else:
            result = subprocess.run(command, shell=shell, check=False)
            return result.returncode, "", ""
    except Exception as e:
        return 1, "", str(e)


def check_ssh_tools():
    ssh_ok = run_command(["ssh", "-V"], capture_output=True)[0] in (0, 255)
    scp_ok = run_command(["scp", "-h"], capture_output=True)[0] in (0, 1)
    if not ssh_ok:
        print("Error: SSH client not found. Install OpenSSH.")
        return False
    if not scp_ok:
        print("Error: SCP not found. Install OpenSSH.")
        return False
    return True


def main():
    parser = argparse.ArgumentParser(
        description='Copy TwinCAT boot folder to TcBSD over SSH',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  CopyToTcBSDBootFolder.py --source-path 'C:\\Path\\To\\TwinCAT OS (x64)' --remote-host 192.168.1.100
  CopyToTcBSDBootFolder.py --source-path '/path/to/Boot' --remote-host 192.168.1.100 --restart
  CopyToTcBSDBootFolder.py --source-path './xyz' --remote-host tcbsd.local --username myuser --restart
        """
    )
    parser.add_argument('--source-path', required=True,
                        help='Source folder (e.g., "Boot")')
    parser.add_argument('--remote-host', required=True,
                        help='Remote host IP or name')
    parser.add_argument('--restart', action='store_true',
                        help='Restart TwinCAT after copy')
    parser.add_argument('--username', default='Administrator',
                        help='SSH user (default: Administrator)')
    args = parser.parse_args()

    print("\n=== TwinCAT Boot Folder Copy Script ===\n")
    if not check_ssh_tools():
        sys.exit(1)

    source = Path(args.source_path)
    if not source.exists():
        print(f"Error: '{source}' not found")
        show_usage()
        sys.exit(1)
    source = source.resolve()
    folder = source.name

    print("Configuration:")
    print(f"  Source:        {source}")
    print(f"  Remote host:   {args.remote_host}")
    print(f"  SSH user:      {args.username}")
    print(f"  Restart flag:  {'Yes' if args.restart else 'No'}")
    print(f"  Destination:   /usr/local/etc/TwinCAT/3.1/Boot\n")

    temp_dest = f"{args.username}@{args.remote_host}:~/"
    final_dest = "/usr/local/etc/TwinCAT/3.1/Boot"

    print("1) Uploading to remote temp...")
    code, _, err = run_command(["scp", "-r", str(source), temp_dest])
    if code != 0:
        print(f"SCP failed ({code}): {err}")
        sys.exit(1)

    print("2) Setting up Boot directory and copying files...")
    # Build the corrected sequence: create if needed, then fix perms if exists, then copy
    cmds = [
        "echo 'Creating Boot directory if it does not exist...'",
        # Only create if it doesn't exist (avoids unnecessary doas prompts)
        f"if [ ! -d '{final_dest}' ]; then "
        f"doas mkdir -p '{final_dest}'; fi",
        "echo 'Checking and fixing Boot folder ownership if needed...'",
        # only chown if owner or group is wrong
        f"if [ \"$(stat -f '%Su' '{final_dest}')\" != 'Administrator' ] || "
        f"[ \"$(stat -f '%Sg' '{final_dest}')\" != 'wheel' ]; then "
        f"doas chown -R Administrator:wheel '{final_dest}'; fi",
        "echo 'Checking and fixing Boot folder write permission if needed...'",
        # only chmod if not owner-writable
        f"if [ ! -w '{final_dest}' ]; then "
        f"doas chmod -R u+rwxX '{final_dest}'; fi",
        "echo 'Copying files...'",
        f"cd ~/{folder} && cp -R ./* '{final_dest}/'",
        "echo 'Cleaning up temp...'",
        f"cd ~ && rm -rf '{folder}'",
    ]

    if args.restart:
        cmds += [
            "echo 'Checking doas configuration for TcSysExe.exe...'",
            # Check if the doas rule already exists
            f"if ! grep -q 'permit nopass {args.username} cmd TcSysExe.exe' /usr/local/etc/doas.conf 2>/dev/null; then "
            f"echo 'Adding doas rule for TcSysExe.exe...' && "
            f"echo 'permit nopass {args.username} cmd TcSysExe.exe' | doas tee -a /usr/local/etc/doas.conf; "
            f"else echo 'doas rule for TcSysExe.exe already exists'; fi",
            "echo 'Restarting TwinCAT...'",
            "doas TcSysExe.exe --run",
            "echo 'Mode:'",
            "TcSysExe.exe --mode"
        ]
    else:
        cmds += [
            "echo 'Skipping restart (use --restart)'",
            "echo 'Mode:'",
            "TcSysExe.exe --mode"
        ]

    full = " && ".join(cmds)
    code, _, _ = run_command(["ssh", "-t", f"{args.username}@{args.remote_host}", full])

    if code == 0:
        print("\n=== Success ===")
        print("Boot folder updated (created and configured as needed).")
    else:
        print(f"\nError: Remote step failed (exit {code})")
        sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nCancelled by user."); sys.exit(130)
    except Exception as e:
        print(f"\nUnexpected error: {e}"); sys.exit(1)