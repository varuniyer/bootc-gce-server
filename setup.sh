#!/usr/bin/env bash
set -euo pipefail

# Nothing logs into the VM.
dnf remove -y openssh-server openssh-clients
rm -rf /etc/ssh
# nfs-utils, gssproxy, and rpcbind serve NFS. subscription-manager, insights-client, and rhc
# register the system with Red Hat and report to it. The image uses none of them.
dnf remove -y nfs-utils gssproxy rpcbind subscription-manager insights-client rhc
dnf install -y tailscale postgresql17-server
dnf clean all
# CacheDirectory= creates /var/cache/tailscale at start. Under DynamicUser=, systemd migrates the RPM's
# root-owned copy into /var/cache/private, a rename that fails across overlay layers.
rmdir /var/cache/tailscale
# PGDG's RPM ships a per-version data tree and a login profile, and pgdata.conf's data dir uses neither.
rm -r /var/lib/pgsql/17 /var/lib/pgsql/.bash_profile
# PGDG's RPM gives postgres a login shell.
usermod -s /usr/sbin/nologin postgres
# systemd-getty-generator adds a login prompt on the kernel's serial console.
# Masking the template drops it, and the serial log stays readable.
systemctl mask serial-getty@.service

# RHEL's SELinux policy has no file contexts for Caddy's paths, so these label them for httpd_t. The boolean
# grants httpd_t only name_connect to http_port_t, which ACME and OCSP need.
semanage fcontext -a -t httpd_exec_t /usr/bin/caddy
semanage fcontext -a -t httpd_config_t '/etc/caddy(/.*)?'
semanage fcontext -a -t httpd_var_lib_t '/var/lib/caddy(/.*)?'
semanage boolean -m --on httpd_graceful_shutdown
# PGDG's server binaries take /usr/bin's labels, so postgres runs confined as postgresql_t.
semanage fcontext -a -e /usr/bin /usr/pgsql-17/bin
# COPY'd binaries and the paths above need SELinux labels.
restorecon -R /usr/bin /usr/pgsql-17 /etc/caddy

groupadd -r caddy
useradd -r -g caddy -d /var/lib/caddy -s /usr/sbin/nologin caddy

mkdir /etc/webdav /etc/pki/containers

# Rebuild initramfs so prepare-root.conf's [etc] transient takes effect.
KVER=$(basename /usr/lib/modules/*)
dracut --no-hostonly --force --kver "$KVER" /usr/lib/modules/"$KVER"/initramfs.img

# The base image ships group-writable files that its own RPMs declare 0644,
# and a umask-002 checkout makes COPY'd files group-writable.
find /usr /etc /opt \( -type f -o -type d \) -perm /022 -exec chmod go-w {} +

chown root:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile

# boot-root.service runs as Group=pghash, so the hash file it writes
# belongs to pghash, and postgres reads it as a member.
groupadd -r pghash
usermod -aG pghash postgres

# Every shipped unit links the shared sandbox.
for unit in boot-root boot-tailscale boot-postgresql tailscaled rclone-webdav caddy postgresql; do
    mkdir -p /usr/lib/systemd/system/$unit.service.d
    ln -s ../../sandbox.conf /usr/lib/systemd/system/$unit.service.d/sandbox.conf
done
for unit in boot-postgresql postgresql; do
    ln -s ../../run-as-postgres.conf /usr/lib/systemd/system/$unit.service.d/run-as-postgres.conf
done
for unit in boot-root boot-postgresql postgresql; do
    ln -s ../../pgdata.conf /usr/lib/systemd/system/$unit.service.d/pgdata.conf
done

systemctl enable nftables tailscaled boot-tailscale rclone-webdav caddy postgresql bootc-fetch-apply-updates.timer

bootc container lint
