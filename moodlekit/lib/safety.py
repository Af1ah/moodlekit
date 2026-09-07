#!/usr/bin/env python3
"""Read-only validation helpers for MoodleKit backup and archive inputs."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import sys
import tarfile
from pathlib import Path, PurePosixPath


SUPPORTED_DB_TYPES = {"postgres", "mariadb", "mysql"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_tar(path: Path) -> None:
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError(f"archive is empty: {path}")
        for member in members:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise ValueError(f"unsafe archive path in {path.name}: {member.name}")
            if member.issym() or member.islnk():
                target = PurePosixPath(member.linkname)
                if target.is_absolute() or ".." in target.parts:
                    raise ValueError(
                        f"unsafe archive link in {path.name}: {member.name} -> {member.linkname}"
                    )
            if member.isdev() or member.isfifo():
                raise ValueError(f"unsafe special file in {path.name}: {member.name}")


def validate_bundle(path: Path) -> dict:
    manifest_path = path / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"manifest.json not found in {path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("manifest.json must contain an object")

    required = ("db_type", "moodle_version", "php_version")
    missing = [key for key in required if not str(manifest.get(key, "")).strip()]
    if missing:
        raise ValueError("manifest is missing required fields: " + ", ".join(missing))
    if manifest["db_type"] not in SUPPORTED_DB_TYPES:
        raise ValueError(f"unsupported database type: {manifest['db_type']}")

    artifacts = []
    checksums = manifest.get("checksums") or {}
    if not isinstance(checksums, dict):
        raise ValueError("manifest checksums must be an object")
    for name, expected in checksums.items():
        if not expected:
            continue
        artifact = path / name
        if not artifact.is_file():
            raise ValueError(f"checksummed artifact is missing: {name}")
        actual = sha256(artifact)
        if actual.lower() != str(expected).lower():
            raise ValueError(f"checksum mismatch for {name}")
        artifacts.append(name)

    dump = path / "database.sql.gz"
    if not dump.is_file():
        raise ValueError("required database.sql.gz is missing")
    if dump.stat().st_size == 0:
        raise ValueError("database.sql.gz is empty")
    with gzip.open(dump, "rb") as stream:
        while stream.read(1024 * 1024):
            pass

    for name in ("moodledata.tar.gz", "code.tar.gz"):
        archive = path / name
        if archive.is_file():
            validate_tar(archive)
            artifacts.append(name)

    return {
        "db_type": manifest["db_type"],
        "moodle_version": str(manifest["moodle_version"]),
        "php_version": str(manifest["php_version"]),
        "verified_artifacts": sorted(set(artifacts)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    bundle = sub.add_parser("validate-backup")
    bundle.add_argument("path")
    archive = sub.add_parser("validate-archive")
    archive.add_argument("path")
    args = parser.parse_args()
    try:
        path = Path(args.path).resolve(strict=True)
        if args.command == "validate-backup":
            if not path.is_dir():
                raise ValueError(f"backup path is not a directory: {path}")
            print(json.dumps(validate_bundle(path), separators=(",", ":")))
        else:
            validate_tar(path)
            print(json.dumps({"archive": os.fspath(path), "status": "valid"}))
        return 0
    except (OSError, ValueError, json.JSONDecodeError, tarfile.TarError, gzip.BadGzipFile) as exc:
        print(f"backup validation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
