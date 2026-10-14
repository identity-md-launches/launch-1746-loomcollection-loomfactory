#!/usr/bin/env python3
"""Export deterministic ABI arrays from local Forge artifacts, or check committed exports."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if an ABI export is absent or stale")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    mismatches = []
    for name in ("LaunchToken", "LoomCollection", "LoomFactory"):
        artifact = root / "out" / f"{name}.sol" / f"{name}.json"
        if not artifact.is_file():
            parser.error(f"missing {artifact.relative_to(root)}; run forge build first")
        abi = json.loads(artifact.read_text())["abi"]
        exported = json.dumps(abi, indent=2) + "\n"
        destination = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not destination.is_file() or destination.read_text() != exported:
                mismatches.append(str(destination.relative_to(root)))
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(exported)
            print(destination.relative_to(root))
    if mismatches:
        parser.error("stale or missing ABI exports: " + ", ".join(mismatches))
    if args.check:
        print("All three ABI exports match the local build artifacts.")


if __name__ == "__main__":
    main()
