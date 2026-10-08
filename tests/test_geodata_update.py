import fcntl
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mihomo'))
import geodata_update as geo


class GeodataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'mihomo').write_text('fixture'); (self.root / 'mihomo').chmod(0o755)
        for name in geo.FILES: (self.root / name).write_bytes(b'old ' + name.encode())
        for name in ['config.yaml', '.api-secret', '.sub-url']:
            (self.root / name).write_bytes(b'private ' + name.encode())
        self.before = {p.name: p.read_bytes() for p in self.root.iterdir()}
        self.new = {name: b'new ' + name.encode() for name in geo.FILES}

    def fetch(self, url, path):
        name = url.rsplit('/', 1)[-1]
        if name.endswith('.sha256sum'):
            path.write_text(hashlib.sha256(self.new[name.removesuffix('.sha256sum')]).hexdigest())
        else:
            path.write_bytes(self.new[name])

    def unchanged(self):
        for name, content in self.before.items(): self.assertEqual((self.root / name).read_bytes(), content)
        self.assertFalse(list(self.root.glob('.geodata-update-*')))

    def test_success_preserves_configuration_and_records_time(self):
        result = geo.update(self.root, self.fetch, lambda *_: None)
        for name in geo.FILES: self.assertEqual((self.root / name).read_bytes(), self.new[name])
        for name in ['config.yaml', '.api-secret', '.sub-url']: self.assertEqual((self.root / name).read_bytes(), self.before[name])
        self.assertIn('下次启用', result)
        self.assertTrue((self.root / '.geodata-updated-at').exists())
        self.assertIn('最新', geo.update(self.root, self.fetch, lambda *_: None))

    def test_download_failure_changes_nothing(self):
        def failure(url, path):
            if url.endswith('geosite.dat'): raise geo.GeoUpdateError('offline')
            self.fetch(url, path)
        with self.assertRaises(geo.GeoUpdateError): geo.update(self.root, failure, lambda *_: None)
        self.unchanged()

    def test_hash_failure_changes_nothing(self):
        def corrupt(url, path):
            self.fetch(url, path)
            if url.endswith('geosite.dat'): path.write_bytes(b'corrupt')
        with self.assertRaises(geo.GeoUpdateError): geo.update(self.root, corrupt, lambda *_: None)
        self.unchanged()

    def test_empty_manifest_changes_nothing(self):
        def empty(url, path): path.write_bytes(b'')
        with self.assertRaises(geo.GeoUpdateError): geo.update(self.root, empty, lambda *_: None)
        self.unchanged()

    def test_format_failure_changes_nothing(self):
        def reject(*_): raise geo.GeoUpdateError('format')
        with self.assertRaises(geo.GeoUpdateError): geo.update(self.root, self.fetch, reject)
        self.unchanged()

    def test_replace_failure_rolls_back_even_after_a_rename(self):
        def fail_after_replace(source, target):
            geo.replace(source, target)
            if target.name == 'geosite.dat': raise OSError('disk failure')
        with self.assertRaises(geo.GeoUpdateError): geo.update(self.root, self.fetch, lambda *_: None, fail_after_replace)
        self.unchanged()

    def test_concurrent_update_is_rejected(self):
        with (self.root / '.geodata-update.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(geo.GeoUpdateError): geo.update(self.root, self.fetch, lambda *_: None)
        self.unchanged()

    def test_http_failure_is_reported(self):
        with patch.object(geo.subprocess, 'run') as run:
            run.return_value.returncode = 22
            with self.assertRaises(geo.GeoUpdateError): geo.fetch('https://example.com/data', self.root / 'download')

    def test_selected_database_only_and_real_progress_events(self):
        requested = []
        events = []
        def track(url, path): requested.append(url); self.fetch(url, path)
        def inspect(stage, core):
            self.assertEqual((stage / 'geosite.dat').read_bytes(), self.before['geosite.dat'])
            self.assertEqual((stage / 'country.mmdb').read_bytes(), self.before['country.mmdb'])
        geo.update(self.root, track, inspect, selected=['geoip.dat'], progress=events.append)
        self.assertEqual(len(requested), 2)
        self.assertEqual((self.root / 'geoip.dat').read_bytes(), self.new['geoip.dat'])
        for name in ['geosite.dat', 'country.mmdb']: self.assertEqual((self.root / name).read_bytes(), self.before[name])
        downloaded = next(event for event in events if event.get('downloaded', 0) > 0)
        self.assertEqual(downloaded['downloaded'], len(self.new['geoip.dat']))
        self.assertEqual(downloaded['total'], len(self.new['geoip.dat']))
        self.assertEqual(events[-1]['phase'], 'installing')

    def test_metadata_check_fetches_no_databases_and_changes_nothing(self):
        requested = []
        def track(url, path): requested.append(url); self.fetch(url, path)
        result = geo.check(self.root, track)
        self.assertTrue(all(item['available'] for item in result.values()))
        self.assertEqual(len(requested), 3)
        self.assertTrue(all(url.endswith('.sha256sum') for url in requested))
        self.unchanged()

    def test_invalid_component_is_rejected(self):
        with self.assertRaises(geo.GeoUpdateError): geo.update(self.root, self.fetch, selected=['../other'])
        self.unchanged()


if __name__ == '__main__': unittest.main()
