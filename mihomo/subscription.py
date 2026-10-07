#!/usr/bin/env python3
"""订阅测试与更新：安全解析、内核校验、原子写入、加载读回、失败回退。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

from parse_sub import SubscriptionError, parse_subscription, to_yaml


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('wb', dir=path.parent, prefix='.sub-write-', delete=False) as file:
            temporary = Path(file.name)
            file.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


class SubscriptionManager:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.url_file = self.directory / '.sub-url'
        self.nodes_file = self.directory / 'providers/nodes.yaml'
        self.runtime_file = self.directory / '.run-config.yaml'
        self.api = os.environ.get('MIHOMO_API', '127.0.0.1:9090')

    def running(self):
        try:
            pid = int((self.directory / '.mihomo.pid').read_text().strip())
            os.kill(pid, 0)
            return True
        except (OSError, ValueError):
            return False

    def fetch(self, url):
        try:
            parsed = urllib.parse.urlsplit(url)
            valid = parsed.scheme in ('http', 'https') and parsed.hostname and parsed.port != 0
        except ValueError:
            valid = False
        if not valid or any(character.isspace() for character in url):
            raise SubscriptionError('请输入有效的 http:// 或 https:// 订阅地址。')
        with tempfile.TemporaryDirectory(prefix='.sub-stage-', dir=self.directory) as temporary:
            work = Path(temporary)
            raw = work / 'response'
            print('→ 拉取订阅…', flush=True)
            try:
                response = subprocess.run([
                    'curl', '-sS', '-L', '--proto', '=http,https', '--proto-redir', '=http,https',
                    '--connect-timeout', '8', '--max-time', '30', '--max-filesize', str(16 * 1024 * 1024),
                    '-A', 'mihomo/1.19.32', '-o', str(raw), '-w', '%{http_code}', url
                ], capture_output=True, text=True, timeout=35)
            except (OSError, subprocess.TimeoutExpired):
                raise SubscriptionError('订阅下载失败或超时，请检查网络后重试。') from None
            if response.returncode:
                raise SubscriptionError(f'订阅下载失败（curl {response.returncode}），请检查网络或服务器证书。')
            if response.stdout.strip() != '200':
                raise SubscriptionError(f'订阅服务器返回 HTTP {response.stdout.strip() or "未知"}。')
            proxies, form, failures = parse_subscription(raw)
            print(f'✓ {form}，解析出 {len(proxies)} 个节点', flush=True)
            if failures:
                print(f'! 跳过 {len(failures)} 条不支持或无效的链接', flush=True)
            self.validate(proxies, work)
            return proxies

    def validate(self, proxies, work):
        binary = self.directory / 'mihomo'
        if not os.access(binary, os.X_OK):
            raise SubscriptionError('缺少 mihomo 内核，无法检查节点配置。')
        # 不运行机场下发的 DNS、规则或脚本，仅校验节点。
        candidate = work / 'validate.yaml'
        candidate.write_text(to_yaml({
            'mixed-port': 0, 'mode': 'rule', 'allow-lan': False,
            'dns': {'enable': False}, 'proxies': proxies, 'rules': ['MATCH,DIRECT']
        }) + '\n', encoding='utf-8')
        os.chmod(candidate, 0o600)
        try:
            result = subprocess.run([str(binary), '-t', '-d', str(self.directory), '-f', str(candidate)],
                                    capture_output=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            raise SubscriptionError('节点配置检查失败或超时，本次未保存。') from None
        if result.returncode:
            raise SubscriptionError('节点配置未通过内核检查，请检查节点协议、端口或认证参数。')
        print('✓ 内核节点检查通过', flush=True)

    def control(self, action):
        try:
            result = subprocess.run(['bash', str(self.directory / 'mihomoctl.sh'), action],
                                    capture_output=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            raise SubscriptionError('代理服务操作超时或失败。') from None
        if result.returncode:
            raise SubscriptionError('代理服务启动失败，请检查端口占用或当前配置。')

    def verify(self, proxies):
        try:
            secret = (self.directory / '.api-secret').read_text().strip()
        except OSError:
            secret = ''
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        expected = {proxy['name'] for proxy in proxies}
        for _ in range(3):
            try:
                request = urllib.request.Request(f'http://{self.api}/providers/proxies/nodes')
                if secret:
                    request.add_header('Authorization', f'Bearer {secret}')
                with opener.open(request, timeout=4) as response:
                    loaded = json.load(response).get('proxies', [])
                if len(loaded) == len(proxies) and {proxy.get('name') for proxy in loaded} == expected:
                    print(f'✓ 内核已加载 {len(proxies)} 个节点', flush=True)
                    return
            except Exception:
                pass
            time.sleep(.2)
        raise SubscriptionError('内核未能加载完整节点列表。')

    def execute(self, operation, url=None):
        if url is None:
            try:
                url = self.url_file.read_text().strip()
            except OSError:
                raise SubscriptionError('尚未设置订阅地址。') from None
        proxies = self.fetch(url)
        nodes = (to_yaml({'proxies': proxies}) + '\n').encode('utf-8')
        if operation == 'test':
            print('✓ 订阅测试通过；订阅地址、节点和代理状态均未修改', flush=True)
            return
        # 延迟导入避免与链式设置模块的 atomic_write 导入形成循环。
        from chain_proxy import subscription_updates
        chain_changes = subscription_updates(self.directory, proxies)
        if operation == 'fetch':
            atomic_write(self.nodes_file, nodes)
            for path, content in chain_changes.items(): atomic_write(path, content)
            return
        was_running = self.running()
        paths = list(dict.fromkeys([self.url_file, self.nodes_file, self.runtime_file] + list(chain_changes)))
        snapshots = {path: path.read_bytes() if path.exists() else None for path in paths}
        stopped = False
        start_attempted = False
        try:
            if was_running:
                self.control('stop')
                stopped = True
            atomic_write(self.nodes_file, nodes)
            atomic_write(self.url_file, url.encode('utf-8'))
            for path, content in chain_changes.items(): atomic_write(path, content)
            start_attempted = True
            self.control('start')
            self.verify(proxies)
        except Exception:
            failures = []
            if start_attempted:
                try:
                    self.control('stop')
                except Exception:
                    failures.append('停止新服务')
            for path, content in snapshots.items():
                try:
                    if content is None:
                        path.unlink(missing_ok=True)
                    else:
                        atomic_write(path, content)
                except OSError:
                    failures.append('恢复配置文件')
            if was_running and stopped:
                try:
                    self.control('start')
                except Exception:
                    failures.append('恢复原服务')
            if failures:
                raise SubscriptionError('更新失败，自动恢复未完成：' + '、'.join(failures) + '。') from None
            raise SubscriptionError('订阅更新未生效，已恢复原订阅与节点，请检查代理配置或端口占用。') from None
        print('✓ 订阅已保存，新节点已生效', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['test', 'fetch', 'update', 'save'])
    parser.add_argument('url', nargs='?')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        SubscriptionManager(Path(__file__).resolve().parent).execute(args.operation, args.url)
        return 0
    except Exception as error:
        # 解析器和 curl 的原始错误可能包含凭据；仅输出明确的用户提示。
        detail = str(error) if isinstance(error, SubscriptionError) else '订阅操作失败，请检查文件权限或配置。'
        print(f'✗ {detail}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
