# bootc-gce-server

This repository builds an immutable bootc RHEL image for a single-node personal web stack: a public static site plus tailnet-only WebDAV and PostgreSQL, with stateless configuration rendered from GCE instance metadata on every boot. Caddy serves the public site, and the MTA-STS policy at `mta-sts.<DOMAIN>`, on port 443. Tailscale exposes WebDAV and PostgreSQL to the tailnet.

The image's only deployment-specific values are the site it serves, PostgreSQL settings sized for `c4a-standard-1`, and this repository's `ghcr.io` image, which it pulls and verifies updates from. `provision.sh` puts every deployment-specific setting and secret the VM needs into GCE instance metadata, and the VM reads them at boot. The same image therefore deploys to any GCP project on an Arm machine type.

Filesystem layout follows the conventions described in the [RHEL image mode documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/index).

## Why bootc

The VM's OS is a container image. `Containerfile` and `setup.sh` define the whole OS, Podman builds it, and CI signs and publishes it like any other image. The image is ordinary RHEL with systemd units and shell scripts, so changing it takes no Nix expressions, and the VM pulls its own updates, so shipping a change takes no SSH-driven tool like Ansible.

On RHEL bootc, the base image, every package, the Go toolchain, and the published image all carry signatures that the build or the VM checks. Red Hat signs the base image and the Go toolchain, each package repository signs its packages, and CI signs the published image (see [Base Image](#architecture) and [Signed Images](#architecture)). Fedora bootc cannot match that chain, because Fedora publishes its bootc base images unsigned ([releng#10624](https://forge.fedoraproject.org/releng/tickets/issues/10624)).

Nothing logs into the VM, so the running system changes only through a signed image update (see [Signed Images](#architecture) and [Automatic Updates](#architecture)) or an instance metadata change. Because `/etc` resets on every boot (see [Stateless Configuration](#architecture)), each boot reproduces what the image and instance metadata state.

The cost is latency. Every change to the repo, a one-line config edit included, ships as a CI build that the VM applies on its own update schedule. Recovery from bad state takes a reset or reprovisioning (see [FAQ](#faq)).

## Architecture

- **Stateless Configuration**: `prepare-root.conf` makes `/etc` transient, so every boot starts it fresh from the image's `/usr/etc`. Boot scripts then render the files that derive from instance metadata. Persistent state lives under `/var`.
- **Base Image**: `Containerfile` builds upon `registry.redhat.io/rhel10/rhel-bootc:latest`. CI pulls it with a Red Hat registry service account. `containers/build-policy.json` makes the build accept it only when its sigstore signature verifies against Red Hat's release key 3. `setup.sh` installs Tailscale from Tailscale's RHEL repository and PostgreSQL 17 from the PostgreSQL project's PGDG repository, and dnf verifies each against its repository's GPG key, which the image ships. Red Hat's public UBI repositories in `ubi.repo` supply every other package and work without a Red Hat subscription. A Go stage builds Caddy and rclone from their latest release tags with Red Hat's Go, which verifies the source against the Go checksum database. Another stage fetches the built site and CV from the `site` branch of the website repo that `WEBSITE_REPO` names.
- **Continuous Integration**: A GitHub Actions workflow builds the arm64 image with Podman, signs it, pushes it to `ghcr.io`, and rebuilds the GCE seed image, which `provision.sh` creates the VM from. It installs gcloud from Google's apt repository and builds the seed image with Red Hat's `bootc-image-builder`, and it checks each against a key this repository pins. The workflow runs on each push to `main` that changes a file besides `README.md`, `AGENTS.md`, and `LICENSE`, daily from a Cloud Scheduler job so package updates ship without commits, and on dispatch from the website repo's publish workflow. A newer run cancels one in progress.
- **Automatic Updates**: The running VM pulls updates from `ghcr.io` through the `bootc-fetch-apply-updates` systemd timer and reboots to apply each one.
- **Signed Images**: CI signs each pushed image with the signing key. `containers/policy.json` makes the VM accept an update only when its signature verifies against the public key from instance metadata.

## Deployment & Configuration

`provision.sh`, `build.env`, and `containers/policy.json` hold the non-secret settings, and `provision.sh` prompts for secrets. It pushes the Caddy settings, the MTA-STS policy, the password hashes, the Tailscale OAuth client secret, and the signing public key into GCE instance metadata, stores the GitHub PAT in a Cloud Scheduler job and the website repo, and stores the signing key pair and the Red Hat registry token in GitHub Actions.

### 1. Prepare the Project
Install Podman, jq, the gcloud CLI, and the [GitHub CLI](https://cli.github.com/). Run `gh auth login` as an account that can manage Actions secrets and variables in this repository and the website repo, and `gcloud auth login` as a project owner. Select the project with `gcloud config set project`, then enable the APIs that the script and CI use:
```bash
gcloud services enable compute.googleapis.com cloudscheduler.googleapis.com iam.googleapis.com iamcredentials.googleapis.com storage.googleapis.com
```
CI authenticates through the IAM Credentials API. Only CI calls it, so this command is the one step that enables it. The first build fails if the command has not run.

In the Tailscale admin console, enable HTTPS certificates for the tailnet and create an OAuth client with `auth_keys` write scope on `tag:server`. In the Tailscale policy file, give `tag:server` a `tagOwners` entry and grant clients access to `tag:server` on TCP 5432 and 8080 only.

Create a Red Hat account if you have none, then create a registry service account at https://access.redhat.com/terms-based-registry/. The service account's page shows its username, in the form `1234567|name`, and its token. `provision.sh` asks for both.

Then edit the settings at the top of `provision.sh`, `WEBSITE_REPO` in `build.env`, and the image name in `containers/policy.json`:
- `ZONE`, `MACHINE_TYPE`, `DISK_SIZE`, `DISK_TYPE`: GCP zone, machine type, and the size and type of the boot disk, passed to `gcloud compute instances create`. The image is arm64, so `MACHINE_TYPE` must be an Arm type. `postgresql.conf` is sized for `c4a-standard-1`.
- `DOMAIN`: Primary domain Caddy serves (fills `{$DOMAIN}` in the Caddyfile).
- `ACME_EMAIL`: Email address for the ACME account.
- `REDIR_LIST`: Comma-separated domains that permanently redirect to the same path on `https://<DOMAIN>`.
- `MTA_STS_URL`: URL that `provision.sh` fetches the MTA-STS policy body from, once.
- `WEBDAV_USERNAME`: WebDAV login name.
- `WEBSITE_REPO`: The website repo, the GitHub repository whose `site` branch supplies the served site (see [Base Image](#architecture)).
- `containers/policy.json`: Its `ghcr.io/<owner>/<repo>` key is the image CI pushes and the VM accepts. `build-and-publish.sh` reads that image name, and `provision.sh` derives this repository's name from it.

The script prompts for these secrets without echoing them:
- Tailscale OAuth client secret. It never expires, so the same value works on every reprovisioning.
- Fine-grained GitHub PAT with Actions read/write on this repository only. The `bootc-build` Cloud Scheduler job stores it to dispatch the daily build, and the website repo stores it as the `GH_WORKFLOW_TOKEN` Actions secret, which its publish workflow uses to dispatch the same build. The script asks for it only while that job is missing. When the PAT expires, both dispatches stop until you replace it (see [FAQ](#faq)).
- Red Hat registry token from the service account's page, which CI uses to pull the base image. The script also asks for the service account's username and stores it as the `REDHAT_REGISTRY_USERNAME` Actions variable. It asks for both only while the `REDHAT_REGISTRY_TOKEN` Actions secret is missing. Service accounts stay valid until you regenerate or delete them (see [FAQ](#faq)).
- PostgreSQL `experiments` password and WebDAV password. `provision.sh` hashes these locally so only the hashes reach instance metadata.

`provision.sh` keeps each secret and password hash out of argv, the environment, shell history, and local disk.

### 2. Provision the VM
```bash
./provision.sh
```
This script creates the VM. It also creates each of these resources that is missing: the `bootc-ip` static address, the `allow-web` firewall rule (TCP 80 and 443), the `allow-tailscale-wireguard` firewall rule (UDP on the port in `tailscale/wireguard-port.env`) for direct WireGuard paths, the seed bucket that `build.env` names, and the `bootc-build` Cloud Scheduler job that dispatches the daily image build.

The script also gives CI access to GCP without a service account key. GitHub Actions runs on `main` act as the `bootc-ci` service account through Workload Identity Federation, and that account can only write GCE images and the seed bucket.

When the `SIGSTORE_PUBLIC_KEY` Actions variable is missing, the script creates the signing key pair. The private key and its passphrase become Actions secrets, and the public key becomes that variable. Later runs reuse the key. The script starts a signed build when it creates a key or when the seed image is missing, and it waits for the seed image before creating the VM.

Point A records for `<DOMAIN>`, `mta-sts.<DOMAIN>`, and every `REDIR_LIST` domain at the `bootc-ip` address. The address survives VM deletion, so the records stay valid across reprovisioning. MTA-STS also needs the `_mta-sts.<DOMAIN>` TXT record that your mail provider specifies.

A project's `default` network starts with `default-allow-ssh` and `default-allow-rdp` rules. Nothing on this VM listens on those ports. Delete them unless other VMs in the project still need SSH or RDP:
```bash
gcloud compute firewall-rules delete default-allow-ssh default-allow-rdp
```

### 3. Remove First-Boot Values
After provisioning, verify that you can connect to PostgreSQL over the tailnet. Then remove from instance metadata the two values that only the Tailscale login and the PostgreSQL bootstrap read:
```bash
gcloud compute instances remove-metadata bootc-server --keys=ts-oauth-secret,postgresql-experiments-hash
```
Removing `ts-oauth-secret` matters most, because that secret never expires. The PostgreSQL check confirms that the VM used both values, and later boots read neither. Until the Tailscale login and the PostgreSQL bootstrap succeed, every boot retries them from these values. If the check fails, keep both values and reset the VM with `gcloud compute instances reset bootc-server`. When psql instead reports `password authentication failed for user "experiments"`, see [FAQ](#faq). The remaining metadata values are re-read on every boot and must stay.

## Access

`boot-tailscale.sh` logs the node in. Its `tailscale serve` config forwards tailnet TCP 5432 to local PostgreSQL and proxies tailnet HTTPS 8080 to the rclone WebDAV server on loopback. Your Tailscale policy file from step 1 decides which clients reach those ports.

**PostgreSQL**:
```bash
psql 'postgresql://experiments@bootc-gce-server.<tailnet>.ts.net:5432/experiments'
```

**WebDAV**: `tailscaled` terminates TLS under the node's MagicDNS name. It obtains the Let's Encrypt certificate on the first request and renews it, and the certificate survives reboots and image updates. Configure an `rclone` remote named `webdav` (`type = webdav`, `vendor = rclone`, `url = https://bootc-gce-server.<tailnet>.ts.net:8080`) using `WEBDAV_USERNAME` and the WebDAV password, then access it via:
```bash
rclone ls webdav:
```

## Reprovisioning

Deleting the VM also deletes its boot disk, and with it everything under `/var`: the PostgreSQL data, WebDAV files, Caddy certificates, and Tailscale state. Copy off anything you need first. To reprovision the VM:
1. **Delete the old node from the Machines page of the Tailscale admin console**, so the new VM can register under the `bootc-gce-server` MagicDNS name.
2. Delete the existing VM in GCP.
3. Run `./provision.sh`.
4. Repeat step 3 of the deployment to remove the first-boot values.

## FAQ

### What if psql rejects the `experiments` password after provisioning?

If psql reports `password authentication failed for user "experiments"` for the password you meant to set, the bootstrap succeeded with a mistyped one. A reset does not retry the bootstrap, because every boot skips it once the PostgreSQL data dir exists (see `boot-root.sh`). If you know the mistyped password, connect with it as in Access and run psql's `\password`, which hashes the new password before sending it. A role can change its own password. Otherwise the only recovery is reprovisioning, because `postgres` authenticates only by peer on the VM's local socket (see `postgresql/pg_hba.conf`) and nothing logs into the VM. Reprovisioning deletes everything under `/var`, which holds nothing you need until you write to PostgreSQL or WebDAV.

### What if the WebDAV server rejects the WebDAV password?

`boot-root.sh` renders the WebDAV `htpasswd` from the `webdav-htpasswd` metadata value on every boot, so a mistyped WebDAV password needs only a new hash in that value and a reset. Run this in an interactive shell, with `<WEBDAV_USERNAME>` replaced by the `WEBDAV_USERNAME` from `provision.sh`. Like `provision.sh`, it keeps the password and its hash out of argv, the environment, shell history, and local disk.
```bash
read -rsp 'WebDAV password: ' WEBDAV_PASSWORD && echo
webdav_htpasswd=$(printf '%s' "$WEBDAV_PASSWORD" | podman run --rm -i --log-driver=none --network=none docker.io/library/httpd:alpine htpasswd -niB <WEBDAV_USERNAME>) && unset WEBDAV_PASSWORD
gcloud compute instances add-metadata bootc-server --metadata-from-file=webdav-htpasswd=<(printf '%s' "$webdav_htpasswd") && unset webdav_htpasswd
gcloud compute instances reset bootc-server
```

### How do I replace an expired GitHub PAT?

Run this from the repository root in an interactive shell, with `<REGION>` replaced by the `REGION` that `provision.sh` derives from `ZONE`. Like `provision.sh`, it keeps the PAT out of argv, the environment, shell history, and local disk.
```bash
source build.env
read -rsp 'GitHub PAT: ' GH_WORKFLOW_TOKEN && echo
CLOUDSDK_CORE_DISABLE_FILE_LOGGING=1 gcloud scheduler jobs update http bootc-build --location=<REGION> --flags-file=<(printf -- '--update-headers: "Authorization=Bearer %s"\n' "$GH_WORKFLOW_TOKEN")
printf '%s' "$GH_WORKFLOW_TOKEN" | gh secret set GH_WORKFLOW_TOKEN --repo "$WEBSITE_REPO" && unset GH_WORKFLOW_TOKEN
```

### How do I replace the Red Hat registry token?

Regenerate the token, or create a new service account, at https://access.redhat.com/terms-based-registry/. Then run this from the repository root in an interactive shell. Like `provision.sh`, it keeps the token out of argv, the environment, shell history, and local disk.
```bash
read -rsp 'Red Hat registry token: ' REDHAT_REGISTRY_TOKEN && echo
printf '%s' "$REDHAT_REGISTRY_TOKEN" | gh secret set REDHAT_REGISTRY_TOKEN && unset REDHAT_REGISTRY_TOKEN
```
A new service account also has a new username. Store it with `gh variable set REDHAT_REGISTRY_USERNAME --body '<USERNAME>'`, with `<USERNAME>` replaced by the username its page shows.

### How do I pick up a change to the MTA-STS policy?

Update the `mta-sts-txt` metadata value and reset the VM. `boot-root.sh` renders the policy from that value on every boot.

### How do I rotate the signing key?

Delete the `SIGSTORE_PUBLIC_KEY` Actions variable before reprovisioning. `provision.sh` then creates a new signing key pair, starts a signed build, and puts the new public key into the new VM's instance metadata.

## Hardening

- **Removed Services**: `setup.sh` removes the SSH server and client and deletes `/etc/ssh`. It also removes NFS and Red Hat's registration and reporting tools (`subscription-manager`, `insights-client`, and `rhc`), and masks the serial console login.
- **Network**: `nftables` loads a static default-drop ruleset. Inbound traffic is restricted to web ports, WireGuard UDP, DHCP replies, and rate-limited ICMP echo requests. Outbound is limited to DHCP, DNS, NTP, HTTP(S), Tailscale ports, and ICMP. IPv6 is dropped on every path, loopback included. Only root can reach the GCE metadata service. `tailscaled` runs in userspace networking mode, so no tunnel interface exists and it never alters the VM's nftables rules.
- **Systemd Sandboxing**: Every unit this repository ships runs under the strict systemd sandbox in `sandbox.conf`, which empties the capability bounding set. Each unit adds only its own differences, such as its writable paths. Caddy and `boot-root` list the capabilities they keep in a `zz-capabilities.conf` drop-in.
- **Least Privilege**: Caddy retains `CAP_NET_BIND_SERVICE` and runs confined as SELinux `httpd_t`. RHEL's SELinux policy has no file contexts for Caddy's paths, so `setup.sh` labels them with `semanage` and turns on `httpd_graceful_shutdown`, the boolean that lets `httpd_t` connect to `http_port_t` ports for ACME and OCSP. PGDG's server binaries take `/usr/bin`'s labels, so PostgreSQL runs confined as `postgresql_t`. RHEL's policy lets systemd enter that domain only without `NoNewPrivileges`, so `postgresql_local.cil` adds the permission the policy already gives `httpd_t`. `tailscaled` and the WebDAV server run unprivileged as `DynamicUser` services.
- **Secret Handling**: `boot-root.sh` renders the PostgreSQL password hash into a `pghash`-group file, which `boot-postgresql.sh` opens as postgres and feeds to `bootstrap.sh` on stdin. The WebDAV `htpasswd` is rendered root-only and delivered via systemd `LoadCredential`.

## Repository Layout

### Build & Provisioning
- `Containerfile`: Multi-stage build definition.
- `setup.sh`: Applies the final stage's build-time mutations.
- `provision.sh`: Provisioning script (see [Deployment & Configuration](#deployment--configuration)).
- `build.env`: Seed image and bucket names and `WEBSITE_REPO`, sourced by both `provision.sh` and `build-and-publish.sh`.
- `build-and-publish.sh` / `.github/workflows/build-and-publish.yml`: CI pipeline (see [Continuous Integration](#architecture)).
- `ubi.repo`: Red Hat's public UBI repositories (see [Base Image](#architecture)).
- `ci/`: Google's apt source and GPG key for CI's gcloud (see [Continuous Integration](#architecture)).

### Top-Level Scripts & Services
- `boot-root.{sh,service}`: Runs as root and renders configuration files from metadata on each boot.
- `boot-root-capabilities.conf`: `boot-root`'s capability drop-in (see [Hardening](#hardening)).
- `go-build.sh`: Builds `caddy` and `rclone` (see [Base Image](#architecture)).
- `fetch_metadata.sh`: Helper the boot scripts use to read values from instance metadata.
- `rclone-webdav.service`: WebDAV server running `rclone serve`.

### Service Folders
- `caddy/`: `Caddyfile` (static, with `{$VAR}` placeholders filled from instance metadata), `caddy.service`, `caddy-capabilities.conf` (see [Hardening](#hardening)), and `caddy-dirs.conf`.
- `postgresql/`: Server configs (`postgresql.conf`, `pg_hba.conf`), `pgdg.repo` and `PGDG-RPM-GPG-KEY-AARCH64-RHEL` (see [Base Image](#architecture)), `postgresql.service`, the bootstrap (`boot-postgresql.{sh,service}`, `bootstrap.sh`, `bootstrap.sql`), `run-as-postgres.conf` (unit settings both PostgreSQL units share), `pgdata.conf` (the data dir for `boot-root` and both PostgreSQL units), `postgresql_local.cil` (see [Hardening](#hardening)), and `postgresql-dirs.conf`.
- `tailscale/`: `tailscale.repo` and `RPM-GPG-KEY-tailscale` (see [Base Image](#architecture)), `tailscaled.service`, which replaces the RPM's unit (see [Hardening](#hardening)), `boot-tailscale.{sh,service}` (see [Access](#access)), `wireguard-port.env` (the WireGuard port that `tailscaled`, `nftables`, and `provision.sh` read), and `nftables-wireguard-port.conf` (the `nftables.service` drop-in that passes that port to `nft`).

### Configuration
- `prepare-root.conf`, `nftables.conf`, `fstab`, `journald.conf`: Standalone configuration files.
- `sandbox.conf`: Shared systemd sandbox (see [Hardening](#hardening)).
- `tmpfiles.d/root.conf`: Masks systemd's `root.conf` tmpfiles entry.
- `containers/`: Signature policy for image updates (see [Signed Images](#architecture)). `policy.json` accepts local `containers-storage` images, so CI's seed-image build can install the unsigned image it just built. `bootc-gce-server.yaml` turns on sigstore attachments, so CI's push writes image signatures to the registry and the VM reads them from there. `sigpolicy.toml` makes `bootc install` enforce the signature policy. `build-policy.json` and `SIGSTORE-redhat-release3` make CI's build verify the base image (see [Base Image](#architecture)).
- `hash-postgresql-password/`: SCRAM-SHA-256 hasher for PostgreSQL passwords, which `provision.sh` runs in a `postgres:17-alpine` container.
