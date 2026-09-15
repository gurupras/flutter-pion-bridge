#!/usr/bin/env bash
# Install gomobile + gobind at the golang.org/x/mobile version go/go.mod pins,
# so CI binds with exactly the bind runtime the module compiles against.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

version="$(cd "$REPO_ROOT/go" && go list -m -f '{{.Version}}' golang.org/x/mobile)"
echo "Installing gomobile/gobind $version"
go install "golang.org/x/mobile/cmd/gomobile@$version" "golang.org/x/mobile/cmd/gobind@$version"
