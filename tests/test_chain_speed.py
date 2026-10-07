import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mihomo'))
from chain_proxy import chain_nodes, render, apply, subscription_updates, ENTRY, EXIT
from node_speed import speed_from_sample, SAMPLE_BYTES
from parse_sub import SubscriptionError, load_yaml, to_yaml

PROXIES = [{'name': '入口测试', 'type': 'trojan', 'server': 'entry.example', 'port': 443, 'password': 'fake-a'},
           {'name': '出口测试', 'type': 'trojan', 'server': 'exit.example', 'port': 443, 'password': 'fake-b'}]
SOURCE = '''mixed-port: 7890
secret: "__API_SECRET__"
find-process-mode: off
dns:
  enable: true
  direct-nameserver: [223.5.5.5]
proxy-groups:
  - name: PROXY
    type: url-test
    use: [nodes]
    url: https://example.com/test
  - name: 手动选择
    type: select
    use: [nodes]
rules:
  - DOMAIN-SUFFIX,local.example,DIRECT
  - MATCH,PROXY
'''

class ChainTests(unittest.TestCase):
    def test_two_hops_point_exit_to_entry_without_modifying_original(self):
        before = copy.deepcopy(PROXIES)
        result = chain_nodes(PROXIES, '入口测试', '出口测试')
        self.assertEqual(result[0]['name'], ENTRY)
        self.assertEqual(result[1]['name'], EXIT)
        self.assertEqual(result[1]['dialer-proxy'], ENTRY)
        self.assertNotIn('dialer-proxy', result[0])
        self.assertEqual(PROXIES, before)

    def test_same_missing_and_nonproxy_nodes_are_rejected(self):
        for entry, exit in [('入口测试', '入口测试'), ('missing', '出口测试')]:
            with self.assertRaises(SubscriptionError): chain_nodes(PROXIES, entry, exit)
        with self.assertRaises(SubscriptionError): chain_nodes(PROXIES + [{'name':'direct','type':'direct'}], 'direct', '出口测试')

    def test_render_enable_and_disable_preserve_rules_dns_and_modes(self):
        updated, state = render(SOURCE, PROXIES, {'enabled': False}, True, '入口测试', '出口测试')
        data = load_yaml(updated)
        self.assertEqual(data['proxy-groups'][0]['proxies'], [EXIT])
        self.assertEqual(data['proxy-groups'][1]['proxies'], [EXIT])
        self.assertIn('find-process-mode: off', updated)
        self.assertEqual(data['dns']['direct-nameserver'], ['223.5.5.5'])
        self.assertEqual(data['dns']['proxy-server-nameserver'], ['https://dns.alidns.com/dns-query'])
        self.assertIn(SOURCE[SOURCE.index('rules:'):], updated)
        restored, disabled = render(updated, PROXIES, state, False, '入口测试', '出口测试')
        self.assertNotIn('proxies', load_yaml(restored))
        self.assertEqual(load_yaml(restored)['proxy-groups'], load_yaml(SOURCE)['proxy-groups'])
        self.assertEqual(load_yaml(restored)['dns'], load_yaml(SOURCE)['dns'])
        self.assertFalse(disabled['enabled'])

    def test_other_custom_nodes_and_groups_are_preserved(self):
        source = SOURCE + 'proxies:\n  - {name: custom, type: direct}\n'
        updated, state = render(source, PROXIES, {'enabled': False}, True, '入口测试', '出口测试')
        self.assertEqual(load_yaml(updated)['proxies'][0], {'name':'custom','type':'direct'})
        changed = updated.replace('proxies: ["MIMIO_CHAIN_EXIT"]', 'proxies: ["DIRECT"]', 1)
        with self.assertRaises(SubscriptionError): render(changed, PROXIES, state, False, '', '')

    def test_reload_failure_restores_all_files(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp); (home/'providers').mkdir()
            (home/'providers/nodes.yaml').write_text(to_yaml({'proxies': PROXIES}))
            (home/'config.yaml').write_text(SOURCE); (home/'.api-secret').write_text('fake-secret')
            (home/'.run-config.yaml').write_text(SOURCE.replace('__API_SECRET__','fake-secret'))
            before = {name:(home/name).read_bytes() for name in ['config.yaml','.run-config.yaml']}
            with patch('chain_proxy.subprocess.run') as process, patch('chain_proxy.running', return_value=True), \
                 patch('chain_proxy.reload_runtime', side_effect=[SubscriptionError('failed'), None]):
                process.return_value.returncode = 0
                with self.assertRaises(SubscriptionError): apply(home, True, '入口测试', '出口测试')
            for name, data in before.items(): self.assertEqual((home/name).read_bytes(), data)
            self.assertFalse((home/'.mimio-chain.json').exists())

    def test_speed_units_and_invalid_samples(self):
        self.assertEqual(speed_from_sample(200, SAMPLE_BYTES, 2), .5)
        self.assertEqual(speed_from_sample(200, SAMPLE_BYTES, .25), 4)
        for sample in [(500,SAMPLE_BYTES,1), (200,100,1), (200,SAMPLE_BYTES,0)]:
            with self.assertRaises(ValueError): speed_from_sample(*sample)

    def test_subscription_refresh_updates_chain_credentials_and_handles_removed_node(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            enabled, state = render(SOURCE, PROXIES, {'enabled': False}, True, '入口测试', '出口测试')
            (home/'config.yaml').write_text(enabled); (home/'.mimio-chain.json').write_text(json.dumps(state)); (home/'.api-secret').write_text('fake-secret')
            renewed = copy.deepcopy(PROXIES); renewed[1]['password'] = 'renewed-secret'
            updates = subscription_updates(home, renewed)
            nodes = load_yaml(updates[home/'config.yaml'].decode())['proxies']
            self.assertEqual(next(p for p in nodes if p['name']==EXIT)['password'], 'renewed-secret')
            updates = subscription_updates(home, [renewed[0]])
            self.assertFalse(json.loads(updates[home/'.mimio-chain.json'])['enabled'])
            self.assertEqual(load_yaml(updates[home/'config.yaml'].decode())['dns'], load_yaml(SOURCE)['dns'])

if __name__ == '__main__': unittest.main()
