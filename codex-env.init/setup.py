#!/usr/bin/env python3
"""Prepare the rootless Podman lab; keep generated state outside the checkout."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--refresh-image', action='store_true', help='rebuild the lab image; retain the existing container and data')
options = parser.parse_args()
root = Path(__file__).resolve().parent
repo = root.parent
state_dir = Path(os.environ.get('PODMAN_LAB_STATE_DIR', repo.parent / '.environment/rootless-podman'))
name = 'codex-rootless-podman'
image = 'localhost/codex-rootless-podman:debian13'
env = os.environ.copy()
env.setdefault('DOCKER_CONFIG', str(state_dir / 'docker'))
Path(env['DOCKER_CONFIG']).mkdir(parents=True, exist_ok=True)


def docker(*args, capture=False, check=True):
    try:
        result = subprocess.run(['docker', *args], env=env, text=True,
                                capture_output=capture, check=False)
    except FileNotFoundError:
        raise SystemExit('Docker CLI is required on the Linux host') from None
    if check and result.returncode:
        if capture:
            message = result.stderr
            for key in ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY']:
                if env.get(key):
                    message = message.replace(env[key], '[proxy]')
            sys.stderr.write(message)
        # Do not print build arguments: proxy URLs can contain credentials.
        raise SystemExit(f'Docker {args[0]} failed (exit {result.returncode}); check host capabilities and output above')
    return result


host = docker('info', '--format', '{{.OSType}}/{{.Architecture}}', capture=True).stdout.strip()
if host not in ('linux/x86_64', 'linux/amd64'):
    raise SystemExit(f'This lab is validated on Linux amd64; detected {host}')

existing = docker('container', 'inspect', name, capture=True, check=False)
container = json.loads(existing.stdout)[0] if existing.returncode == 0 else None
if container:
    if (container['Config'].get('Labels') or {}).get('io.codex.lab') != 'rootless-podman':
        raise SystemExit('Existing container belongs to another workflow; refusing to change it')
    project_mounts = [m for m in container['Mounts'] if m['Destination'] == '/project']
    if len(project_mounts) != 1 or Path(project_mounts[0]['Source']).resolve() != repo:
        raise SystemExit('Existing lab mounts a different checkout; stop and inspect it before proceeding')
    if project_mounts[0].get('RW') or not container['HostConfig'].get('Privileged'):
        raise SystemExit('Existing lab does not meet the read-only project / privileged outer-container contract')

cert = os.environ.get('CODEX_PROXY_CERT')
has_cert = bool(cert and Path(cert).is_file())
if docker('image', 'inspect', image, capture=True, check=False).returncode or options.refresh_image:
    docker('buildx', 'version', capture=True)
    args = ['buildx', 'build', '--load', '--platform', 'linux/amd64',
            '--network', 'host', '--progress', 'plain', '-t', image]
    if has_cert:
        args += ['--secret', 'id=environment_ca,src=' + cert]
    hosts = set()
    for key in ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'no_proxy', 'NO_PROXY']:
        value = os.environ.get(key)
        if not value:
            continue
        args += ['--build-arg', key + '=' + value]
        host = urllib.parse.urlparse(value).hostname if key.lower() != 'no_proxy' else None
        if host and host not in hosts:
            try:
                address = socket.gethostbyname(host)
            except OSError:
                raise SystemExit('Cannot resolve configured proxy hostname; check runtime network configuration') from None
            args += ['--add-host', host + ':' + address]
            hosts.add(host)
    docker(*args, str(root))

if container:
    if not container['State']['Running']:
        docker('start', name)
    if options.refresh_image:
        print('Lab image rebuilt; the existing container and volume were retained')
else:
    docker('run', '-d', '--name', name, '--privileged', '--cgroupns=private',
           '--label', 'io.codex.lab=rootless-podman', '--tmpfs', '/run', '--tmpfs', '/tmp',
           '--mount', 'type=volume,src=codex-rootless-podman-home,dst=/home/tester',
           '--mount', f'type=bind,src={repo},dst=/project,readonly', image)

if has_cert:
    docker('cp', cert, name + ':/usr/local/share/ca-certificates/environment-proxy.crt')
    docker('exec', name, 'chmod', '0644', '/usr/local/share/ca-certificates/environment-proxy.crt')
    docker('exec', name, 'update-ca-certificates')
docker('exec', name, '/bin/bash', '-ec',
       'mkdir -p /dev/net; '
       'if [ ! -c /dev/net/tun ]; then mknod /dev/net/tun c 10 200; fi; '
       'chmod 0666 /dev/net/tun')
for attempt in range(30):
    if docker('exec', name, 'systemctl', 'is-active', 'systemd-logind.service',
              capture=True, check=False).returncode == 0:
        break
    time.sleep(1)
else:
    raise SystemExit('systemd-logind did not become ready; inspect docker logs ' + name)
docker('exec', name, 'systemctl', 'start', 'user@1000.service')
docker('exec', name, 'systemctl', 'set-property', 'user-1000.slice',
       'MemoryAccounting=yes', 'CPUAccounting=yes')
result = subprocess.run([sys.executable, str(root / 'run.py'), 'podman', 'info',
                         '--format', '{{.Host.Security.Rootless}}'], capture_output=True, text=True)
if result.returncode or result.stdout.strip() != 'true':
    sys.stderr.write(result.stderr)
    raise SystemExit('Rootless Podman readiness failed; do not substitute rootful Podman or Docker')
print(f'Rootless Podman lab ready: tester (uid 1000); {repo} mounted read-only at /project')
