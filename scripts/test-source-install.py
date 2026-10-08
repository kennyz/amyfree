#!/usr/bin/env python3
"""Reproduce first source install without relying on the developer's runtime."""
import gzip
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile

repo = Path(__file__).resolve().parents[1]
cache = repo / 'build/release-deps'
with tempfile.TemporaryDirectory(prefix='amyfree-source-install-') as tmp:
    root = Path(tmp)
    checkout = root / 'checkout'; checkout.mkdir()
    archive = root / 'source.tar'
    with archive.open('wb') as output:
        subprocess.run(['git', 'archive', 'HEAD'], cwd=repo, stdout=output, check=True)
    with tarfile.open(archive) as source:
        source.extractall(checkout, filter='data')
    for name in ['install-source-runtime.sh', 'install-menubar.sh', 'fetch-deps.sh', 'refresh-geodata.sh']:
        shutil.copyfile(repo / 'scripts' / name, checkout / 'scripts' / name)
    shutil.copyfile(repo / 'mihomo/geodata_update.py', checkout / 'mihomo/geodata_update.py')
    assert not (checkout / 'mihomo/mihomo').exists()
    binary_dir = root / 'bin'; binary_dir.mkdir()
    fake_curl = binary_dir / 'curl'
    # Mock transport only; execute the actual core from the checksum-verified release cache.
    fake_curl.write_text('''#!/bin/bash
set -eu
output='' url=''
while [ "$#" -gt 0 ]; do
 case "$1" in -o) output="$2"; shift 2;; -w|--max-time|--retry|--connect-timeout) shift 2;; http*) url="$1"; shift;; *) shift;; esac
done
case "$url" in
 *.gz) cp CACHE/mihomo.gz "$output";;
 */geoip.dat) cp CACHE/geoip.dat "$output";;
 */geosite.dat) cp CACHE/geosite.dat "$output";;
 */country.mmdb) cp CACHE/country.mmdb "$output";;
 *) exit 22;;
esac
'''.replace('CACHE', shlex.quote(str(cache))))
    fake_curl.chmod(0o755)
    destination = root / "User's runtime"
    environment = dict(os.environ, PATH=str(binary_dir) + ':' + os.environ['PATH'])
    command = ['bash', str(checkout / 'scripts/install-source-runtime.sh'), str(destination)]
    subprocess.run(command, env=environment, check=True, stdout=subprocess.PIPE)
    for name in ['mihomo', 'geoip.dat', 'geosite.dat', 'country.mmdb', 'mihomoctl.sh', 'proxyctl.sh', 'tun.sh', 'config.yaml', '.api-secret']:
        assert (destination / name).is_file(), name
    subprocess.run([str(destination / 'mihomo'), '-v'], check=True, stdout=subprocess.PIPE)
    assert not (destination / '.sub-url').exists(), 'placeholder blocks first-launch subscription prompt'
    assert (destination / '.api-secret').stat().st_mode & 0o777 == 0o600
    print('PASS fresh Git checkout installs real kernel, databases, scripts and private credentials')
    private = ['config.yaml', '.api-secret', '.sub-url', 'providers/nodes.yaml', 'geoip.dat']
    for name in private: (destination / name).write_text('private fixture ' + name)
    (destination / 'python3').write_text('#!/bin/bash\nexport PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1\nexec /missing/old/app/python3 "$@"\n')
    subprocess.run(command, env=environment, check=True, stdout=subprocess.PIPE)
    for name in private: assert (destination / name).read_text() == 'private fixture ' + name
    assert not (destination / 'python3').exists()
    print('PASS repair preserves user state and removes obsolete release Python launcher')
    (checkout / 'mihomo/mihomo').write_text('#!/bin/bash\nexit 1\n')
    (checkout / 'mihomo/mihomo').chmod(0o755)
    subprocess.run(command, env=environment, check=True, stdout=subprocess.PIPE)
    subprocess.run([str(destination / 'mihomo'), '-v'], check=True, stdout=subprocess.PIPE)
    print('PASS damaged cached kernel is downloaded again before installation')
    # Failed downloads must not publish an empty executable or replace an existing app.
    (checkout / 'mihomo/mihomo').unlink()
    fake_curl.write_text('#!/bin/bash\nexit 22\n'); fake_curl.chmod(0o755)
    missing = root / 'failed runtime'
    result = subprocess.run(['bash', str(checkout / 'scripts/install-source-runtime.sh'), str(missing)], env=environment, capture_output=True)
    assert result.returncode != 0
    assert not (checkout / 'mihomo/mihomo').exists()
    assert not (missing / 'mihomo').exists()
    print('PASS download failure stops before installing an empty kernel')
