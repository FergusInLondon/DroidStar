#!/usr/bin/env bash
#
# Build DroidStar Android packages inside a Fedora container, leaving the host
# untouched apart from the build/output dirs in the source tree.
#
# The toolchain image is built once and tagged with a hash of its inputs
# (Dockerfile, build-android.sh, base image, ABIs); it is only rebuilt when
# that tag does not exist locally.
#
# Usage: scripts/build-android-docker.sh [--rebuild] [build-android.sh options]
#   --rebuild    Force a rebuild of the toolchain image
#   All other options are passed to build-android.sh (--release, --aab, ...).
#
# Environment:
#   CONTAINER_ENGINE   podman or docker (default: podman if found, else docker)
#   BASE_IMAGE         default: registry.fedoraproject.org/fedora:45
#   IMAGE_ABIS         ABIs baked into the image (default: "arm64-v8a;armeabi-v7a")
#   IMAGE_NAME         default: droidstar-android-build
#   CONTAINER_BUILD_ARGS / CONTAINER_RUN_ARGS
#                      Extra args for the engine's build/run (word-split), e.g.
#                      CONTAINER_RUN_ARGS="--network host"
#   JOBS, QT_ANDROID_KEYSTORE_*  Passed through (keystore file is mounted ro).
#
# Build state lives in the source tree: build-android-container/, dist/ and .cache/
# (Gradle cache and the debug signing key).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$SCRIPT_DIR/android-build.Dockerfile"

BASE_IMAGE="${BASE_IMAGE:-registry.fedoraproject.org/fedora:45}"
IMAGE_ABIS="${IMAGE_ABIS:-arm64-v8a;armeabi-v7a}"
IMAGE_NAME="${IMAGE_NAME:-droidstar-android-build}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ -z "${CONTAINER_ENGINE:-}" ]]; then
    if command -v podman >/dev/null; then CONTAINER_ENGINE=podman
    elif command -v docker >/dev/null; then CONTAINER_ENGINE=docker
    else die "neither podman nor docker found"; fi
fi
ENGINE="$CONTAINER_ENGINE"

REBUILD=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --rebuild) REBUILD=1 ;;
        -h|--help) sed -n '3,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) ARGS+=("$a") ;;
    esac
done

# ------------------------------------------------------------ image tag ---
HASH="$( { cat "$DOCKERFILE" "$SCRIPT_DIR/build-android.sh"; \
           printf '%s\n' "$BASE_IMAGE" "$IMAGE_ABIS"; } | sha256sum | cut -c1-12 )"
IMAGE="$IMAGE_NAME:$HASH"

read -r -a EXTRA_BUILD <<< "${CONTAINER_BUILD_ARGS:-}"
read -r -a EXTRA_RUN   <<< "${CONTAINER_RUN_ARGS:-}"

if [[ $REBUILD -eq 1 ]] || ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
    log "Building toolchain image $IMAGE (several GB, one-off)"
    "$ENGINE" build \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
        --build-arg ANDROID_ABIS="$IMAGE_ABIS" \
        -t "$IMAGE" -f "$DOCKERFILE" "${EXTRA_BUILD[@]}" "$SCRIPT_DIR"
    log "Built $IMAGE. Older $IMAGE_NAME images can be removed with: $ENGINE image ls $IMAGE_NAME"
else
    log "Using existing image $IMAGE"
fi

# ------------------------------------------------------------------ run ---
mkdir -p "$SRC_DIR/.cache/home"

run_args=(
    --rm
    -v "$SRC_DIR:/src:z"
    -w /src
    -e HOME=/src/.cache/home
    # Separate from a host build's CMake cache, which has different paths.
    -e BUILD_DIR=/src/build-android-container
)
[[ -t 0 && -t 1 ]] && run_args+=(-it)

# Run as the invoking user so outputs aren't root-owned.
if [[ "$ENGINE" == podman ]]; then
    run_args+=(--userns=keep-id)
else
    run_args+=(--user "$(id -u):$(id -g)")
fi

[[ -n "${JOBS:-}" ]] && run_args+=(-e JOBS)

if [[ -n "${QT_ANDROID_KEYSTORE_PATH:-}" ]]; then
    ks="$(realpath "$QT_ANDROID_KEYSTORE_PATH")"
    [[ -f "$ks" ]] || die "keystore not found: $QT_ANDROID_KEYSTORE_PATH"
    # Values are passed by name, so secrets don't appear on the command line.
    run_args+=(
        -v "$ks:/run/keystore:ro,z"
        -e QT_ANDROID_KEYSTORE_PATH=/run/keystore
        -e QT_ANDROID_KEYSTORE_ALIAS
        -e QT_ANDROID_KEYSTORE_STORE_PASS
        -e QT_ANDROID_KEYSTORE_KEY_PASS
    )
fi

log "Running build in $IMAGE"
exec "$ENGINE" run "${run_args[@]}" "${EXTRA_RUN[@]}" "$IMAGE" \
    /src/scripts/build-android.sh --skip-deps "${ARGS[@]}"
