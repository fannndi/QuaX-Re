import cairosvg
import os
from pathlib import Path
from PIL import Image

BACKGROUND_COLOR = "#080808"

def generate_icon_png(svg_file):
    output_file = svg_file.replace('.svg', '.png')
    cairosvg.svg2png(
        url=svg_file,
        write_to=output_file,
        output_width=2000,
        output_height=2000,
        background_color=BACKGROUND_COLOR
    )
    print("Generated", output_file)

def generate_adaptive_foreground(svg_file):
    base_name = os.path.splitext(svg_file)[0]
    output_file = f"{base_name}-foreground-432x432.png"
    
    cairosvg.svg2png(
        url=svg_file,
        write_to=output_file,
        output_width=432,
        output_height=432,
    )
    print("Generated", output_file)

def generate_adaptive_monochrome(svg_file):
    base_name = os.path.splitext(svg_file)[0]
    output_file = f"{base_name}-monochrome-432x432.png"

    cairosvg.svg2png(
        url=svg_file,
        write_to=output_file,
        output_width=432,
        output_height=432,
    )
    img = Image.open(output_file).convert("RGBA")
    mono_img = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    for x in range(432):
        for y in range(432):
            r, g, b, a = img.getpixel((x, y))
            if a > 0:
                mono_img.putpixel((x, y), (255, 255, 255, a))

    mono_img.save(output_file, "PNG")
    print("Generated", output_file)

def generate_adaptive_background(svg_file):
    base_name = os.path.splitext(svg_file)[0]
    output_file = f"{base_name}-background.png"

    img = Image.new("RGB", (432, 432), BACKGROUND_COLOR)
    img.save(output_file, "PNG")
    print("Generated", output_file)

def main():
    svg_file = str(Path(__file__).parent / "assets" / "icon.svg")
    generate_icon_png(svg_file)
    generate_adaptive_foreground(svg_file)
    generate_adaptive_monochrome(svg_file)
    generate_adaptive_background(svg_file)
    
if __name__ == "__main__":
    main()