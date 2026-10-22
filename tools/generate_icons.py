"""Generate Dayflow's original geometric application mark. Requires Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw
import json

CLIENT = Path(__file__).resolve().parents[1] / "client"
image = Image.new("RGBA", (1024, 1024), (92, 111, 232, 255))
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((235, 240, 789, 344), radius=32, fill="white")
draw.rounded_rectangle((235, 435, 789, 539), radius=32, fill=(255, 255, 255, 200))
draw.rounded_rectangle((235, 630, 570, 734), radius=32, fill=(255, 255, 255, 150))


def png(path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(path)


for size in (192, 512):
    png(CLIENT / "web" / "icons" / f"Icon-{size}.png", size)
    png(CLIENT / "web" / "icons" / f"Icon-maskable-{size}.png", size)
png(CLIENT / "web" / "favicon.png", 64)
image.save(CLIENT / "windows" / "runner" / "resources" / "app_icon.ico", format="ICO",
           sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
for folder, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
    png(CLIENT / "android" / "app" / "src" / "main" / "res" / f"mipmap-{folder}" / "ic_launcher.png", size)
icons = CLIENT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
for item in json.loads((icons / "Contents.json").read_text())["images"]:
    if "filename" in item:
        size = round(float(item["size"].split("x")[0]) * float(item["scale"].replace("x", "")))
        # iOS application icons require RGB without an alpha channel.
        image.convert("RGB").resize((size, size), Image.Resampling.LANCZOS).save(icons / item["filename"])
print("Dayflow icons generated.")
