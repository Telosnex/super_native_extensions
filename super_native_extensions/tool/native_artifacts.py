#!/usr/bin/env python3
"""Maintainer-only artifact validation/provenance and manifest assembly."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import tempfile
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / 'native_artifacts'
TARGETS = {
    'macos-arm64', 'macos-x64', 'ios-arm64-iphoneos',
    'ios-arm64-iphonesimulator', 'ios-x64-iphonesimulator',
    'android-arm', 'android-arm64', 'android-x64',
    'linux-arm64', 'linux-x64', 'linux-riscv64', 'windows-x64', 'windows-arm64',
}
NAME = 'super_native_extensions_native'


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest():
    # Include all tracked Rust inputs, including Cargo.lock and generated-map inputs.
    files = run('git', 'ls-files', 'rust').splitlines()
    h = hashlib.sha256()
    for name in sorted(files):
        h.update(name.encode() + b'\0' + (ROOT / name).read_bytes() + b'\0')
    return h.hexdigest()


def validate(target, file):
    data = file.read_bytes()
    arch = target.split('-')[1]
    if target.startswith(('linux-', 'android-')):
        assert data[:4] == b'\x7fELF' and data[5] == 1, 'Expected little-endian ELF'
        assert struct.unpack_from('<H', data, 18)[0] == {'arm': 40, 'arm64': 183, 'x64': 62, 'riscv64': 243}[arch], 'ELF machine mismatch'
        assert data[4] == (1 if arch == 'arm' else 2), 'ELF class mismatch'
        if target.startswith('android-'):
            ndk = Path(os.environ.get('ANDROID_NDK_HOME', str(Path.home() / 'Library/Android/sdk/ndk/28.2.13676358')))
            host = 'darwin-x86_64' if sys.platform == 'darwin' else 'linux-x86_64'
            tools = ndk / 'toolchains/llvm/prebuilt' / host / 'bin'
            readelf, nm = str(tools / 'llvm-readelf'), str(tools / 'llvm-nm')
        else:
            cross = {'x64': 'x86_64', 'arm64': 'aarch64', 'riscv64': 'riscv64'}[arch] + '-linux-gnu'
            readelf, nm = cross + '-readelf', cross + '-nm'
        dynamic = run(readelf, '-d', str(file))
        assert f'[{file.name}]' in dynamic and 'SONAME' in dynamic, 'Missing SONAME'
        assert 'RPATH' not in dynamic and 'RUNPATH' not in dynamic, 'Unexpected runtime path'
        exports = run(nm, '-D', '--defined-only', str(file))
        if target.startswith('android-'):
            assert 'libc++_shared' not in dynamic, 'Unbundled C++ runtime'
            loads = [s.split()[-1] for s in run(readelf, '-lW', str(file)).splitlines() if s.strip().startswith('LOAD ')]
            assert loads and all(int(v, 16) >= 16384 for v in loads), 'Missing 16K page alignment'
    elif target.startswith(('macos-', 'ios-')):
        assert run('lipo', '-archs', str(file)) == {'arm64': 'arm64', 'x64': 'x86_64'}[arch]
        assert run('otool', '-D', str(file)).splitlines()[-1] == '@rpath/' + file.name
        deps = run('otool', '-L', str(file))
        assert '/opt/homebrew' not in deps and '/usr/local' not in deps
        version = run('xcrun', 'vtool', '-show-build', str(file))
        expected = 'MACOS' if target.startswith('macos-') else ('IOSSIMULATOR' if target.endswith('iphonesimulator') else 'IOS')
        assert 'platform ' + expected in version
        exports = run('nm', '-gU', str(file))
        # Flutter rewrites the install name to long build-directory paths for
        # tests. The prebuilt must reserve Mach-O header space for this.
        with tempfile.TemporaryDirectory() as directory:
            copy = Path(directory) / file.name
            shutil.copyfile(file, copy)
            run('install_name_tool', '-id', '/test/' + 'x' * 220 + '/' + file.name, str(copy))
    else:
        assert data[:2] == b'MZ'
        pe = struct.unpack_from('<I', data, 0x3c)[0]
        assert data[pe:pe + 4] == b'PE\0\0'
        assert struct.unpack_from('<H', data, pe + 4)[0] == {'arm64': 0xaa64, 'x64': 0x8664}[arch], 'PE machine mismatch'
        # llvm-readobj is available on the Windows Actions runner.
        exports = run('llvm-readobj', '--coff-exports', str(file))
    def has_symbol(symbol):
        return re.search(r'(?:^|\s)_?' + re.escape(symbol) + r'(?:\s|$)', exports) is not None
    assert has_symbol('super_native_extensions_init_message_channel_context')
    init = ('Java_com_superlist_super_1native_1extensions_SuperNativeExtensionsPlugin_init'
            if target.startswith('android-') else 'super_native_extensions_init')
    assert has_symbol(init), 'Missing platform init export'
    # Load + symbol lookup only: calling init requires an actual Flutter engine.
    host_os = {'darwin': 'macos', 'linux': 'linux', 'win32': 'windows'}.get(sys.platform)
    host_arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64', 'AMD64': 'x64', 'riscv64': 'riscv64'}.get(platform.machine())
    smoke = target == f'{host_os}-{host_arch}'
    if smoke:
        lib = ctypes.CDLL(str(file.resolve()))
        getattr(lib, init)
        getattr(lib, 'super_native_extensions_init_message_channel_context')
    return smoke


def record(target, triple, file):
    assert target in TARGETS
    file = Path(file)
    smoke = validate(target, file)
    source = source_digest()
    metadata = {
        'path': file.relative_to(DIRECTORY).as_posix(),
        'sha256': digest(file),
        'size': file.stat().st_size,
        'source_sha256': source,
        'cargo_lock_sha256': digest(ROOT / 'rust/Cargo.lock'),
        'rust': run('rustc', '+1.97.1', '--version'),
        'target': triple,
        'host': platform.platform(),
        'image': os.environ.get('SNE_BUILD_IMAGE'),
        'runner_image': os.environ.get('ImageVersion'),
        'load_smoke_test': smoke,
    }
    if target.startswith(('macos-', 'ios-')):
        metadata['toolchain'] = run('xcodebuild', '-version')
    elif target.startswith('android-'):
        metadata['toolchain'] = 'Android NDK 28.2.13676358; API 24'
    elif target.startswith('linux-'):
        metadata['toolchain'] = run(triple.replace('riscv64gc', 'riscv64').replace('-unknown', '') + '-gcc', '--version')
    else:
        metadata['toolchain'] = 'MSVC ' + os.environ.get('VCToolsVersion', 'runner default')
    file.with_name('build.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(metadata, indent=2))


def assemble(verify=False):
    artifacts = {}
    source = source_digest()
    for target in sorted(TARGETS):
        metadata = json.loads((DIRECTORY / target / 'build.json').read_text())
        assert metadata['source_sha256'] == source, f'Stale source: {target}'
        assert metadata['cargo_lock_sha256'] == digest(ROOT / 'rust/Cargo.lock')
        assert metadata['sha256'] == digest(DIRECTORY / metadata['path']), target
        artifacts[target] = {'path': metadata['path'], 'sha256': metadata['sha256']}
    manifest = {'schema': 1, 'profile': 1, 'sources': {
        'rust_source_sha256': source,
        'cargo_lock_sha256': digest(ROOT / 'rust/Cargo.lock'),
    }, 'toolchains': {
        'rust': '1.97.1',
        'apple': 'Xcode 26.0.1; macOS 12, iOS 13 (arm64 simulator 14)',
        'android': 'NDK 28.2.13676358; API 24; 16KB pages',
        'linux': 'Debian bullseye snapshot 20260801T000000Z; GCC 10; glibc 2.31',
        'linux-riscv64': 'Ubuntu 22.04 target sysroot; GCC 11; glibc 2.35',
        'windows': 'Windows Server 2022 Actions runner; MSVC (see build.json)',
    }, 'artifacts': artifacts}
    if verify:
        assert manifest == json.loads((DIRECTORY / 'manifest.json').read_text()), 'Manifest differs from build provenance'
        print(f'Verified source, provenance, and all {len(artifacts)} artifacts')
    else:
        (DIRECTORY / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(f'Assembled {len(artifacts)} verified artifacts')


if __name__ == '__main__':
    if sys.argv[1:] == ['assemble']:
        assemble()
    elif sys.argv[1:] == ['verify']:
        assemble(verify=True)
    elif len(sys.argv) == 5 and sys.argv[1] == 'record':
        record(*sys.argv[2:])
    else:
        sys.exit('Usage: native_artifacts.py record <target> <triple> <file> | assemble | verify')
