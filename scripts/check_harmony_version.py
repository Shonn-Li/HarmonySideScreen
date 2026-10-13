#!/usr/bin/env python3
"""Check that one Harmony Side Screen release version identifies all app metadata."""
import json
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def main():
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("VERSION must contain a semantic release version.")
    app = json.loads((ROOT / "HarmonyClient/AppScope/app.json5").read_text())["app"]
    plist = plistlib.loads((ROOT / "MacHost/Info.plist").read_bytes())
    versions = {
        "Harmony app": app["versionName"],
        "Mac short version": plist["CFBundleShortVersionString"],
        "Mac build version": plist["CFBundleVersion"],
    }
    for name in ("HarmonyClient/oh-package.json5", "HarmonyClient/entry/oh-package.json5"):
        versions[name] = json.loads((ROOT / name).read_text())["version"]
    record = json.loads((ROOT / f"docs/versions/{version}.json").read_text())
    versions["version record"] = record["version"]
    errors = [f"{name}: {value} != {version}" for name, value in versions.items() if value != version]
    if record["tag"] != f"v{version}-preview.1":
        errors.append("Record tag must identify the intended first preview of this version.")
    if not isinstance(app["versionCode"], int) or app["versionCode"] < 1:
        errors.append("Harmony versionCode must be positive.")
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Harmony Side Screen {version}: app versions and record agree.")

if __name__ == "__main__":
    main()
