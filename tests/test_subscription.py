import base64
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mihomo'))
from parse_sub import SubscriptionError, load_yaml, parse_subscription, to_yaml
from subscription import SubscriptionManager

NODE = {'name': '测试 "节点"', 'type': 'trojan', 'server': 'node.example', 'port': 443,
        'password': 'test-credential', 'tls': True, 'udp': True, 'alpn': ['h2', 'http/1.1']}
YAML = '''proxies:
  - name: 测试节点
    type: trojan
    server: node.example
    port: 443
    password: test-credential
    tls: true
    udp: true
    alpn: [h2, http/1.1]
proxy-groups:
  - name: remote-group
    type: select
    proxies: [测试节点]
rules:
  - MATCH,remote-group
'''


class ParserTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def parse(self, text):
        path = self.directory / 'response'
        path.write_text(text)
        return parse_subscription(path)

    def test_clash_yaml_preserves_types_and_node_options(self):
        nodes, form, failures = self.parse(YAML)
        self.assertEqual(form, 'Clash YAML')
        self.assertEqual(len(nodes), 1)
        self.assertIs(nodes[0]['tls'], True)
        self.assertIsInstance(nodes[0]['port'], int)
        self.assertEqual(nodes[0]['alpn'], ['h2', 'http/1.1'])
        self.assertFalse(failures)
        output = load_yaml(to_yaml({'proxies': nodes}))
        self.assertEqual(set(output), {'proxies'})

    def test_json_and_flow_yaml(self):
        self.assertEqual(self.parse(json.dumps({'proxies': [NODE]}))[0], [NODE])
        text = 'proxies: [{name: test, type: trojan, server: node.example, port: 443, password: fake}]'
        self.assertEqual(self.parse(text)[0][0]['port'], 443)

    def test_plain_and_base64_links(self):
        line = 'trojan://fake-password@node.example:443?sni=node.example#sample'
        for text in [line, base64.b64encode(line.encode()).decode().rstrip('=')]:
            self.assertEqual(self.parse(text)[0][0]['type'], 'trojan')

    def test_line_by_line_base64(self):
        lines = ['trojan://first@a.example:443#first', 'trojan://second@b.example:443#second']
        text = '\n'.join(base64.b64encode(line.encode()).decode() for line in lines)
        self.assertEqual(len(self.parse(text)[0]), 2)

    def test_empty_html_and_empty_proxies_fail(self):
        for text in ['', '<html>sign in</html>', 'proxies: []', '{"rules": []}']:
            with self.subTest(text=text), self.assertRaises(SubscriptionError):
                self.parse(text)

    def test_duplicate_invalid_ports_and_cycles_fail(self):
        for proxies in [[NODE, NODE], [{**NODE, 'port': True}], [{**NODE, 'port': 99999}]]:
            with self.assertRaises(SubscriptionError):
                self.parse(json.dumps({'proxies': proxies}))
        with self.assertRaises(SubscriptionError):
            self.parse('proxies: &loop [*loop]')

    def test_yaml_object_construction_is_denied(self):
        with self.assertRaises(SubscriptionError):
            load_yaml('!!python/object/apply:builtins.str [unsafe]')

    def test_ruby_fallback_loads_yaml_safely(self):
        with patch.dict(sys.modules, {'yaml': None}):
            result = load_yaml(YAML)
            self.assertEqual(len(result['proxies']), 1)
            self.assertIs(result['proxies'][0]['tls'], True)
            with self.assertRaises(SubscriptionError):
                load_yaml('!ruby/object:Object {}')

    def test_quotes_and_lists_round_trip(self):
        node = {**NODE, 'alpn': ['quote"here', 'back\\slash', 'colon:value']}
        self.assertEqual(load_yaml(to_yaml({'proxies': [node]}))['proxies'], [node])

    def test_bad_input_does_not_replace_existing_node_file(self):
        source = self.directory / 'bad'
        target = self.directory / 'nodes.yaml'
        source.write_text('<html>error test-credential</html>')
        target.write_text('old nodes')
        import parse_sub
        output = io.StringIO()
        with patch.object(sys, 'argv', ['parse_sub.py', str(source), str(target), '--nodes-only']), contextlib.redirect_stderr(output):
            self.assertEqual(parse_sub.main(), 1)
        self.assertEqual(target.read_text(), 'old nodes')
        self.assertNotIn('test-credential', output.getvalue())


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.manager = SubscriptionManager(self.directory)
        self.manager.url_file.write_text('https://old.example/sub')
        self.manager.nodes_file.parent.mkdir()
        self.manager.nodes_file.write_text('old nodes')
        self.manager.runtime_file.write_text('old runtime')

    def contents(self):
        return {path.name: path.read_bytes() for path in [self.manager.url_file, self.manager.nodes_file, self.manager.runtime_file]}

    def test_test_only_uses_new_url_and_changes_nothing(self):
        old = self.contents()
        with patch.object(self.manager, 'fetch', return_value=[NODE]) as fetch, patch.object(self.manager, 'control') as control:
            self.manager.execute('test', 'https://new.example/sub')
            fetch.assert_called_once_with('https://new.example/sub')
            control.assert_not_called()
        self.assertEqual(self.contents(), old)

    def test_fetch_failure_preserves_files_and_service(self):
        old = self.contents()
        with patch.object(self.manager, 'fetch', side_effect=SubscriptionError('invalid YAML')), patch.object(self.manager, 'control') as control:
            with self.assertRaises(SubscriptionError):
                self.manager.execute('save', 'https://new.example/sub')
            control.assert_not_called()
        self.assertEqual(self.contents(), old)

    def test_save_commits_and_verifies_loaded_nodes(self):
        with patch.object(self.manager, 'fetch', return_value=[NODE]), patch.object(self.manager, 'running', return_value=False), \
             patch.object(self.manager, 'control') as control, patch.object(self.manager, 'verify') as verify:
            self.manager.execute('save', 'https://new.example/sub')
            control.assert_called_once_with('start')
            verify.assert_called_once_with([NODE])
        self.assertEqual(self.manager.url_file.read_text(), 'https://new.example/sub')
        self.assertEqual(load_yaml(self.manager.nodes_file.read_text())['proxies'], [NODE])
        self.assertEqual(self.manager.nodes_file.stat().st_mode & 0o777, 0o600)

    def test_failed_start_restores_url_nodes_and_runtime(self):
        old = self.contents()
        def control(action):
            if action == 'start':
                self.manager.runtime_file.write_text('new runtime')
                raise SubscriptionError('startup failure')
        with patch.object(self.manager, 'fetch', return_value=[NODE]), patch.object(self.manager, 'running', return_value=False), \
             patch.object(self.manager, 'control', side_effect=control):
            with self.assertRaises(SubscriptionError):
                self.manager.execute('save', 'https://new.example/sub')
        self.assertEqual(self.contents(), old)

    def test_verification_failure_restarts_original_service(self):
        old = self.contents()
        with patch.object(self.manager, 'fetch', return_value=[NODE]), patch.object(self.manager, 'running', return_value=True), \
             patch.object(self.manager, 'control') as control, patch.object(self.manager, 'verify', side_effect=SubscriptionError('not loaded')):
            with self.assertRaises(SubscriptionError):
                self.manager.execute('save', 'https://new.example/sub')
        self.assertEqual(self.contents(), old)
        self.assertEqual([call.args[0] for call in control.call_args_list], ['stop', 'start', 'stop', 'start'])


if __name__ == '__main__':
    unittest.main()
