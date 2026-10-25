#!/usr/bin/env python3
"""Qualify legacy Omarchy Color references without changing Qt or GPU packages."""
import argparse
from pathlib import Path
import re
import shutil

REFERENCE = re.compile(r"(?<![\w.])Color\.")
IMPORT = re.compile(r"^import qs\.Commons(?:\s+\d+(?:\.\d+)?)?\s*$", re.MULTILINE)
ALIAS = "CachyOmarchyPalette"


def patched_text(path, text):
    if not REFERENCE.search(text):
        return text
    match = IMPORT.search(text)
    if match:
        module = match.group().strip().removeprefix("import ")
    elif path.parent.name == "Commons" and (path.parent / "qmldir").is_file():
        if not re.search(r"^singleton Color\s", (path.parent / "qmldir").read_text(), re.MULTILINE):
            return text
        module = "qs.Commons"
    else:
        # Do not rewrite unrelated QML Color types or already-qualified imports.
        return text
    if re.search(rf"\bas\s+{ALIAS}\b", text):
        raise ValueError(f"Reserved import alias already exists: {path}")
    result = REFERENCE.sub(f"{ALIAS}.Color.", text)
    return re.sub(r"^import ", f"import {module} as {ALIAS}\nimport ", result, count=1, flags=re.MULTILINE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Omarchy shell directory or user plugin directory")
    parser.add_argument("--apply", action="store_true", help="write changes (default: preview only)")
    parser.add_argument("--backup-dir", type=Path, help="new directory outside root; required with --apply")
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir():
        parser.error(f"not a directory: {root}")
    changes = []
    for path in sorted(root.rglob("*.qml")):
        if path.is_symlink() or root not in path.resolve().parents:
            continue
        old = path.read_text()
        new = patched_text(path, old)
        if old != new:
            changes.append((path, new))
    if args.apply:
        if args.backup_dir is None:
            parser.error("--apply requires --backup-dir")
        backup = args.backup_dir.resolve()
        if backup == root or root in backup.parents:
            parser.error("backup directory must be outside the patched tree")
        if changes:
            # Never overwrite an earlier backup. Save every original before editing.
            backup.mkdir(parents=True, exist_ok=False)
            for path, _ in changes:
                target = backup / path.relative_to(root)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
            for path, new in changes:
                path.write_text(new)
    for path, _ in changes:
        print(path.relative_to(root))
    print(f"{'Patched' if args.apply else 'Would patch'} {len(changes)} file(s).")


if __name__ == "__main__":
    main()
