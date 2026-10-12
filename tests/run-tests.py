#!/usr/bin/env python3
"""Isolated script/config tests. NOT a live Ubuntu or end-to-end call test.
Run: python3 tests/run-tests.py
Dependencies: bash, python3, jq, openssl, PHP CLI, nginx; root for file-owner tests.
No host service is started and no production configuration is written.
"""
import configparser
import ctypes
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import py_compile
import shlex
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'deploy-nextcloud.sh'
TMP = tempfile.TemporaryDirectory(prefix='nextcloud-script-test-')
QA = Path(TMP.name)
RENDER = QA / 'rendered'


def run(cmd, **kwargs):
    return subprocess.run(cmd, text=True, capture_output=True, **kwargs)


def bash(code, **kwargs):
    return run(['bash', '-c', f'source {shlex.quote(str(SCRIPT))}\n' + code], **kwargs)


class DeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = run(['bash', str(ROOT/'tests/render-configs.sh'), str(RENDER)])
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        spec = importlib.util.spec_from_file_location('probe', RENDER/'lib/probe.py')
        cls.probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.probe)

    def test_bash_and_embedded_syntax(self):
        for script in [SCRIPT, ROOT/'tests/render-configs.sh']:
            self.assertEqual(run(['bash', '-n', str(script)]).returncode, 0)
        py_compile.compile(str(RENDER/'lib/probe.py'), doraise=True)
        self.assertEqual(run(['php', '-l', str(RENDER/'lib/occ-stdin.php')]).returncode, 0)
        text = SCRIPT.read_text()
        hook = text.split("write_file /etc/letsencrypt/renewal-hooks/deploy/50-nextcloud-deploy 750 <<'EOF'\n",1)[1].split('\nEOF',1)[0]
        target = QA/'renewal-hook.sh'
        target.write_text(hook+'\n')
        self.assertEqual(run(['bash', '-n', str(target)]).returncode, 0)

    def test_nginx_config(self):
        certdir = RENDER/'certs'
        cert = run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '45',
            '-subj', '/CN=cloud.example.com', '-addext', 'subjectAltName=DNS:cloud.example.com,DNS:talk.example.com',
            '-keyout', str(certdir/'privkey.pem'), '-out', str(certdir/'fullchain.pem')])
        self.assertEqual(cert.returncode,0,cert.stderr)
        site = RENDER/'root/etc/nginx/sites-available/nextcloud-deploy.conf'
        target = QA/'nginx-site.conf'
        target.write_text(site.read_text().replace('/etc/nginx/snippets/nextcloud-security.conf',str(RENDER/'root/etc/nginx/snippets/nextcloud-security.conf')))
        main = QA/'nginx-test.conf'
        main.write_text(f'pid {QA}/nginx.pid; error_log {QA}/error.log; events {{ worker_connections 64; }} http {{ access_log off; include {target}; }}')
        result = run([shutil.which('nginx') or '/usr/sbin/nginx', '-t', '-c', str(main)])
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        # The certificate coverage test must reject a different hostname.
        mismatch = run(['openssl','x509','-in',str(certdir/'fullchain.pem'),'-noout','-checkhost','other.example.com'])
        self.assertNotEqual(mismatch.returncode,0)

    def test_janus_libconfig_syntax(self):
        try:
            lib = ctypes.CDLL('libconfig.so.11')
        except OSError:
            self.skipTest('libconfig is not installed')
        lib.config_init.argtypes = [ctypes.c_void_p]
        lib.config_read_file.argtypes = [ctypes.c_void_p,ctypes.c_char_p]
        lib.config_read_file.restype = ctypes.c_int
        lib.config_destroy.argtypes = [ctypes.c_void_p]
        for path in (RENDER/'root/etc/nextcloud-janus').glob('*.jcfg'):
            storage = ctypes.create_string_buffer(8192)
            lib.config_init(storage)
            result = lib.config_read_file(storage,str(path).encode())
            lib.config_destroy(storage)
            self.assertEqual(result,1,path.name)

    def test_signaling_config(self):
        conf = configparser.ConfigParser()
        conf.read(RENDER/'state/signaling.conf')
        self.assertEqual(conf['http']['listen'],'127.0.0.1:8081')
        self.assertEqual(conf['app']['trustedproxies'],'127.0.0.1')
        self.assertEqual(conf['backend']['skipverify'],'false')
        self.assertEqual(conf['backend']['allowall'],'false')
        self.assertEqual(conf['mcu']['url'],'ws://127.0.0.1:8188')
        self.assertIn(len(conf['sessions']['hashkey']),(32,64))
        self.assertIn(len(conf['sessions']['blockkey']),(16,24,32))

    def test_validation(self):
        base = '''
NEXTCLOUD_DOMAIN=cloud.example.com TALK_DOMAIN=talk.example.com TURN_DOMAIN=talk.example.com
EMAIL=admin@example.com ADMIN_USER=ncadmin DNS_KEY_NAME=nextcloud-acme.
DNS_ALGORITHM=HMAC-SHA256 DNS_SIGN_QUERY=false MANAGE_UFW=1 NC_MAJOR=35 NC_VERSION=''
HPB_IMAGE=strukturag/nextcloud-spreed-signaling:2.1.1 DEFAULT_PHONE_REGION=''
DNS_PORT=53 JANUS_MIN_PORT=20000 JANUS_MAX_PORT=20199 TURN_MIN_PORT=49160 TURN_MAX_PORT=49259
SSH_PORT=22 DNS_PROPAGATION_SECONDS=120 PHP_MAX_CHILDREN=6
'''
        self.assertEqual(bash(base+'validate_configuration').returncode,0)
        bad = ['NEXTCLOUD_DOMAIN="evil.example.com;id"', 'TALK_DOMAIN=cloud.example.com',
            'TURN_MIN_PORT=20001', 'DNS_ALGORITHM=HMAC-MD5', 'SSH_PORT=65536',
            'NC_VERSION=35.0.0RC1', 'MANAGE_UFW=2', 'PHP_MAX_CHILDREN=0']
        for change in bad:
            self.assertNotEqual(bash(base+change+'\nvalidate_configuration').returncode,0,change)

    @unittest.skipUnless(os.geteuid()==0,'Root ownership is required for file tests')
    def test_atomic_write_and_private_directory(self):
        directory = QA/'private'
        directory.mkdir(mode=0o700)
        result = bash(f'''
STATE_DIR={shlex.quote(str(QA/'state-filetest'))}
install -d -m 700 "$STATE_DIR"
p={shlex.quote(str(directory/'managed.conf'))}
printf 'first\\n' | write_file "$p" 600
before=$(stat -c %Y "$p")
sleep 1
printf 'first\\n' | write_file "$p" 600
[[ $(stat -c %Y "$p") == "$before" ]]
[[ $(stat -c %a "$(dirname "$p")") == 700 ]]
check_trusted_file "$p"
chmod 644 "$p"
if (check_trusted_file "$p"); then exit 2; fi
chmod 600 "$p"
printf 'second\\n' | write_file "$p" 600
[[ $(cat "$STATE_DIR/backups$p") == first ]]
''')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    @unittest.skipUnless(os.geteuid()==0,'Root ownership is required for file tests')
    def test_secrets_are_reused(self):
        state = QA/'state-secrets'
        state.mkdir(mode=0o700)
        result = bash(f'''
STATE_DIR={shlex.quote(str(state))}
NC_DIR={shlex.quote(str(QA/'unused-nextcloud'))}
NEXTCLOUD_DOMAIN=cloud.example.com TALK_DOMAIN=talk.example.com TURN_DOMAIN=talk.example.com ADMIN_USER=ncadmin
ensure_secrets
first=$(sha256sum "$STATE_DIR/secrets.env")
ensure_secrets
[[ $(sha256sum "$STATE_DIR/secrets.env") == "$first" ]]
[[ $(stat -c %a "$STATE_DIR/secrets.env") == 600 ]]
''')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(result.stdout,'')

    def test_talk_initialization_repeat_and_repair(self):
        state = QA/'occ-state.json'
        env = dict(os.environ,OCC_TEST_STATE=str(state))
        invoke = f'''
NEXTCLOUD_DOMAIN=cloud.example.com TALK_DOMAIN=talk.example.com TURN_DOMAIN=talk.example.com
SIGNALING_SECRET=signaling-test-secret TURN_SECRET=turn-test-secret
occ() {{ python3 -S {shlex.quote(str(ROOT/'tests/mock-occ.py'))} "$@"; }}
configure_talk
'''
        for _ in range(2):
            result = bash(invoke,env=env)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        data=json.loads(state.read_text())
        self.assertEqual(data['commands'].count('talk:signaling:add'),1)
        self.assertEqual(data['commands'].count('talk:turn:add'),2)
        self.assertEqual(data['commands'].count('talk:stun:add'),1)
        data['signaling']['servers'].append({'server':'https://talk.example.com/standalone-signaling/','verify':False})
        data['turn'][0]['secret']='wrong-secret'
        state.write_text(json.dumps(data))
        result = bash(invoke,env=env)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        data=json.loads(state.read_text())
        self.assertEqual(len(data['signaling']['servers']),1)
        self.assertTrue(data['signaling']['servers'][0]['verify'])
        self.assertEqual(len(data['turn']),2)
        self.assertTrue(all(s['secret']=='turn-test-secret' for s in data['turn']))

    def test_stun_packet_and_response_parser(self):
        probe=self.probe
        attrs=[probe.attribute(0x0019,b'\x11\0\0\0'),probe.attribute(0x0006,b'abc')]
        key=b'test-key'
        request,txid=probe.packet(3,attrs,key)
        kind,length,cookie,tx=struct.unpack('!HHI12s',request[:20])
        self.assertEqual((kind,cookie,tx),(3,probe.COOKIE,txid))
        self.assertEqual(length,len(request)-20)
        self.assertEqual(request[-20:],hmac.new(key,request[:-24],hashlib.sha1).digest())
        self.assertEqual(probe.attribute(9,b'abc')[-1:],b'\0')
        class FakeSocket:
            def sendall(self,request):
                self.response=struct.pack('!HHI12s',0x0103,0,probe.COOKIE,request[8:20])
            def recv(self,length):
                chunk=self.response[:length]
                self.response=self.response[length:]
                return chunk
        for datagram in [True,False]:
            kind,result=probe.exchange(FakeSocket(),datagram,3,attrs,key)
            self.assertEqual(kind,0x0103)
            self.assertEqual(result,{})

    def test_redis_order_and_private_listeners(self):
        code=SCRIPT.read_text()
        self.assertLess(code.index('occ config:system:set redis host'),code.index('occ config:system:set memcache.locking'))
        coturn=(RENDER/'root/etc/turnserver.conf').read_text()
        self.assertIn('use-auth-secret',coturn)
        self.assertIn('external-ip=8.8.4.4/10.0.0.2',coturn)
        self.assertIn('no-cli',coturn)
        self.assertIn('no-tcp-relay',coturn)
        self.assertIn('listen: 127.0.0.1:4222',(RENDER/'root/etc/nextcloud-nats.conf').read_text())
        self.assertIn('ws_ip = "127.0.0.1"',(RENDER/'root/etc/nextcloud-janus/janus.transport.websockets.jcfg').read_text())


if __name__=='__main__':
    try:
        unittest.main(verbosity=2)
    finally:
        TMP.cleanup()
