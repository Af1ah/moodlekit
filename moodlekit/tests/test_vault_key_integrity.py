#!/usr/bin/env python3
"""Regression tests for binary vault master-key handling."""

import tempfile
from pathlib import Path
import sys

LIB_DIR = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB_DIR))

from vault import EncryptedVault  # noqa: E402


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        vault_path = root / "vault.bin"
        key_path = root / ".master.key"

        # Leading/trailing ASCII whitespace bytes are valid key material and
        # must survive reopening unchanged.
        binary_key = b"\n" + (b"k" * 30) + b"\t"
        key_path.write_bytes(binary_key)
        vault = EncryptedVault(vault_path, key_path)
        vault.set_global("timezone", "Etc/UTC")
        reopened = EncryptedVault(vault_path, key_path)
        assert reopened.get_global("timezone") == "Etc/UTC"
        assert key_path.read_bytes() == binary_key

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        vault_path = root / "vault.bin"
        key_path = root / ".master.key"
        key_path.write_bytes(b"short")
        vault = EncryptedVault(vault_path, key_path)
        try:
            vault.set_global("x", "y")
        except RuntimeError as exc:
            assert "Refusing to replace" in str(exc)
        else:
            raise AssertionError("invalid existing key was silently replaced")
        assert key_path.read_bytes() == b"short"

    print("PASS: binary vault keys are preserved and invalid keys fail closed")


if __name__ == "__main__":
    main()
