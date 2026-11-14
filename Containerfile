FROM registry.redhat.io/rhel10/rhel-bootc:latest AS base


FROM base AS go-build
COPY ubi.repo /etc/yum.repos.d/ubi.repo
COPY go-build.sh /go-build.sh
RUN bash /go-build.sh


# The website repo's publish workflow builds the site and CV into its `site` branch.
FROM base AS site
ARG WEBSITE_REPO
RUN mkdir /site && curl -sSf --retry 3 --retry-all-errors https://codeload.github.com/$WEBSITE_REPO/tar.gz/refs/heads/site | tar -xz -C /site --strip-components=1


FROM base

COPY --chown=0:0 --from=site /site /usr/share/site
COPY --chown=0:0 --from=go-build /build/caddy /build/rclone /usr/bin/

COPY fstab                  /etc/fstab
COPY prepare-root.conf      /usr/lib/ostree/prepare-root.conf
COPY caddy/Caddyfile        /etc/caddy/Caddyfile
COPY journald.conf          /etc/systemd/journald.conf
COPY sandbox.conf           /usr/lib/systemd/sandbox.conf
COPY postgresql/run-as-postgres.conf /usr/lib/systemd/run-as-postgres.conf
COPY postgresql/pgdata.conf /usr/lib/systemd/pgdata.conf
COPY tailscale/wireguard-port.env /usr/lib/systemd/wireguard-port.env
COPY tmpfiles.d/root.conf   /etc/tmpfiles.d/root.conf
COPY nftables.conf          /etc/sysconfig/nftables.conf
COPY postgresql/postgresql-dirs.conf /usr/lib/tmpfiles.d/postgresql-dirs.conf
COPY caddy/caddy-dirs.conf  /usr/lib/tmpfiles.d/caddy-dirs.conf
COPY containers/policy.json /etc/containers/policy.json
COPY ubi.repo              /etc/yum.repos.d/ubi.repo
COPY tailscale/tailscale.repo /etc/yum.repos.d/tailscale.repo
COPY tailscale/RPM-GPG-KEY-tailscale /etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale
COPY postgresql/pgdg.repo  /etc/yum.repos.d/pgdg.repo
COPY postgresql/PGDG-RPM-GPG-KEY-AARCH64-RHEL /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-AARCH64-RHEL
COPY containers/bootc-gce-server.yaml /etc/containers/registries.d/bootc-gce-server.yaml
COPY containers/sigpolicy.toml /usr/lib/bootc/install/sigpolicy.toml
COPY postgresql/postgresql.conf postgresql/pg_hba.conf /etc/postgresql/
COPY postgresql/bootstrap.sql /usr/share/boot-postgresql/

COPY setup.sh boot-root.sh fetch_metadata.sh tailscale/boot-tailscale.sh postgresql/boot-postgresql.sh postgresql/bootstrap.sh /opt/scripts/
COPY boot-root.service rclone-webdav.service tailscale/boot-tailscale.service postgresql/boot-postgresql.service postgresql/postgresql.service caddy/caddy.service /usr/lib/systemd/system/
COPY boot-root-capabilities.conf /usr/lib/systemd/system/boot-root.service.d/zz-capabilities.conf
COPY caddy/caddy-capabilities.conf /usr/lib/systemd/system/caddy.service.d/zz-capabilities.conf
# The Tailscale RPM owns /usr/lib/systemd/system/tailscaled.service, and a unit in /etc/systemd/system replaces it.
COPY tailscale/tailscaled.service /etc/systemd/system/tailscaled.service
COPY tailscale/nftables-wireguard-port.conf /usr/lib/systemd/system/nftables.service.d/wireguard-port.conf

RUN chmod +x /opt/scripts/* && /opt/scripts/setup.sh
