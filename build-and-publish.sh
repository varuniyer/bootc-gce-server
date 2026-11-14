#!/usr/bin/env bash
set -euo pipefail

IMAGE="$(jq -r '.transports.docker | keys[0]' containers/policy.json):latest"
source "$PWD/build.env"

# The runner ships no gcloud. apt checks Google's repository against the key this repo pins.
install -D -m 0644 ci/google-cloud-apt.gpg /etc/apt/keyrings/google-cloud-apt.gpg
cp ci/google-cloud-apt.sources /etc/apt/sources.list.d/
apt-get update -q
apt-get install -y -q google-cloud-cli

printf '%s' "$GITHUB_TOKEN" | podman login --password-stdin -u "$GITHUB_ACTOR" "${IMAGE%%/*}"
printf '%s' "$REDHAT_REGISTRY_TOKEN" | podman login --password-stdin -u "$REDHAT_REGISTRY_USERNAME" registry.redhat.io
# Sigstore attachments carry Red Hat's signature on the base image and the signature that podman push adds for the VM.
mkdir -p /etc/containers/registries.d && cp containers/bootc-gce-server.yaml /etc/containers/registries.d/
# --pull=always makes every build check the base image against build-policy.json.
podman build --layers=false --pull=always --signature-policy containers/build-policy.json --build-arg WEBSITE_REPO="$WEBSITE_REPO" -f Containerfile -t "$IMAGE" .
podman push --sign-by-sigstore-private-key <(printf '%s' "$SIGSTORE_PRIVATE_KEY") --sign-passphrase-file <(printf '%s' "$SIGSTORE_PASSPHRASE") "$IMAGE"

mkdir -p output
GRAPH_ROOT=$(podman info --format '{{.Store.GraphRoot}}')
# The builder runs privileged, so it gets the same signature check as the base image.
BUILDER=registry.redhat.io/rhel10/bootc-image-builder:latest
podman pull --signature-policy containers/build-policy.json "$BUILDER"
podman run --rm --privileged --pull=never -v "$PWD/output:/output" -v "$GRAPH_ROOT:/var/lib/containers/storage" \
  "$BUILDER" --type raw --use-librepo=True --rootfs ext4 "$IMAGE"

ARCHIVE="gs://$SEED_BUCKET/$SEED_IMAGE.tar.gz"
tar --format=oldgnu -Sczf - -C output/image disk.raw | gcloud storage cp - "$ARCHIVE"
gcloud compute images delete "$SEED_IMAGE" --quiet || true
gcloud compute images create "$SEED_IMAGE" \
    --source-uri="$ARCHIVE" \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC
gcloud storage rm "$ARCHIVE"
