#!/usr/bin/env python3
"""Verify and package an Android phone/TV APK from the current source."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import zipfile

from core_identity import source_digest
from release import ROOT, validate

ABIS = {'armeabi-v7a', 'arm64-v8a', 'x86_64'}


def elf_16k(data):
    if data[:4] != b'\x7fELF' or data[5] != 1:
        raise ValueError('Invalid Android ELF library')
    if data[4] != 2:
        raise ValueError('Expected a 64-bit Android library')
    offset = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    loads = 0
    for index in range(count):
        at = offset + index * size
        if struct.unpack_from('<I', data, at)[0] != 1:
            continue
        loads += 1
        file_offset, address = struct.unpack_from('<QQ', data, at + 8)
        alignment = struct.unpack_from('<Q', data, at + 48)[0]
        if alignment < 16384 or (file_offset - address) % 16384:
            raise ValueError('Native library does not support 16 KB pages')
    if not loads:
        raise ValueError('Native library has no loadable segments')


def check_libraries(apk, mode, core_digest, build_version):
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        bytecode = [archive.read(name) for name in names if re.fullmatch(r'classes\d*\.dex', name)]
        for bridge in (b'Lgo/Seq;', b'Lmobile/Mobile;', b'Lmobile/Client;'):
            if not any(bridge in dex for dex in bytecode):
                raise ValueError('Go JNI bridge classes were removed or renamed')
        abis = {name.split('/')[1] for name in names if name.startswith('lib/') and name.endswith('.so')}
        if abis != ABIS:
            raise ValueError(f'Expected all three Android ABIs, found {sorted(abis)}')
        required = {'libflutter.so', 'libgojni.so'} | ({'libapp.so'} if mode == 'release' else set())
        for abi in sorted(ABIS):
            libraries = {name.rsplit('/', 1)[1] for name in names if name.startswith(f'lib/{abi}/') and name.endswith('.so')}
            if not required <= libraries:
                raise ValueError(f'Missing app/core native libraries for {abi}')
            core = archive.read(f'lib/{abi}/libgojni.so')
            if core_digest.encode() not in core or build_version.encode() not in core:
                raise ValueError(f'Embedded Go core does not match current source/version: {abi}')
            if abi != 'armeabi-v7a':
                for library in sorted(libraries):
                    try:
                        elf_16k(archive.read(f'lib/{abi}/{library}'))
                    except (ValueError, IndexError, struct.error) as error:
                        raise ValueError(f'Invalid 16 KB native alignment: {abi}/{library}') from error
    return sorted(abis)


def check_identity(badging, manifest, certificate, name, build, mode, expected_fingerprint=''):
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging, re.M)
    expected_id = 'com.maxduke.guoguo_mobile' + ('.dev' if mode == 'debug' else '')
    expected_version = name + ('-dev' if mode == 'debug' else '')
    if not package or package.groups() != (expected_id, build, expected_version):
        raise ValueError('APK identity does not match current source and build mode')
    if "sdkVersion:'24'" not in badging:
        raise ValueError('APK must retain Android API 24 minimum')
    if 'android.intent.category.LEANBACK_LAUNCHER' not in manifest or 'android:banner' not in manifest:
        raise ValueError('APK is missing its TV launcher or banner')
    debug_signer = 'android debug' in certificate.lower()
    if mode == 'release' and debug_signer:
        raise ValueError('Refusing to publish a debug-signed release APK')
    if mode == 'release' and 'application-debuggable' in badging:
        raise ValueError('Refusing to publish a debuggable release APK')
    fingerprint = re.search(r'Signer #1 certificate SHA-256 digest: ([0-9a-fA-F]{64})', certificate)
    if not fingerprint:
        raise ValueError('APK signing certificate could not be verified')
    if mode == 'release' and (not re.fullmatch('[0-9a-f]{64}', expected_fingerprint) or fingerprint.group(1).lower() != expected_fingerprint):
        raise ValueError('APK signer does not match the fixed project release certificate')
    return expected_id, fingerprint.group(1).lower()


def run(tool, *arguments):
    return subprocess.run([str(tool), *map(str, arguments)], check=True, capture_output=True, text=True).stdout


def build_origin(environment):
    if environment.get('GITHUB_ACTIONS') != 'true':
        return {'buildEnvironment': 'local', 'run_url': ''}
    server = environment.get('GITHUB_SERVER_URL', 'https://github.com')
    repository, run_id = environment.get('GITHUB_REPOSITORY', ''), environment.get('GITHUB_RUN_ID', '')
    if not re.fullmatch(r'[^/\s]+/[^/\s]+', repository) or not run_id.isdecimal():
        raise ValueError('GitHub build origin is incomplete')
    return {'buildEnvironment': 'github-actions', 'run_url': f'{server}/{repository}/actions/runs/{run_id}'}


def package(apk, tools, mode, root=ROOT, tag=None):
    name, build = validate(root, tag)
    commit = os.environ.get('GITHUB_SHA', '')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('GITHUB_SHA must identify the exact source commit')
    badging = run(tools / 'aapt', 'dump', 'badging', apk)
    manifest = run(tools / 'aapt', 'dump', 'xmltree', apk, 'AndroidManifest.xml')
    certificate = run(tools / 'apksigner', 'verify', '--verbose', '--print-certs', apk)
    application_id, fingerprint = check_identity(badging, manifest, certificate, name, build, mode, os.environ.get('ANDROID_CERTIFICATE_SHA256', ''))
    run(tools / 'zipalign', '-c', '-P', '16', '4', apk)
    digest = source_digest(root)
    abis = check_libraries(apk, mode, digest, f'{name}+{build}')
    output = root / 'build/android-package'
    output.mkdir(parents=True, exist_ok=True)
    filename = f'Guoguo-{name}+{build}-android' + ('-test' if mode == 'debug' else '') + '.apk'
    expected = {filename, 'build-info-android.json', 'SHA256SUMS-android'}
    if any(path.name not in expected for path in output.iterdir()):
        raise ValueError('Android package output contains another build; use a fresh output directory')
    target = output / filename
    shutil.copyfile(apk, target)
    info = output / 'build-info-android.json'
    info.write_text(json.dumps({
        'version': name, 'build': build, 'commit': commit, 'platform': 'android',
        'mode': mode, 'applicationId': application_id, 'certificateSha256': fingerprint,
        'coreSourceDigest': digest, 'abis': abis, 'minSdk': 24,
        'television': True, 'elf16k': True,
        **build_origin(os.environ),
    }, indent=2) + '\n')
    checksums = []
    for path in (target, info):
        with path.open('rb') as source:
            checksums.append(f'{hashlib.file_digest(source, "sha256").hexdigest()}  {path.name}\n')
    (output / 'SHA256SUMS-android').write_text(''.join(checksums))
    print(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--build-tools', required=True, type=Path)
    parser.add_argument('--mode', choices=['debug', 'release'], default='debug')
    args = parser.parse_args()
    tag = os.environ.get('GITHUB_REF_NAME') if os.environ.get('GITHUB_REF_TYPE') == 'tag' else None
    package(args.apk, args.build_tools, args.mode, tag=tag)


if __name__ == '__main__':
    main()
