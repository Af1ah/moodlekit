#!/usr/bin/env python3
"""
MoodleKit Cloud Backup Engine
=============================
Advanced multi-site backup orchestrator with embedded rclone --rc controller,
live Telegram progress tracking, stall detection, and encrypted vault integration.

Features:
- Streamed compressed database dumps (no uncompressed SQL files on disk).
- Exact Google Drive remote path matching:
    {gdrive_remote}/{server_name}/{domain}/database
    {gdrive_remote}/{server_name}/{domain}/moodledata
    {gdrive_remote}/{server_name}/extra_dirs/{name}
  Matches existing backup directory structures to avoid data duplication.
- Live byte transfer speed, percentage, ETA, and error reporting via rclone --rc.
- Single Telegram message tracking across restarts (avoids message spam).
- Graceful SIGTERM/SIGINT shutdown with Telegram notification.
- Supports reading directly from MoodleKit's encrypted vault (/etc/moodlekit/vault.bin)
  or config.json / secrets.json files.
- Auto-discovers all Moodle sites on disk & vault.
"""

import argparse
import fcntl
import gzip
import html
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error
import urllib.parse
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

# Import MoodleKit Vault if available
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(PROJECT_ROOT / "lib"))
try:
    from vault import EncryptedVault
except ImportError:
    EncryptedVault = None

# =============================================================================
# Utilities
# =============================================================================

def esc(text: str) -> str:
    """Escape dynamic text for Telegram HTML mode."""
    return html.escape(str(text), quote=False)

