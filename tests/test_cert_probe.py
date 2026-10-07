from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mihomo'))
from cert_probe import classify_dates, tls_target, inspect_certificate, combine_certificates


class CertificateTests(unittest.TestCase):
    def test_expiry_boundaries_and_untrusted_are_distinct(self):
        now = 2_000_000_000
        self.assertEqual(classify_dates(now-100, now+31*86400, now)['state'], 'valid')
        self.assertEqual(classify_dates(now-100, now+30*86400, now)['state'], 'expiring')
        self.assertEqual(classify_dates(now-100, now, now)['state'], 'expired')
        self.assertEqual(classify_dates(now+1, now+86400, now)['state'], 'not_yet_valid')
        self.assertEqual(classify_dates(now-100, now+60*86400, now, trusted=False)['state'], 'untrusted')
        self.assertEqual(classify_dates(now-100, now-1, now)['days_left'], 0)

    def test_sni_and_special_protocols(self):
        node = {'type':'trojan','server':'example.com','port':443,'sni':'tls.example'}
        self.assertEqual(tls_target(node), ('example.com',443,'tls.example'))
        self.assertEqual(tls_target({**node,'servername':'override.example'})[2], 'override.example')
        self.assertEqual(tls_target({'type':'vless','tls':True,'reality-opts':{'public-key':'demo'}})['state'], 'not_applicable')
        self.assertEqual(tls_target({'type':'ss'})['state'], 'not_applicable')
        self.assertEqual(tls_target({'type':'tuic'})['state'], 'unsupported')

    def test_connection_failure_is_unknown_not_expired(self):
        with socket.socket() as closed:
            closed.bind(('127.0.0.1',0)); port=closed.getsockname()[1]
        value=inspect_certificate({'type':'trojan','server':'127.0.0.1','port':port}, timeout=.2)
        self.assertEqual(value['state'], 'unknown')
        self.assertNotIn('not_after',value)

    def test_chain_reports_worst_or_earliest_certificate(self):
        valid={'state':'valid','not_after':9999999999}
        soon={'state':'expiring','not_after':8888888888}
        expired={'state':'expired','not_after':1111111111}
        self.assertEqual(combine_certificates([valid,soon])['state'],'expiring')
        self.assertEqual(combine_certificates([soon,expired])['state'],'expired')
        self.assertEqual(combine_certificates([valid,{'state':'unknown'}])['state'],'unknown')

    def test_local_tls_certificate_dates_are_read_without_trusting_self_signed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); cert=root/'cert.pem'; key=root/'key.pem'
            subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','10',
                            '-keyout',str(key),'-out',str(cert),'-subj','/CN=localhost'],
                           check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(str(cert),str(key))
            listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(4); listener.settimeout(.2)
            port=listener.getsockname()[1]; stopped=threading.Event()
            def serve():
                while not stopped.is_set():
                    try: raw,_=listener.accept()
                    except socket.timeout: continue
                    except OSError: break
                    try:
                        with context.wrap_socket(raw,server_side=True) as secured:
                            secured.settimeout(.5)
                            try: secured.recv(1)
                            except OSError: pass
                    except ssl.SSLError: raw.close()
            thread=threading.Thread(target=serve,daemon=True); thread.start()
            try:
                result=inspect_certificate({'type':'trojan','server':'127.0.0.1','port':port,'sni':'localhost'})
                self.assertEqual(result['state'],'untrusted')
                self.assertFalse(result['trusted'])
                self.assertGreater(result['days_left'],0)
                self.assertIn('not_after',result)
            finally:
                stopped.set(); listener.close(); thread.join(timeout=2)

if __name__=='__main__': unittest.main()
