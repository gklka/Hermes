#!/usr/bin/env python3
"""Takes the website's screenshots (docs/images) from the app in demo mode.

    capture.py <Hermes.app> [scene …]

Builds the sample chats (make-demo.py) in a temporary folder, launches the app on them
(`-DemoData`, see App/Util/DemoMode.swift), stages each scene (DemoDirector's commands), captures
the app's windows one by one (screencapture, which needs the Screen Recording permission) and
puts them together with their shadows on a transparent background. The app comes to the front
while it runs; it's quit at the end.
"""
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "docs", "images")

EMMA, GROUP, NOAH, MIA = "201", "301", "202", "203"
MAIN = ["closewindows", "filter all", "size 1120 780", "sidebar 300"]

# name: commands (see DemoDirector.run).
SCENES = {
    "hero-light": ["appearance light", *MAIN, f"select {EMMA}", "wait 1500", f"typing {EMMA} {EMMA}"],
    "hero-dark": ["appearance dark", *MAIN, f"select {GROUP}", "wait 1500"],
    "tapbacks": ["appearance light", *MAIN, f"select {EMMA}", "wait 1500", "tapback m6"],
    "find": ["appearance light", *MAIN, f"select {GROUP}", "wait 1000", "find trail"],
    "calls": ["appearance dark", *MAIN, f"select {NOAH}", "wait 1500", f"call {NOAH}"],
    "cards": ["appearance light", *MAIN, f"select {MIA}", "wait 1500"],
    "requests": ["appearance light", *MAIN, "filter requests", "wait 1000", "select 212"],
    "window": ["appearance light", *MAIN, f"select {EMMA}", f"window {GROUP}", "wait 300", "size 540 720"],
    "members": ["appearance dark", *MAIN, f"select {GROUP}", "wait 1000", "members"],
    "edits": ["appearance light", *MAIN, f"select {EMMA}", "wait 1000", "edits m8"],
}


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def wait_for(path, seconds=30):
    for _ in range(seconds * 10):
        if os.path.exists(path):
            return True
        time.sleep(0.1)
    return False


def windows(tool, pid):
    found = [json.loads(line) for line in run([tool, str(pid)]).splitlines() if line.strip()]
    # Real windows: not the menu bar's or the invisible ones.
    return [w for w in found if w["alpha"] > 0 and w["width"] > 40 and w["height"] > 40 and w["layer"] < 100]


def shadow_for(window, scale):
    """A window's shadow like macOS's: large and soft for windows, smaller for popovers."""
    big = window["width"] > 320 and window["height"] > 240
    return (36 if big else 14) * scale, (0.45 if big else 0.25), (16 if big else 4) * scale


def compose(shots, scale, path):
    pad = 70 * scale
    left = min(w["x"] for w, _ in shots) * scale - pad
    top = min(w["y"] for w, _ in shots) * scale - pad
    right = max(w["x"] + w["width"] for w, _ in shots) * scale + pad
    bottom = max(w["y"] + w["height"] for w, _ in shots) * scale + pad
    canvas = Image.new("RGBA", (int(right - left), int(bottom - top)), (0, 0, 0, 0))
    # Back to front.
    for window, image in reversed(shots):
        x = int(window["x"] * scale - left)
        y = int(window["y"] * scale - top)
        if window.get("region"):
            # Already with its shadow, over its window.
            canvas.alpha_composite(image, (x, y))
            continue
        blur, opacity, offset = shadow_for(window, scale)
        alpha = image.getchannel("A").point(lambda a: int(a * opacity))
        shadow = Image.new("RGBA", image.size, (0, 0, 0, 255))
        shadow.putalpha(alpha)
        layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        layer.paste(shadow, (x, int(y + offset)))
        layer = layer.filter(ImageFilter.GaussianBlur(blur / 2))
        canvas = Image.alpha_composite(canvas, layer)
        canvas.alpha_composite(image, (x, y))
    # WebP keeps the transparency at a fraction of PNG's size.
    canvas.save(path, quality=88, method=6)


def main():
    app = os.path.abspath(sys.argv[1])
    names = sys.argv[2:] or list(SCENES)
    os.makedirs(OUT, exist_ok=True)
    work = tempfile.mkdtemp(prefix="hermes-demo-")
    data = os.path.join(work, "data")
    run([sys.executable, os.path.join(HERE, "make-demo.py"), data])
    tool = os.path.join(work, "windows")
    run(["xcrun", "swiftc", "-O", os.path.join(HERE, "windows.swift"), "-o", tool])

    # The demo copy's own settings (window frames, toolbar) start fresh.
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        bundle_id = plistlib.load(f)["CFBundleIdentifier"]
    subprocess.run(["defaults", "delete", bundle_id], capture_output=True)
    subprocess.run(["open", "-n", app, "--args", "-DemoData", data, "-ApplePersistenceIgnoreState", "YES"], check=True)
    pid = None
    for _ in range(100):
        out = subprocess.run(["pgrep", "-f", f"DemoData {data}"], capture_output=True, text=True).stdout.split()
        if out:
            pid = int(out[0])
            break
        time.sleep(0.1)
    if not pid:
        sys.exit("The app didn't start")
    time.sleep(3)
    try:
        for name in names:
            done = os.path.join(data, "done")
            if os.path.exists(done):
                os.remove(done)
            subprocess.run(["open", app], check=True)
            with open(os.path.join(data, "command.tmp"), "w") as f:
                f.write("\n".join(SCENES[name]) + "\n")
            os.rename(os.path.join(data, "command.tmp"), os.path.join(data, "command"))
            if not wait_for(done):
                print(f"{name}: timed out")
                continue
            shots = []
            scale = 1
            for i, window in enumerate(windows(tool, pid)):
                if os.environ.get("DEBUG"):
                    print(window)
                file = os.path.join(work, f"{name}-{i}.png")
                subprocess.run(["screencapture", "-x", "-o", f"-l{window['id']}", file], check=True)
                image = Image.open(file).convert("RGBA")
                if image.width / window["width"] not in (1, 2, 3):
                    # A popover or sheet comes out as its parent window: take what's on screen
                    # there instead (it's over that window, which is what's around it).
                    region = f"-R{window['x']},{window['y']},{window['width']},{window['height']}"
                    subprocess.run(["screencapture", "-x", region, file], check=True)
                    image = Image.open(file).convert("RGBA")
                    window["region"] = True
                scale = image.width / window["width"]
                if os.environ.get("DEBUG"):
                    print(file, image.size)
                shots.append((window, image))
            if not shots:
                print(f"{name}: no windows")
                continue
            path = os.path.join(OUT, f"{name}.webp")
            compose(shots, scale, path)
            print(f"{name}: {len(shots)} windows → {os.path.relpath(path, ROOT)}")
    finally:
        subprocess.run(["kill", str(pid)])


if __name__ == "__main__":
    main()