def human_size(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024.0:
            return f"{n:3.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}PB"

def human_eta(seconds: Optional[float]) -> str:
    if not seconds or seconds <= 0 or seconds != seconds:
        return "?"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"

def progress_bar(pct: float, width: int = 16) -> str:
    pct = max(0.0, min(100.0, pct))
    filled = int(width * pct / 100)
    return "█" * filled + "░" * (width - filled)

def now_str() -> str:
    return datetime.now().strftime("%H:%M:%S")

def free_local_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port

# =============================================================================
# Logging
# =============================================================================

class Logger:
    def __init__(self, log_path: Path):
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            self.fh = open(log_path, "a", buffering=1)
        except OSError:
            fallback = Path(f"/tmp/{log_path.name}")
            self.fh = open(fallback, "a", buffering=1)

    def write(self, msg: str):
        line = f"[{now_str()}] {msg}"
        print(line, flush=True)
        try:
            self.fh.write(line + "\n")
        except Exception:
            pass

    def close(self):
        try:
            self.fh.close()
        except Exception:
            pass

# =============================================================================
# Telegram Live Notifications
# =============================================================================

class Telegram:
    def __init__(
        self,
        token: str,
        chat_id: str,
        logger: Logger,
        edit_interval: int = 15,
        state_file: Optional[Path] = None,
        state_key: Optional[str] = None,
    ):
        self.token = token
        self.chat_id = chat_id
        self.logger = logger
        self.edit_interval = edit_interval
        self.last_text = None
        self.last_edit_ts = 0
        self.enabled = bool(token and token != "YOUR_BOT_TOKEN_HERE" and chat_id and chat_id != "YOUR_CHAT_ID_HERE")
        self._next_send_attempt = 0
        self._send_backoff = 30

        self.state_file = state_file
        self.state_key = state_key
        self.message_id = self._load_message_id()

    def _load_message_id(self) -> Optional[int]:
        if not self.state_file or not self.state_key:
            return None
        try:
            data = json.loads(self.state_file.read_text())
            if data.get("key") == self.state_key:
                return data.get("message_id")
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            pass
        return None

    def _save_message_id(self):
        if not self.state_file or not self.state_key or self.message_id is None:
            return
        try:
            self.state_file.parent.mkdir(parents=True, exist_ok=True)
            self.state_file.write_text(json.dumps({"key": self.state_key, "message_id": self.message_id}))
        except OSError as e:
            self.logger.write(f"[telegram] could not persist message id: {e}")

    def _call(self, method: str, payload: dict) -> Optional[dict]:
        if not self.enabled:
            return None
        url = f"https://api.telegram.org/bot{self.token}/{method}"
        data = json.dumps(payload).encode()
        req = urllib.request.Request(
            url, data=data, headers={"Content-Type": "application/json"}, method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            if "message is not modified" not in body:
                self.logger.write(f"[telegram] {method} HTTP error: {body[:300]}")
            return None
        except Exception as e:
            self.logger.write(f"[telegram] {method} failed: {e}")
            return None

    def send(self, text: str) -> bool:
        if not self.enabled:
            return False
        resp = self._call(
            "sendMessage", {"chat_id": self.chat_id, "text": text, "parse_mode": "HTML"}
        )
        if resp and resp.get("ok"):
            self.message_id = resp["result"]["message_id"]
            self.last_text = text
            self.last_edit_ts = time.time()
            self._send_backoff = 30
            self._save_message_id()
            return True
        self.logger.write(f"[telegram] could not create status message; backing off {self._send_backoff}s")
        self._next_send_attempt = time.time() + self._send_backoff
        self._send_backoff = min(self._send_backoff * 2, 600)
        return False

    def edit(self, text: str, force: bool = False):
        if not self.enabled:
            return
        if text == self.last_text:
            return
        if not force and (time.time() - self.last_edit_ts) < self.edit_interval:
            return
        if self.message_id is None:
            if time.time() < self._next_send_attempt:
                return
            self.send(text)
            return

        url = f"https://api.telegram.org/bot{self.token}/editMessageText"
        data = json.dumps(
            {"chat_id": self.chat_id, "message_id": self.message_id, "text": text, "parse_mode": "HTML"}
        ).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                json.loads(resp.read().decode())
            self.last_text = text
            self.last_edit_ts = time.time()
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            if "message is not modified" in body:
                self.last_text = text
                self.last_edit_ts = time.time()
                return
            if any(s in body.lower() for s in ("message to edit not found", "message_id_invalid", "message can't be edited")):
                self.logger.write(f"[telegram] tracked message invalid; starting fresh message")
                self.message_id = None
                if self.state_file:
                    try:
                        self.state_file.unlink(missing_ok=True)
                    except OSError:
                        pass
                self.send(text)
            else:
                self.logger.write(f"[telegram] editMessageText HTTP error: {body[:300]}")
        except Exception as e:
            self.logger.write(f"[telegram] editMessageText failed: {e}")

# =============================================================================
# Rclone Controller
# =============================================================================

@dataclass
class RcloneResult:
    ok: bool
    stalled: bool = False
    returncode: Optional[int] = None
    bytes_transferred: int = 0
    errors: int = 0

_active_rclone_procs: set = set()

class RcloneJob:
    def __init__(
        self,
        src: str,
        dst: str,
        label: str,
        extra_flags: list,
        log_file: Path,
        logger: Logger,
        stall_timeout: int,
        poll_interval: int,
        on_progress=None,
        dry_run: bool = False,
    ):
        self.src = src
        self.dst = dst
        self.label = label
        self.extra_flags = extra_flags
        self.log_file = log_file
        self.logger = logger
        self.stall_timeout = stall_timeout
        self.poll_interval = poll_interval
        self.on_progress = on_progress
        self.dry_run = dry_run

    def _rc_call(self, port: int, method: str) -> Optional[dict]:
        url = f"http://127.0.0.1:{port}/{method}"
        req = urllib.request.Request(url, data=b"{}", headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode())
        except Exception:
            return None

    def run_once(self) -> RcloneResult:
        port = free_local_port()
        cmd = [
            "rclone", "sync", self.src, self.dst,
            "--rc", f"--rc-addr=127.0.0.1:{port}", "--rc-no-auth",
            "-v", "--stats", "30s", "--log-file", str(self.log_file),
        ] + self.extra_flags
        if self.dry_run:
            cmd.append("--dry-run")

        self.logger.write(f"[{self.label}] launching: {' '.join(cmd)}")

        try:
            proc = subprocess.Popen(cmd, start_new_session=True)
        except OSError as e:
            self.logger.write(f"[{self.label}] could not launch rclone: {e}")
            return RcloneResult(ok=False, returncode=None)

        _active_rclone_procs.add(proc)
        try:
            return self._monitor(proc, port)
        finally:
            _active_rclone_procs.discard(proc)

    def _monitor(self, proc: subprocess.Popen, port: int) -> RcloneResult:
        stats_ready = False
        for _ in range(20):
            if self._rc_call(port, "core/stats") is not None:
                stats_ready = True
                break
            if proc.poll() is not None:
                break
            time.sleep(0.5)

        last_bytes = -1
        last_change_ts = time.time()
        result = RcloneResult(ok=False)

        while True:
            rc = proc.poll()
            stats = self._rc_call(port, "core/stats") if stats_ready else None

            if stats:
                b = stats.get("bytes", 0)
                total = stats.get("totalBytes", 0)
                speed = stats.get("speed", 0)
                eta = stats.get("eta")
                errors = stats.get("errors", 0)
                transfers = stats.get("transfers", 0)
                total_transfers = stats.get("totalTransfers", 0)

                if b != last_bytes:
                    last_bytes = b
                    last_change_ts = time.time()

                if self.on_progress:
                    self.on_progress(
                        label=self.label,
                        bytes_done=b,
                        bytes_total=total,
                        speed=speed,
                        eta=eta,
                        errors=errors,
                        files_done=transfers,
                        files_total=total_transfers,
                    )

                stalled_for = time.time() - last_change_ts
                if stalled_for > self.stall_timeout:
                    self.logger.write(
                        f"[{self.label}] STALLED - no byte progress for {int(stalled_for)}s, killing"
                    )
                    self._kill(proc)
                    result.stalled = True
                    result.ok = False
                    result.bytes_transferred = last_bytes if last_bytes > 0 else 0
                    return result

            if rc is not None:
                result.returncode = rc
                result.ok = (rc == 0)
                result.bytes_transferred = last_bytes if last_bytes > 0 else 0
                if stats:
                    result.errors = stats.get("errors", 0)
                return result

            time.sleep(self.poll_interval)

    @staticmethod
    def _kill(proc: subprocess.Popen):
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            time.sleep(3)
            if proc.poll() is None:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass

    PERMANENT_EXIT_CODES = {1, 2, 3, 4}

    def run_with_retries(self, max_retries: int, backoff: int) -> RcloneResult:
        attempt = 0
        while True:
            attempt += 1
            result = self.run_once()
            if result.ok:
                return result
            if result.returncode in self.PERMANENT_EXIT_CODES:
                self.logger.write(f"[{self.label}] permanent exit code {result.returncode} - not retrying")
                return result
            if attempt > max_retries:
                self.logger.write(f"[{self.label}] giving up after {attempt} attempts")
                return result
            wait = backoff * attempt
            reason = "stalled" if result.stalled else f"exit code {result.returncode}"
            self.logger.write(f"[{self.label}] attempt {attempt} failed ({reason}); retrying in {wait}s")
            time.sleep(wait)

# =============================================================================
# Moodle Config Extraction & Auto-Discovery
# =============================================================================

def parse_moodle_config(config_path: Path) -> dict:
    if not config_path.exists():
        return {}
    text = config_path.read_text(errors="replace")

    def grab(key: str) -> Optional[str]:
        m = re.search(rf"\\\$CFG->{key}\s*=\s*['\"](.*?)['\"]", text)
        if not m:
            m = re.search(rf"\$CFG->{key}\s*=\s*['\"](.*?)['\"]", text)
        if not m:
            m = re.search(rf"['\"]{key}['\"]\s*=>?\s*['\"](.*?)['\"]", text)
        return m.group(1) if m else None

    return {
        "dbtype": grab("dbtype") or "mysqli",
        "dbname": grab("dbname") or "",
        "dbuser": grab("dbuser") or "",
        "dbpass": grab("dbpass") or "",
        "dataroot": grab("dataroot") or "",
        "wwwroot": grab("wwwroot") or "",
    }

def domain_from_wwwroot(wwwroot: Optional[str], fallback: str) -> str:
    """Extract domain from $CFG->wwwroot or fallback to folder name."""
    if not wwwroot:
        return fallback
    try:
        netloc = urllib.parse.urlsplit(wwwroot).netloc
        if not netloc:
            return fallback
        domain = netloc.split("@")[-1].split(":")[0]
        return domain or fallback
    except Exception:
        return fallback

def discover_all_moodle_sites(config_sites: List[str]) -> List[Path]:
    """Combine configured sites, vault sites, and disk-scanned sites."""
    seen_configs = set()
    result: List[Path] = []

    def is_disqualified(path_obj: Path) -> bool:
        s_path = str(path_obj).lower()
        for sub in [
            "/blocks/", "/mod/", "/theme/", "/enrol/", "/auth/", "/filter/",
            "/report/", "/repository/", "/local/", "/dataformat/", "/portfolio/",
            "/webservice/", "/question/", "/availability/", "/grade/", "/message/",
            "/media/", "/cache/", "/backup/", "/payment/", "plugins/", "aims-plugins",
            "theme_", "theme-", "_backup_", "_old_", ".bak", "/temp/", "/tmp/"
        ]:
            if sub in s_path:
                return True
        return False

    def add_site(path_obj: Path):
        if is_disqualified(path_obj):
            return

        # Support both traditional and Moodle 5.1+ public/ layouts
        cfg = path_obj / "config.php"
        if not cfg.exists() and (path_obj / "public" / "config.php").exists():
            cfg = path_obj / "public" / "config.php"

        if cfg.exists():
            try:
                cfg_vals = parse_moodle_config(cfg)
                if cfg_vals.get("dbname") and cfg_vals.get("dataroot"):
                    resolved = cfg.resolve()
                    if resolved not in seen_configs:
                        seen_configs.add(resolved)
                        result.append(path_obj)
            except Exception:
                pass

    # 1. From config.json (explicit user selection takes priority)
    if config_sites:
        for s in config_sites:
            if s:
                add_site(Path(s))
        if result:
            return result

    # 2. From Encrypted Vault
    if EncryptedVault is not None:
        try:
            vault = EncryptedVault()
            for slug, sdata in vault.list_sites().items():
                mdir = sdata.get("moodle_dir")
                if mdir:
                    add_site(Path(mdir))
        except Exception:
            pass

    # 3. Standard filesystem locations (only if no explicit config_sites or vault sites)
    scan_roots = [Path("/var/www"), Path("/opt/moodle"), Path("/home")]
    for root in scan_roots:
        if root.exists():
            for cfg in root.glob("**/config.php"):
                # Avoid deep nested node_modules or cache
                if "node_modules" not in str(cfg) and "cache" not in str(cfg):
                    if cfg.parent.name == "public" and cfg.parent.parent.exists():
                        add_site(cfg.parent.parent)
                    else:
                        add_site(cfg.parent)

    return result

# =============================================================================
# Backup Run Orchestrator
# =============================================================================

class BackupRun:
    def __init__(self, config: dict, secrets: dict, dry_run: bool, only_db: bool):
        self.cfg = config
        self.secrets = secrets
        self.dry_run = dry_run
        self.only_db = only_db

        self.server_name = config.get("server_name") or socket.gethostname()
        self.start_time = datetime.now()
        self.date_str = self.start_time.strftime("%Y-%m-%d")
        self.time_str = self.start_time.strftime("%Y-%m-%d_%H-%M-%S")

        log_dir = Path(config.get("log_dir", "/var/log/moodlekit"))
        self.logger = Logger(log_dir / f"backup_{self.date_str}.log")
        
        try:
            log_dir.mkdir(parents=True, exist_ok=True)
            self.rclone_log = log_dir / f"rclone_{self.date_str}.log"
            with open(self.rclone_log, "a"):
                pass
        except OSError:
            self.rclone_log = Path(f"/tmp/rclone_{self.date_str}.log")

        self.tg = Telegram(
            secrets.get("telegram_bot_token", ""),
            secrets.get("telegram_chat_id", ""),
            self.logger,
            edit_interval=config.get("telegram_edit_interval_seconds", 15),
            state_file=(log_dir if log_dir.exists() and os.access(log_dir, os.W_OK) else Path("/tmp")) / "telegram_message_state.json",
            state_key=f"{self.server_name}_{self.date_str}",
        )

        self.error_count = 0
        self.body_lines = []
        self.header = (
            f"📦 <b>Backup: {esc(self.server_name)}</b>\n"
            f"📅 {self.date_str}\n"
            + ("〰️" * 8) + "\n"
        )

    def rclone_global_flags(self) -> list:
        r = self.cfg.get("rclone", {})
        flags = [
            "--transfers", str(r.get("transfers", 8)),
            "--checkers", str(r.get("checkers", 12)),
            "--tpslimit", str(r.get("tpslimit", 8)),
            "--drive-chunk-size", r.get("drive_chunk_size", "32M"),
            "--fast-list",
            "--size-only",
            "--contimeout", "60s",
            "--timeout", "10m",
            "--retries", "5",
            "--low-level-retries", "15",
            "--bwlimit", str(r.get("bwlimit", "0")),
        ]
        client_id = self.secrets.get("drive_client_id")
        client_secret = self.secrets.get("drive_client_secret")
        if client_id and client_secret:
            flags += [f"--drive-client-id={client_id}", f"--drive-client-secret={client_secret}"]
        flags += r.get("extra_flags", [])
        return flags

    def make_progress_cb(self, site_label: str):
        def cb(label, bytes_done, bytes_total, speed, eta, errors, files_done, files_total):
            if bytes_total and bytes_total > 0:
                pct = 100.0 * bytes_done / bytes_total
                bar = progress_bar(pct)
                body = (
                    f"⏳ <b>{site_label}</b>\n"
                    f"{bar} {pct:4.1f}%\n"
                    f"{human_size(bytes_done)} / {human_size(bytes_total)}  "
                    f"@ {human_size(speed)}/s\n"
                    f"Files: {files_done}/{files_total}   ETA: {human_eta(eta)}"
                )
            else:
                body = f"⏳ <b>{site_label}</b>\n🔍 Scanning files (verifying remote state)..."
            if errors:
                body += f"\n⚠️ errors so far: {errors}"
            self.tg.edit(self.header + "\n".join(self.body_lines) + ("\n" if self.body_lines else "") + body)
        return cb

    def append_summary(self, line: str):
        self.body_lines.append(line)
        self.tg.edit(self.header + "\n".join(self.body_lines), force=True)

    def sync_dir(self, src: str, dst: str, label: str, extra_flags: list = None) -> RcloneResult:
        job = RcloneJob(
            src=src,
            dst=dst,
            label=label,
            extra_flags=self.rclone_global_flags() + (extra_flags or []),
            log_file=self.rclone_log,
            logger=self.logger,
            stall_timeout=self.cfg.get("stall_timeout_seconds", 420),
            poll_interval=self.cfg.get("poll_interval_seconds", 5),
            on_progress=self.make_progress_cb(label),
            dry_run=self.dry_run,
        )
        return job.run_with_retries(
            max_retries=self.cfg.get("max_retries", 3),
            backoff=self.cfg.get("retry_backoff_seconds", 30),
        )

    def dump_database(self, site_dir: Path, cfg_vals: dict, instance_dir: Path) -> Optional[Path]:
        dbname = cfg_vals["dbname"]
        dbtype = cfg_vals["dbtype"]
        dump_path = instance_dir / f"db_{dbname}_{self.time_str}.sql.gz"

        if dump_path.exists():
            dump_path.unlink()

        if self.dry_run:
            self.logger.write(f"[dry-run] would dump {dbtype} database {dbname}")
            return dump_path

        instance_dir.mkdir(parents=True, exist_ok=True)

        if dbtype in ("pgsql", "postgres"):
            dump_cmd = ["pg_dump", "-U", cfg_vals["dbuser"], "-h", "localhost", dbname]
            env = dict(os.environ, PGPASSWORD=cfg_vals.get("dbpass", ""))
        elif dbtype in ("mariadb", "mysqli", "mysql"):
            dump_cmd = [
                "mysqldump", f"-u{cfg_vals['dbuser']}", f"-p{cfg_vals['dbpass']}",
                "-h", "localhost",
                "--no-tablespaces",
                "--single-transaction",
                "--quick",
                dbname,
            ]
            env = os.environ.copy()
        else:
            self.logger.write(f"Unsupported DB type: {dbtype}")
            return None

        self.logger.write(f"Dumping {dbtype} database {dbname} (streamed to gzip)...")
        try:
            with open(dump_path, "wb") as out_f:
                dump_proc = subprocess.Popen(dump_cmd, stdout=subprocess.PIPE, env=env)
                gzip_proc = subprocess.Popen(["gzip", "-c"], stdin=dump_proc.stdout, stdout=out_f)
                dump_proc.stdout.close()
                gzip_proc.communicate()
                dump_proc.wait()
            if dump_proc.returncode != 0 or gzip_proc.returncode != 0:
                self.logger.write(f"Dump failed for {dbname} (dump_rc={dump_proc.returncode})")
                dump_path.unlink(missing_ok=True)
                return None
        except Exception as e:
            self.logger.write(f"Dump exception for {dbname}: {e}")
            dump_path.unlink(missing_ok=True)
            return None

        if not self._gzip_ok(dump_path):
            self.logger.write(f"Dump for {dbname} failed integrity test")
            return None

        return dump_path

    @staticmethod
    def _gzip_ok(path: Path) -> bool:
        try:
            with gzip.open(path, "rb") as f:
                while f.read(1024 * 1024):
                    pass
            return True
        except Exception:
            return False

    def cleanup_old_dumps(self, instance_dir: Path):
        keep_n = self.cfg.get("keep_last_n_db_dumps", 3)
        if not instance_dir.exists():
            return
        dumps = sorted(
            instance_dir.glob("db_*.sql.gz"), key=lambda f: f.stat().st_mtime, reverse=True
        )
        for f in dumps[keep_n:]:
            self.logger.write(f"Removing old local dump (keeping {keep_n}): {f}")
            f.unlink(missing_ok=True)

    def run(self) -> int:
        self.tg.edit(self.header + "⏳ <i>Initializing backup orchestrator...</i>", force=True)
        self.logger.write("=" * 60)
        self.logger.write(f"Starting cloud backup workflow on {self.server_name}")

        configured_sites = self.cfg.get("moodle_sites", [])
        all_sites = discover_all_moodle_sites(configured_sites)

        if not all_sites:
            self.logger.write("No Moodle sites discovered on server")
            self.append_summary("⚠️ <b>No Moodle sites detected on host</b>")
            self.error_count += 1

        local_backup_root = Path(self.cfg.get("local_backup_root", "/opt/db_backups"))
        gdrive_remote = self.cfg.get("gdrive_remote", "gdrive:MoodleBackup")

        for site_dir in all_sites:
            site_label = site_dir.name
            config_php = site_dir / "config.php"

            if not config_php.exists():
                self.logger.write(f"config.php not found for {site_label}")
                self.append_summary(f"❌ <b>{esc(site_label)}</b> [missing config.php]")
                self.error_count += 1
                continue

            cfg_vals = parse_moodle_config(config_php)
            if not all(cfg_vals.get(k) for k in ("dbtype", "dbname", "dbuser", "dataroot")):
                self.logger.write(f"Could not parse DB config for {site_label}")
                self.append_summary(f"❌ <b>{esc(site_label)}</b> [config parse error]")
                self.error_count += 1
                continue

            # Exact remote domain mapping matching reference architecture
            remote_label = domain_from_wwwroot(cfg_vals.get("wwwroot"), fallback=site_label)

            instance_dir = local_backup_root / self.server_name / site_label
            instance_dir.mkdir(parents=True, exist_ok=True)
            site_errors = 0

            # 1. DB dump
            self.tg.edit(
                self.header + "\n".join(self.body_lines) +
                ("\n" if self.body_lines else "") +
                f"⏳ <b>{esc(remote_label)}</b>\n💾 [1/3] Creating compressed database dump...",
                force=True
            )
            dump_path = self.dump_database(site_dir, cfg_vals, instance_dir)
            if dump_path is None:
                site_errors += 1
                self.append_summary(f"❌ <b>{esc(remote_label)}</b> [DB dump failed]")
                self.error_count += 1
                continue

            self.cleanup_old_dumps(instance_dir)
            db_size = human_size(dump_path.stat().st_size) if dump_path.exists() else "?"

            # 2. Upload DB dump
            db_dst = f"{gdrive_remote}/{self.server_name}/{remote_label}/database"
            db_result = self.sync_dir(
                str(instance_dir), db_dst,
                f"{esc(remote_label)}</b>\n📤 [2/3] Uploading database dumps<b>",
            )
            if not db_result.ok:
                site_errors += 1
                self.error_count += 1

            # 3. Sync moodledata (clean exclusions)
            if not self.only_db:
                dataroot = cfg_vals["dataroot"]
                if Path(dataroot).is_dir():
                    data_dst = f"{gdrive_remote}/{self.server_name}/{remote_label}/moodledata"
                    data_result = self.sync_dir(
                        dataroot, data_dst,
                        f"{esc(remote_label)}</b>\n📂 [3/3] Syncing moodledata files<b>",
                        extra_flags=[
                            "--exclude", "cache/**",
                            "--exclude", "localcache/**",
                            "--exclude", "sessions/**",
                            "--exclude", "trashdir/**",
                            "--exclude", "temp/**",
                            "--exclude", "muc/**",
                        ],
                    )
                    if not data_result.ok:
                        site_errors += 1
                        self.error_count += 1
                else:
                    self.logger.write(f"dataroot directory not found: {dataroot}")
                    site_errors += 1
                    self.error_count += 1

            if site_errors == 0:
                self.append_summary(f"✅ <b>{esc(remote_label)}</b> [DB: {db_size}]")
            else:
                self.append_summary(f"⚠️ <b>{esc(remote_label)}</b> [finished with errors]")

        # 4. Extra directories
        extra_dirs = self.cfg.get("extra_backup_dirs", [
            "/etc/nginx/sites-available",
            "/etc/moodlekit"
        ])
        for extra in extra_dirs:
            if isinstance(extra, dict):
                extra_path = Path(extra.get("path", ""))
                name = extra.get("name", extra_path.name)
            else:
                extra_path = Path(extra)
                name = extra_path.name

            if not extra_path.is_dir():
                continue

            extra_dst = f"{gdrive_remote}/{self.server_name}/extra_dirs/{name}"
            result = self.sync_dir(
                str(extra_path), extra_dst,
                f"extra · {esc(name)}",
            )
            if result.ok:
                self.append_summary(f"✅ <b>{esc(name)}</b>")
            else:
                self.append_summary(f"⚠️ <b>{esc(name)}</b> [sync failed]")
                self.error_count += 1

        self.logger.write(f"Cloud backup completed with {self.error_count} error(s)")
        if self.error_count == 0:
            final = f"🎉 <b>Backup completed successfully!</b>\n🕒 {now_str()}"
        else:
            final = f"⚠️ <b>Backup finished with {self.error_count} error(s).</b>\nCheck /var/log/moodlekit/ logs on host."
        self.tg.edit(self.header + "\n".join(self.body_lines) + "\n\n" + final, force=True)

        self.logger.close()
        return self.error_count

# =============================================================================
# Locking & Signal Handlers
# =============================================================================

def acquire_lock(lock_path: Path):
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        fh = open(lock_path, "w")
    except OSError:
        fallback = Path(f"/tmp/{lock_path.name}")
        fh = open(fallback, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Another backup run is already active (lock file held). Exiting.")
        sys.exit(1)
    fh.write(str(os.getpid()))
    fh.flush()
    return fh

def install_kill_notifier(run: BackupRun):
    def handler(signum, frame):
        sig_name = signal.Signals(signum).name
        run.logger.write(f"Received {sig_name} - notifying Telegram and terminating subprocesses")
        for proc in list(_active_rclone_procs):
            try:
                RcloneJob._kill(proc)
            except Exception:
                pass
        try:
            text = (
                run.header + "\n".join(run.body_lines)
                + f"\n\n🛑 <b>Backup interrupted</b> ({sig_name})\n🕒 {now_str()}"
            )
            run.tg.edit(text, force=True)
        except Exception:
            pass
        sys.exit(143 if signum == signal.SIGTERM else 130)

    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)

# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="MoodleKit Cloud Backup Engine")
    parser.add_argument("--config", default="/opt/moodlekit-data/backup/config.json")
    parser.add_argument("--secrets", default="/opt/moodlekit-data/backup/secrets.json")
    parser.add_argument("--dry-run", action="store_true", help="Simulate backup without uploading")
    parser.add_argument("--only-db", action="store_true", help="Dump and upload databases only")
    parser.add_argument("--lock-file", default="/run/lock/moodle_backup.lock")
    args = parser.parse_args()

    config = {
        "server_name": None,
        "moodle_sites": [],
        "extra_backup_dirs": ["/etc/nginx/sites-available", "/etc/moodlekit"],
        "local_backup_root": "/opt/db_backups",
        "log_dir": "/var/log/moodlekit",
        "keep_last_n_db_dumps": 3,
        "gdrive_remote": "gdrive:MoodleBackup",
        "rclone": {
            "transfers": 8,
            "checkers": 12,
            "tpslimit": 8,
            "drive_chunk_size": "32M",
            "bwlimit": "0",
            "extra_flags": []
        },
        "stall_timeout_seconds": 420,
        "poll_interval_seconds": 5,
        "max_retries": 3,
        "retry_backoff_seconds": 30,
        "telegram_edit_interval_seconds": 15
    }
    secrets = {
        "telegram_bot_token": "",
        "telegram_chat_id": "",
        "drive_client_id": "",
        "drive_client_secret": ""
    }

    # 1. Load from Encrypted Vault
    if EncryptedVault is not None:
        try:
            vault = EncryptedVault()
            g_data = vault.get_global()
            if g_data:
                if g_data.get("server_name"):
                    config["server_name"] = g_data["server_name"]
                if g_data.get("gdrive_remote"):
                    config["gdrive_remote"] = g_data["gdrive_remote"]
                for k in ("telegram_bot_token", "telegram_chat_id", "drive_client_id", "drive_client_secret"):
                    if g_data.get(k):
                        secrets[k] = g_data[k]
        except Exception:
            pass

    # 2. Overlay config.json / secrets.json if present
    cfg_file = Path(args.config)
    if cfg_file.exists():
        try:
            config.update(json.loads(cfg_file.read_text()))
        except Exception as e:
            print(f"Warning: Could not read config file {cfg_file}: {e}")

    sec_file = Path(args.secrets)
    if sec_file.exists():
        try:
            secrets.update(json.loads(sec_file.read_text()))
        except Exception as e:
            print(f"Warning: Could not read secrets file {sec_file}: {e}")

    lock_fh = acquire_lock(Path(args.lock_file))
    try:
        run = BackupRun(config, secrets, dry_run=args.dry_run, only_db=args.only_db)
        install_kill_notifier(run)
        error_count = run.run()
    finally:
        fcntl.flock(lock_fh, fcntl.LOCK_UN)
        lock_fh.close()

    sys.exit(min(error_count, 255))

if __name__ == "__main__":
    main()
