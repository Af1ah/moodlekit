#!/usr/bin/env python3
"""
MoodleKit Encrypted Binary Vault Engine
=======================================
Stores site configurations, global server settings, database credentials,
and cloud backup secrets in an encrypted binary vault file (/etc/moodlekit/vault.bin).

Uses AES-256 with PBKDF2 (100,000 iterations) + HMAC-SHA256 for authenticated encryption.
Master key is stored with strict 0600 permissions at /etc/moodlekit/.master.key.
"""

import os
import sys
import json
import base64
import hashlib
import hmac
import secrets
import subprocess
import argparse
from pathlib import Path
from typing import Dict, Any, Optional

DEFAULT_VAULT_DIR = Path(os.environ.get("MOODLEKIT_STATE_DIR", "/etc/moodlekit"))
DEFAULT_VAULT_FILE = Path(os.environ.get("MOODLEKIT_VAULT_PATH", str(DEFAULT_VAULT_DIR / "vault.bin")))
DEFAULT_KEY_FILE = Path(os.environ.get("MOODLEKIT_KEY_PATH", str(DEFAULT_VAULT_DIR / ".master.key")))

PBKDF2_ITERATIONS = 100000
SALT_SIZE = 16
IV_SIZE = 16
HMAC_KEY_SIZE = 32
AES_KEY_SIZE = 32

