#!/usr/bin/env python3
"""
=============================================================================
MoodleKit — 1-Click Multi-Tenant Production Installer & Bootstrap Wizard
=============================================================================
Usage:
  Interactive Mode:
    ./easy-install.py

  Non-Interactive / Scripted Mode:
    ./easy-install.py --sitename academy.example.com --email admin@example.com --moodle-version 5.2
=============================================================================
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
ORCHESTRATOR = BASE_DIR / "moodlekit-docker.py"

# ANSI Colors
C_RESET = "\033[0m"
C_BOLD = "\033[1m"
C_RED = "\033[31m"
C_GREEN = "\033[32m"
C_YELLOW = "\033[33m"
C_BLUE = "\033[34m"
C_CYAN = "\033[36m"


def cprint(msg: str, color: str = "", bold: bool = False) -> None:
    style = f"{C_BOLD if bold else ''}{color}"
    print(f"{style}{msg}{C_RESET}")


def banner() -> None:
    cprint(r"""
  __  __                 _ _      _  ___ _   
 |  \/  |___  ___  __| | |___ | |/ (_) |_ 
 | |\/| / _ \/ _ \/ _` | / -_)| ' <| |  _|
 |_|  |_\___/\___/\__,_|_\___| |_|\_\_|\__|
  One-Click Multi-Tenant Docker Cloud Stack
    """, C_CYAN, bold=True)
    cprint("=" * 65, C_CYAN)


def check_docker_prerequisites() -> None:
    for cmd in ["docker"]:
        try:
            subprocess.run([cmd, "--version"], capture_output=True, check=True)
        except Exception:
            cprint(f"[!] '{cmd}' is not installed or not in PATH.", C_RED, bold=True)
            cprint("Please install Docker & Docker Compose plugin and rerun this script.", C_YELLOW)
            sys.exit(1)


def interactive_wizard() -> None:
    banner()
    cprint("Welcome to the MoodleKit 1-Click Multi-Tenant Setup Wizard!\n", C_GREEN, bold=True)

    cprint("--- Step 1: Core Gateway & Infrastructure Configuration ---", C_BLUE, bold=True)
    email = input("Enter admin email for Let's Encrypt SSL certificates (default: admin@example.com): ").strip()
    if not email:
        email = "admin@example.com"

    cprint("\n--- Step 2: Initial Tenant Site Setup ---", C_BLUE, bold=True)
    slug = input("Enter a tenant slug (lowercase letters/numbers, e.g. 'academy'): ").strip() or "academy"
    domain = input(f"Enter the domain or subdomain for '{slug}' (e.g. learn.mycompany.com or {slug}.localhost): ").strip() or f"{slug}.localhost"
    
    cprint("\nSelect Moodle Version:", C_BLUE)
    cprint("  1) Moodle 5.2 (Latest Stable, modern public/ router)", C_CYAN)
    cprint("  2) Moodle 4.5 (Long Term Support - LTS)", C_CYAN)
    v_choice = input("Choice [1/2] (default: 1): ").strip() or "1"
    moodle_version = "5.2" if v_choice == "1" else "4.5"

    admin_pass = input("Enter Moodle Admin password (leave empty to auto-generate): ").strip()
    fullname = input(f"Enter full site name (default: {slug.title()} Moodle Academy): ").strip() or f"{slug.title()} Moodle Academy"

    cprint("\n--- Summary of Configuration ---", C_YELLOW, bold=True)
    cprint(f"  SSL Email:       {email}")
    cprint(f"  Tenant Slug:     {slug}")
    cprint(f"  Domain:          {domain}")
    cprint(f"  Moodle Version:  {moodle_version}")
    cprint(f"  Site Name:       {fullname}")

    confirm = input("\nProceed with installation? [Y/n]: ").strip().lower()
    if confirm and confirm != "y":
        cprint("Installation aborted.", C_YELLOW)
        sys.exit(0)

    cprint("\n[+] Initializing Core Services (Caddy, MariaDB, Redis)...", C_GREEN, bold=True)
    subprocess.run([sys.executable, str(ORCHESTRATOR), "init", "-e", email], check=True)

    cprint(f"\n[+] Provisioning Tenant Site '{slug}'...", C_GREEN, bold=True)
    create_cmd = [
        sys.executable, str(ORCHESTRATOR), "site", "create", slug,
        "-d", domain,
        "-m", moodle_version,
        "--fullname", fullname,
    ]
    if admin_pass:
        create_cmd.extend(["-p", admin_pass])
    if domain.startswith("localhost") or domain.endswith(".local"):
        create_cmd.append("--no-ssl")

    subprocess.run(create_cmd, check=True)

    cprint("\n🎉 All Done! Your Multi-Tenant Moodle Stack is Live.", C_GREEN, bold=True)
    cprint(f"To add more tenant sites at any time, run:", C_CYAN)
    cprint(f"  ./moodlekit-docker site create <new_slug> --domain <new_domain>\n", C_YELLOW)


def main() -> None:
    check_docker_prerequisites()

    parser = argparse.ArgumentParser(description="MoodleKit 1-Click Multi-Tenant Installer")
    parser.add_argument("-s", "--sitename", help="Tenant domain / hostname")
    parser.add_argument("-n", "--slug", help="Tenant slug (identifier)")
    parser.add_argument("-e", "--email", help="Let's Encrypt email")
    parser.add_argument("-v", "--moodle-version", default="5.2", help="Moodle version (5.2 or 4.5)")
    parser.add_argument("-p", "--admin-pass", help="Moodle administrator password")
    parser.add_argument("--fullname", help="Site full name")
    parser.add_argument("--no-ssl", action="store_true", help="Disable SSL for local testing")
    parser.add_argument("-y", "--yes", action="store_true", help="Skip interactive prompts")

    args = parser.parse_args()

    # If no flags provided, launch interactive wizard
    if not args.sitename and not args.slug and not args.yes:
        interactive_wizard()
        return

    # Non-interactive / scripted execution
    email = args.email or "admin@example.com"
    domain = args.sitename or "academy.localhost"
    slug = args.slug or domain.split(".")[0].replace("-", "_")

    cprint(f"==> Non-Interactive Setup: Tenant={slug}, Domain={domain}, Version={args.moodle_version}", C_BLUE, bold=True)

    # 1. Init core
    subprocess.run([sys.executable, str(ORCHESTRATOR), "init", "-e", email], check=True)

    # 2. Create site
    create_cmd = [
        sys.executable, str(ORCHESTRATOR), "site", "create", slug,
        "-d", domain,
        "-m", args.moodle_version,
    ]
    if args.admin_pass:
        create_cmd.extend(["-p", args.admin_pass])
    if args.fullname:
        create_cmd.extend(["--fullname", args.fullname])
    if args.no_ssl or domain.startswith("localhost") or domain.endswith(".local"):
        create_cmd.append("--no-ssl")

    subprocess.run(create_cmd, check=True)


if __name__ == "__main__":
    main()
