"""Compile a single-file GUI client and verify the actual package."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
import zipfile

base = Path(__file__).resolve().parent
version = '0.6.0'
release = base / 'releases'
release.mkdir(exist_ok=True)
artifacts = base / 'artifacts'
artifacts.mkdir(exist_ok=True)
windows = Path(os.environ['SystemRoot'])
compiler = windows / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
automation = next((windows / 'Microsoft.NET/assembly/GAC_MSIL/System.Management.Automation').glob('*/System.Management.Automation.dll'))
for name in ['Core.ps1', 'EnvAnchor.ps1', 'tests/Core.Tests.ps1']:
    path = base / name
    path.write_text(path.read_text(encoding='utf-8-sig'), encoding='utf-8-sig')
exe = artifacts / 'EnvAnchor.exe'
subprocess.run([os.sys.executable, str(base / 'make_assets.py')], check=True)
subprocess.run([str(compiler), '/nologo', '/target:winexe', '/platform:anycpu',
                '/out:' + str(exe), '/win32manifest:' + str(base / 'Client.manifest'),
                '/win32icon:' + str(base / 'assets/app.ico'),
                '/reference:' + str(automation), '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
                '/resource:' + str(base / 'Core.ps1') + ',Core.ps1',
                '/resource:' + str(base / 'EnvAnchor.ps1') + ',EnvAnchor.ps1',
                '/resource:' + str(base / 'tests/Core.Tests.ps1') + ',Core.Tests.ps1',
                '/resource:' + str(base / 'assets/app.png') + ',app.png',
                str(base / 'Client.cs'), str(base / 'Ui.cs'), str(base / 'Worker.cs')], check=True)
binary = exe.read_bytes()
pe = struct.unpack_from('<I', binary, 0x3c)[0]
assert binary[pe:pe+4] == b'PE\0\0'
assert struct.unpack_from('<H', binary, pe + 24 + 68)[0] == 2
files = {'EnvAnchor.exe': exe, '使用说明.md': base / 'README.md',
         'assets/app.svg': base / 'assets/app.svg', 'docs/preview.png': base / 'docs/preview.png',
         'CHANGELOG.md': base / 'CHANGELOG.md'}
archive = release / ('EnvAnchor-' + version + '-win10-portable.zip')
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
    for name, path in files.items():
        z.write(path, 'EnvAnchor/' + name)
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    assert set(z.namelist()) == {'EnvAnchor/' + name for name in files}
    assert len(z.namelist()) == len(set(z.namelist()))
    fixture = Path(tempfile.mkdtemp(prefix='env-anchor-package-'))
    z.extractall(fixture)
    for name, path in files.items():
        assert (fixture / 'EnvAnchor' / name).read_bytes() == path.read_bytes()
for mode in ['--self-test', '--smoke-test']:
    result = subprocess.run([str(fixture / 'EnvAnchor/EnvAnchor.exe'), mode], timeout=90)
    if result.returncode:
        error = Path(tempfile.gettempdir()) / 'env-anchor-client-error.txt'
        raise RuntimeError(error.read_text(encoding='utf-8-sig') if error.exists() else mode)
single = release / ('EnvAnchor-' + version + '.exe')
shutil.copyfile(exe, single)
test_lines=(Path(tempfile.gettempdir())/'env-anchor-client-tests.txt').read_text(encoding='utf-8-sig').splitlines()
test_count=sum(line.startswith('PASS:') for line in test_lines)
assert test_count >= 49
report = {
    'version': version,
    'source': 'Source files are fingerprinted below; published with this release in the same repository commit.',
    'package': archive.name,
    'bytes': archive.stat().st_size,
    'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
    'exe': {'name': single.name, 'bytes': single.stat().st_size, 'sha256': hashlib.sha256(binary).hexdigest()},
    'sources': {name: hashlib.sha256((base / name).read_bytes()).hexdigest() for name in
                ['Core.ps1', 'EnvAnchor.ps1', 'Client.cs', 'Ui.cs', 'Worker.cs', 'Client.manifest', 'tests/Core.Tests.ps1', 'README.md', 'build.py', 'make_assets.py', 'assets/app.ico', 'assets/app.png', 'assets/app.svg']},
    'verification': ['ZIP CRC, allowlist, unique root, extracted byte equality',
                     'PE subsystem Windows GUI; runtime GetConsoleWindow is null',
                     str(test_count)+' isolated checks through embedded engine in packaged EXE',
                     'GUI all/none selection, default targets, plan switching, asynchronous worker with UI message pump, isolated startup shortcut, bounds and offscreen render'],
    'limitations': ['No real shutdown/reset cycle or physical multi-drive test',
                    'No real user data or startup entries modified', 'No actual Clash/TUN integration test',
                    'Unsigned executable', 'High-DPI multi-monitor behavior not tested'],
}
(release / ('verification-' + version + '.json')).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({key: report[key] for key in ['package', 'bytes', 'sha256', 'exe']}, indent=2))
