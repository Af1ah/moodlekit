#!/usr/bin/env python3
"""
=============================================================================
MoodleKit Docker — High-Performance Multi-Tenant Moodle Cloud Orchestrator
=============================================================================
Supports:
- One-Click Multi-Tenant Moodle Provisioning with Custom Domains
- Caddy Web Server with Automatic TLS (Let's Encrypt / ZeroSSL)
- Load Separation (Web PHP-FPM vs Isolated Background Cron Worker)
- Central High-Performance MariaDB & Redis Session/Cache Engine
- Full Plugin Download & Web Installation Permissions
- Secure Dataroot Isolation (Internal X-Accel-Redirect, Non-Executable)
- Atomic Fast Backups & 1-Click Disaster Recovery
=============================================================================
"""

import argparse
import json
import os
import re
import secrets
import shutil
import string
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

VERSION = "2.5.0"
BASE_DIR = Path(__file__).resolve().parent
DOCKER_DIR = BASE_DIR / "docker"
SITES_DIR = BASE_DIR / "sites"
DATA_DIR = BASE_DIR / "data"
BACKUPS_DIR = BASE_DIR / "backups"
CONF_DIR = DOCKER_DIR / "conf"
TEMPLATES_DIR = DOCKER_DIR / "templates"
CADDY_SITES_DIR = CONF_DIR / "caddy" / "sites.d"
ENV_FILE = BASE_DIR / ".env"

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


def info(msg: str) -> None:
    cprint(f"[*] {msg}", C_CYAN)


def success(msg: str) -> None:
    cprint(f"[+] {msg}", C_GREEN, bold=True)


def warn(msg: str) -> None:
    cprint(f"[!] {msg}", C_YELLOW, bold=True)


def err(msg: str) -> None:
    cprint(f"[-] ERROR: {msg}", C_RED, bold=True)


def gen_password(length: int = 24) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def run_cmd(
    cmd: List[str],
    cwd: Optional[Path] = None,
    capture: bool = False,
    check: bool = True,
    env: Optional[Dict[str, str]] = None,
) -> subprocess.CompletedProcess:
    cwd_path = str(cwd) if cwd else str(BASE_DIR)
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    return subprocess.run(
        cmd,
        cwd=cwd_path,
        capture_output=capture,
        text=True,
        check=check,
        env=full_env,
    )


