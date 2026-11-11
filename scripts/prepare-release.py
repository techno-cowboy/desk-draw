#!/usr/bin/env python3
"""Build a ZIP and signed Sparkle appcast without publishing either."""
import argparse
import base64
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = "de.haga-welt.DeskDraw"
REPOSITORY = "https://github.com/techno-cowboy/desk-draw"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def prepare(notes: Path, skip_build: bool) -> Path:
    notes = notes.resolve(strict=True)
    if not notes.read_text().strip():
        raise ValueError("Release notes must not be empty")
    if not skip_build:
        run("./scripts/build-app.sh")
    app = ROOT / "build/Desk Draw.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    source = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "SUPublicEDKey", "SUFeedURL"):
        if info.get(key) != source.get(key):
            raise ValueError(f"App does not match Resources/Info.plist: {key}; rebuild first")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not build.isdigit() or not all(part.isdigit() for part in version.split(".")):
        raise ValueError("Use a numeric build number and stable numeric release version")
    if len(base64.b64decode(info["SUPublicEDKey"], validate=True)) != 32:
        raise ValueError("Invalid Sparkle public key")
    key = run("./scripts/sparkle-tool.sh", "generate_keys", "--account", ACCOUNT, "-p",
              capture_output=True, text=True).stdout.strip()
    if key != info["SUPublicEDKey"]:
        raise ValueError("Keychain signing key does not match the app's SUPublicEDKey")
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("Signed feeds and verification before extraction must be enabled")
    run("codesign", "--verify", "--deep", "--strict", str(app))

    feed = ROOT / "appcast.xml"
    if feed.exists():
        published_builds = [int(item.text) for item in ET.parse(feed).iter(f"{SPARKLE}version")]
        if published_builds and int(build) <= max(published_builds):
            raise ValueError("Build number must exceed every published appcast version")
    releases = ROOT / "build/releases"
    releases.mkdir(parents=True, exist_ok=True)
    destination = releases / f"v{version}"
    if destination.exists():
        raise ValueError(f"Already prepared: {destination}; preserve published bytes or remove an unpublished preparation first")
    with tempfile.TemporaryDirectory(prefix=".prepare-", dir=releases) as temporary:
        stage = Path(temporary)
        name = f"Desk-Draw-{version}"
        archive = stage / f"{name}.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
        shutil.copyfile(notes, stage / f"{name}.md")
        if feed.exists():
            shutil.copyfile(feed, stage / "appcast.xml")
        run("./scripts/sparkle-tool.sh", "generate_appcast", "--account", ACCOUNT,
            "--versions", build, "--maximum-deltas", "0", "--maximum-versions", "0",
            "--download-url-prefix", f"{REPOSITORY}/releases/download/v{version}/",
            "--link", REPOSITORY, "--embed-release-notes", str(stage))
        generated_feed = stage / "appcast.xml"
        run("./scripts/sparkle-tool.sh", "sign_update", "--account", ACCOUNT, "--verify", str(generated_feed))
        item = next(item for item in ET.parse(generated_feed).iter("item")
                    if item.findtext(f"{SPARKLE}version") == build)
        enclosure = item.find("enclosure")
        if enclosure is None or int(enclosure.attrib["length"]) != archive.stat().st_size:
            raise ValueError("Appcast archive length mismatch")
        expected_url = f"{REPOSITORY}/releases/download/v{version}/{archive.name}"
        if enclosure.attrib["url"] != expected_url:
            raise ValueError("Unexpected archive URL in appcast")
        run("./scripts/sparkle-tool.sh", "sign_update", "--account", ACCOUNT, "--verify",
            str(archive), enclosure.attrib[f"{SPARKLE}edSignature"])
        # Keep only shipping files. Extracted bundles, delta files, and old archives must not be published.
        for path in list(stage.iterdir()):
            if path.name not in {archive.name, generated_feed.name}:
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
        shutil.copyfile(notes, stage / "release-notes.md")
        checksums = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
                            for path in sorted(stage.iterdir()) if path.is_file())
        (stage / "SHA256SUMS").write_text(checksums)
        stage.rename(destination)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("notes", type=Path, help="Markdown release notes to embed in the signed feed")
    parser.add_argument("--skip-build", action="store_true", help="Use the existing matching app bundle")
    arguments = parser.parse_args()
    try:
        print(f"Prepared release: {prepare(arguments.notes, arguments.skip_build)}")
        print("Publish the ZIP before copying its signed appcast.xml to the repository root.")
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as error:
        parser.exit(1, f"Release preparation failed: {error}\n")
