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
from datetime import datetime, timezone

FILES = ('geoip.dat', 'geosite.dat', 'country.mmdb')
DEFAULT_BASE = 'https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release'


class GeoUpdateError(Exception):
    pass


def fetch(url, target):
    result = subprocess.run(['curl', '-fLsS', '--connect-timeout', '20', '--max-time', '180', '--retry', '2',
                             '--proto', '=https', '--proto-redir', '=https', url, '-o', str(target)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    if result.returncode:
        raise GeoUpdateError('下载失败，请检查网络后重试。原规则库未修改。')


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


def update(directory, download=fetch, validator=validate, replacer=replace):
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
            for name in FILES:
                print('正在下载 ' + name + '…', flush=True)
                download(base + '/' + name + '.sha256sum', stage / (name + '.sha256sum'))
                checksum = (stage / (name + '.sha256sum')).read_text().split()
                expected = checksum[0].lower() if checksum else ''
                if not re.fullmatch('[0-9a-f]{64}', expected):
                    raise GeoUpdateError('无法读取规则库校验值，原规则库未修改。')
                download(base + '/' + name, stage / name)
                actual = hashlib.sha256((stage / name).read_bytes()).hexdigest()
                if actual != expected:
                    raise GeoUpdateError(name + ' 校验失败，原规则库未修改，请稍后重试。')
            validator(stage, core)
            if all((directory / name).is_file() and (directory / name).read_bytes() == (stage / name).read_bytes() for name in FILES):
                return '规则库已是最新版本。'
            backup = stage / 'backup'; backup.mkdir()
            for name in FILES:
                if (directory / name).exists(): shutil.copyfile(directory / name, backup / name)
            try:
                for name in FILES:
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
            return 'GeoIP、GeoSite 和 MMDB 已更新。下次启用代理时加载新规则库。'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', required=True)
    args = parser.parse_args()
    try:
        print(update(args.home))
    except Exception as error:
        message = str(error) if isinstance(error, GeoUpdateError) else '更新未完成，原规则库仍可用，请稍后重试。'
        print(message)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
