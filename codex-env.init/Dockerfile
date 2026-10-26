FROM debian:trixie-slim

RUN --mount=type=secret,id=environment_ca \
    set -eu; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        podman uidmap fuse-overlayfs passt slirp4netns crun \
        systemd-sysv dbus-user-session iproute2 ca-certificates curl \
        bash coreutils findutils grep sed procps shellcheck; \
    if [ -s /run/secrets/environment_ca ]; then \
        cp /run/secrets/environment_ca /usr/local/share/ca-certificates/environment-proxy.crt; \
        chmod 0644 /usr/local/share/ca-certificates/environment-proxy.crt; \
        update-ca-certificates; \
    fi; \
    rm -rf /var/lib/apt/lists/*; \
    useradd --create-home --uid 1000 --shell /bin/bash tester; \
    mkdir -p /var/lib/systemd/linger /home/tester/work /home/tester/.config/containers; \
    touch /var/lib/systemd/linger/tester; \
    printf '[storage]\ndriver = "overlay"\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\n' \
        > /home/tester/.config/containers/storage.conf; \
    chown -R tester:tester /home/tester

STOPSIGNAL SIGRTMIN+3
CMD ["/bin/bash", "-ec", "if [ ! -c /dev/fuse ]; then mknod /dev/fuse c 10 229; fi; chmod 0666 /dev/fuse; exec /sbin/init"]
