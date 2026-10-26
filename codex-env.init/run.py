#!/usr/bin/env python3
"""Run an entire command/script as the lab's ordinary user."""
import os
from pathlib import Path
import subprocess
import sys

if len(sys.argv) == 1:
    raise SystemExit('Usage: python3 run.py COMMAND [ARG ...]')
repo = Path(__file__).resolve().parent.parent
state = Path(os.environ.get('PODMAN_LAB_STATE_DIR', repo.parent / '.environment/rootless-podman'))
env = os.environ.copy()
env.setdefault('DOCKER_CONFIG', str(state / 'docker'))
args = ['docker', 'exec', '-i', '--user', '1000:1000',
        '--env', 'HOME=/home/tester', '--env', 'USER=tester', '--env', 'LOGNAME=tester',
        '--env', 'LANG=C.UTF-8', '--env', 'LC_ALL=C.UTF-8',
        '--env', 'XDG_RUNTIME_DIR=/run/user/1000',
        '--env', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus',
        '--workdir', '/home/tester/work']
for name in ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'no_proxy', 'NO_PROXY']:
    if os.environ.get(name):
        args += ['--env', name]
args += ['codex-rootless-podman', *sys.argv[1:]]
raise SystemExit(subprocess.run(args, env=env).returncode)
