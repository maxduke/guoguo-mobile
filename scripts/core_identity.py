#!/usr/bin/env python3
"""Bind native artifacts to the exact core source bytes and bridge protocol."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROTOCOL = 2


def source_digest(root=ROOT):
    core = root / 'native/core'
    files = sorted(path for path in core.rglob('*') if path.is_file() and (
        path.name in ('go.mod', 'go.sum') or
        (path.suffix == '.go' and not path.name.endswith('_test.go')) or
        'internal/webui' in path.relative_to(core).as_posix()))
    digest = hashlib.sha256()
    for path in files:
        name = path.relative_to(core).as_posix().encode()
        data = path.read_bytes()
        digest.update(len(name).to_bytes(4, 'big') + name)
        digest.update(len(data).to_bytes(8, 'big') + data)
    return digest.hexdigest()


def artifact_hashes(artifact):
    files = [artifact] if artifact.is_file() else sorted(path for path in artifact.rglob('*') if path.is_file())
    if not files:
        raise ValueError('Native artifact is missing or empty')
    return {path.name if artifact.is_file() else path.relative_to(artifact).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}


def write_manifest(artifact, manifest, platform, root=ROOT):
    document = {'protocol': PROTOCOL, 'sourceDigest': source_digest(root), 'platform': platform, 'files': artifact_hashes(artifact)}
    manifest.write_text(json.dumps(document, indent=2) + '\n')


def verify(artifact, manifest, platform, root=ROOT):
    document = json.loads(manifest.read_text())
    expected = {'protocol': PROTOCOL, 'sourceDigest': source_digest(root), 'platform': platform, 'files': artifact_hashes(artifact)}
    if document != expected:
        raise ValueError('Native core artifact does not match current source or platform; rebuild it')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['digest', 'write', 'verify'])
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--platform', choices=['ios', 'android'])
    args = parser.parse_args()
    if args.command == 'digest':
        print(source_digest())
        return
    if not (args.artifact and args.manifest and args.platform):
        parser.error('artifact, manifest and platform are required')
    if args.command == 'write':
        write_manifest(args.artifact, args.manifest, args.platform)
    else:
        verify(args.artifact, args.manifest, args.platform)


if __name__ == '__main__':
    main()
