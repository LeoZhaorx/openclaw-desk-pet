#!/usr/bin/env python3
"""Fail when the Git index contains files that are unsafe to publish."""

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAX_GITHUB_FILE_BYTES = 100 * 1024 * 1024
WARN_FILE_BYTES = 50 * 1024 * 1024
FORBIDDEN_PARTS = {".DS_Store", ".build", "__MACOSX", "media-backup", "media-original"}
FORBIDDEN_SUFFIXES = {".log", ".pid", ".zip", ".pem", ".p12"}
TEXT_SECRET_PATTERNS = {
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"),
    "OpenAI-style key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    "personal macOS path": re.compile(r"/(?:Users/leo|Volumes/AI CodeX)(?:/|\b)"),
    "private quick prompt": re.compile(r"给慢慢发短信"),
}


def tracked_files():
    result = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True
    )
    return [ROOT / item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def main() -> int:
    errors = []
    warnings = []
    for path in tracked_files():
        relative = path.relative_to(ROOT)
        parts = set(relative.parts)
        if parts & FORBIDDEN_PARTS:
            errors.append(f"forbidden tracked path: {relative}")
        if path.suffix.lower() in FORBIDDEN_SUFFIXES:
            errors.append(f"forbidden tracked file type: {relative}")
        if path.name == ".desk-sprite.env":
            errors.append(f"private environment file is tracked: {relative}")
        if not path.is_file():
            continue
        size = path.stat().st_size
        if size > MAX_GITHUB_FILE_BYTES:
            errors.append(f"file exceeds GitHub's 100 MiB limit: {relative} ({size} bytes)")
        elif size > WARN_FILE_BYTES:
            warnings.append(f"large binary should remain stable or move to Git LFS: {relative} ({size} bytes)")

        sample = path.read_bytes()
        if b"\0" in sample[:8192]:
            continue
        try:
            text = sample.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if relative == Path("scripts/check_release.py"):
            continue
        for label, pattern in TEXT_SECRET_PATTERNS.items():
            if pattern.search(text):
                errors.append(f"{label} found in {relative}")

    for warning in warnings:
        print(f"WARNING: {warning}")
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"Release audit passed for {len(tracked_files())} tracked files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
