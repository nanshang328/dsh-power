"""Build the button icon for dsh-power from the user's illustration.

Source of truth:  dsh-power/client/niang-sleep.png   (whatever the user drops there)
Usage:            python tools/build-icon.py

It only *measures* candidate encodings so we can pick one that keeps the widget
small; the actual data-URI injection is done by tools/embed-icon.cjs.
"""
import os
import shutil
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
CLIENT = os.path.join(PLUGIN, "client")
TARGET = os.path.join(CLIENT, "niang-sleep.png")
SOURCE = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\21155\Desktop\shuijiao.png"
OUT = os.path.join(PLUGIN, "_icon-build")

os.makedirs(CLIENT, exist_ok=True)
os.makedirs(OUT, exist_ok=True)

if os.path.abspath(SOURCE) != os.path.abspath(TARGET):
    shutil.copyfile(SOURCE, TARGET)

im = Image.open(TARGET)
print("source      :", TARGET)
print("size        :", im.size, "mode", im.mode, "bytes", os.path.getsize(TARGET))
print("aspect      : %.4f" % (im.width / im.height))

rgb = im.convert("RGB")
rows = []
for width in (256, 384, 512):
    height = max(1, round(width * im.height / im.width))
    resized = rgb.resize((width, height), Image.LANCZOS)
    for ext, kw in (("png", {"optimize": True}), ("webp", {"quality": 86, "method": 6})):
        path = os.path.join(OUT, "niang-%d.%s" % (width, ext))
        resized.save(path, **kw)
        size = os.path.getsize(path)
        rows.append((os.path.basename(path), "%dx%d" % (width, height), size, round(size * 4 / 3)))

print()
print("%-22s %-10s %9s %10s" % ("file", "pixels", "bytes", "b64 chars"))
for name, pixels, size, b64 in sorted(rows, key=lambda r: r[2]):
    print("%-22s %-10s %9d %10d" % (name, pixels, size, b64))

# The one the widget actually inlines: 512px wide (3.2x the 160px chip, so it
# stays sharp on HiDPI) WebP (40 KB base64 vs 267 KB for the PNG).
FINAL = os.path.join(CLIENT, "niang-sleep.webp")
rgb.resize((512, max(1, round(512 * im.height / im.width))), Image.LANCZOS).save(
    FINAL, "webp", quality=86, method=6
)
print()
print("embedded icon :", FINAL, os.path.getsize(FINAL), "bytes")
print("next          : node tools/embed-icon.cjs")