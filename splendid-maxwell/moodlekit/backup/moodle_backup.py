#!/usr/bin/env python3
# =============================================================================
# backup/moodle_backup.py — MoodleKit integrated Python cloud backup script
# =============================================================================

import os
import sys
import json
import time
import subprocess
import logging
import argparse
import urllib.request
import urllib.parse
from datetime import datetime, timedelta
from pathlib import Path
import math
import fnmatch

# =============================================================================
# Utility: Notifications
# =============================================================================

class TelegramNotifier:
    def __init__(self, token: str, chat_id: str):
        self.token = token
        self.chat_id = chat_id
        self.last_msg_id = None
        self.last_edit_time = 0
        self.edit_interval = 10
        self.base_url = f"https://api.telegram.org/bot{self.token}"
        self.enabled = bool(self.token and self.token != "YOUR_BOT_TOKEN_HERE" and self.chat_id)

    def _send_request(self, method: str, data: dict) -> dict:
        if not self.enabled:
            return {}
        try:
            req = urllib.request.Request(
                f"{self.base_url}/{method}",
                data=urllib.parse.urlencode(data).encode('utf-8')
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                return json.loads(response.read().decode())
        except Exception as e:
            logging.error(f"Telegram API error: {e}")
            return {}

    def send(self, text: str):
        if not self.enabled:
            logging.info(f"[Mock Telegram Send] {text}")
            return
        res = self._send_request("sendMessage", {
            "chat_id": self.chat_id,
            "text": text,
            "parse_mode": "HTML"
        })
        if res.get("ok"):
            self.last_msg_id = res["result"]["message_id"]
            self.last_edit_time = time.time()

    def edit(self, text: str, force: bool = False):
        if not self.enabled:
            logging.info(f"[Mock Telegram Edit] {text}")
            return
        if not self.last_msg_id:
            return self.send(text)
        
        now = time.time()
        if not force and (now - self.last_edit_time < self.edit_interval):
            return

        self._send_request("editMessageText", {
            "chat_id": self.chat_id,
            "message_id": self.last_msg_id,
            "text": text,
            "parse_mode": "HTML"
        })
        self.last_edit_time = now

# =============================================================================
# Helper: Format Bytes
# =============================================================================
def format_bytes(size_bytes: int) -> str:
    if size_bytes == 0:
        return "0B"
    size_name = ("B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB")
    i = int(math.floor(math.log(size_bytes, 1024)))
    p = math.pow(1024, i)
    s = round(size_bytes / p, 2)
    return f"{s} {size_name[i]}"

# =============================================================================
# Backup Process
# =============================================================================

class BackupManager:
    def __init__(self, config: dict, secrets: dict):
        self.config = config
        self.secrets = secrets
        self.notifier = TelegramNotifier(
            secrets.get("telegram_bot_token", ""),
            secrets.get("telegram_chat_id", "")
        )
        self.server_name = config.get("server_name", "MoodleServer")
        self.local_root = Path(config.get("local_backup_root", "/var/backups/moodlekit"))
        self.gdrive_remote = config.get("gdrive_remote", "gdrive:moodlekit-backups")
        
    def _run_moodlekit_backup(self) -> bool:
        logging.info("Running moodlekit backup-all...")
        try:
            # We call the CLI command directly
            process = subprocess.run(
                ["moodlekit", "backup", "all"],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True
            )
            if process.returncode != 0:
                logging.error(f"moodlekit backup failed:\n{process.stdout}")
                return False
            return True
        except FileNotFoundError:
            logging.error("moodlekit CLI not found in PATH.")
            return False
            
    def _get_directory_size(self, path: Path) -> int:
        total_size = 0
        for dirpath, _, filenames in os.walk(path):
            for f in filenames:
                fp = os.path.join(dirpath, f)
                if not os.path.islink(fp):
                    total_size += os.path.getsize(fp)
        return total_size

    def _sync_to_gdrive(self) -> bool:
        logging.info(f"Syncing {self.local_root} to {self.gdrive_remote}...")
        
        rclone_cfg = self.config.get("rclone", {})
        cmd = [
            "rclone", "sync",
            str(self.local_root),
            self.gdrive_remote,
            "--verbose",
            "--stats=5s",
            f"--transfers={rclone_cfg.get('transfers', 4)}",
            f"--checkers={rclone_cfg.get('checkers', 8)}",
            f"--tpslimit={rclone_cfg.get('tpslimit', 10)}",
            f"--drive-chunk-size={rclone_cfg.get('drive_chunk_size', '128M')}"
        ]
        
        bwlimit = rclone_cfg.get('bwlimit', '0')
        if bwlimit != "0":
            cmd.append(f"--bwlimit={bwlimit}")
            
        cmd.extend(rclone_cfg.get("extra_flags", []))
        
        try:
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True
            )
            
            while True:
                line = process.stdout.readline()
                if not line and process.poll() is not None:
                    break
                if line:
                    line = line.strip()
                    if "Transferred:" in line and "ETA" in line:
                        self.notifier.edit(f"<b>Syncing:</b>\n<pre>{line}</pre>")
                    elif "ERROR" in line:
                        logging.error(f"rclone: {line}")
                        
            return process.returncode == 0
        except Exception as e:
            logging.error(f"rclone exception: {e}")
            return False

    def run(self):
        start_time = datetime.now()
        logging.info(f"Starting backup for {self.server_name}")
        self.notifier.send(f"🔄 <b>{self.server_name}</b>: Backup started...")

        # 1. Local backup via moodlekit CLI
        self.notifier.edit(f"🔄 <b>{self.server_name}</b>: Creating local backups...", force=True)
        if not self._run_moodlekit_backup():
            self.notifier.edit(f"❌ <b>{self.server_name}</b>: Local backup failed! Check logs.", force=True)
            return
            
        local_size = self._get_directory_size(self.local_root)
        local_size_str = format_bytes(local_size)
        
        # 2. Sync to cloud via rclone
        self.notifier.edit(f"🔄 <b>{self.server_name}</b>: Local complete ({local_size_str}). Syncing to cloud...", force=True)
        if not self._sync_to_gdrive():
            self.notifier.edit(f"❌ <b>{self.server_name}</b>: Cloud sync failed! Check logs.", force=True)
            return
            
        # Success
        end_time = datetime.now()
        duration = end_time - start_time
        duration_str = str(duration).split('.')[0] # HH:MM:SS
        
        msg = (
            f"✅ <b>{self.server_name}</b>: Backup Successful\n\n"
            f"<b>Duration:</b> {duration_str}\n"
            f"<b>Size:</b> {local_size_str}\n"
            f"<b>Time:</b> {end_time.strftime('%Y-%m-%d %H:%M:%S')}"
        )
        self.notifier.edit(msg, force=True)
        logging.info("Backup completed successfully.")

# =============================================================================
# Main
# =============================================================================
def main():
    parser = argparse.ArgumentParser(description="MoodleKit Cloud Backup")
    parser.add_argument("--config", required=True, help="Path to config.json")
    parser.add_argument("--secrets", required=True, help="Path to secrets.json")
    args = parser.parse_args()

    # Load config
    try:
        with open(args.config, 'r') as f:
            config = json.load(f)
        with open(args.secrets, 'r') as f:
            secrets = json.load(f)
    except Exception as e:
        print(f"Error loading config/secrets: {e}")
        sys.exit(1)

    # Setup logging
    log_dir = Path(config.get("log_dir", "/var/log/moodlekit"))
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "backup.log"

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(log_file),
            logging.StreamHandler(sys.stdout)
        ]
    )

    manager = BackupManager(config, secrets)
    manager.run()

if __name__ == "__main__":
    main()
