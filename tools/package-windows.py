"""Build and verify a portable bundle with a clean top-level directory."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    app = root / 'apps/flutter_app'
    if not args.skip_build:
        subprocess.run([str(root / '.tools/flutter/bin/flutter.bat'),
                        'build', 'windows', '--release', '--no-pub'], cwd=app, check=True)
    build = app / 'build/windows/x64'
    release = build / 'runner/Release'
    now = datetime.datetime.now().astimezone()
    name = 'Folinq-windows-x64-' + now.strftime('%Y%m%d-%H%M%S')
    stage = root / '.work/packages' / name / 'Folinq'
    stage.mkdir(parents=True, exist_ok=False)
    runtime = stage / 'runtime'
    runtime.mkdir()
    shutil.copy2(release / 'FolinqLauncher.exe', stage / 'Folinq.exe')
    for filename in ('Folinq.exe', 'app_api.dll', 'flutter_windows.dll',
                     'pdfium.dll', 'native_assets.json'):
        shutil.copy2(release / filename, runtime / filename)
    # Flutter plugins (including desktop file-drop support) ship native DLLs.
    for library in release.glob('*.dll'):
        shutil.copy2(library, runtime / library.name)
    shutil.copytree(release / 'data', runtime / 'data')

    # Use the redistributable belonging to the VS instance that built this app.
    cache = (build / 'CMakeCache.txt').read_text(encoding='utf-8')
    linker_key = 'CMAKE_LINKER:FILEPATH='
    linker = Path(next(line[len(linker_key):] for line in cache.splitlines()
                       if line.startswith(linker_key)))
    imports = subprocess.check_output(
        [str(linker.with_name('dumpbin.exe')), '/dependents', str(stage / 'Folinq.exe')],
        text=True, errors='replace')
    dependencies = {name.lower() for name in re.findall(
        r'^\s+([\w.-]+\.dll)\s*$', imports, re.MULTILINE | re.IGNORECASE)}
    if not dependencies or dependencies - {'kernel32.dll', 'user32.dll'}:
        raise RuntimeError('Launcher must only depend on system DLLs: ' + str(dependencies))
    key = 'CMAKE_GENERATOR_INSTANCE:INTERNAL='
    vs = Path(next(line[len(key):] for line in cache.splitlines() if line.startswith(key)))
    candidates = list((vs / 'VC/Redist/MSVC').glob('*/x64/Microsoft.VC*.CRT'))
    if not candidates:
        raise RuntimeError('Visual C++ x64 redistributable not found')
    crt = max(candidates, key=lambda p: tuple(int(n) for n in p.parents[1].name.split('.')))
    # Verified direct and transitive dependencies of the runner and Rust engine.
    for filename in ('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'):
        shutil.copy2(crt / filename, runtime / filename)
    for filename in ('README.md', 'LICENSE'):
        shutil.copy2(root / filename, runtime / filename)
    (stage / '使用说明.txt').write_text(
        'Folinq 页翎 — Windows 64 位便携版\n\n'
        '请完整解压后，双击根目录的 Folinq.exe 启动。\n'
        'runtime 文件夹包含全部运行库和资源，请保留在启动程序旁边。\n'
        '升级时完整解压到新文件夹即可，原有本地项目和恢复记录继续保留。\n\n'
        '点击工作台左上角的图标或 Folinq 页翎，可查看版本、访问或复制项目开源地址。\n'
        '开源地址：https://github.com/ShanGuoP/Folinq\n\n'
        '支持拖入 PDF 打开、删除最近记录（保留源文件）、可编辑 Word 导出、输出目录记忆。\n'
        '复杂 PDF 的 Word 排版仍需校对。\n'
        '扫描页可在 Word、Markdown、TXT 导出窗口启用在线 PaddleOCR，填写自己的服务地址和 Token。\n'
        '在线识别默认关闭，开启后会上传所选页面，可能消耗服务额度。\n'
        '在线 Word 保留标题、列表、可编辑表格和配图；Markdown 含配图并保存为 ZIP；TXT 为纯文字。\n', encoding='utf-8-sig')
    info = {'name': 'Folinq 页翎', 'created_at': now.isoformat(),
            'layout': 'Folinq.exe + runtime/', 'crt': str(crt.relative_to(vs)),
            'engine_sha256': sha256((runtime / 'app_api.dll').read_bytes()),
            'app_sha256': sha256((runtime / 'data/app.so').read_bytes())}
    (runtime / 'BUILD_INFO.json').write_text(
        json.dumps(info, ensure_ascii=False, indent=2), encoding='utf-8')
    manifest = {p.relative_to(stage).as_posix(): sha256(p.read_bytes())
                for p in sorted(stage.rglob('*')) if p.is_file()}
    (runtime / 'SHA256SUMS.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    archive = root / 'dist/windows' / (name + '.zip')
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for p in sorted(stage.rglob('*')):
            if p.is_file():
                z.write(p, 'Folinq/' + p.relative_to(stage).as_posix())
    with zipfile.ZipFile(archive) as z:
        if z.testzip() is not None:
            raise RuntimeError('Archive CRC check failed')
        for path, digest in manifest.items():
            if sha256(z.read('Folinq/' + path)) != digest:
                raise RuntimeError('Archive content mismatch: ' + path)
        entries = len(z.namelist())
    digest = sha256(archive.read_bytes())
    archive.with_suffix('.zip.sha256').write_text(
        digest + '  ' + archive.name + '\n', encoding='ascii')
    result = {'archive': str(archive), 'stage': str(stage),
              'bytes': archive.stat().st_size, 'entries': entries, 'sha256': digest}
    (root / '.work/packages/latest-package.json').write_text(
        json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
