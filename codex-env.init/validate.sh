#!/bin/bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 "$script_dir/run.py" bash -se -- "${1:-localhost/nextcloud-fpm-base:ci}" <<'BASH'
set -euo pipefail
fpm_image=$1
test "$(id -u)" = 1000
test "$(podman info --format '{{.Host.Security.Rootless}}')" = true
for image in docker.io/library/alpine:3.23 "$fpm_image"; do
    if ! podman image exists "$image"; then
        printf 'Required test image missing: %s; pull or load it first\n' "$image" >&2
        exit 1
    fi
done
test "$(podman run --rm --network=none --memory=64m docker.io/library/alpine:3.23 cat /sys/fs/cgroup/memory.max)" = 67108864
echo 'Rootless memory limit: passed'
work=$(mktemp -d /home/tester/work/environment-smoke.XXXXXXXX)
token=${work##*/}
token=${token,,}
cleanup() {
    rc=$?
    trap - EXIT
    podman rm -f "$token-web" >/dev/null 2>&1 || true
    podman image rm "localhost/$token:check" >/dev/null 2>&1 || true
    if ! podman unshare rm -rf -- "$work"; then
        rc=1
    fi
    exit "$rc"
}
trap cleanup EXIT
printf 'FROM docker.io/library/alpine:3.23\nRUN printf "rootless-build-ok\\n" > /build-proof\n' > "$work/Containerfile"
podman build --pull=never --network=none -t "localhost/$token:check" "$work"
test "$(podman run --rm --network=none "localhost/$token:check" cat /build-proof)" = rootless-build-ok
echo 'Rootless image build and run: passed'
printf 'rootless-network-ok\n' > "$work/probe.txt"
podman run -d --name "$token-web" --pull=never --network=pasta \
    -p 127.0.0.1::8080 --read-only \
    --mount "type=bind,src=$work,dst=/probe,readonly" \
    --entrypoint /usr/bin/python3 "$fpm_image" \
    -m http.server 8080 --bind 0.0.0.0 --directory /probe
endpoint=$(podman port "$token-web" 8080/tcp)
for attempt in $(seq 1 30); do
    if curl --noproxy '*' -fsS "http://$endpoint/probe.txt" > "$work/response.txt" 2>/dev/null; then
        test "$(cat "$work/response.txt")" = rootless-network-ok
        echo 'Rootless pasta network and loopback port: passed'
        exit 0
    fi
    sleep 1
done
podman logs "$token-web"
exit 1
BASH
