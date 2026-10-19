#!/usr/bin/env python3
"""Collect license notices from the exact Cargo-resolved dependency sources."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--locked', '--format-version', '1', '--filter-platform', 'aarch64-apple-darwin']))
resolved = {node['id'] for node in metadata['resolve']['nodes']}
packages = []
for package in sorted(metadata['packages'], key=lambda value: (value['name'], value['version'])):
    if package['id'] not in resolved or package['source'] is None:
        continue
    root = Path(package['manifest_path']).parent.resolve()
    destination = output / (package['name'] + '-' + package['version'])
    notices = set()
    for path in root.rglob('*'):
        if path.is_file() and path.resolve().is_relative_to(root) and re.match(r'^(LICENSE|LICENCE|COPYING|NOTICE|UNLICENSE)([._-].*)?$', path.name, re.I):
            notices.add(path)
    license_file = package.get('license_file')
    if license_file:
        path = (root / license_file).resolve()
        if path.is_file() and path.is_relative_to(root): notices.add(path)
    for path in notices:
        target = destination / path.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    packages.append({'name': package['name'], 'version': package['version'], 'license': package.get('license'),
                     'source': package['source'], 'notices': sorted(str(path.relative_to(root)) for path in notices)})
(output / 'dependencies.json').write_text(json.dumps(packages, indent=2) + '\n')
sysroot = Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip())
standard_library_notice = sysroot / 'share/doc/rust/COPYRIGHT-library.html'
if not standard_library_notice.is_file():
    raise SystemExit('Rust standard library copyright notice is missing from this toolchain.')
shutil.copyfile(standard_library_notice, output / 'COPYRIGHT-library.html')
lines = ['# Rust dependencies', '', 'Dependency versions and declared licenses are taken from Cargo.lock and the resolved package manifests.', '']
lines += ['Rust standard library notices are included in COPYRIGHT-library.html.', '']
lines += ['- ' + item['name'] + ' ' + item['version'] + ': ' + (item['license'] or 'See package notices') for item in packages]
(output / 'README.md').write_text('\n'.join(lines) + '\n')
print('Collected license metadata for', len(packages), 'Rust dependencies.')