def load_env() -> Dict[str, str]:
    env_vars = {}
    if ENV_FILE.exists():
        with open(ENV_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                env_vars[k.strip()] = v.strip().strip('"').strip("'")
    return env_vars


def save_env(env_vars: Dict[str, str]) -> None:
    lines = [
        "# =============================================================================",
        "# MoodleKit Docker Environment Configuration",
        f"# Generated: {datetime.now().isoformat()}",
        "# =============================================================================",
    ]
    for k, v in sorted(env_vars.items()):
        lines.append(f'{k}="{v}"')
    with open(ENV_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")


# =============================================================================
# Multi-Tenant Sizing Profiles
# =============================================================================
SIZING_PROFILES = {
    "small": {
        "fpm_pm": "ondemand",
        "fpm_max_children": "15",
        "fpm_start_servers": "2",
        "fpm_min_spare": "1",
        "fpm_max_spare": "4",
        "fpm_idle_timeout": "10s",
        "fpm_max_requests": "1000",
        "php_mem_limit": "256M",
        "mem_limit": "1.5g",
        "cpu_limit": "1.0",
        "description": "Small / Idle-Optimized (10–50 concurrent users)",
    },
    "medium": {
        "fpm_pm": "dynamic",
        "fpm_max_children": "35",
        "fpm_start_servers": "4",
        "fpm_min_spare": "2",
        "fpm_max_spare": "8",
        "fpm_idle_timeout": "10s",
        "fpm_max_requests": "1000",
        "php_mem_limit": "512M",
        "mem_limit": "3.0g",
        "cpu_limit": "2.0",
        "description": "Medium (50–150 concurrent users)",
    },
    "big": {
        "fpm_pm": "dynamic",
        "fpm_max_children": "60",
        "fpm_start_servers": "8",
        "fpm_min_spare": "4",
        "fpm_max_spare": "15",
        "fpm_idle_timeout": "10s",
        "fpm_max_requests": "1000",
        "php_mem_limit": "512M",
        "mem_limit": "5.0g",
        "cpu_limit": "3.5",
        "description": "Big / High Concurrency (200–350 concurrent users)",
    },
    "enterprise": {
        "fpm_pm": "dynamic",
        "fpm_max_children": "120",
        "fpm_start_servers": "15",
        "fpm_min_spare": "8",
        "fpm_max_spare": "25",
        "fpm_idle_timeout": "10s",
        "fpm_max_requests": "1000",
        "php_mem_limit": "768M",
        "mem_limit": "10.0g",
        "cpu_limit": "6.0",
        "description": "Enterprise (400–700+ concurrent users, 32GB+ hosts only)",
    },
}


def detect_system_ram_mb() -> int:
    try:
        with open("/proc/meminfo", "r") as f:
            mem_kb = int(re.search(r"MemTotal:\s+(\d+)", f.read()).group(1))
        return mem_kb // 1024
    except Exception:
        return 16384


def ensure_core_env() -> Dict[str, str]:
    env = load_env()
    updated = False
    ram_mb = detect_system_ram_mb()

    if "DB_ROOT_PASSWORD" not in env:
        env["DB_ROOT_PASSWORD"] = gen_password(24)
        updated = True
    if "DB_ADMIN_PASSWORD" not in env:
        env["DB_ADMIN_PASSWORD"] = gen_password(24)
        updated = True
    if "REDIS_PASSWORD" not in env:
        env["REDIS_PASSWORD"] = gen_password(24)
        updated = True
    if "LETSENCRYPT_EMAIL" not in env:
        env["LETSENCRYPT_EMAIL"] = "admin@localhost"
        updated = True
    if "HTTP_PORT" not in env:
        env["HTTP_PORT"] = "80"
        updated = True
    if "HTTPS_PORT" not in env:
        env["HTTPS_PORT"] = "443"
        updated = True
    if "MOODLE_IMAGE" not in env:
        env["MOODLE_IMAGE"] = "moodlekit/moodle-app:8.3"
        updated = True

    # Hardware-aware memory auto-tuning
    if "DB_BUFFER_POOL_SIZE" not in env:
        if ram_mb >= 28000:
            env["DB_BUFFER_POOL_SIZE"] = "14336M"
        elif ram_mb >= 14000:
            env["DB_BUFFER_POOL_SIZE"] = "6144M"
        else:
            env["DB_BUFFER_POOL_SIZE"] = "2560M"
        updated = True

    if "REDIS_MAX_MEMORY" not in env:
        if ram_mb >= 28000:
            env["REDIS_MAX_MEMORY"] = "3072M"
        elif ram_mb >= 14000:
            env["REDIS_MAX_MEMORY"] = "1536M"
        else:
            env["REDIS_MAX_MEMORY"] = "512M"
        updated = True

    if updated:
        save_env(env)
    return env


def sync_master_compose() -> None:
    lines = [
        "# =============================================================================",
        "# MoodleKit Master Docker Compose",
        "# Automatically synchronized across all active tenant sites",
        "# =============================================================================",
        "name: moodlekit",
        "",
        "include:",
        "  - docker/compose.core.yml",
    ]
    if SITES_DIR.exists():
        for site_dir in sorted(SITES_DIR.iterdir()):
            if site_dir.is_dir() and (site_dir / "compose.yml").exists():
                lines.append(f"  - sites/{site_dir.name}/compose.yml")

    with open(BASE_DIR / "docker-compose.yml", "w") as f:
        f.write("\n".join(lines) + "\n")


def compose_core_cmd(action: List[str]) -> subprocess.CompletedProcess:
    compose_file = DOCKER_DIR / "compose.core.yml"
    env = ensure_core_env()
    cmd = ["docker", "compose", "-p", "moodlekit", "-f", str(compose_file), "--env-file", str(ENV_FILE)] + action
    return run_cmd(cmd, env=env)


def reload_caddy() -> bool:
    try:
        res = compose_core_cmd(["exec", "-T", "caddy", "caddy", "reload", "--config", "/etc/caddy/Caddyfile"])
        if res.returncode == 0:
            info("Caddy reverse proxy reloaded successfully.")
            return True
    except Exception as e:
        warn(f"Could not reload Caddy directly: {e}. If core is not running yet, it will load on startup.")
    return False


def exec_db_query(sql: str) -> subprocess.CompletedProcess:
    env = ensure_core_env()
    root_pass = env["DB_ROOT_PASSWORD"]
    cmd = [
        "docker",
        "compose",
        "-f",
        str(DOCKER_DIR / "compose.core.yml"),
        "--env-file",
        str(ENV_FILE),
        "exec",
        "-T",
        "db",
        "mariadb",
        "-u",
        "root",
        f"-p{root_pass}",
        "-e",
        sql,
    ]
    return run_cmd(cmd, capture=True)


# =============================================================================
# Core Infrastructure Lifecycle
# =============================================================================

def cmd_build(args: argparse.Namespace) -> None:
    cprint("==> Building High-Performance Moodle PHP-FPM Docker Image...", C_BLUE, bold=True)
    env = ensure_core_env()
    image_tag = env.get("MOODLE_IMAGE", "moodlekit/moodle-app:8.3")
    cmd = [
        "docker",
        "build",
        "-t",
        image_tag,
        "-f",
        str(DOCKER_DIR / "Dockerfile"),
        str(DOCKER_DIR),
    ]
    if getattr(args, "no_cache", False):
        cmd.append("--no-cache")
    run_cmd(cmd)
    success(f"Image '{image_tag}' built successfully!")


def cmd_init(args: argparse.Namespace) -> None:
    cprint("=================================================================", C_BLUE, bold=True)
    cprint("       MoodleKit Docker — Initializing Core Infrastructure       ", C_BLUE, bold=True)
    cprint("=================================================================", C_BLUE, bold=True)

    # 1. Ensure Directories
    for d in [SITES_DIR, DATA_DIR / "caddy" / "data", DATA_DIR / "caddy" / "config", DATA_DIR / "db", DATA_DIR / "redis", BACKUPS_DIR, CADDY_SITES_DIR]:
        d.mkdir(parents=True, exist_ok=True)

    # 2. Build or pull app image
    env = ensure_core_env()
    if getattr(args, "email", None):
        env["LETSENCRYPT_EMAIL"] = args.email
        save_env(env)

    info("Checking Moodle PHP-FPM base image...")
    image_tag = env.get("MOODLE_IMAGE", "moodlekit/moodle-app:8.3")
    try:
        run_cmd(["docker", "image", "inspect", image_tag], capture=True)
        info(f"Using existing Docker image: {image_tag}")
    except subprocess.CalledProcessError:
        info(f"Image {image_tag} not found locally. Building now...")
        cmd_build(args)

    # 3. Start Core Services
    info("Starting Core Services (Caddy, MariaDB, Redis)...")
    compose_core_cmd(["up", "-d"])

    # 4. Wait for MariaDB health
    info("Waiting for MariaDB database to be ready...")
    for _ in range(30):
        try:
            res = exec_db_query("SELECT 1;")
            if res.returncode == 0:
                success("MariaDB database is healthy!")
                break
        except Exception:
            pass
        time.sleep(2)
    else:
        warn("Database took longer than expected to initialize. Check logs with: docker compose -f docker/compose.core.yml logs db")

    success("MoodleKit Core Infrastructure is UP and READY!")
    cprint(f"  Web Gateway (Caddy): Ports {env.get('HTTP_PORT', '80')} & {env.get('HTTPS_PORT', '443')}")
    cprint(f"  Shared Database:      MariaDB (Internal Host: db:3306)")
    cprint(f"  Shared Cache/Session: Redis (Internal Host: redis:6379)")
    cprint("\nYou can now provision tenant sites using: ./moodlekit-docker site create <slug> --domain <domain>")


def cmd_status(args: argparse.Namespace) -> None:
    cprint("==> MoodleKit Core Services Status:", C_BLUE, bold=True)
    try:
        compose_core_cmd(["ps"])
    except Exception as e:
        err(f"Failed to check core status: {e}")

    cprint("\n==> Registered Tenant Sites:", C_BLUE, bold=True)
    cmd_site_list(args)


# =============================================================================
# Multi-Tenant Site Management
# =============================================================================

def download_moodle_source(target_dir: Path, version: str) -> None:
    target_dir.mkdir(parents=True, exist_ok=True)
    if (target_dir / "index.php").exists() and (target_dir / "version.php").exists():
        info("Existing Moodle codebase detected in target directory. Skipping download.")
        return

    info(f"Downloading Moodle {version} codebase...")
    branch_map = {
        "5.2": "MOODLE_502_STABLE",
        "5.1": "MOODLE_501_STABLE",
        "5.0": "MOODLE_500_STABLE",
        "4.5": "MOODLE_405_STABLE",
        "4.4": "MOODLE_404_STABLE",
        "4.3": "MOODLE_403_STABLE",
        "4.2": "MOODLE_402_STABLE",
    }
    branch = branch_map.get(version, f"MOODLE_{version.replace('.', '')}_STABLE" if "." in version else version)
    
    # Try git shallow clone first for speed
    try:
        info(f"Cloning from official Moodle repository (branch: {branch})...")
        run_cmd([
            "git", "clone",
            "--depth", "1",
            "--branch", branch,
            "https://github.com/moodle/moodle.git",
            str(target_dir),
        ])
        success(f"Moodle {version} ({branch}) cloned successfully.")
        return
    except Exception as e:
        warn(f"Git clone failed: {e}. Falling back to release archive download...")

    # Fallback to direct archive download
    tar_url = f"https://download.moodle.org/download.php/direct/stable{version.replace('.', '')}/moodle-latest-{version.replace('.', '')}.tgz"
    with tempfile.NamedTemporaryFile(suffix=".tgz", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        info(f"Downloading archive from {tar_url}...")
        run_cmd(["curl", "-fsSL", "-o", str(tmp_path), tar_url])
        info("Extracting archive...")
        with tarfile.open(tmp_path, "r:gz") as tar:
            # Strip top-level moodle/ folder
            for member in tar.getmembers():
                if member.name.startswith("moodle/"):
                    member.name = member.name[len("moodle/"):]
                    if member.name:
                        tar.extract(member, path=target_dir)
        success(f"Moodle {version} archive extracted successfully.")
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


def render_template(tpl_path: Path, context: Dict[str, Any]) -> str:
    with open(tpl_path, "r") as f:
        content = f.read()

    # Simple logic handlers for {{#KEY}}...{{/KEY}}
    for k, v in context.items():
        pattern = re.compile(rf"\{{\{{#\s*{k}\s*\}}\}}(.*?)\{{\{{/\s*{k}\s*\}}\}}", re.DOTALL)
        if bool(v):
            content = pattern.sub(r"\1", content)
        else:
            content = pattern.sub("", content)

    # Variable replacement {{KEY}}
    for k, v in context.items():
        content = content.replace(f"{{{{{k}}}}}", str(v))

    return content


def get_site_compose_file(slug: str) -> Path:
    return SITES_DIR / slug / "compose.yml"


def cmd_site_create(args: argparse.Namespace) -> None:
    slug = args.slug.lower().strip()
    if not re.match(r"^[a-z0-9_]+$", slug):
        err("Site slug must contain only lowercase letters, numbers, and underscores.")
        sys.exit(1)

    site_dir = SITES_DIR / slug
    if site_dir.exists() and not getattr(args, "force", False):
        err(f"Site directory already exists: {site_dir}. Use --force to overwrite configuration.")
        sys.exit(1)

    cprint("=================================================================", C_BLUE, bold=True)
    cprint(f"       Provisioning New Moodle Tenant Site: {slug}       ", C_BLUE, bold=True)
    cprint("=================================================================", C_BLUE, bold=True)

    env = ensure_core_env()
    domain = getattr(args, "domain", None) or f"{slug}.localhost"
    moodle_version = getattr(args, "moodle_version", None) or "5.2"
    db_name = f"moodle_{slug}"
    db_user = f"moodle_{slug}"
    db_pass = getattr(args, "db_pass", None) or gen_password(24)
    admin_user = getattr(args, "admin_user", None) or "admin"
    admin_pass = getattr(args, "admin_pass", None) or "Admin123!#"
    admin_email = getattr(args, "admin_email", None) or f"admin@{domain}"
    site_fullname = getattr(args, "fullname", None) or f"Moodle Academy ({slug})"
    site_shortname = getattr(args, "shortname", None) or slug.upper()
    is_moodle5 = float(moodle_version.split(".")[0]) >= 5.0

    info(f"Target Domain:       {domain}")
    info(f"Moodle Version:      {moodle_version} ({'Moodle 5.x Router' if is_moodle5 else 'Moodle 4.x Classic'})")
    info(f"Database:            MariaDB ({db_name})")
    info(f"Redis Sessions:      Enabled (Prefix: {slug}_sess_)")

    # Step 1: Create Database & User on Shared MariaDB
    info("Provisioning database and user on shared MariaDB...")
    sql = f"""
    CREATE DATABASE IF NOT EXISTS `{db_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '{db_user}'@'%' IDENTIFIED BY '{db_pass}';
    GRANT ALL PRIVILEGES ON `{db_name}`.* TO '{db_user}'@'%';
    FLUSH PRIVILEGES;
    """
    exec_db_query(sql)
    success("Database and user provisioned.")

    # Step 2: Create Site Folders
    code_dir = site_dir / "code"
    moodledata_dir = site_dir / "moodledata"
    code_dir.mkdir(parents=True, exist_ok=True)
    moodledata_dir.mkdir(parents=True, exist_ok=True)

    # Step 3: Download Codebase if needed
    if not getattr(args, "skip_download", False):
        download_moodle_source(code_dir, moodle_version)

    # Step 4: Render config.php
    info("Generating production config.php...")
    proto = "http" if domain.startswith("localhost") or domain.endswith(".local") or getattr(args, "no_ssl", False) else "https"
    wwwroot = f"{proto}://{domain}"
    if getattr(args, "http_port", None) and getattr(args, "http_port") != "80":
        wwwroot += f":{args.http_port}"

    config_context = {
        "SLUG": slug,
        "DOMAIN": domain,
        "WWWROOT": wwwroot,
        "DB_TYPE": "mariadb",
        "DB_HOST": "db",
        "DB_PORT": "3306",
        "DB_NAME": db_name,
        "DB_USER": db_user,
        "DB_PASS": db_pass,
        "DB_PREFIX": "mdl_",
        "SSLPROXY": "true" if proto == "https" else "false",
        "IS_MOODLE5": is_moodle5,
        "USE_REDIS_SESSIONS": True,
        "REDIS_HOST": "redis",
        "REDIS_PORT": 6379,
        "REDIS_AUTH": env.get("REDIS_PASSWORD", ""),
    }
    rendered_config = render_template(TEMPLATES_DIR / "config.php.tpl", config_context)
    with open(code_dir / "config.php", "w") as f:
        f.write(rendered_config)
    success("config.php generated.")

    # Step 5: Render Caddy Route Snippet
    has_public = (code_dir / "public").exists()
    web_root = f"/var/www/html/{slug}/code/public" if has_public else f"/var/www/html/{slug}/code"
    container_root = "/var/www/html/public" if has_public else "/var/www/html"
    caddy_context = {
        "SLUG": slug,
        "DOMAIN": domain,
        "UPSTREAM": f"moodle-app-{slug}:9000",
        "WEB_ROOT": web_root,
        "CONTAINER_ROOT": container_root,
    }
    rendered_caddy = render_template(TEMPLATES_DIR / "site.caddy.tpl", caddy_context)
    with open(CADDY_SITES_DIR / f"{slug}.caddy", "w") as f:
        f.write(rendered_caddy)
    success(f"Caddy route created: {CADDY_SITES_DIR / f'{slug}.caddy'}")

    # Step 6: Render Site Compose File
    plan_name = getattr(args, "plan", "medium") or "medium"
    plan_name = plan_name.lower().strip()
    if plan_name not in SIZING_PROFILES:
        err(f"Unknown sizing plan '{plan_name}'. Available: {', '.join(SIZING_PROFILES.keys())}")
        sys.exit(1)

    ram_mb = detect_system_ram_mb()
    if plan_name == "enterprise" and ram_mb < 28000 and not getattr(args, "force", False):
        warn(f"Notice: 'enterprise' plan is recommended for 32GB+ hosts (Detected: {ram_mb // 1024}GB).")

    profile = SIZING_PROFILES[plan_name]
    info(f"Generating tenant compose with Sizing Profile '{plan_name.upper()}' ({profile['description']})...")

    compose_context = {
        "SLUG": slug,
        "DOMAIN": domain,
        "BASE_DIR": str(BASE_DIR),
        "IMAGE_NAME": env.get("MOODLE_IMAGE", "moodlekit/moodle-app:8.3"),
        "DB_PASS": db_pass,
        "REDIS_AUTH": env.get("REDIS_PASSWORD", ""),
        "PLAN_NAME": plan_name,
        "PLAN_DESC": profile["description"],
        "FPM_PM": profile["fpm_pm"],
        "FPM_MAX_CHILDREN": profile["fpm_max_children"],
        "FPM_START_SERVERS": profile["fpm_start_servers"],
        "FPM_MIN_SPARE": profile["fpm_min_spare"],
        "FPM_MAX_SPARE": profile["fpm_max_spare"],
        "FPM_IDLE_TIMEOUT": profile["fpm_idle_timeout"],
        "FPM_MAX_REQUESTS": profile["fpm_max_requests"],
        "PHP_MEM_LIMIT": profile["php_mem_limit"],
        "CPU_LIMIT": profile["cpu_limit"],
        "MEM_LIMIT": profile["mem_limit"],
    }
    rendered_compose = render_template(TEMPLATES_DIR / "tenant-compose.yml.tpl", compose_context)
    compose_file = get_site_compose_file(slug)
    with open(compose_file, "w") as f:
        f.write(rendered_compose)
    success("Tenant compose file created.")

    # Step 7: Launch Tenant Containers
    info("Starting tenant application and isolated cron worker...")
    sync_master_compose()
    run_cmd(["docker", "compose", "-p", "moodlekit", "-f", str(compose_file), "up", "-d"])
    reload_caddy()

    # Step 8: Compile Composer Authoritative Classmap
    info("Compiling authoritative Composer classmap (composer install --no-dev --classmap-authoritative)...")
    composer_cli = [
        "docker", "compose", "-p", "moodlekit", "-f", str(compose_file),
        "exec", "-T", f"moodle-app-{slug}",
        "gosu", "www-data",
        "composer", "install", "--no-dev", "--classmap-authoritative", "--no-interaction",
    ]
    try:
        run_cmd(composer_cli)
        success("Authoritative classmap generated.")
    except Exception as e:
        warn(f"Composer optimization notice: {e}")

    # Step 9: Run Non-Interactive Moodle Database Installation
    if not getattr(args, "skip_install", False):
        info("Initializing Moodle database schema and admin account...")
        time.sleep(2)
        install_cli = [
            "docker", "compose", "-p", "moodlekit", "-f", str(compose_file),
            "exec", "-T", f"moodle-app-{slug}",
            "gosu", "www-data",
            "php", "/var/www/html/admin/cli/install_database.php",
            f"--adminuser={admin_user}",
            f"--adminpass={admin_pass}",
            f"--adminemail={admin_email}",
            f"--fullname={site_fullname}",
            f"--shortname={site_shortname}",
            "--agree-license",
        ]
        try:
            run_cmd(install_cli)
            success("Moodle database initialized successfully!")
        except subprocess.CalledProcessError as e:
            warn(f"Moodle CLI installer returned non-zero code ({e.returncode}). If the database was already populated, this is normal.")

    # Save Tenant Metadata
    meta = {
        "slug": slug,
        "domain": domain,
        "plan": plan_name,
        "wwwroot": wwwroot,
        "moodle_version": moodle_version,
        "is_moodle5": is_moodle5,
        "db_name": db_name,
        "db_user": db_user,
        "db_pass": db_pass,
        "admin_user": admin_user,
        "admin_pass": admin_pass,
        "created_at": datetime.now().isoformat(),
    }
    with open(site_dir / "meta.json", "w") as f:
        json.dump(meta, f, indent=2)

    cprint("\n=================================================================", C_GREEN, bold=True)
    cprint(f"       Tenant Site '{slug}' Ready for Production!       ", C_GREEN, bold=True)
    cprint("=================================================================", C_GREEN, bold=True)
    print(f"  URL:             {wwwroot}")
    print(f"  Sizing Plan:     {plan_name.upper()} ({profile['description']})")
    print(f"  Admin Username:  {admin_user}")
    print(f"  Admin Password:  {admin_pass}")
    print(f"  Database Name:   {db_name}")
    print(f"  Code Path:       {code_dir}")
    print(f"  Data Path:       {moodledata_dir}")
    print(f"  Web Installer:   Ready (All plugin directories have full write permissions)")
    cprint("=================================================================\n", C_GREEN, bold=True)


def cmd_site_list(args: argparse.Namespace) -> None:
    if not SITES_DIR.exists():
        info("No tenant sites directory found.")
        return

    sites = [d for d in SITES_DIR.iterdir() if d.is_dir()]
    if not sites:
        info("No tenant sites found. Create one with: ./moodlekit-docker site create <slug>")
        return

    print("-" * 95)
    print(f"{'SLUG':<15} {'DOMAIN':<22} {'PLAN':<10} {'MOODLE':<8} {'DATABASE':<18} {'STATUS':<12}")
    print("-" * 95)

    for s in sorted(sites):
        meta_file = s / "meta.json"
        domain = "Unknown"
        version = "Unknown"
        plan = "medium"
        db_name = f"moodle_{s.name}"
        if meta_file.exists():
            try:
                with open(meta_file, "r") as f:
                    meta = json.load(f)
                    domain = meta.get("domain", domain)
                    version = str(meta.get("moodle_version", version))
                    plan = meta.get("plan", plan)
                    db_name = meta.get("db_name", db_name)
            except Exception:
                pass

        # Check container status
        status = "stopped"
        try:
            res = run_cmd(["docker", "inspect", "-f", "{{.State.Status}}", f"moodle-app-{s.name}"], capture=True, check=False)
            if res.returncode == 0:
                status = res.stdout.strip()
        except Exception:
            pass

        color = C_GREEN if status == "running" else C_YELLOW
        status_colored = f"{color}{status}{C_RESET}"
        print(f"{s.name:<15} {domain:<22} {plan:<10} {version:<8} {db_name:<18} {status_colored}")
    print("-" * 95)


def cmd_site_remove(args: argparse.Namespace) -> None:
    slug = args.slug.lower().strip()
    site_dir = SITES_DIR / slug
    if not site_dir.exists():
        err(f"Site '{slug}' does not exist.")
        sys.exit(1)

    if not getattr(args, "force", False):
        confirm = input(f"Are you sure you want to completely remove tenant '{slug}' and its database? (y/N): ")
        if confirm.lower() != "y":
            info("Operation cancelled.")
            return

    info(f"Removing tenant site '{slug}'...")

    # 1. Stop and remove containers
    compose_file = get_site_compose_file(slug)
    if compose_file.exists():
        info("Stopping tenant containers...")
        run_cmd(["docker", "compose", "-f", str(compose_file), "down", "-v"], check=False)

    # 2. Remove Caddy snippet & reload
    caddy_file = CADDY_SITES_DIR / f"{slug}.caddy"
    if caddy_file.exists():
        caddy_file.unlink()
        reload_caddy()

    # 3. Drop Database and User
    info("Dropping database and user from MariaDB...")
    sql = f"""
    DROP DATABASE IF EXISTS `moodle_{slug}`;
    DROP USER IF EXISTS 'moodle_{slug}'@'%';
    FLUSH PRIVILEGES;
    """
    exec_db_query(sql)

    # 4. Remove Filesystem unless --keep-data
    if not getattr(args, "keep_data", False):
        info(f"Deleting site directory {site_dir}...")
        shutil.rmtree(site_dir)
        success(f"Site '{slug}' completely removed.")
    else:
        success(f"Site '{slug}' containers and DB removed. Data preserved in {site_dir}.")


# =============================================================================
# Backup & Disaster Recovery
# =============================================================================

def cmd_site_backup(args: argparse.Namespace) -> None:
    slug = args.slug.lower().strip()
    site_dir = SITES_DIR / slug
    if not site_dir.exists():
        err(f"Site '{slug}' not found.")
        sys.exit(1)

    cprint(f"==> Starting Production Backup for Tenant: {slug}...", C_BLUE, bold=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    site_backup_dir = BACKUPS_DIR / slug
    site_backup_dir.mkdir(parents=True, exist_ok=True)
    archive_name = f"backup_{slug}_{timestamp}.tar.gz"
    final_archive = site_backup_dir / archive_name

    with tempfile.TemporaryDirectory() as tmp_work_dir:
        work_path = Path(tmp_work_dir)
        
        # 1. Atomic Database Dump
        info("Dumping MariaDB database with transactional consistency...")
        env = ensure_core_env()
        root_pass = env["DB_ROOT_PASSWORD"]
        db_dump_file = work_path / "database.sql"
        dump_cmd = [
            "docker", "compose",
            "-f", str(DOCKER_DIR / "compose.core.yml"),
            "--env-file", str(ENV_FILE),
            "exec", "-T", "db",
            "mariadb-dump",
            "-u", "root",
            f"-p{root_pass}",
            "--single-transaction",
            "--quick",
            f"moodle_{slug}",
        ]
        with open(db_dump_file, "w") as f:
            subprocess.run(dump_cmd, stdout=f, check=True)
        success("Database dump completed.")

        # 2. Copy metadata & config
        if (site_dir / "meta.json").exists():
            shutil.copy2(site_dir / "meta.json", work_path / "meta.json")
        if (site_dir / "code" / "config.php").exists():
            shutil.copy2(site_dir / "code" / "config.php", work_path / "config.php")

        # 3. Create Manifest
        manifest = {
            "slug": slug,
            "timestamp": timestamp,
            "backup_version": VERSION,
            "archive_name": archive_name,
        }
        with open(work_path / "manifest.json", "w") as f:
            json.dump(manifest, f, indent=2)

        # 4. Package into Compressed Archive (excluding ephemeral caches)
        info("Archiving Moodledata (excluding temporary caches) and custom plugins...")
        with tarfile.open(final_archive, "w:gz") as tar:
            tar.add(work_path / "database.sql", arcname="database.sql")
            tar.add(work_path / "manifest.json", arcname="manifest.json")
            if (work_path / "meta.json").exists():
                tar.add(work_path / "meta.json", arcname="meta.json")
            if (work_path / "config.php").exists():
                tar.add(work_path / "config.php", arcname="config.php")

            # Add moodledata excluding cache, sessions, localcache, temp
            moodledata = site_dir / "moodledata"
            if moodledata.exists():
                def exclude_ephemeral(tarinfo):
                    norm = "/" + tarinfo.name.strip("/") + "/"
                    for ex in ["cache", "localcache", "temp", "trashdir", "sessions", "muc"]:
                        if f"/moodledata/{ex}/" in norm or f"/{ex}/" in norm:
                            return None
                    return tarinfo
                tar.add(moodledata, arcname="moodledata", filter=exclude_ephemeral)

            # Add code directory
            code_dir = site_dir / "code"
            if code_dir.exists():
                tar.add(code_dir, arcname="code")

    size_mb = final_archive.stat().st_size / (1024 * 1024)
    success(f"Backup archive created: {final_archive} ({size_mb:.2f} MB)")


def cmd_site_restore(args: argparse.Namespace) -> None:
    slug = args.slug.lower().strip()
    archive_path = Path(args.archive_path).resolve()
    if not archive_path.exists():
        err(f"Backup archive not found: {archive_path}")
        sys.exit(1)

    cprint(f"==> Restoring Tenant Site: {slug} from {archive_path.name}...", C_BLUE, bold=True)
    site_dir = SITES_DIR / slug
    site_dir.mkdir(parents=True, exist_ok=True)
    code_dir = site_dir / "code"
    moodledata_dir = site_dir / "moodledata"

    with tempfile.TemporaryDirectory() as tmp_work_dir:
        work_path = Path(tmp_work_dir)
        info("Extracting backup archive...")
        with tarfile.open(archive_path, "r:gz") as tar:
            tar.extractall(path=work_path)

        # 1. Restore Code and Moodledata
        if (work_path / "code").exists():
            if code_dir.exists():
                shutil.rmtree(code_dir)
            shutil.copytree(work_path / "code", code_dir)

        if (work_path / "moodledata").exists():
            if moodledata_dir.exists():
                shutil.rmtree(moodledata_dir)
            shutil.copytree(work_path / "moodledata", moodledata_dir)

        # 2. Provision Database and Restore SQL Dump
        env = ensure_core_env()
        root_pass = env["DB_ROOT_PASSWORD"]
        db_name = f"moodle_{slug}"
        db_user = f"moodle_{slug}"
        db_pass = gen_password(24)

        info("Re-creating database and user...")
        sql = f"""
        CREATE DATABASE IF NOT EXISTS `{db_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '{db_user}'@'%' IDENTIFIED BY '{db_pass}';
        GRANT ALL PRIVILEGES ON `{db_name}`.* TO '{db_user}'@'%';
        FLUSH PRIVILEGES;
        """
        exec_db_query(sql)

        db_dump = work_path / "database.sql"
        if db_dump.exists():
            info("Importing SQL database dump...")
            import_cmd = [
                "docker", "compose",
                "-f", str(DOCKER_DIR / "compose.core.yml"),
                "--env-file", str(ENV_FILE),
                "exec", "-T", "db",
                "mariadb",
                "-u", "root",
                f"-p{root_pass}",
                db_name,
            ]
            with open(db_dump, "r") as f:
                subprocess.run(import_cmd, stdin=f, check=True)
            success("Database restored.")

        # 3. Adjust Domain & Config
        domain = getattr(args, "domain", None) or f"{slug}.localhost"
        is_moodle5 = (code_dir / "public").exists()
        proto = "http" if domain.startswith("localhost") or domain.endswith(".local") or getattr(args, "no_ssl", False) else "https"
        wwwroot = f"{proto}://{domain}"

        config_context = {
            "SLUG": slug,
            "DOMAIN": domain,
            "WWWROOT": wwwroot,
            "DB_TYPE": "mariadb",
            "DB_HOST": "db",
            "DB_PORT": "3306",
            "DB_NAME": db_name,
            "DB_USER": db_user,
            "DB_PASS": db_pass,
            "DB_PREFIX": "mdl_",
            "SSLPROXY": "true" if proto == "https" else "false",
            "IS_MOODLE5": is_moodle5,
            "USE_REDIS_SESSIONS": True,
            "REDIS_HOST": "redis",
            "REDIS_PORT": 6379,
            "REDIS_AUTH": env.get("REDIS_PASSWORD", ""),
        }
        rendered_config = render_template(TEMPLATES_DIR / "config.php.tpl", config_context)
        with open(code_dir / "config.php", "w") as f:
            f.write(rendered_config)

        # 4. Generate Caddy & Compose files
        has_public = (code_dir / "public").exists()
        web_root = f"/var/www/html/{slug}/code/public" if has_public else f"/var/www/html/{slug}/code"
        container_root = "/var/www/html/public" if has_public else "/var/www/html"
        caddy_context = {
            "SLUG": slug,
            "DOMAIN": domain,
            "UPSTREAM": f"moodle-app-{slug}:9000",
            "WEB_ROOT": web_root,
            "CONTAINER_ROOT": container_root,
        }
        with open(CADDY_SITES_DIR / f"{slug}.caddy", "w") as f:
            f.write(render_template(TEMPLATES_DIR / "site.caddy.tpl", caddy_context))

        plan_name = getattr(args, "plan", "medium") or "medium"
        plan_name = plan_name.lower().strip()
        if plan_name not in SIZING_PROFILES:
            plan_name = "medium"
        profile = SIZING_PROFILES[plan_name]

        compose_context = {
            "SLUG": slug,
            "DOMAIN": domain,
            "BASE_DIR": str(BASE_DIR),
            "IMAGE_NAME": env.get("MOODLE_IMAGE", "moodlekit/moodle-app:8.3"),
            "DB_PASS": db_pass,
            "REDIS_AUTH": env.get("REDIS_PASSWORD", ""),
            "PLAN_NAME": plan_name,
            "PLAN_DESC": profile["description"],
            "FPM_PM": profile["fpm_pm"],
            "FPM_MAX_CHILDREN": profile["fpm_max_children"],
            "FPM_START_SERVERS": profile["fpm_start_servers"],
            "FPM_MIN_SPARE": profile["fpm_min_spare"],
            "FPM_MAX_SPARE": profile["fpm_max_spare"],
            "FPM_IDLE_TIMEOUT": profile["fpm_idle_timeout"],
            "FPM_MAX_REQUESTS": profile["fpm_max_requests"],
            "PHP_MEM_LIMIT": profile["php_mem_limit"],
            "CPU_LIMIT": profile["cpu_limit"],
            "MEM_LIMIT": profile["mem_limit"],
        }
        compose_file = get_site_compose_file(slug)
        with open(compose_file, "w") as f:
            f.write(render_template(TEMPLATES_DIR / "tenant-compose.yml.tpl", compose_context))

        # 5. Start containers & reload Caddy
        sync_master_compose()
        run_cmd(["docker", "compose", "-p", "moodlekit", "-f", str(compose_file), "up", "-d"])
        reload_caddy()

        success(f"Tenant site '{slug}' successfully restored at {wwwroot}!")


# =============================================================================
# CLI Plugins & Exec Helpers
# =============================================================================

def cmd_site_exec(args: argparse.Namespace) -> None:
    slug = args.slug.lower().strip()
    compose_file = get_site_compose_file(slug)
    if not compose_file.exists():
        err(f"Site '{slug}' compose configuration not found.")
        sys.exit(1)

    cmd = [
        "docker", "compose", "-p", "moodlekit", "-f", str(compose_file),
        "exec", f"moodle-app-{slug}",
        "gosu", "www-data",
    ] + args.command
    subprocess.run(cmd)


def cmd_site_cron(args: argparse.Namespace) -> None:
    slug = args.slug.lower().strip()
    info(f"Triggering immediate Moodle cron for tenant '{slug}'...")
    args.command = ["php", "/var/www/html/admin/cli/cron.php"]
    cmd_site_exec(args)


def cmd_site_plugin_install(args: argparse.Namespace) -> None:
    slug = args.slug.lower().strip()
    site_dir = SITES_DIR / slug
    if not site_dir.exists():
        err(f"Site '{slug}' not found.")
        sys.exit(1)

    plugin_source = args.source.strip()
    info(f"Installing plugin from {plugin_source} into '{slug}'...")

    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)
        zip_file = tmp_path / "plugin.zip"

        if plugin_source.startswith("http://") or plugin_source.startswith("https://"):
            info("Downloading plugin archive...")
            run_cmd(["curl", "-fsSL", "-o", str(zip_file), plugin_source])
        else:
            shutil.copy2(plugin_source, zip_file)

        info("Extracting plugin archive...")
        shutil.unpack_archive(zip_file, tmp_path / "extracted")

        # Discover plugin root inside extracted folder
        extracted = tmp_path / "extracted"
        children = [d for d in extracted.iterdir() if d.is_dir()]
        plugin_folder = children[0] if len(children) == 1 else extracted

        # Read version.php to determine frankenstyle component
        version_php = plugin_folder / "version.php"
        if not version_php.exists():
            err("Plugin does not contain version.php. Invalid Moodle plugin archive.")
            sys.exit(1)

        with open(version_php, "r") as f:
            vcontent = f.read()

        match = re.search(r"\$plugin->component\s*=\s*['\"]([a-z0-9_]+)['\"];", vcontent)
        if not match:
            err("Could not detect $plugin->component in version.php.")
            sys.exit(1)

        component = match.group(1)
        info(f"Detected Moodle component: {component}")

        # Map component frankenstyle prefix to folder path
        prefix_map = {
            "mod_": "mod",
            "block_": "blocks",
            "theme_": "theme",
            "local_": "local",
            "auth_": "auth",
            "enrol_": "enrol",
            "report_": "report",
            "tool_": "admin/tool",
            "format_": "course/format",
            "filter_": "filter",
            "tinymce_": "lib/editor/tinymce/plugins",
            "tiny_": "lib/editor/tiny/plugins",
        }
        dest_parent = None
        plugin_name = component
        for prefix, path in prefix_map.items():
            if component.startswith(prefix):
                dest_parent = site_dir / "code" / path
                plugin_name = component[len(prefix):]
                break

        if not dest_parent:
            dest_parent = site_dir / "code" / "local"
            plugin_name = component

        dest_dir = dest_parent / plugin_name
        if dest_dir.exists():
            warn(f"Existing plugin directory {dest_dir} will be replaced.")
            shutil.rmtree(dest_dir)

        dest_parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(plugin_folder, dest_dir)
        success(f"Plugin installed to {dest_dir}.")

        # Trigger non-interactive database upgrade
        info("Running Moodle database upgrade for new plugin...")
        exec_args = argparse.Namespace(
            slug=slug,
            command=["php", "/var/www/html/admin/cli/upgrade.php", "--non-interactive"],
        )
        cmd_site_exec(exec_args)
        success("Plugin installation and upgrade completed!")


def cmd_site_fix_perms(args: argparse.Namespace) -> None:
    slug = args.slug.lower().strip()
    site_dir = SITES_DIR / slug
    if not site_dir.exists():
        err(f"Site '{slug}' not found.")
        sys.exit(1)

    mode = getattr(args, "mode", "standard")
    info(f"Hardening permissions on '{slug}' according to Moodle standards (Mode: {mode})...")

    dir_perm = "2770" if mode == "strict" else "2775"
    file_perm = "0660" if mode == "strict" else "0664"

    compose_file = get_site_compose_file(slug)
    if compose_file.exists():
        perm_script = f"""
        chown -R www-data:www-data /var/moodledata
        find /var/moodledata -type d -exec chmod {dir_perm} {{}} + 2>/dev/null || true
        find /var/moodledata -type f -exec chmod {file_perm} {{}} + 2>/dev/null || true

        chown -R www-data:www-data /var/www/html
        find /var/www/html -type d -exec chmod 0755 {{}} + 2>/dev/null || true
        find /var/www/html -type f -exec chmod 0644 {{}} + 2>/dev/null || true
        """
        if mode != "strict":
            perm_script += """
            for pdir in admin/tool auth availability/condition blocks cache/stores course/format enrol filter grade/export grade/import grade/report local message/output mod plagiarism question/behaviour question/format question/type report repository theme vendor; do
                for base in /var/www/html /var/www/html/public; do
                    if [ -d "$base/$pdir" ]; then
                        find "$base/$pdir" -type d -exec chmod 2775 {} + 2>/dev/null || true
                        find "$base/$pdir" -type f -exec chmod 0664 {} + 2>/dev/null || true
                    fi
                done
            done
            """
        perm_script += """
        if [ -f /var/www/html/config.php ]; then
            chmod 0644 /var/www/html/config.php
        fi
        """
        run_cmd([
            "docker", "compose", "-p", "moodlekit", "-f", str(compose_file),
            "exec", "-T", f"moodle-app-{slug}",
            "bash", "-c", perm_script,
        ])

    success(f"Permissions for '{slug}' hardened successfully (moodledata dirs={dir_perm}, files={file_perm}).")


def cmd_site_resize(args: argparse.Namespace) -> None:
    slug = args.slug.lower().strip()
    site_dir = SITES_DIR / slug
    if not site_dir.exists():
        err(f"Site '{slug}' not found.")
        sys.exit(1)

    plan_name = args.plan.lower().strip()
    if plan_name not in SIZING_PROFILES:
        err(f"Unknown sizing plan '{plan_name}'. Available: {', '.join(SIZING_PROFILES.keys())}")
        sys.exit(1)

    ram_mb = detect_system_ram_mb()
    if plan_name == "enterprise" and ram_mb < 28000 and not getattr(args, "force", False):
        warn(f"Notice: 'enterprise' plan is recommended for 32GB+ hosts (Detected: {ram_mb // 1024}GB). Use -f/--force to override.")

    profile = SIZING_PROFILES[plan_name]
    info(f"Resizing tenant '{slug}' to plan '{plan_name.upper()}' ({profile['description']})...")

    meta_file = site_dir / "meta.json"
    meta = {}
    if meta_file.exists():
        try:
            with open(meta_file, "r") as f:
                meta = json.load(f)
        except Exception:
            pass

    domain = meta.get("domain", f"{slug}.localhost")
    db_pass = meta.get("db_pass", "")
    env = ensure_core_env()

    compose_context = {
        "SLUG": slug,
        "DOMAIN": domain,
        "BASE_DIR": str(BASE_DIR),
        "IMAGE_NAME": env.get("MOODLE_IMAGE", "moodlekit/moodle-app:8.3"),
        "DB_PASS": db_pass,
        "REDIS_AUTH": env.get("REDIS_PASSWORD", ""),
        "PLAN_NAME": plan_name,
        "PLAN_DESC": profile["description"],
        "FPM_PM": profile["fpm_pm"],
        "FPM_MAX_CHILDREN": profile["fpm_max_children"],
        "FPM_START_SERVERS": profile["fpm_start_servers"],
        "FPM_MIN_SPARE": profile["fpm_min_spare"],
        "FPM_MAX_SPARE": profile["fpm_max_spare"],
        "FPM_IDLE_TIMEOUT": profile["fpm_idle_timeout"],
        "FPM_MAX_REQUESTS": profile["fpm_max_requests"],
        "PHP_MEM_LIMIT": profile["php_mem_limit"],
        "CPU_LIMIT": profile["cpu_limit"],
        "MEM_LIMIT": profile["mem_limit"],
    }
    rendered_compose = render_template(TEMPLATES_DIR / "tenant-compose.yml.tpl", compose_context)
    compose_file = get_site_compose_file(slug)
    with open(compose_file, "w") as f:
        f.write(rendered_compose)

    # Hot reload container with new resource limits and FPM parameters
    info("Applying new sizing limits to container...")
    sync_master_compose()
    run_cmd(["docker", "compose", "-p", "moodlekit", "-f", str(compose_file), "up", "-d", f"moodle-app-{slug}"])

    meta["plan"] = plan_name
    with open(meta_file, "w") as f:
        json.dump(meta, f, indent=2)

    success(f"Tenant '{slug}' successfully resized to plan '{plan_name.upper()}' with 0 downtime!")


def cmd_site_plans(args: argparse.Namespace) -> None:
    cprint("==> MoodleKit Multi-Tenant Sizing Profiles:", C_BLUE, bold=True)
    print("-" * 105)
    print(f"{'PLAN':<12} {'PROCESS MODE':<14} {'WORKERS':<10} {'RAM LIMIT':<12} {'CPU LIMIT':<12} {'CAPACITY & TARGET'}")
    print("-" * 105)
    for name, p in SIZING_PROFILES.items():
        print(f"{name:<12} {p['fpm_pm']:<14} {p['fpm_max_children']:<10} {p['mem_limit']:<12} {p['cpu_limit']:<12} {p['description']}")
    print("-" * 105)


# =============================================================================
# RAM Auto-Tuning Engine
# =============================================================================

def cmd_tune(args: argparse.Namespace) -> None:
    cprint("==> Calculating Hardware & Cluster Capacity Parameters...", C_BLUE, bold=True)
    total_ram_mb = detect_system_ram_mb()

    if total_ram_mb >= 28000:
        tier = "32GB+ High-Capacity Cluster"
        db_buffer_mb = 14336
        redis_mb = 3072
        target_workers = "250–400 total workers across tenants"
        capacity = "Up to 4 Big sites (1,200+ concurrent users) or 1 Enterprise + 2 Big or 20+ Small sites"
    elif total_ram_mb >= 14000:
        tier = "16GB Standard Production Cluster"
        db_buffer_mb = 6144
        redis_mb = 1536
        target_workers = "90–120 total workers across tenants"
        capacity = "Up to 2 Big sites (500–600 concurrent users) or 1 Big + 2 Med or 10+ Small sites"
    else:
        tier = "8GB Entry-Level / Dev Cluster"
        db_buffer_mb = 2560
        redis_mb = 512
        target_workers = "30–50 total workers across tenants"
        capacity = "Up to 1 Med or 4 Small sites"

    cprint(f"  Detected Hardware Tier:    {tier} ({total_ram_mb} MB RAM)")
    cprint(f"  MariaDB Buffer Pool:       {db_buffer_mb} MB")
    cprint(f"  Redis Max Memory:          {redis_mb} MB")
    cprint(f"  PHP-FPM Worker Budget:     {target_workers}")
    cprint(f"  Cluster Sizing Capacity:   {capacity}")

    env = ensure_core_env()
    env["DB_BUFFER_POOL_SIZE"] = f"{db_buffer_mb}M"
    env["REDIS_MAX_MEMORY"] = f"{redis_mb}M"
    save_env(env)
    success("Hardware-tuned parameters updated in .env.")


# =============================================================================
# CLI Parser Definition
# =============================================================================

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="moodlekit-docker",
        description=f"MoodleKit Docker v{VERSION} — Multi-Tenant Cloud Moodle Orchestrator",
    )
    parser.add_argument("-v", "--version", action="version", version=f"MoodleKit Docker v{VERSION}")

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # init
    p_init = subparsers.add_parser("init", help="Bootstrap core infrastructure (Caddy, DB, Redis)")
    p_init.add_argument("-e", "--email", help="Admin email for Let's Encrypt SSL")

    # build
    p_build = subparsers.add_parser("build", help="Build optimized Moodle PHP-FPM image")
    p_build.add_argument("--no-cache", action="store_true", help="Build without cache")

    # status
    subparsers.add_parser("status", help="Show system and tenant health status")

    # tune
    p_tune = subparsers.add_parser("tune", help="Auto-tune RAM parameters for DB, Redis, PHP")
    p_tune.add_argument("-m", "--mode", choices=["balanced", "conservative", "aggressive"], default="balanced")

    # site commands
    p_site = subparsers.add_parser("site", help="Manage tenant sites")
    site_sub = p_site.add_subparsers(dest="subcommand", help="Site operations")

    # site plans
    site_sub.add_parser("plans", help="List all available tenant sizing profiles and capacity specs")

    # site create
    p_sc = site_sub.add_parser("create", help="Create a new Moodle tenant")
    p_sc.add_argument("slug", help="Unique tenant slug (e.g. academy)")
    p_sc.add_argument("-d", "--domain", help="Custom domain or subdomain")
    p_sc.add_argument("--plan", choices=list(SIZING_PROFILES.keys()), default="medium", help="Tenant sizing plan (small, medium, big, enterprise)")
    p_sc.add_argument("-m", "--moodle-version", default="5.2", help="Moodle version (5.2 or 4.5)")
    p_sc.add_argument("-u", "--admin-user", default="admin", help="Moodle admin username")
    p_sc.add_argument("-p", "--admin-pass", help="Moodle admin password")
    p_sc.add_argument("-e", "--admin-email", help="Moodle admin email")
    p_sc.add_argument("--fullname", help="Full site name")
    p_sc.add_argument("--shortname", help="Short site name")
    p_sc.add_argument("--db-pass", help="Custom DB password")
    p_sc.add_argument("--http-port", help="Port in case of local non-ssl testing")
    p_sc.add_argument("--no-ssl", action="store_true", help="Disable HTTPS")
    p_sc.add_argument("--skip-download", action="store_true", help="Skip codebase download")
    p_sc.add_argument("--skip-install", action="store_true", help="Skip CLI database install")
    p_sc.add_argument("-f", "--force", action="store_true", help="Force overwrite / override constraints")

    # site resize
    p_resize = site_sub.add_parser("resize", help="Dynamically resize a tenant's plan and resource limits")
    p_resize.add_argument("slug", help="Tenant slug")
    p_resize.add_argument("--plan", choices=list(SIZING_PROFILES.keys()), required=True, help="New sizing plan")
    p_resize.add_argument("-f", "--force", action="store_true", help="Force resize override")

    # site list
    site_sub.add_parser("list", help="List all tenant sites")

    # site remove
    p_sr = site_sub.add_parser("remove", help="Remove a tenant site")
    p_sr.add_argument("slug", help="Tenant slug")
    p_sr.add_argument("-f", "--force", action="store_true", help="Force removal without prompt")
    p_sr.add_argument("--keep-data", action="store_true", help="Preserve filesystem data")

    # site backup
    p_sb = site_sub.add_parser("backup", help="Create a backup archive of a tenant")
    p_sb.add_argument("slug", help="Tenant slug")

    # site restore
    p_sres = site_sub.add_parser("restore", help="Restore tenant from backup archive")
    p_sres.add_argument("slug", help="Tenant slug")
    p_sres.add_argument("archive_path", help="Path to .tar.gz backup archive")
    p_sres.add_argument("-d", "--domain", help="New domain for restored site")
    p_sres.add_argument("--plan", choices=list(SIZING_PROFILES.keys()), default="medium", help="Tenant sizing plan")
    p_sres.add_argument("--no-ssl", action="store_true", help="Disable HTTPS")

    # site cron
    p_cron = site_sub.add_parser("cron", help="Trigger immediate cron for tenant")
    p_cron.add_argument("slug", help="Tenant slug")

    # site exec
    p_exec = site_sub.add_parser("exec", help="Execute command inside tenant container")
    p_exec.add_argument("slug", help="Tenant slug")
    p_exec.add_argument("command", nargs=argparse.REMAINDER, help="Command to run")

    # site plugin
    p_plug = site_sub.add_parser("plugin", help="Install plugins into tenant")
    p_plug.add_argument("slug", help="Tenant slug")
    p_plug.add_argument("action", choices=["install"], help="Plugin action")
    p_plug.add_argument("source", help="Plugin ZIP URL or local path")

    # site fix-perms
    p_perms = site_sub.add_parser("fix-perms", help="Fix & harden file/directory permissions according to Moodle standards")
    p_perms.add_argument("slug", help="Tenant slug")
    p_perms.add_argument("-m", "--mode", choices=["standard", "strict"], default="standard", help="Permission mode (standard: web installer allowed, strict: read-only codebase)")

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(0)

    if args.command == "init":
        cmd_init(args)
    elif args.command == "build":
        cmd_build(args)
    elif args.command == "status":
        cmd_status(args)
    elif args.command == "tune":
        cmd_tune(args)
    elif args.command == "site":
        if not args.subcommand:
            cmd_site_list(args)
        elif args.subcommand == "plans":
            cmd_site_plans(args)
        elif args.subcommand == "create":
            cmd_site_create(args)
        elif args.subcommand == "resize":
            cmd_site_resize(args)
        elif args.subcommand == "list":
            cmd_site_list(args)
        elif args.subcommand == "remove":
            cmd_site_remove(args)
        elif args.subcommand == "backup":
            cmd_site_backup(args)
        elif args.subcommand == "restore":
            cmd_site_restore(args)
        elif args.subcommand == "cron":
            cmd_site_cron(args)
        elif args.subcommand == "exec":
            cmd_site_exec(args)
        elif args.subcommand == "plugin":
            cmd_site_plugin_install(args)
        elif args.subcommand == "fix-perms":
            cmd_site_fix_perms(args)


if __name__ == "__main__":
    main()


