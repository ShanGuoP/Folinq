"""Verify ARM64 APK native libraries, 16 KiB alignment, brand and PDFium notices."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile


def verify(path):
    checked = []
    with zipfile.ZipFile(path) as apk, path.open('rb') as raw:
        if apk.testzip() is not None:
            raise RuntimeError('APK CRC check failed')
        names = set(apk.namelist())
        required = {'lib/arm64-v8a/libapp_api.so', 'lib/arm64-v8a/libpdfium.so',
                    'lib/arm64-v8a/libflutter.so', 'lib/arm64-v8a/libapp.so',
                    'assets/flutter_assets/assets/branding/folinq.png',
                    'assets/licenses/pdfium/LICENSE'}
        if not required.issubset(names):
            raise RuntimeError('Missing APK resources: ' + str(sorted(required - names)))
        for entry in apk.infolist():
            if not entry.filename.endswith('.so'):
                continue
            if not entry.filename.startswith('lib/arm64-v8a/'):
                raise RuntimeError('Unexpected native ABI: ' + entry.filename)
            data = apk.read(entry)
            if data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != 183:
                raise RuntimeError('Expected little-endian ARM64 ELF: ' + entry.filename)
            phoff = struct.unpack_from('<Q', data, 32)[0]
            size, count = struct.unpack_from('<HH', data, 54)
            loads = 0
            for index in range(count):
                kind, flags, offset, address, physical, filesz, memsz, alignment = struct.unpack_from(
                    '<IIQQQQQQ', data, phoff + index * size)
                if kind == 1:
                    loads += 1
                    if alignment < 16384 or offset % 16384 != address % 16384:
                        raise RuntimeError('ELF is not 16 KiB compatible: ' + entry.filename)
            if not loads:
                raise RuntimeError('ELF has no load segments: ' + entry.filename)
            if entry.compress_type == zipfile.ZIP_STORED:
                raw.seek(entry.header_offset)
                header = raw.read(30)
                name_length, extra_length = struct.unpack_from('<HH', header, 26)
                if (entry.header_offset + 30 + name_length + extra_length) % 16384:
                    raise RuntimeError('APK native library is not ZIP-aligned: ' + entry.filename)
            checked.append(entry.filename)
    return {'apk': str(path.resolve()), 'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'native_libraries': checked, 'elf_and_zip_alignment': '16 KiB',
            'scope': 'Static package verification; does not replace device testing.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.apk), ensure_ascii=False))
