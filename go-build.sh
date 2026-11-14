#!/usr/bin/env bash
set -euo pipefail

dnf install -y --setopt=install_weak_deps=False golang
# Both projects' release builds disable cgo.
export CGO_ENABLED=0 GOBIN=/build

# Each @latest resolves to the newest release tag. Red Hat's Go verifies every module against sum.golang.org.
CADDY_VERSION=$(go list -m -f '{{.Version}}' github.com/caddyserver/caddy/v2@latest)
RCLONE_VERSION=$(go list -m -f '{{.Version}}' github.com/rclone/rclone@latest)

# Caddy reads its version only as a dependency of the module being built, so a direct install sets it
# through CustomVersion. The trimpath and tag settings match Caddy's release builds.
go install -trimpath -tags nobadger,nomysql,nopgx -ldflags "-X github.com/caddyserver/caddy/v2.CustomVersion=$CADDY_VERSION" "github.com/caddyserver/caddy/v2/cmd/caddy@$CADDY_VERSION"
# The ldflags, fs.Version included, match rclone's release builds.
go install -ldflags "-s -X github.com/rclone/rclone/fs.Version=$RCLONE_VERSION" "github.com/rclone/rclone@$RCLONE_VERSION"
