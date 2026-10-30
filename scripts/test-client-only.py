#!/usr/bin/env python3
"""Client-only upgrade retirement and outbound settings preservation."""
from pathlib import Path
import json, os, re, subprocess, tarfile, tempfile

ROOT=Path(__file__).resolve().parents[1]
MIGRATE=ROOT/'ikev2-manager-runtime/ikev2-client-migrate.sh'
BUNDLE=ROOT/'luci-ikev2-domains/iran/domains.lst'
with tempfile.TemporaryDirectory() as directory:
    work=Path(directory); router=work/'root'; config=router/'etc/config'; config.mkdir(parents=True)
    binary=work/'bin'; binary.mkdir()
    log=work/'runtime.log'
    state=router/'etc/ikev2-manager'; state.mkdir()
    conns=router/'etc/swanctl/conf.d'; conns.mkdir(parents=True)
    shared=router/'usr/share/ikev2-domains'; shared.mkdir(parents=True)
    (shared/'iran-domains.txt').write_bytes(BUNDLE.read_bytes())
    (config/'ikev2-manager').write_text('globals=globals\nglobals.schema_version=2\nglobals.configured=1\nserver=server\nserver.enabled=1\nserver.outbound_zone=clientvpn\nclient=client\nclient.enabled=1\nclient.remote_address=vpn.example.net\nclient.username=outbound-user\nclient.tunnel_dns_provider=google\nclient.tunnel_dns_upstream=https://dns.google/dns-query\ndomains=domains\ndomains.iran_direct=0\nold_user=user_policy\nold_user.username=old-user\n')
    (config/'firewall').write_text('ikev2pbr_in=zone\nikev2pbr_in.name=ikev2in\nikev2pbr_server=rule\nikev2access_lan=forwarding\nikev2pbr_out=zone\nikev2pbr_out.name=clientvpn\nforeign=rule\n')
    (config/'pbr').write_text('ikev2pbr_domains=policy\nikev2pbr_domains.src_addr=@br-lan @ipsec-in\npersonal=policy\npersonal.src_addr=@custom\n')
    (state/'users.db').write_text('old-user\t0sc2VjcmV0\n')
    client_secret=b'outbound-user\t0scHJlc2VydmU=\n'
    (state/'client.secret').write_bytes(client_secret)
    (conns/'30-inbound.conf').write_text('old responder\n')
    (conns/'20-proxy-out.conf').write_text('preserve outbound\n')
    uci=binary/'uci'
    uci.write_text('#!/bin/sh\ncase "$*" in *"commit pbr") [ -f "$UCI_STUB_DIR/pbr" ] || exit 1;; esac\nexec "$TEST_UCI_STUB" "$@"\n'); uci.chmod(0o755)
    runtime='''#!/bin/sh
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >>"$TEST_RUNTIME_LOG"
case "$name:$*" in
 'ubus:call service list '*) printf '{"ikev2-user-policy":{}}\n';;
 'swanctl:--list-conns')
  if [ -f "$IKEV2_ROOT/etc/swanctl/conf.d/30-inbound.conf" ]; then printf 'ikev2-in:\n'; fi
  printf 'proxy-out:\n';;
 'fw4:check') [ "${TEST_FAIL_FW4:-0}" = 0 ];;
 *) exit 0;;
esac
'''
    for name in ('ubus','swanctl','fw4','nft','ip'):
        path=binary/name; path.write_text(runtime); path.chmod(0o755)
    env=dict(os.environ,PATH=str(binary)+os.pathsep+os.environ['PATH'],IKEV2_ROOT=str(router),IKEV2_UCI_BIN=str(uci),UCI_STUB_DIR=str(config),TEST_UCI_STUB=str(ROOT/'scripts/uci-stub.sh'),TEST_RUNTIME_LOG=str(log),IKEV2_RUNTIME_LIB_DIR=str(ROOT/"ikev2-manager-runtime/lib"),IKEV2_ACTION_LOCK=str(work/"action.lock"),IKEV2_ACTION_LOCK_STATUS=str(work/"action.status"))
    tar=binary/'tar'
    tar.write_text('#!/bin/sh\nif [ "${TEST_FAIL_TAR:-0}" = 1 ]; then printf broken >"$2"; exit 1; fi\nexec /bin/tar "$@"\n'); tar.chmod(0o755)
    failed_archive=subprocess.run(['sh',str(MIGRATE)],env=dict(env,TEST_FAIL_TAR='1'),capture_output=True)
    assert failed_archive.returncode!=0
    assert not (state/'legacy-inbound-backup.tar.gz').exists()
    assert (state/'users.db').exists() and (conns/'30-inbound.conf').exists()
    # A failure must not mark the migration complete or lose the private backup.
    first=subprocess.run(['sh',str(MIGRATE)],env=dict(env,TEST_FAIL_FW4='1'),capture_output=True)
    assert first.returncode!=0
    assert 'client_only_schema=1' not in (config/'ikev2-manager').read_text()
    archive=state/'legacy-inbound-backup.tar.gz'
    assert archive.stat().st_mode & 0o777 == 0o600
    with tarfile.open(archive) as backup:
        assert backup.extractfile('etc/ikev2-manager/users.db').read()==b'old-user\t0sc2VjcmV0\n'
    subprocess.run(['sh',str(MIGRATE)],env=env,check=True,capture_output=True)
    settings=(config/'ikev2-manager').read_text()
    assert '\nserver=' not in settings and 'old_user=' not in settings
    assert 'client.remote_address=vpn.example.net' in settings
    assert 'globals.outbound_zone=clientvpn' in settings
    assert 'client.tunnel_dns_provider=cloudflare' in settings
    assert 'client.tunnel_dns_upstream=https://cloudflare-dns.com/dns-query' in settings
    assert 'client.tunnel_dns_bootstrap=1.1.1.1:53 1.0.0.1:53' in settings
    assert 'domains.iran_direct=1' in settings
    assert (state/'client.secret').read_bytes()==client_secret
    assert (conns/'20-proxy-out.conf').read_text()=='preserve outbound\n'
    assert not (state/'users.db').exists()
    fw=(config/'firewall').read_text()
    assert 'ikev2pbr_domains.src_addr=@br-lan\n' in (config/'pbr').read_text()
    assert 'personal.src_addr=@custom' in (config/'pbr').read_text()
    assert 'foreign=rule' in fw and 'ikev2pbr_out=zone' in fw
    assert 'ikev2pbr_in=' not in fw and 'ikev2access_lan=' not in fw
    calls=log.read_text()
    assert 'swanctl --terminate --ike ikev2-in --timeout 5' in calls
    assert 'swanctl --terminate --ike proxy-out' not in calls
    assert calls.index('fw4 -q reload')<calls.index('nft delete table inet ikev2_user_policy')
    assert not (state/'iran-cidrs.txt').read_bytes()
    assert (state/'iran-domains.txt').read_bytes()==BUNDLE.read_bytes()
    before=(settings,archive.read_bytes(),log.read_bytes())
    subprocess.run(['sh',str(MIGRATE)],env=env,check=True,capture_output=True)
    assert before==( (config/'ikev2-manager').read_text(),archive.read_bytes(),log.read_bytes()),'migration is not idempotent'
    manager=ROOT/'luci-ikev2-manager/ikev2-manager.sh'
    env['IKEV2_RUNTIME_LIB_DIR']=str(ROOT/'ikev2-manager-runtime/lib')
    for action in ('server-get','users-show','acme-get','server-ensure'):
        result=subprocess.run(['sh',str(manager),action],env=env,capture_output=True)
        assert result.returncode!=0,action
    out=subprocess.check_output(['sh',str(manager),'client-get'],env=env,text=True)
    assert 'tunnel_dns_upstream=https://cloudflare-dns.com/dns-query' in out
    assert 'preserve' not in out

    # The independently applied Site Link exit role retains shared credentials.
    settings=settings.replace('globals.client_only_schema=1\n','')+'server=server\n'
    (config/'ikev2-manager').write_text(settings)
    (config/'ikev2-site-link').write_text('applied=state\napplied.enabled=1\napplied.role=exit\n')
    certificate=router/'etc/swanctl/x509/ikev2.pem'; certificate.parent.mkdir()
    certificate.write_text('shared certificate\n')
    subprocess.run(['sh',str(MIGRATE)],env=env,check=True,capture_output=True)
    assert certificate.read_text()=='shared certificate\n'
    # An unconfigured older installation may not have installed PBR yet.
    (config/'pbr').unlink()
    (config/'ikev2-manager').write_text('globals=globals\nclient=client\ndomains=domains\nserver=server\nserver.enabled=0\n')
    subprocess.run(['sh',str(MIGRATE)],env=env,check=True,capture_output=True)
    # A fresh install needs no legacy runtime or private archive.
    (config/'ikev2-manager').write_text('globals=globals\nclient=client\ndomains=domains\n')
    archive.unlink(); log.unlink()
    subprocess.run(['sh',str(MIGRATE)],env=env,check=True,capture_output=True)
    assert not archive.exists() and not log.exists()
    assert not (work/'action.lock').exists()

menu=json.loads((ROOT/'luci-ikev2-manager/menu.json').read_text())
assert not any(x.endswith(('/users','/server')) for x in menu)
acl=(ROOT/'luci-ikev2-manager/acl.json').read_text()
assert not any(x in acl for x in ['users-show','server-input','acme-issue','advanced-start inbound'])
for path in ['luci-ikev2-manager/settings.js','luci-ikev2-manager/users.js','ikev2-manager-runtime/ikev2-user-policy.sh','windows-profile-installer']:
    assert not (ROOT/path).exists(),path
# The fixed resolver definitions ignore any obsolete UCI provider settings.
source=(ROOT/'ikev2-manager-runtime/ikev2-domain-router.sh').read_text()
functions='\n'.join(re.search(r'^'+name+r'\(\) \{.*?^}',source,re.M|re.S)[0] for name in ['tunnel_dns_endpoints','tunnel_dns_bootstrap'])
output=subprocess.check_output(['sh','-c',functions+'\ntunnel_dns_endpoints; tunnel_dns_bootstrap'],text=True)
assert output=='https://cloudflare-dns.com/dns-query\n1.1.1.1:53 1.0.0.1:53\n'
print('client-only upgrade, failure/retry, credentials, retired APIs and fixed DNS tests OK')
