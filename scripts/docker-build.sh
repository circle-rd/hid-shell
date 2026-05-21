#!/usr/bin/env bash
# Build the HID-Shell binaries inside the project Dockerfile so no
# host-side Nim / mingw / zig install is required.
#
# Usage:
#   ./scripts/docker-build.sh            # build image + run build_all.sh
#   ./scripts/docker-build.sh shell      # drop into an interactive shell
#
# The repo root is bind-mounted at /workspace; produced binaries land
# in ./dist/ on the host.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${HID_SHELL_IMAGE:-hid-shell-builder:latest}"

echo "==> building image ${IMAGE} (--target toolchain)"
docker build --target toolchain -t "${IMAGE}" "${HERE}"

if [[ "${1:-}" == "shell" ]]; then
  exec docker run --rm -it \
    -v "${HERE}:/workspace" -w /workspace \
    "${IMAGE}" bash
fi

echo "==> running ./scripts/build_all.sh inside the container"
exec docker run --rm \
  -v "${HERE}:/workspace" -w /workspace \
  "${IMAGE}" ./scripts/build_all.sh
