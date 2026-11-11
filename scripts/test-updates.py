#!/usr/bin/env python3
"""Exercise real Sparkle installation and tampering rejection using disposable apps and localhost."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import plistlib
import os
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
FRAMEWORKS = ROOT / "build/Desk Draw.app/Contents/Frameworks"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, cwd=ROOT, **kwargs)


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def exercise(binary: Path, mode: str):
    with tempfile.TemporaryDirectory(prefix="desk-draw-update-test-") as directory:
        root = Path(directory)
        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=directory))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://localhost:{server.server_port}/"
            app = root / "Installed/Update Test.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            shutil.copyfile(binary, app / "Contents/MacOS/UpdateFixture")
            (app / "Contents/MacOS/UpdateFixture").chmod(0o755)
            shutil.copytree(FRAMEWORKS, app / "Contents/Frameworks", symlinks=True)
            source = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
            info = {key: value for key, value in source.items() if key.startswith("SU")}
            bundle_id = f"de.haga-welt.DeskDraw.UpdateTest.{uuid.uuid4().hex}"
            result = root / "result.txt"
            info.update({
                "CFBundleIdentifier": bundle_id,
                "CFBundleName": "Desk Draw Update Test",
                "CFBundleExecutable": "UpdateFixture",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "0.0.1",
                "LSMinimumSystemVersion": "14.0",
                "LSUIElement": True,
                "SUFeedURL": url + "appcast.xml",
                "DeskDrawTestOutput": str(result),
                # Only the disposable fixture permits HTTP. Production uses HTTPS exclusively.
                "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
            })
            plist = app / "Contents/Info.plist"
            plist.write_bytes(plistlib.dumps(info))
            signing_env = dict(os.environ, DESKDRAW_SIGN_IDENTITY="-")
            run("./scripts/sign-app.sh", str(app), env=signing_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            newer = root / "New/Update Test.app"
            shutil.copytree(app, newer, symlinks=True)
            newer_info = dict(info, CFBundleVersion="2", CFBundleShortVersionString="0.0.2")
            (newer / "Contents/Info.plist").write_bytes(plistlib.dumps(newer_info))
            run("./scripts/sign-app.sh", str(newer), env=signing_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            archive = root / "Update.zip"
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(newer), str(archive))
            run("./scripts/sparkle-tool.sh", "generate_appcast", "--account", "de.haga-welt.DeskDraw",
                "--download-url-prefix", url, "--maximum-deltas", "0", str(root), stdout=subprocess.DEVNULL)
            if mode == "bad-feed":
                feed = root / "appcast.xml"
                feed.write_bytes(feed.read_bytes().replace(b"<title>", b"<title>tampered ", 1))
            elif mode == "bad-archive":
                data = bytearray(archive.read_bytes())
                data[-1] ^= 1  # Keep the length unchanged; the signed bytes must be checked.
                archive.write_bytes(data)
            if mode == "valid":
                for smoke in ("--smoke-updater", "--smoke-opt-out"):
                    run(str(app / "Contents/MacOS/UpdateFixture"), smoke, timeout=15)
            started = time.monotonic()
            # Direct launch keeps stdout out of the user's desktop. Sparkle performs its real helper install/relaunch.
            with (root / "fixture.log").open("w") as log:
                process = subprocess.Popen([str(app / "Contents/MacOS/UpdateFixture")], stdout=log, stderr=log)
                try:
                    while not result.exists() and time.monotonic() - started < 50:
                        time.sleep(0.1)
                    value = result.read_text() if result.exists() else "no result"
                    installed = plistlib.loads(plist.read_bytes())["CFBundleVersion"]
                    if mode == "valid":
                        assert value == "installed" and installed == "2", (value, installed, (root / "fixture.log").read_text())
                    else:
                        assert value.startswith("rejected:") and installed == "1", (value, installed, (root / "fixture.log").read_text())
                    print(f"PASS {mode}: {value.split(':')[0]}, bundle build {installed}", flush=True)
                    process.wait(timeout=5)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
                    # Clean the test's isolated Sparkle defaults; no real app preferences are touched.
                    subprocess.run(["defaults", "delete", bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    binary = ROOT / "build/UpdateFixture"
    run("swiftc", "-swift-version", "5", "-target", "arm64-apple-macos14.0", "-F", str(FRAMEWORKS),
        "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "Sources/DeskDraw/AppUpdater.swift", "Tests/UpdateFixture/main.swift", "-o", str(binary))
    for mode in ("valid", "bad-feed", "bad-archive"):
        exercise(binary, mode)
