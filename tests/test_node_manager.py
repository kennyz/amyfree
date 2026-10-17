import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mihomo'))
import node_manager
from node_manager import delete, get, merge_custom, parse_node, save, status
from parse_sub import SubscriptionError, load_yaml, to_yaml

SUBSCRIPTION = [{'name': '订阅甲', 'type': 'trojan', 'server': 'a.example', 'port': 443, 'password': 'fake-a'},
                {'name': '订阅乙', 'type': 'trojan', 'server': 'b.example', 'port': 443, 'password': 'fake-b'}]
LINK = 'trojan://fake-c@c.example:8443?sni=c.example#%E6%89%8B%E5%B7%A5%E4%B8%99'


class NodeManagerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name); (self.home / 'providers').mkdir()
        (self.home / 'providers/nodes.yaml').write_text(to_yaml({'proxies': SUBSCRIPTION}))
        for target, value in [('SubscriptionManager.validate', None), ('reload', None)]:
            patcher = patch('node_manager.' + target, return_value=value); self.addCleanup(patcher.stop)
            setattr(self, target.split('.')[-1], patcher.start())
        patcher = patch('chain_proxy.running', return_value=False); self.addCleanup(patcher.stop); patcher.start()

    def loaded(self):
        return load_yaml((self.home / 'providers/nodes.yaml').read_text())['proxies']

    def test_parse_link_yaml_json_and_reject_bad_input(self):
        self.assertEqual(parse_node(LINK)['name'], '手工丙')
        self.assertEqual(parse_node(to_yaml(SUBSCRIPTION[0]))['port'], 443)
        self.assertEqual(parse_node(json.dumps({'proxies': [SUBSCRIPTION[1]]})), SUBSCRIPTION[1])
        for text in ['', 'hello', LINK + '\n' + LINK, json.dumps(SUBSCRIPTION), 'name: x\ntype: direct\n',
                     'name: x\ntype: trojan\nserver: s\nport: 70000\n']:
            with self.assertRaises(SubscriptionError): parse_node(text)

    def test_add_edit_and_delete_custom_node(self):
        self.assertEqual(save(self.home, '', LINK), {'name': '手工丙', 'applied': False})
        self.assertEqual([p['name'] for p in self.loaded()], ['订阅甲', '订阅乙', '手工丙'])
        self.assertEqual(status(self.home)['nodes'][2], {'name': '手工丙', 'origin': 'added'})
        edited = get(self.home, '手工丙')['config'].replace('8443', '9443')
        save(self.home, '手工丙', edited)
        self.assertEqual(self.loaded()[2]['port'], 9443)
        delete(self.home, '手工丙')
        self.assertEqual(self.loaded(), SUBSCRIPTION)
        self.assertEqual(oct((self.home / 'custom-nodes.json').stat().st_mode & 0o777), oct(0o600))

    def test_edited_subscription_node_survives_refresh_and_restores(self):
        renamed = get(self.home, '订阅甲')['config'].replace('订阅甲', '我的甲').replace('a.example', 'mine.example')
        save(self.home, '订阅甲', renamed)
        self.assertEqual(self.loaded()[0]['server'], 'mine.example')
        self.assertEqual(status(self.home)['nodes'][0], {'name': '我的甲', 'origin': 'edited'})
        # 订阅刷新后仍套用编辑，并更新订阅原样副本。
        renewed = [dict(SUBSCRIPTION[0], password='renewed'), SUBSCRIPTION[1]]
        self.assertEqual(merge_custom(self.home, renewed)[0]['server'], 'mine.example')
        delete(self.home, '我的甲')
        self.assertEqual(self.loaded(), SUBSCRIPTION)
        with self.assertRaises(SubscriptionError): delete(self.home, '订阅乙')

    def test_unchanged_save_is_not_recorded_as_edit(self):
        save(self.home, '订阅乙', get(self.home, '订阅乙')['config'])
        self.assertEqual(json.loads((self.home / 'custom-nodes.json').read_text())['edited'], {})

    def test_duplicate_name_is_rejected_without_changes(self):
        with self.assertRaises(SubscriptionError): save(self.home, '', to_yaml(dict(SUBSCRIPTION[0], server='x.example')))
        self.assertFalse((self.home / 'custom-nodes.json').exists())

    def test_refresh_skips_custom_node_that_now_clashes(self):
        save(self.home, '', LINK)
        clash = SUBSCRIPTION + [dict(SUBSCRIPTION[0], name='手工丙')]
        with patch('builtins.print'):
            merged = merge_custom(self.home, clash)
        self.assertEqual([p['name'] for p in merged], ['订阅甲', '订阅乙', '手工丙'])
        self.assertEqual(merged[2]['server'], 'a.example')

    def test_reload_failure_restores_files(self):
        before = (self.home / 'providers/nodes.yaml').read_bytes()
        with patch('chain_proxy.running', return_value=True):
            self.reload.side_effect = [SubscriptionError('failed'), None]
            with self.assertRaises(SubscriptionError): save(self.home, '', LINK)
        self.assertEqual((self.home / 'providers/nodes.yaml').read_bytes(), before)
        self.assertFalse((self.home / 'custom-nodes.json').exists())

    def test_lenient_parse_for_form_and_source_switching(self):
        self.assertEqual(parse_node('', strict=False), {})
        partial = parse_node('{"udp": true, "type": "vless", "port": 443}', strict=False)
        self.assertEqual(list(partial), ['type', 'port', 'udp'])
        self.assertEqual(parse_node(LINK, strict=False)['server'], 'c.example')
        with self.assertRaises(SubscriptionError): parse_node('[1, 2]', strict=False)
        self.assertIn('node', get(self.home, '订阅甲'))

    def test_cli_reports_json(self):
        with patch.object(sys, 'argv', ['node_manager.py', 'status', '--home', str(self.home)]), patch('builtins.print') as output:
            self.assertEqual(node_manager.main(), 0)
        self.assertEqual(len(json.loads(output.call_args[0][0])['nodes']), 2)


if __name__ == '__main__': unittest.main()
