#!/usr/bin/env python3
"""Exercise the real signed installer against isolated application/config paths."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import threading
import zipfile

repo = Path(__file__).resolve().parents[1]
installer = repo / 'scripts/install.sh'
version = plistlib.loads((repo / 'app/Info.plist').read_bytes())['CFBundleShortVersionString']
archive = repo / f'build/release/Amyfree-{version}-macOS-arm64.zip'
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def app_version(path): return plistlib.loads((path / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']

with tempfile.TemporaryDirectory(prefix='amyfree-installer-tests-') as tmp:
    root = Path(tmp)
    target = root / "User's Applications/Amyfree.app"
    settings = root / 'settings'
    settings.mkdir()
    for name in ['config.yaml', '.api-secret', '.sub-url']:
        (settings / name).write_text('private fixture ' + name)
    before = {p.name: sha(p) for p in settings.iterdir()}
    env = dict(os.environ, MIHOMO_HOME=str(settings))
    arguments = ['--version', 'v' + version, '--archive', str(archive), '--sha256', sha(archive), '--target', str(target), '--no-open']
    def invoke(args, script=installer, success=True):
        result = subprocess.run(['/bin/bash', str(script)] + args, env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result
    previous = repo / 'build/release/Amyfree-1.3.4-macOS-arm64.zip'
    if previous.exists():
        invoke(['--version', 'v1.3.4', '--archive', str(previous), '--sha256', sha(previous), '--target', str(target), '--no-open'])
        assert app_version(target) == '1.3.4'
    # stdin execution is exactly how curl | bash invokes the installer.
    piped = subprocess.run(['/bin/bash', '-s', '--'] + arguments, input=installer.read_text(), env=env, capture_output=True, text=True)
    assert piped.returncode == 0, piped.stderr
    assert app_version(target) == version
    original = sha(target / 'Contents/MacOS/Amyfree')
    print('PASS curl-style stdin installation with spaces/apostrophes in target')
    invoke(arguments)
    print('PASS repeated installation')
    info = target / 'Contents/Info.plist'
    saved_info = info.read_bytes()
    newer_info = plistlib.loads(saved_info); newer_info['CFBundleShortVersionString'] = '9.0.0'
    info.write_bytes(plistlib.dumps(newer_info))
    try:
        invoke(arguments, success=False)
        assert app_version(target) == '9.0.0'
    finally:
        info.write_bytes(saved_info)
    print('PASS downgrade rejected without replacing newer application')
    bad_hash = arguments.copy(); bad_hash[bad_hash.index('--sha256') + 1] = '0' * 64
    invoke(bad_hash, success=False)
    bad_version = arguments.copy(); bad_version[bad_version.index('--version') + 1] = 'v1.4.0;open'
    invoke(bad_version, success=False)
    print('PASS hash failure and malformed version leave application intact')
    for name, link in [('traversal.zip', False), ('symlink.zip', True)]:
        malicious = root / name
        with zipfile.ZipFile(malicious, 'w') as output:
            if link:
                info = zipfile.ZipInfo('Amyfree.app/Contents/Resources/escape')
                info.create_system = 3; info.external_attr = (stat.S_IFLNK | 0o777) << 16
                output.writestr(info, '../../../../escaped')
            else:
                output.writestr('../escaped', 'unsafe')
        args = arguments.copy(); args[args.index('--archive') + 1] = str(malicious); args[args.index('--sha256') + 1] = sha(malicious)
        invoke(args, success=False)
        assert not (root / 'escaped').exists()
    print('PASS archive traversal and escaping symbolic links rejected')
    tamper_root = root / 'tamper'
    subprocess.run(['ditto', '-x', '-k', str(archive), str(tamper_root)], check=True)
    plist = tamper_root / 'Amyfree.app/Contents/Info.plist'
    value = plistlib.loads(plist.read_bytes()); value['CFBundleName'] = 'Altered'
    plist.write_bytes(plistlib.dumps(value))
    tampered = root / 'tampered.zip'
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(tamper_root / 'Amyfree.app'), str(tampered)], check=True)
    args = arguments.copy(); args[args.index('--archive') + 1] = str(tampered); args[args.index('--sha256') + 1] = sha(tampered)
    invoke(args, success=False)
    assert sha(target / 'Contents/MacOS/Amyfree') == original
    print('PASS modified signed application rejected before replacement')
    faulty = root / 'fault-injection.sh'
    source = installer.read_text()
    trigger = 'mv "$INCOMING/Amyfree.app" "$TARGET"'
    assert source.count(trigger) == 1
    faulty.write_text(source.replace(trigger, 'false # Simulated rename failure after backup'))
    invoke(arguments, script=faulty, success=False)
    assert sha(target / 'Contents/MacOS/Amyfree') == original
    assert not list(target.parent.glob('.Amyfree-install.*'))
    print('PASS replacement failure rolls back to original signed application')
    # Stage first, then run the same detached-helper path used by AppUpdater.
    staged = invoke(arguments + ['--stage-only'])
    directory = Path(next(line.removeprefix('AMYFREE_STAGED=') for line in staged.stdout.splitlines() if line.startswith('AMYFREE_STAGED=')))
    try:
        sleeper = subprocess.Popen(['/bin/sleep', '.8'])
        reaper = threading.Thread(target=sleeper.wait)
        reaper.start()
        try:
            invoke(['--staged', str(directory), '--target', str(target), '--wait-pid', str(sleeper.pid), '--no-open'])
        finally:
            reaper.join(timeout=5)
    finally:
        if directory.exists(): shutil.rmtree(directory)
    assert app_version(target) == version
    assert before == {p.name: sha(p) for p in settings.iterdir()}
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
    print('PASS staged update, parent-process wait, signature integrity and private-settings preservation')
