#!/usr/bin/env python3
"""Builds the pictures in docs/images from HTML with headless Chrome.

    python3 scripts/build-images.py

The app's screenshots are docs/images/screen-*.png (taken in the simulator).
Replace one and run again to get it into the banner and the phone frames.
"""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMAGES = ROOT / "docs" / "images"
ICON = ROOT / "OnYourMarks" / "Resources" / "onyourmarks_icon.png"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

COPY = {
    "tagline": "The starter in your pocket.",
    "sub": "Start commands, the gun and false-start detection for sprint training. All you need is your iPhone.",
    "states": ("On your marks", "Set", "Go"),
    "hold": "random hold",
}

CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { width: 100%; height: 100%; overflow: hidden; }
body {
  font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif;
  color: white; -webkit-font-smoothing: antialiased;
}
.track {
  position: absolute; inset: 0;
  background:
    radial-gradient(circle at 30% 24%, rgba(255,255,255,.2), rgba(255,255,255,0) 47%),
    linear-gradient(135deg, #FF8A3D 0%, #FB5236 55%, #DE2B3E 100%);
}
.lanes { position: absolute; left: 0; right: 0; bottom: 0; width: 100%; height: 26%; }
.content { position: absolute; inset: 0; }
h1 { font-weight: 800; letter-spacing: -0.02em; line-height: 1.04; }
p { font-weight: 500; line-height: 1.3; opacity: .94; }
.yellow { color: #FFD23F; }
.icon { border-radius: 22.5%; box-shadow: 0 .06em .25em rgba(90,10,20,.35); display: block; }
.brand { display: flex; align-items: center; gap: .45em; font-weight: 800; letter-spacing: -0.02em; }
.phone {
  position: relative; border-radius: 13.5% / 6.2%; background: #1c1c1e; padding: 2.6%;
  box-shadow: 0 30px 80px rgba(80,0,20,.45), 0 0 0 2px rgba(255,255,255,.18) inset;
}
.phone img { display: block; width: 100%; border-radius: 11.5% / 5.3%; }
.card {
  background: rgba(60,20,20,.26); border-radius: 36px; position: relative; overflow: hidden;
  box-shadow: 0 0 0 2px rgba(255,255,255,.14) inset;
}
.pill {
  display: inline-flex; align-items: center; gap: .5em; padding: .5em 1em; border-radius: 99em;
  background: #FF3B30; font-weight: 700; box-shadow: 0 8px 24px rgba(120,0,0,.35);
}
.chip {
  padding: .55em 1.05em; border-radius: .6em; font-weight: 700; background: rgba(255,255,255,.2);
  box-shadow: 0 0 0 2px rgba(255,255,255,.3) inset; white-space: nowrap;
}
.chip.go { background: #FFD23F; color: #2b2320; box-shadow: none; }
.hold { flex: 1; display: flex; flex-direction: column; align-items: center; gap: .35em; font-size: .62em; font-weight: 600; opacity: .9; min-width: 3em; text-align: center; }
.hold i { display: block; width: 100%; border-top: .22em dashed rgba(255,255,255,.75); }
.dash { width: 1.4em; border-top: .16em solid rgba(255,255,255,.75); }
"""

LANES = """<svg class="lanes" viewBox="0 0 1000 260" preserveAspectRatio="none">
<g fill="none" stroke="white" stroke-opacity=".13" stroke-width="5" stroke-linecap="round">
<path d="M-20,40 Q500,-10 1020,40"/><path d="M-20,110 Q500,60 1020,110"/>
<path d="M-20,180 Q500,130 1020,180"/><path d="M-20,250 Q500,200 1020,250"/></g></svg>"""


def sequence(copy, size):
    a, b, c = copy["states"]
    return f"""<div style="display:flex;align-items:center;gap:.5em;font-size:{size}px;width:100%">
<span class="chip">{a}</span><span class="dash"></span><span class="chip">{b}</span>
<span class="hold"><i></i>{copy["hold"]}</span><span class="chip go">{c}</span></div>"""


def brand(size):
    return f'<div class="brand" style="font-size:{size}px"><img class="icon" src="{ICON.as_uri()}" style="width:1.5em;height:1.5em">OnYourMarks</div>'


def phone(shot, width):
    return f'<div class="phone" style="width:{width}px"><img src="{(IMAGES / f"screen-{shot}.png").as_uri()}"></div>'


def page(body, background=True):
    track = f'<div class="track"></div>{LANES}' if background else ""
    return f'<!DOCTYPE html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body>{track}<div class="content">{body}</div></body></html>'


def wide(w, h):
    """The banner: text left, two phones right."""
    c = COPY
    u = h / 630
    return page(f"""
<div style="position:absolute;left:{70*u}px;top:{64*u}px">{brand(34*u)}</div>
<div style="position:absolute;left:{70*u}px;top:{190*u}px;width:{w*0.5}px">
  <h1 style="font-size:{76*u}px">{c["tagline"]}</h1>
  <p style="font-size:{27*u}px;margin-top:{26*u}px;max-width:{560*u}px">{c["sub"]}</p>
  <div style="margin-top:{40*u}px;max-width:{560*u}px">{sequence(c, 21*u)}</div>
</div>
<div style="position:absolute;right:{250*u}px;top:{110*u}px;transform:rotate(-5deg)">{phone("review-athlete", 250*u)}</div>
<div style="position:absolute;right:{50*u}px;top:{50*u}px;transform:rotate(4deg)">{phone("starter", 270*u)}</div>
""")


def plain(body):
    return page(f'<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center">{body}</div>', background=False)


def render(html, path, w, h, transparent=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as file:
        file.write(html)
    arguments = [
        CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
        f"--window-size={int(w)},{int(h)}", f"--screenshot={path}", "--allow-file-access-from-files",
    ]
    if transparent:
        arguments.append("--default-background-color=00000000")
    subprocess.run(arguments + [Path(file.name).as_uri()], check=True, capture_output=True)
    Path(file.name).unlink()
    print(path.relative_to(ROOT), f"{int(w)}x{int(h)}")


def main():
    render(wide(1280, 640), IMAGES / "banner.png", 1280, 640)

    for shot in ["starter", "settings", "review-athlete"]:
        render(plain(phone(shot, 480)), IMAGES / f"phone-{shot}.png", 600, 1140, transparent=True)


if __name__ == "__main__":
    main()
