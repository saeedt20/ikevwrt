#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nikitid
"""Transition regressions from the installed-runtime audit; offline only."""
import json
import os
from pathlib import Path
import select
import signal
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def function(file, name):
    source = (ROOT / file).read_text()
    start = source.index(name + '() ')
    closing = ')' if source[start + len(name) + 3] == '(' else '}'
    end = source.index('\n' + closing + '\n', start) + 3
    return source[start:end] + '\n'

def run(source, env=None, success=True):
    p = subprocess.run(['sh', '-c', source], env=env, capture_output=True, text=True, timeout=15)
    assert (p.returncode == 0) == success, (p.returncode, p.stdout, p.stderr)
    return p.stdout

with tempfile.TemporaryDirectory() as folder:
    work = Path(folder)
    env = dict(os.environ, WORK=folder)
    actions = '. ' + shlex.quote(str(ROOT / 'ikev2-manager-runtime/lib/actions.sh')) + '\n'
    # Suspend the first owner after mkdir. A second owner and a stale-lock
    # inspector must both respect the publication gate, without timing guesses.
    for mode in ('pid', 'action'):
        lock = work / (mode + '.lock')
        ready_r, ready_w = os.pipe()
        resume_r, resume_w = os.pipe()
        acquire = 'pid_lock_acquire "$lock"' if mode == 'pid' else 'acquire_action_lock test one'
        busy = 'pid_lock_busy "$lock"' if mode == 'pid' else 'action_lock_busy'
        release = 'pid_lock_release "$lock"' if mode == 'pid' else 'release_action_lock'
        setup = actions + 'stat() { echo 1; }; date() { case "$1" in -r) echo 1;; *) command date "$@";; esac; }\n' + f'lock={shlex.quote(str(lock))}\naction_lock_dir="$lock"\naction_lock_status="$lock.status"\n'
        owner_code = setup + f'''
mkdir() {{
    command mkdir "$@" || return
    printf ready >&{ready_w}
    read -r resume <&{resume_r}
}}
{acquire} || exit 1
printf held >&{ready_w}
read -r resume <&{resume_r}
{release}
'''
        owner = subprocess.Popen(['sh', '-c', owner_code], pass_fds=(ready_w, resume_r), env=env, start_new_session=True)
        os.close(ready_w)
        os.close(resume_r)
        def receive(expected):
            assert select.select([ready_r], [], [], 10)[0], 'owner failed to reach interleaving barrier'
            assert os.read(ready_r, len(expected)) == expected
        try:
            receive(b'ready')
            run(setup + 'IKEV2_ACTION_LOCK_WAIT_SECONDS=1\n' + acquire, env, False)
            run(setup + busy, env)
            assert lock.is_dir()
            os.write(resume_w, b'continue\n')
            receive(b'held')
            # An unrelated process cannot release the actual owner's lock.
            run(setup + release, env)
            assert lock.is_dir()
            os.write(resume_w, b'continue\n')
            assert owner.wait(timeout=10) == 0
            assert not lock.exists()
        finally:
            os.killpg(owner.pid, signal.SIGKILL) if owner.poll() is None else None
            owner.wait()
            os.close(ready_r)
            os.close(resume_w)
        # The supported router has no stat applet. A crash before publishing
        # a PID must still become recoverable after the legacy grace period.
        lock.mkdir()
        run(setup + 'stat() { return 127; }\n' + acquire + ' && ' + release, env)
        assert not lock.exists()
        # Legacy stale owners remain recoverable after an upgrade.
        lock.mkdir()
        if mode == 'pid':
            (lock / 'pid').write_text('99999999\n')
        else:
            Path(str(lock) + '.status').write_text('pid=99999999\n')
        run(setup + acquire + ' && ' + release, env)
        assert not lock.exists()
    print('audit: publication race, foreign release and stale recovery OK')

    # Every mutation must preserve at least one terminal default, including a
    # legacy metric-zero guard and a rejected netlink update.
    bindir = work / 'bin'
    bindir.mkdir()
    ip = bindir / 'ip'
    ip.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(os.environ['WORK'])/'routes.json'
s=json.loads(p.read_text()); a=sys.argv[1:]
if 'show' in a:
    for metric in s['guards']:
        print('unreachable default' + ((' metric '+str(metric)) if metric else ''))
elif 'replace' in a:
    if s.get('fail'): sys.exit(1)
    s['guards']=sorted(set(s['guards']+[32767]))
elif 'flush' in a:
    assert a[-3:] == ['unreachable','metric','0'], a
    s['guards']=[m for m in s['guards'] if m != 0]
else: raise AssertionError(a)
if 'show' not in a:
    assert s['guards'], 'terminal default disappeared during mutation'
    s['mutations']+=1
    p.write_text(json.dumps(s))
