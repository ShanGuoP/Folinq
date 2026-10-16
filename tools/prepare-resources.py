"""Rebuild ignored Windows resources from pinned, verified sources (Python 3.11+)."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
REVISION = "2894aab31764f10f29c421bdfd2340d3b382d384"
FONT_SOURCE = f"https://raw.githubusercontent.com/google/fonts/{REVISION}/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf"
FONT_INPUT_HASH = "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da"
FONT_OUTPUT_HASH = "9cec903964d0ea39a8e79eea35e731b9959138f91126d9ea5a162eae0ee90742"
LICENSE_HASH = "1c05c68c34f9708415aada51f17e1b0092d2cea709bf4a94cd38114f9e73d7d9"
WHEEL_URL = "https://files.pythonhosted.org/packages/c7/93/0dd45cd283c32dea1545151d8c3637b4b8c53cdb3a625aeb2885b184d74d/fonttools-4.60.1-py3-none-any.whl"
WHEEL_HASH = "906306ac7afe2156fcf0042173d6ebbb05416af70f6b370967b47f8f00103bbb"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(url, path, expected):
    if path.is_file() and digest(path) == expected:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    # Verify before replacing any previously downloaded file.
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError(f"Checksum mismatch: {url}")
    path.write_bytes(data)


def build_font(root, cache):
    directory = root / "apps/flutter_app/assets/fonts"
    directory.mkdir(parents=True, exist_ok=True)
    download(f"https://raw.githubusercontent.com/google/fonts/{REVISION}/ofl/notosanssc/OFL.txt",
             directory / "OFL-NotoSansSC.txt", LICENSE_HASH)
    output = directory / "NotoSansSC.ttf"
    if not output.is_file() or digest(output) != FONT_OUTPUT_HASH:
        source = cache / "NotoSansSC-VF.ttf"
        wheel = cache / "fonttools-4.60.1.whl"
        download(FONT_SOURCE, source, FONT_INPUT_HASH)
        download(WHEEL_URL, wheel, WHEEL_HASH)
        # Import directly from the verified pure-Python wheel. No global install.
        sys.path.insert(0, str(wheel))
        from fontTools.ttLib import TTFont
        from fontTools.varLib.instancer import instantiateVariableFont
        font = TTFont(source, recalcTimestamp=False)
        instantiateVariableFont(font, {"wght": 400}, inplace=True)
        for table in font["cmap"].tables:
            if table.isUnicode():
                for codepoint in list(table.cmap):
                    if 0x2E80 <= codepoint <= 0x2FFF:
                        del table.cmap[codepoint]
        candidate = directory / "NotoSansSC.generated.ttf"
        font.save(candidate)
        if digest(candidate) != FONT_OUTPUT_HASH:
            raise RuntimeError("Generated font checksum mismatch")
        candidate.replace(output)
    manifest = dict(source=FONT_SOURCE, revision=REVISION,
                    source_sha256=FONT_INPUT_HASH, sha256=FONT_OUTPUT_HASH,
                    transformation="fontTools 4.60.1; static weight 400; source timestamp retained; removed cmap aliases U+2E80-U+2FFF; glyph outlines unchanged",
                    license="OFL-1.1")
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def check_brand_assets(root):
    # The user-provided artwork and multi-resolution ICO are source assets.
    # Do not silently substitute the former generic icon on a clean checkout.
    assets = {
        "apps/flutter_app/assets/branding/folinq.png": b"\x89PNG\r\n\x1a\n",
        "apps/flutter_app/windows/runner/resources/app_icon.ico": b"\x00\x00\x01\x00",
    }
    for relative, signature in assets.items():
        path = root / relative
        if not path.is_file() or not path.read_bytes().startswith(signature):
            raise RuntimeError(f"Missing or invalid brand asset: {relative}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--cache", type=Path, default=ROOT / ".tools/resource-cache")
    args = parser.parse_args()
    build_font(args.root, args.cache)
    check_brand_assets(args.root)
    print("Font, license, manifest and Windows icon are ready.")
