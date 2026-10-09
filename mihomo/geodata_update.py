#!/usr/bin/env python3
"""Download and validate a complete Geo database set before transactional replacement."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
from datetime import datetime, timezone

FILES = ('geoip.dat', 'geosite.dat', 'country.mmdb')
DEFAULT_BASE = 'https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release'


class GeoUpdateError(Exception):
    pass


def public_metadata(url):
    try:
        result = subprocess.run(['curl', '-fLsS', '--connect-timeout', '8', '--max-time', '15',
                                 '--proto', '=https', '--proto-redir', '=https', url],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
        if result.returncode == 0:
            value = json.loads(result.stdout)
            return value if isinstance(value, dict) else {}
    except (ValueError, subprocess.TimeoutExpired):
        pass
    return {}


def resolve_source(base):
    # Pin all files to one revision so the size and checksum refer to the same data.
    if base == DEFAULT_BASE:
        metadata = public_metadata('https://api.github.com/repos/MetaCubeX/meta-rules-dat/commits/release')
        revision = metadata.get('sha', '')
        if isinstance(revision, str) and re.fullmatch('[0-9a-f]{40}', revision): return base.replace('@release', '@' + revision)
    return base


def remote_size(url):
    match = re.fullmatch(r'https://testingcf\.jsdelivr\.net/gh/MetaCubeX/meta-rules-dat@([0-9a-f]{40})/(geoip\.dat|geosite\.dat|country\.mmdb)', url)
    if match:
        revision, name = match.groups()
        metadata = public_metadata('https://api.github.com/repos/MetaCubeX/meta-rules-dat/contents/' + name + '?ref=' + revision)
        size = metadata.get('size', 0)
        return size if isinstance(size, int) and size > 0 else 0
    return 0


def response_size(headers):
    responses = [block for block in re.split(r'\r?\n\r?\n', headers) if block.startswith('HTTP/')]
    if not responses or not re.match(r'HTTP/\S+\s+2\d\d\b', responses[-1]): return 0
    match = re.search(r'(?im)^content-length:\s*(\d+)', responses[-1])
    return int(match.group(1)) if match else 0


def fetch(url, target, progress=None):
    args = ['curl', '-fLsS', '--connect-timeout', '20', '--max-time', '180', '--retry', '2',
            '--proto', '=https', '--proto-redir', '=https', url, '-o', str(target)]
    if progress is None:
        result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        code = result.returncode
    else:
        known_total = remote_size(url)
        progress(0, known_total)
        headers = target.with_name(target.name + '.headers')
        process = subprocess.Popen(args + ['--dump-header', str(headers)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 600
        try:
            while True:
                total = known_total or (response_size(headers.read_text(errors='replace')) if headers.exists() else 0)
                progress(target.stat().st_size if target.exists() else 0, total)
                if process.poll() is not None: break
                if time.monotonic() > deadline: raise GeoUpdateError('下载超时，请稍后重试。')
                time.sleep(.15)
            code = process.returncode
            if code == 0:
                completed = target.stat().st_size
                progress(completed, completed)
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
    if code:
        raise GeoUpdateError('下载失败，请检查网络后重试。原规则库未修改。')


def checksum(base, name, stage, download):
    download(base + '/' + name + '.sha256sum', stage / (name + '.sha256sum'))
    parts = (stage / (name + '.sha256sum')).read_text().split()
    expected = parts[0].lower() if parts else ''
    if not re.fullmatch('[0-9a-f]{64}', expected):
        raise GeoUpdateError('无法读取规则库校验值，原规则库未修改。')
    return expected


def check(directory, download=fetch):
    directory = Path(directory).resolve()
    base = os.environ.get('GEODATA_BASE', DEFAULT_BASE).rstrip('/')
    if download is fetch: base = resolve_source(base)
    result = {}
    with tempfile.TemporaryDirectory(prefix='amyfree-geo-check-') as tmp:
        for name in FILES:
            expected = checksum(base, name, Path(tmp), download)
            local = directory / name
            result[name] = {'available': not local.is_file() or hashlib.sha256(local.read_bytes()).hexdigest() != expected,
                            'modified': local.stat().st_mtime if local.is_file() else None}
    return result


def validate(directory, core):
    # Read each format with the real core, without private nodes or bound ports.
    for dat_mode in (True, False):
        config = directory / 'validate.json'
        config.write_text(json.dumps({'mixed-port': 0, 'geo-auto-update': False, 'geodata-mode': dat_mode,
                                      'rules': ['GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'MATCH,DIRECT']}))
        result = subprocess.run([str(core), '-t', '-d', str(directory), '-f', str(config)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if result.returncode:
            raise GeoUpdateError('规则库格式检查失败，原规则库未修改。')


def replace(source, target):
    temporary = target.with_name('.' + target.name + '.incoming')
    try:
        shutil.copyfile(source, temporary)
        temporary.chmod(0o644)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def update(directory, download=fetch, validator=validate, replacer=replace, selected=FILES, progress=None):
    selected = tuple(selected)
    if not selected or len(set(selected)) != len(selected) or any(name not in FILES for name in selected):
        raise GeoUpdateError('规则库名称无效。')
    directory = Path(directory).resolve()
    core = directory / 'mihomo'
    if not core.is_file() or not os.access(core, os.X_OK):
        raise GeoUpdateError('尚未安装 mihomo 内核，请先安装 Amyfree。')
    # Keep the inode stable: unlinking flock files can allow overlapping updates.
    with (directory / '.geodata-update.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise GeoUpdateError('规则库正在更新，请等待完成。')
        with tempfile.TemporaryDirectory(prefix='.geodata-update-', dir=directory) as tmp:
            stage = Path(tmp)
            base = os.environ.get('GEODATA_BASE', DEFAULT_BASE).rstrip('/')
            if download is fetch: base = resolve_source(base)
            for name in FILES:
                if name not in selected:
                    if not (directory / name).is_file(): raise GeoUpdateError('缺少其他规则库，请先完整安装 Amyfree。')
                    shutil.copyfile(directory / name, stage / name)
                    continue
                if progress: progress({'phase': 'downloading', 'file': name, 'downloaded': 0, 'total': 0})
                else: print('正在下载 ' + name + '…', flush=True)
                expected = checksum(base, name, stage, download)
                if progress and download is fetch:
                    fetch(base + '/' + name, stage / name,
                          lambda received, total: progress({'phase': 'downloading', 'file': name, 'downloaded': received, 'total': total}))
                else:
                    download(base + '/' + name, stage / name)
                    if progress: progress({'phase': 'downloading', 'file': name, 'downloaded': (stage / name).stat().st_size, 'total': (stage / name).stat().st_size})
                actual = hashlib.sha256((stage / name).read_bytes()).hexdigest()
                if actual != expected:
                    raise GeoUpdateError(name + ' 校验失败，原规则库未修改，请稍后重试。')
            if progress: progress({'phase': 'validating'})
            validator(stage, core)
            if all((directory / name).is_file() and (directory / name).read_bytes() == (stage / name).read_bytes() for name in FILES):
                return '规则库已是最新版本。'
            backup = stage / 'backup'; backup.mkdir()
            for name in FILES:
                if (directory / name).exists(): shutil.copyfile(directory / name, backup / name)
            if progress: progress({'phase': 'installing'})
            try:
                for name in selected:
                    replacer(stage / name, directory / name)
            except Exception:
                for name in FILES:
                    if (backup / name).exists(): os.replace(backup / name, directory / name)
                    else: (directory / name).unlink(missing_ok=True)
                raise GeoUpdateError('保存失败，已恢复原规则库。')
            try:
                (directory / '.geodata-updated-at').write_text(datetime.now(timezone.utc).isoformat())
            except OSError:
                pass
            labels = {'geoip.dat': 'GeoIP', 'geosite.dat': 'GeoSite', 'country.mmdb': 'MMDB'}
            return '、'.join(labels[name] for name in selected) + ' 已更新。下次启用代理时加载新规则库。'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', required=True)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--files', nargs='+', choices=FILES)
    args = parser.parse_args()
    def emit(event): print(json.dumps(event, ensure_ascii=False), flush=True)
    try:
        if args.check:
            result = check(args.home)
            if args.json: emit({'event': 'checked', 'files': result})
            else: print(json.dumps(result, ensure_ascii=False))
        else:
            callback = (lambda event: emit(dict(event, event='progress'))) if args.json else None
            message = update(args.home, selected=args.files or FILES, progress=callback)
            if args.json: emit({'event': 'complete', 'message': message})
            else: print(message)
    except Exception as error:
        message = str(error) if isinstance(error, GeoUpdateError) else '更新未完成，请稍后重试。'
        if args.json: emit({'event': 'error', 'message': message})
        else: print(message)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
