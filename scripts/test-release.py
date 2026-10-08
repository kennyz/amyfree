#!/usr/bin/env python3
"""Exercise the signed bundle using a fresh home without touching system proxies."""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

repo = Path(__file__).resolve().parents[1]
with (repo / 'app/Info.plist').open('rb') as info:
    version = plistlib.load(info)['CFBundleShortVersionString']
artifact = Path(sys.argv[1] if len(sys.argv) > 1 else repo / f'build/release/Amyfree-{version}-macOS-arm64.zip').resolve()
forbidden = {'.api-secret', '.sub-url', '.sub-raw', 'config.yaml', '.run-config.yaml', '.mimio-chain.json', 'nodes.yaml'}
with tempfile.TemporaryDirectory(prefix='amyfree-release-test-') as tmp:
    root = Path(tmp)
    if artifact.suffix == '.zip':
        subprocess.run(['ditto', '-x', '-k', str(artifact), str(root / 'unpacked')], check=True)
        app = root / 'unpacked/Amyfree.app'
    else:
        app = artifact
    moved = root / "Amyfree's copy.app"
    subprocess.run(['ditto', '--noextattr', '--norsrc', str(app), str(moved)], check=True)
    assert not [p for p in moved.rglob('*') if p.name in forbidden], 'Private runtime state in application'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(moved)], check=True)
    home = root / "fresh user's configuration"
    env = dict(os.environ, MIHOMO_HOME=str(home), PATH='/usr/bin:/bin:/usr/sbin:/sbin', PYTHONDONTWRITEBYTECODE='1')
    executable = moved / 'Contents/MacOS/Amyfree'
    subprocess.run([str(executable), '--prepare-runtime'], env=env, check=True)
    assert (home / '.api-secret').stat().st_mode & 0o777 == 0o600
    assert not (home / '.sub-url').exists()
    python = home / 'python3'
    subprocess.run([str(python), '-c', 'import yaml,ssl,certifi; assert ssl.create_default_context().cert_store_stats()["x509_ca"] > 0; print("PASS bundled Python, YAML and certificate trust store")'], env=env, check=True)
    subprocess.run([str(python), '-m', 'unittest', 'discover', '-s', str(repo / 'tests'), '-p', 'test_*.py'], env=env, check=True)
    menu = subprocess.check_output([str(executable), '--menu-structure'], env=env, text=True)
    assert len(json.loads(menu)) > 0
    assert '检查更新' in menu
    assert (moved / 'Contents/Resources/install.sh').is_file()
    before = hashlib.sha256((home / 'config.yaml').read_bytes()).hexdigest()
    secret = (home / '.api-secret').read_bytes()
    subprocess.run([str(executable), '--prepare-runtime'], env=env, check=True)
    assert (home / '.api-secret').read_bytes() == secret
    assert hashlib.sha256((home / 'config.yaml').read_bytes()).hexdigest() == before
    # Test the template with public rule data and an explicitly fake local-only node.
    (home / 'providers/nodes.yaml').write_text(json.dumps({'proxies': [{'name': 'fixture', 'type': 'http', 'server': '127.0.0.1', 'port': 9}]}))
    subprocess.run([str(home / 'mihomo'), '-t', '-d', str(home), '-f', str(home / 'config.yaml')], env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    isolated = home / 'smoke-test.json'
    isolated.write_text(json.dumps({'mixed-port': 0, 'external-controller': f'127.0.0.1:{port}', 'secret': 'local-test-only', 'mode': 'rule', 'rules': ['MATCH,DIRECT']}))
    process = subprocess.Popen([str(home / 'mihomo'), '-d', str(home), '-f', str(isolated)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for _ in range(100):
            try:
                request = urllib.request.Request(f'http://127.0.0.1:{port}/version', headers={'Authorization': 'Bearer local-test-only'})
                with opener.open(request, timeout=.5) as response:
                    result = json.load(response)
                assert result['version'].lstrip('v') == '1.19.32', result
                break
            except OSError:
                if process.poll() is not None: raise RuntimeError('Signed core stopped unexpectedly')
                time.sleep(.05)
        else:
            raise RuntimeError('Signed core did not become ready')
    finally:
        process.terminate()
        process.wait(timeout=10)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(moved)], check=True)
    print('PASS fresh preparation, path relocation, preserved state, full configuration validation, signed core lifecycle and sealed bundle integrity')