''')
    ip.chmod(0o755)
    env['PATH'] = str(bindir) + os.pathsep + os.environ['PATH']
    routes = work / 'routes.json'
    guard = function('ikev2-manager-runtime/lib/routing.sh', 'ensure_failclosed_default')
    for family in (4, 6):
        for initial, fail in [([32767], False), ([0], False), ([0], True), ([], True)]:
            routes.write_text(json.dumps(dict(guards=initial, fail=fail, mutations=0)))
            run(guard + f'ensure_failclosed_default {family} 123', env, not fail)
            result = json.loads(routes.read_text())
            if initial == [32767]: assert result['mutations'] == 0
            if not fail: assert 32767 in result['guards']
            if fail: assert result['guards'] == initial
    print('audit: continuous fail-closed guard and netlink error propagation OK')

    # A probe success requires a query response, and both bootstrap and DoH
    # must bind to the tunnel. A server address in nslookup output is no answer.
    domain = 'ikev2-manager-runtime/ikev2-domain-router.sh'
    probe = ''.join(function(domain, name) for name in
                    ('valid_dns_name', 'parse_tunnel_doh', 'bounded_nslookup', 'tunnel_dns_query'))
    worker = bindir / 'sing-box'
    worker.write_text('''#!/usr/bin/env python3
import json,os,signal,sys
from pathlib import Path
args=sys.argv
cfg=Path(args[args.index('-c')+1])
s=json.loads(cfg.read_text())
root=Path(os.environ['WORK'])
(root/'probe-captured.json').write_text(json.dumps(s))
(root/'worker-pid').write_text(str(os.getpid()))
(root/'worker-dir').write_text(str(cfg.parent))
with open(root/'ready', 'w') as pipe: pipe.write('ready\\n')
signal.pause()
''')
    worker.chmod(0o755)
    lookup = bindir / 'nslookup'
    lookup.write_text('''#!/bin/sh
[ "$1" = openwrt.org ] && [ "$2" = 127.0.0.44 ] || exit 3
case "$ANSWER" in
 good) printf 'Server: 127.0.0.44\nAddress: 127.0.0.44#53\nName: openwrt.org\nAddress: 203.0.113.20\n';;
 server-only) printf 'Server: 127.0.0.44\nAddress: 127.0.0.44#53\n';;
 error) printf '** server cannot find openwrt.org: NXDOMAIN\n'; exit 1;;
 empty) printf 'Name: openwrt.org\n';;
esac
''')
    lookup.chmod(0o755)
    os.mkfifo(work / 'ready')
    setup = '''listener_calls=0
listener_ready() {
    listener_calls=$((listener_calls + 1))
    [ "$listener_calls" != 1 ] || return 1
    read -r ready <"$WORK/ready"
}
'''
    env['IKEV2_SING_BOX'] = str(worker)
    for answer in ('good', 'server-only', 'error', 'empty'):
        run(probe + setup + 'tunnel_dns_query https://dns.example.net:444/dns-query 192.0.2.53:53',
            dict(env, ANSWER=answer), answer == 'good')
        cfg = json.loads((work / 'probe-captured.json').read_text())
        servers = cfg['dns']['servers']
        assert all(s['bind_interface'] == 'ipsec-out' for s in servers)
        assert servers[0]['server'] == '192.0.2.53' and servers[0]['server_port'] == 53
        assert servers[1]['tls']['server_name'] == 'dns.example.net'
        assert servers[1]['server_port'] == 444 and servers[1]['path'] == '/dns-query'
        assert servers[1]['domain_resolver']['server'] == servers[0]['tag']
        assert cfg['dns']['disable_cache'] is True
        assert cfg['route']['default_domain_resolver'] == 'probe'
        assert cfg['route']['rules'][0]['action'] == 'hijack-dns'
        assert not Path((work / 'worker-dir').read_text()).exists(), 'probe left private files'
        try:
            os.kill(int((work / 'worker-pid').read_text()), 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError('probe left running worker')
    print('audit: real-query contract, tunnel-bound bootstrap and worker cleanup OK')

    health = (ROOT / 'ikev2-manager-runtime/ikev2-health.sh').read_text()
    a = health.index('\t\t\tstate=up\n')
    b = health.index('\t\t\tprintf', a)
    for failures, routing, expected in [(0,'ok','up'), (1,'ok','degraded'), (0,'degraded','degraded')]:
        run(f'failures={failures}; routing_policy_state={routing}\n' + health[a:b] +
            f'[ "$state" = {expected} ]', env)
    print('audit: failed data probe cannot report healthy OK')

    # Targeted proxy retirement uses source CIDRs, retains other clients, and
    # keeps the API credential out of process arguments.
    closer = function('luci-ikev2-domains/ikev2-devices.sh', 'close_device_connections')
    jf = bindir / 'jsonfilter'
    jf.write_text('''#!/usr/bin/env python3
