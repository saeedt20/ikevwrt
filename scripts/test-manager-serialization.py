#!/usr/bin/env python3
"""Overlapping user requests and initialized read paths, without a router."""
import os
from pathlib import Path
import select
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANAGER = ROOT / 'luci-ikev2-manager/ikev2-manager.sh'

with tempfile.TemporaryDirectory() as folder:
    work = Path(folder)
    router = work / 'root'
    for name in ('etc/config', 'etc/ikev2-manager', 'etc/swanctl/conf.d', 'var/run'):
        (router / name).mkdir(parents=True, exist_ok=True)
    (router / 'etc/config/ikev2-manager').write_text(
        'globals=globals\nglobals.schema_version=2\nglobals.configured=0\n')
    database = router / 'etc/ikev2-manager/users.db'
    database.write_text('original\t0sYWJj\n')
    (router / 'etc/swanctl/conf.d/91-inbound-secrets.conf').write_text('secrets {}\n')
    binary = work / 'bin'
    binary.mkdir()
    uci = binary / 'uci'
    uci.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$TEST_UCI_LOG"\nexec ' +
                   shlex.quote(str(ROOT / 'scripts/uci-stub.sh')) + ' "$@"\n')
    swanctl = binary / 'swanctl'
    swanctl.write_text('''#!/bin/sh
if [ "${TEST_BLOCK:-0}" = 1 ]; then
    printf ready >&4
    read -r resume <&3
fi
exit 0
''')
    uci.chmod(0o755)
    swanctl.chmod(0o755)
    env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
               IKEV2_ROOT=str(router), IKEV2_UCI_BIN=str(uci),
               UCI_STUB_DIR=str(router / 'etc/config'),
               TEST_UCI_LOG=str(work / 'uci.log'),
               IKEV2_RUNTIME_LIB_DIR=str(ROOT / 'ikev2-manager-runtime/lib'),
               IKEV2_ACTION_LOCK_WAIT_SECONDS='1')
    subprocess.run(['sh', str(MANAGER), 'users-show'], env=env,
                   check=True, capture_output=True, timeout=10)
    commands = (work / 'uci.log').read_text().splitlines()
    assert not any(' commit ' in c or ' set ' in c for c in commands), commands

    for user in ('alice', 'bob'):
        (work / (user + '.in')).write_text('add\n' + user + '\nsecret\n')
    ready_r, ready_w = os.pipe()
    resume_r, resume_w = os.pipe()
    command = (f'exec 4>&{ready_w}\nexec 3<&{resume_r}\nexec sh ' +
               shlex.quote(str(MANAGER)) + ' user-secret-set')
    first = subprocess.Popen(['sh', '-c', command], env=dict(
        env, TEST_BLOCK='1', IKEV2_USER_INPUT=str(work / 'alice.in')),
        pass_fds=(ready_w, resume_r), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.close(ready_w)
    os.close(resume_r)
    try:
        assert select.select([ready_r], [], [], 10)[0], 'first request did not reach reload'
        assert os.read(ready_r, 5) == b'ready'
        second = subprocess.run(['sh', str(MANAGER), 'user-secret-set'], env=dict(
            env, IKEV2_USER_INPUT=str(work / 'bob.in')), capture_output=True, timeout=10)
        assert second.returncode != 0, 'overlapping user transaction was admitted'
        assert (work / 'bob.in').exists(), 'busy request consumed its input'
        os.write(resume_w, b'continue\n')
        out, error = first.communicate(timeout=10)
        assert first.returncode == 0, (out, error)
        subprocess.run(['sh', str(MANAGER), 'user-secret-set'], env=dict(
            env, IKEV2_USER_INPUT=str(work / 'bob.in')), check=True,
            capture_output=True, timeout=10)
        assert {line.split('\t')[0] for line in database.read_text().splitlines()} == {
            'original', 'alice', 'bob'}
        assert not (router / 'var/run/ikev2-action.lock').exists()
        assert not (router / 'var/run/ikev2-manager-config.lock').exists()
    finally:
        if first.poll() is None:
            first.kill()
            first.wait()
        os.close(ready_r)
        os.close(resume_w)

print('manager serialization and read-only initialization tests OK')