class EncryptedVault:
    def __init__(self, vault_path: Optional[Path] = None, key_path: Optional[Path] = None):
        self.vault_path = Path(vault_path or DEFAULT_VAULT_FILE)
        self.key_path = Path(key_path or DEFAULT_KEY_FILE)
        self.vault_dir = self.vault_path.parent
        self._ensure_paths()

    def _ensure_paths(self):
        try:
            self.vault_dir.mkdir(parents=True, exist_ok=True)
            # Ensure restricted permissions on vault directory
            os.chmod(self.vault_dir, 0o700)
        except (PermissionError, OSError):
            pass

    def get_or_create_master_key(self) -> bytes:
        if self.key_path.exists():
            with open(self.key_path, "rb") as f:
                key = f.read().strip()
                if len(key) >= 32:
                    return key
        # Generate new random master key
        key = secrets.token_bytes(32)
        try:
            with open(self.key_path, "wb") as f:
                f.write(key)
            os.chmod(self.key_path, 0o600)
        except (PermissionError, OSError):
            pass
        return key

    def _derive_keys(self, master_key: bytes, salt: bytes):
        derived = hashlib.pbkdf2_hmac(
            "sha256",
            master_key,
            salt,
            PBKDF2_ITERATIONS,
            dklen=AES_KEY_SIZE + HMAC_KEY_SIZE
        )
        aes_key = derived[:AES_KEY_SIZE]
        hmac_key = derived[AES_KEY_SIZE:]
        return aes_key, hmac_key

    def _encrypt_bytes(self, plaintext: bytes) -> bytes:
        master_key = self.get_or_create_master_key()
        salt = secrets.token_bytes(SALT_SIZE)
        iv = secrets.token_bytes(IV_SIZE)
        aes_key, hmac_key = self._derive_keys(master_key, salt)

        # OpenSSL CLI encryption to avoid dependency on 3rd party pip packages
        proc = subprocess.run(
            [
                "openssl", "enc", "-aes-256-cbc",
                "-K", aes_key.hex(),
                "-iv", iv.hex(),
                "-nosalt"
            ],
            input=plaintext,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True
        )
        ciphertext = proc.stdout

        # Compute HMAC over salt + iv + ciphertext
        h = hmac.new(hmac_key, salt + iv + ciphertext, hashlib.sha256)
        tag = h.digest()

        # Binary format: MAGIC(4) | SALT(16) | IV(16) | TAG(32) | CIPHERTEXT(N)
        magic = b"MDKV" # MoodleKit Vault Magic header
        return magic + salt + iv + tag + ciphertext

    def _decrypt_bytes(self, payload: bytes) -> bytes:
        if len(payload) < 4 + SALT_SIZE + IV_SIZE + 32:
            raise ValueError("Corrupted vault payload: too short")

        magic = payload[:4]
        if magic != b"MDKV":
            raise ValueError("Invalid vault header magic bytes")

        idx = 4
        salt = payload[idx:idx + SALT_SIZE]
        idx += SALT_SIZE
        iv = payload[idx:idx + IV_SIZE]
        idx += IV_SIZE
        tag = payload[idx:idx + 32]
        idx += 32
        ciphertext = payload[idx:]

        master_key = self.get_or_create_master_key()
        aes_key, hmac_key = self._derive_keys(master_key, salt)

        # Verify HMAC
        h = hmac.new(hmac_key, salt + iv + ciphertext, hashlib.sha256)
        expected_tag = h.digest()
        if not hmac.compare_digest(tag, expected_tag):
            raise ValueError("Vault integrity verification failed (bad HMAC tag or incorrect master key)")

        # OpenSSL CLI decryption
        proc = subprocess.run(
            [
                "openssl", "enc", "-d", "-aes-256-cbc",
                "-K", aes_key.hex(),
                "-iv", iv.hex(),
                "-nosalt"
            ],
            input=ciphertext,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True
        )
        return proc.stdout

    def load_data(self) -> Dict[str, Any]:
        if not self.vault_path.exists():
            return {
                "version": 1,
                "global": {},
                "sites": {},
                "backups": {}
            }
        try:
            with open(self.vault_path, "rb") as f:
                payload = f.read()
            if not payload:
                return {"version": 1, "global": {}, "sites": {}, "backups": {}}
            plaintext = self._decrypt_bytes(payload)
            return json.loads(plaintext.decode("utf-8"))
        except Exception as e:
            # If vault exists but cannot be decrypted, return empty dict or raise
            raise RuntimeError(f"Failed to read encrypted vault {self.vault_path}: {e}")

    def save_data(self, data: Dict[str, Any]):
        plaintext = json.dumps(data, indent=2).encode("utf-8")
        encrypted = self._encrypt_bytes(plaintext)
        # Atomic write with temp file
        temp_file = self.vault_path.with_suffix(".tmp")
        with open(temp_file, "wb") as f:
            f.write(encrypted)
        try:
            os.chmod(temp_file, 0o600)
        except OSError:
            pass
        temp_file.replace(self.vault_path)
        try:
            os.chmod(self.vault_path, 0o600)
        except OSError:
            pass

    # ── Site operations ──────────────────────────────────────────────
    def set_site(self, slug: str, site_data: Dict[str, Any]):
        data = self.load_data()
        if "sites" not in data:
            data["sites"] = {}
        data["sites"][slug] = site_data
        self.save_data(data)

    def get_site(self, slug: str) -> Optional[Dict[str, Any]]:
        data = self.load_data()
        return data.get("sites", {}).get(slug)

    def list_sites(self) -> Dict[str, Any]:
        data = self.load_data()
        return data.get("sites", {})

    def delete_site(self, slug: str) -> bool:
        data = self.load_data()
        if "sites" in data and slug in data["sites"]:
            del data["sites"][slug]
            self.save_data(data)
            return True
        return False

    # ── Global operations ────────────────────────────────────────────
    def set_global(self, key: str, value: Any):
        data = self.load_data()
        if "global" not in data:
            data["global"] = {}
        data["global"][key] = value
        self.save_data(data)

    def set_global_batch(self, settings: Dict[str, Any]):
        data = self.load_data()
        if "global" not in data:
            data["global"] = {}
        data["global"].update(settings)
        self.save_data(data)

    def get_global(self, key: Optional[str] = None) -> Any:
        data = self.load_data()
        g = data.get("global", {})
        if key:
            return g.get(key)
        return g

    # ── Export helpers for Bash ──────────────────────────────────────
    def export_site_bash(self, slug: str) -> str:
        site = self.get_site(slug)
        if not site:
            return ""
        lines = []
        for k, v in site.items():
            k_upper = k.upper()
            if isinstance(v, bool):
                v_str = "1" if v else "0"
            elif v is None:
                v_str = ""
            else:
                v_str = str(v).replace("'", "'\\''")
            lines.append(f"export {k_upper}='{v_str}'")
        return "\n".join(lines)

    def export_global_bash(self) -> str:
        g = self.get_global()
        lines = []
        for k, v in g.items():
            k_upper = k.upper()
            if isinstance(v, bool):
                v_str = "1" if v else "0"
            elif v is None:
                v_str = ""
            else:
                v_str = str(v).replace("'", "'\\''")
            lines.append(f"export {k_upper}='{v_str}'")
        return "\n".join(lines)

    # ── Legacy Migration ────────────────────────────────────────────
    def migrate_legacy(self, state_dir: Path = Path("/etc/moodlekit")):
        """Migrate legacy plaintext .conf files into the encrypted vault."""
        migrated = 0
        global_conf = state_dir / "global.conf"
        if global_conf.exists():
            g_data = {}
            with open(global_conf, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        k, v = line.split("=", 1)
                        k = k.strip().lower()
                        v = v.strip().strip('"').strip("'")
                        g_data[k] = v
            if g_data:
                self.set_global_batch(g_data)
                migrated += 1

        sites_dir = state_dir / "sites"
        if sites_dir.exists() and sites_dir.is_dir():
            for conf_file in sites_dir.glob("*.conf"):
                slug = conf_file.stem
                s_data = {}
                with open(conf_file, "r") as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#"):
                            continue
                        if "=" in line:
                            k, v = line.split("=", 1)
                            k = k.strip().lower()
                            v = v.strip().strip('"').strip("'")
                            s_data[k] = v
                if s_data:
                    self.set_site(slug, s_data)
                    migrated += 1

        return migrated

def main():
    parser = argparse.ArgumentParser(description="MoodleKit Encrypted Binary Vault CLI")
    parser.add_argument("--vault-path", help="Path to vault.bin")
    parser.add_argument("--key-path", help="Path to .master.key")
    subparsers = parser.add_subparsers(dest="action", required=True)

    # Global set / get
    p_gset = subparsers.add_parser("gset", help="Set global variable")
    p_gset.add_argument("key")
    p_gset.add_argument("value")

    p_gset_batch = subparsers.add_parser("gset-json", help="Set global variables from JSON")
    p_gset_batch.add_argument("json_data")

    p_gget = subparsers.add_parser("gget", help="Get global variable")
    p_gget.add_argument("key", nargs="?", default=None)

    p_gexport = subparsers.add_parser("gexport", help="Export global variables as bash export statements")

    # Site operations
    p_sset = subparsers.add_parser("sset", help="Set site configuration from JSON")
    p_sset.add_argument("slug")
    p_sset.add_argument("json_data")

    p_sget = subparsers.add_parser("sget", help="Get site configuration as JSON")
    p_sget.add_argument("slug")

    p_sdel = subparsers.add_parser("sdel", help="Delete site configuration")
    p_sdel.add_argument("slug")

    p_slist = subparsers.add_parser("slist", help="List all site slugs")

    p_sexport = subparsers.add_parser("sexport", help="Export site configuration as bash export statements")
    p_sexport.add_argument("slug")

    # All data dump / status
    subparsers.add_parser("dump", help="Dump entire vault as decrypted JSON")
    subparsers.add_parser("status", help="Check vault status")
    subparsers.add_parser("migrate", help="Migrate legacy .conf files into vault")

    args = parser.parse_args()
    vault_p = Path(args.vault_path) if args.vault_path else None
    key_p = Path(args.key_path) if args.key_path else None
    vault = EncryptedVault(vault_p, key_p)

    if args.action == "gset":
        vault.set_global(args.key, args.value)
        print("OK")
    elif args.action == "gset-json":
        data = json.loads(args.json_data)
        vault.set_global_batch(data)
        print("OK")
    elif args.action == "gget":
        val = vault.get_global(args.key)
        if isinstance(val, (dict, list)):
            print(json.dumps(val, indent=2))
        elif val is not None:
            print(val)
        else:
            sys.exit(1)
    elif args.action == "gexport":
        print(vault.export_global_bash())
    elif args.action == "sset":
        data = json.loads(args.json_data)
        vault.set_site(args.slug, data)
        print("OK")
    elif args.action == "sget":
        site = vault.get_site(args.slug)
        if site:
            print(json.dumps(site, indent=2))
        else:
            sys.exit(1)
    elif args.action == "sdel":
        if vault.delete_site(args.slug):
            print("OK")
        else:
            sys.exit(1)
    elif args.action == "slist":
        sites = vault.list_sites()
        for slug in sorted(sites.keys()):
            print(slug)
    elif args.action == "sexport":
        res = vault.export_site_bash(args.slug)
        if res:
            print(res)
        else:
            sys.exit(1)
    elif args.action == "dump":
        print(json.dumps(vault.load_data(), indent=2))
    elif args.action == "status":
        exists = vault.vault_path.exists()
        has_key = vault.key_path.exists()
        sites_count = len(vault.list_sites()) if exists else 0
        print(json.dumps({
            "vault_exists": exists,
            "vault_path": str(vault.vault_path),
            "key_exists": has_key,
            "key_path": str(vault.key_path),
            "managed_sites_count": sites_count
        }, indent=2))
    elif args.action == "migrate":
        count = vault.migrate_legacy()
        print(f"Migrated {count} legacy item(s)")

if __name__ == "__main__":
    main()