import json,sys
args=sys.argv[1:]
if '-i' in args:
    if args[args.index('-i')+1]=='config': obj={'experimental':{'clash_api':{'secret':'a'*64}}}
    else: obj=json.load(open(args[args.index('-i')+1]))
else: obj=json.loads(args[args.index('-s')+1])
key=args[-1]
if '-t' in args: print('array' if isinstance(obj.get('connections'),list) else 'null')
elif key=='@.experimental.clash_api.secret': print(obj['experimental']['clash_api']['secret'])
elif key=='@.connections[*]':
    for c in obj['connections']: print(json.dumps(c))
elif key=='@.id': print(obj['id'])
elif key=='@.metadata.sourceIP': print(obj['metadata']['sourceIP'])
else: sys.exit(1)
''')
    jf.chmod(0o755)
    curl = bindir / 'curl'
    curl.write_text('''#!/usr/bin/env python3
import json,os,stat,sys
from pathlib import Path
args=sys.argv[1:]; root=Path(os.environ['WORK'])
assert not any('Bearer' in a for a in args)
config=Path(args[args.index('--config')+1])
assert stat.S_IMODE(config.stat().st_mode)==0o600
if os.environ.get('API_FAIL')=='1': sys.exit(22)
if '-X' in args:
    with (root/'closed').open('a') as f: f.write(args[-1].split('/')[-1]+'\\n')
else: print(json.dumps({'connections':[
 {'id':'11111111-1111-1111-1111-111111111111','metadata':{'sourceIP':'192.0.2.4'}},
 {'id':'22222222-2222-2222-2222-222222222222','metadata':{'sourceIP':'192.0.2.5'}},
 {'id':'33333333-3333-3333-3333-333333333333','metadata':{'sourceIP':'198.51.100.5'}}]}))
''')
    curl.chmod(0o755)
    setup = '''APP_CONFIG=test; IKEV2_DOMAIN_CONFIG=config
uci() { case "$*" in *engine) echo fakeip;; *) echo 0;; esac; }
'''
    for address, count in [('192.0.2.4',1), ('192.0.2.0/24',2), ('203.0.113.4',0)]:
        (work/'closed').write_text('')
        run(closer + setup + f'close_device_connections {address}', env)
        closed=(work/'closed').read_text().splitlines()
        assert len(closed)==count and not any(c.startswith('3333') for c in closed)
    run(closer + setup + 'close_device_connections 192.0.2.4', dict(env, API_FAIL='1'), False)
    print('audit: targeted proxy CIDR cleanup, credential handling and API errors OK')

    # Resume must reconnect dnsmasq, not only prove that the worker answers.
    resume = function('ikev2-manager-runtime/ikev2-domain-router.sh', 'resume_routing')
    setup = '''
dns_address=127.0.0.42
init_config() { :; }
check_config() { :; }
wait_for_dns() { :; }
nft_start() { :; }
/etc/init.d/ikev2-domain-router() { return 0; }
use_fakeip_dns() { echo cutover; [ "$FAIL_CUTOVER" = 0 ]; }
wait_for_query() { echo "query:$1"; return 0; }
validate_dns_server() { echo "validate:$1"; [ "$1" != 127.0.0.1 ] || [ "$FAIL_QUERY" = 0 ]; }
restore_dnsmasq() { echo rollback; }
write_status() { echo "state:$1"; }
'''
    for cutover, query in [('0', '0'), ('1', '0'), ('0', '1')]:
        result = subprocess.run(['bash', '-c', setup + resume + '\nresume_routing'],
                                env=dict(env, FAIL_CUTOVER=cutover, FAIL_QUERY=query),
                                capture_output=True, text=True, timeout=10)
        if cutover == query == '0':
            assert result.returncode == 0 and 'validate:127.0.0.1' in result.stdout
            assert result.stdout.index('cutover') < result.stdout.index('state:active')
        else:
            assert result.returncode != 0 and 'state:error' in result.stdout
            assert 'state:active' not in result.stdout
    validator = function('ikev2-manager-runtime/ikev2-domain-router.sh', 'validate_dns_server')
    # A failed probe must return, so retries and rollback can execute.
    run('''dns_address=127.0.0.42
die() { exit 7; }
selected_test_domain() { echo vpn.example; }
lookup_address() { echo 203.0.113.4; }
is_fakeip() { return 1; }
''' + validator + '\nif validate_dns_server; then exit 1; fi\necho returned\n', env)
    print('audit: resume DNS cutover, failure status and catchable probes OK')
