#!/usr/bin/env bash
#
# Build DroidStar Android packages (APK and/or AAB) on Fedora Linux.
#
# Installs (if missing):
#   - Fedora build dependencies (dnf)
#   - Qt for Android + matching host Qt, via aqtinstall (in a Python venv)
#   - Android SDK cmdline-tools, platform, build-tools and NDK
#   - KDAB android_openssl prebuilt libraries
# then configures and builds with Qt's CMake Android tooling.
#
# Usage: scripts/build-android.sh [options]
#   --release          Release build (default: debug)
#   --aab              Build an Android App Bundle instead of an APK
#   --abis "a;b"       ABIs to build (default: arm64-v8a). E.g. "arm64-v8a;armeabi-v7a"
#   --clean            Remove the build directory first
#   --skip-deps        Don't install dnf packages
#   --setup-only       Install toolchains only, don't build
#   -h, --help         Show this help
#
# Environment overrides (defaults shown in the CONFIG section below):
#   QT_VERSION, QT_ROOT, ANDROID_SDK_ROOT, ANDROID_NDK_VERSION,
#   ANDROID_PLATFORM, ANDROID_BUILD_TOOLS, CMDLINE_TOOLS_VERSION,
#   JAVA_HOME, JDK_DIR, BUILD_DIR, DIST_DIR, JOBS
#
# Release signing: export these and the package is signed by androiddeployqt:
#   QT_ANDROID_KEYSTORE_PATH, QT_ANDROID_KEYSTORE_ALIAS,
#   QT_ANDROID_KEYSTORE_STORE_PASS, QT_ANDROID_KEYSTORE_KEY_PASS (optional)
# Debug builds are signed with the auto-generated debug key.

set -euo pipefail

# ---------------------------------------------------------------- CONFIG ---
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QT_VERSION="${QT_VERSION:-6.11.3}"
QT_ROOT="${QT_ROOT:-$HOME/Qt}"
QT_MODULES="${QT_MODULES:-qtmultimedia qtserialport}"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-27.2.12479018}"   # r27c
ANDROID_PLATFORM="${ANDROID_PLATFORM:-android-35}"
ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-35.0.0}"
CMDLINE_TOOLS_VERSION="${CMDLINE_TOOLS_VERSION:-13114758}"
ANDROID_OPENSSL_DIR="${ANDROID_OPENSSL_DIR:-$ANDROID_SDK_ROOT/android_openssl}"

BUILD_DIR="${BUILD_DIR:-$SRC_DIR/build-android}"
DIST_DIR="${DIST_DIR:-$SRC_DIR/dist}"
JOBS="${JOBS:-$(nproc)}"

AQT_VENV="${AQT_VENV:-$QT_ROOT/.aqt-venv}"
JDK_DIR="${JDK_DIR:-$HOME/.local/share/droidstar-build/jdk-21}"

BUILD_TYPE=Debug
PACKAGE=apk
ABIS="arm64-v8a"
CLEAN=0
SKIP_DEPS=0
SETUP_ONLY=0

# ----------------------------------------------------------------- utils ---
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

# Map Android ABI name -> Qt/aqt arch directory name.
qt_arch_for_abi() {
    case "$1" in
        arm64-v8a)   echo android_arm64_v8a ;;
        armeabi-v7a) echo android_armv7 ;;
        x86_64)      echo android_x86_64 ;;
        x86)         echo android_x86 ;;
        *) die "unsupported ABI: $1" ;;
    esac
}

# ------------------------------------------------------------------ args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)    BUILD_TYPE=Release ;;
        --aab)        PACKAGE=aab ;;
        --abis)       [[ $# -ge 2 ]] || die "--abis needs a value"; ABIS="$2"; shift ;;
        --clean)      CLEAN=1 ;;
        --skip-deps)  SKIP_DEPS=1 ;;
        --setup-only) SETUP_ONLY=1 ;;
        -h|--help)    usage 0 ;;
        *)            warn "unknown option: $1"; usage 1 ;;
    esac
    shift
done

IFS=';' read -r -a ABI_LIST <<< "$ABIS"
[[ ${#ABI_LIST[@]} -gt 0 ]] || die "no ABIs given"
PRIMARY_ARCH="$(qt_arch_for_abi "${ABI_LIST[0]}")"

# ------------------------------------------------------- system packages ---
install_system_deps() {
    [[ $SKIP_DEPS -eq 1 ]] && { log "Skipping system packages"; return; }
    command -v dnf >/dev/null || die "dnf not found; this script targets Fedora (use --skip-deps to bypass)"

    local pkgs=(
        git cmake ninja-build gcc gcc-c++ make
        python3 python3-pip python3-devel   # devel: aqtinstall deps may build from source
        unzip curl tar findutils which
        # needed by host Qt tools from aqt
        libglvnd-devel libxkbcommon fontconfig
    )
    local missing=()
    for p in "${pkgs[@]}"; do rpm -q "$p" &>/dev/null || missing+=("$p"); done
    [[ ${#missing[@]} -eq 0 ]] && { log "System packages already installed"; return; }

    log "Installing system packages: ${missing[*]}"
    local sudo=()
    [[ $EUID -ne 0 ]] && sudo=(sudo)
    "${sudo[@]}" dnf install -y "${missing[@]}"
}

# Qt's bundled Gradle (8.x) needs JDK 17 or 21. Recent Fedora only packages
# JDK 25+, so fall back to an Eclipse Temurin 21 tarball in the user's home.
setup_java() {
    local jh
    if [[ -z "${JAVA_HOME:-}" ]]; then
        for jh in /usr/lib/jvm/java-21-openjdk /usr/lib/jvm/java-17-openjdk "$JDK_DIR"; do
            [[ -x "$jh/bin/javac" ]] && { export JAVA_HOME="$jh"; break; }
        done
    fi
    if [[ -z "${JAVA_HOME:-}" ]]; then
        log "Downloading Eclipse Temurin JDK 21 into $JDK_DIR"
        local arch tmp
        case "$(uname -m)" in
            x86_64)  arch=x64 ;;
            aarch64) arch=aarch64 ;;
            *) die "unsupported host arch: $(uname -m)" ;;
        esac
        tmp="$(mktemp -d)"
        curl -fL --retry 3 -o "$tmp/jdk.tar.gz" \
            "https://api.adoptium.net/v3/binary/latest/21/ga/linux/${arch}/jdk/hotspot/normal/eclipse"
        mkdir -p "$JDK_DIR"
        tar -xzf "$tmp/jdk.tar.gz" -C "$JDK_DIR" --strip-components=1
        rm -rf "$tmp"
        export JAVA_HOME="$JDK_DIR"
    fi
    [[ -x "$JAVA_HOME/bin/javac" ]] || die "no usable JDK at JAVA_HOME=$JAVA_HOME"
    export PATH="$JAVA_HOME/bin:$PATH"
    log "Using JDK: $JAVA_HOME ($("$JAVA_HOME/bin/java" -version 2>&1 | head -1))"
}

# -------------------------------------------------------------------- Qt ---
install_qt() {
    local need=0 abi arch
    for abi in "${ABI_LIST[@]}"; do
        arch="$(qt_arch_for_abi "$abi")"
        [[ -x "$QT_ROOT/$QT_VERSION/$arch/bin/qt-cmake" ]] || need=1
    done
    [[ -x "$QT_ROOT/$QT_VERSION/gcc_64/bin/qmake" ]] || need=1
    [[ $need -eq 0 ]] && { log "Qt $QT_VERSION already installed in $QT_ROOT"; return; }

    if [[ ! -x "$AQT_VENV/bin/aqt" ]]; then
        log "Creating aqtinstall venv in $AQT_VENV"
        python3 -m venv "$AQT_VENV"
        "$AQT_VENV/bin/pip" install -q --upgrade pip aqtinstall
    fi

    # Host (desktop) Qt: provides moc/rcc/qmlcachegen/androiddeployqt.
    if [[ ! -x "$QT_ROOT/$QT_VERSION/gcc_64/bin/qmake" ]]; then
        log "Installing host Qt $QT_VERSION (linux_gcc_64)"
        "$AQT_VENV/bin/aqt" install-qt -O "$QT_ROOT" linux desktop "$QT_VERSION" linux_gcc_64 \
            -m $QT_MODULES
    fi

    for abi in "${ABI_LIST[@]}"; do
        arch="$(qt_arch_for_abi "$abi")"
        [[ -x "$QT_ROOT/$QT_VERSION/$arch/bin/qt-cmake" ]] && continue
        log "Installing Qt $QT_VERSION for $arch"
        # Qt >= 6.7 publishes Android under "all_os"; older under "linux".
        "$AQT_VENV/bin/aqt" install-qt -O "$QT_ROOT" all_os android "$QT_VERSION" "$arch" \
            -m $QT_MODULES \
        || "$AQT_VENV/bin/aqt" install-qt -O "$QT_ROOT" linux android "$QT_VERSION" "$arch" \
            -m $QT_MODULES
    done
}

# ----------------------------------------------------------- Android SDK ---
install_android_sdk() {
    local sdkmanager="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

    if [[ ! -x "$sdkmanager" ]]; then
        log "Installing Android cmdline-tools ($CMDLINE_TOOLS_VERSION) into $ANDROID_SDK_ROOT"
        local tmp; tmp="$(mktemp -d)"
        curl -fL --retry 3 -o "$tmp/cmdline-tools.zip" \
            "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip"
        unzip -q "$tmp/cmdline-tools.zip" -d "$tmp"
        mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
        rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/latest"
        mv "$tmp/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
        rm -rf "$tmp"
    fi

    local want=(
        "platform-tools"
        "platforms;$ANDROID_PLATFORM"
        "build-tools;$ANDROID_BUILD_TOOLS"
        "ndk;$ANDROID_NDK_VERSION"
    )
    local missing=() p
    [[ -d "$ANDROID_SDK_ROOT/platform-tools" ]]                       || missing+=("${want[0]}")
    [[ -d "$ANDROID_SDK_ROOT/platforms/$ANDROID_PLATFORM" ]]          || missing+=("${want[1]}")
    [[ -d "$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS" ]]     || missing+=("${want[2]}")
    [[ -d "$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION" ]]             || missing+=("${want[3]}")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "Accepting SDK licenses"
        yes | "$sdkmanager" --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null || true
        log "Installing SDK packages: ${missing[*]}"
        "$sdkmanager" --sdk_root="$ANDROID_SDK_ROOT" "${missing[@]}"
    else
        log "Android SDK packages already installed"
    fi

    export ANDROID_SDK_ROOT ANDROID_HOME="$ANDROID_SDK_ROOT"
    export ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"
}

install_android_openssl() {
    if [[ -f "$ANDROID_OPENSSL_DIR/android_openssl.cmake" ]]; then
        log "android_openssl already present"
        return
    fi
    log "Cloning KDAB android_openssl into $ANDROID_OPENSSL_DIR"
    git clone --depth 1 https://github.com/KDAB/android_openssl.git "$ANDROID_OPENSSL_DIR"
}

# ----------------------------------------------------------------- build ---
build() {
    local qt_cmake="$QT_ROOT/$QT_VERSION/$PRIMARY_ARCH/bin/qt-cmake"
    [[ -x "$qt_cmake" ]] || die "qt-cmake not found: $qt_cmake"

    [[ $CLEAN -eq 1 ]] && { log "Cleaning $BUILD_DIR"; rm -rf "$BUILD_DIR"; }

    local cmake_args=(
        -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
        -DQT_HOST_PATH="$QT_ROOT/$QT_VERSION/gcc_64"
        -DANDROID_SDK_ROOT="$ANDROID_SDK_ROOT"
        -DANDROID_NDK_ROOT="$ANDROID_NDK_ROOT"
        -DANDROID_OPENSSL_ROOT="$ANDROID_OPENSSL_DIR"
        -DQT_ANDROID_ABIS="$ABIS"
    )
    if [[ ${#ABI_LIST[@]} -gt 1 ]]; then
        cmake_args+=(-DQT_ANDROID_BUILD_ALL_ABIS=ON)
    fi

    local signed=0
    if [[ -n "${QT_ANDROID_KEYSTORE_PATH:-}" ]]; then
        [[ -f "$QT_ANDROID_KEYSTORE_PATH" ]] || die "keystore not found: $QT_ANDROID_KEYSTORE_PATH"
        [[ -n "${QT_ANDROID_KEYSTORE_ALIAS:-}" ]]      || die "QT_ANDROID_KEYSTORE_ALIAS not set"
        [[ -n "${QT_ANDROID_KEYSTORE_STORE_PASS:-}" ]] || die "QT_ANDROID_KEYSTORE_STORE_PASS not set"
        export QT_ANDROID_KEYSTORE_KEY_PASS="${QT_ANDROID_KEYSTORE_KEY_PASS:-$QT_ANDROID_KEYSTORE_STORE_PASS}"
        cmake_args+=(-DQT_ANDROID_SIGN_APK=ON -DQT_ANDROID_SIGN_AAB=ON)
        signed=1
    elif [[ $BUILD_TYPE == Release ]]; then
        warn "No keystore configured: release package will be unsigned"
    fi

    log "Configuring ($BUILD_TYPE, ABIs: $ABIS)"
    "$qt_cmake" "${cmake_args[@]}"

    log "Building $PACKAGE"
    cmake --build "$BUILD_DIR" --parallel "$JOBS" --target "$PACKAGE"

    mkdir -p "$DIST_DIR"
    local rev; rev="$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    local suffix; suffix="$(tr '[:upper:]' '[:lower:]' <<< "$BUILD_TYPE")"
    [[ $BUILD_TYPE == Release && $signed -eq 0 ]] && suffix+="-unsigned"

    local found=0 f
    while IFS= read -r -d '' f; do
        local dest="$DIST_DIR/DroidStar-${rev}-${suffix}.${PACKAGE}"
        cp -f "$f" "$dest"
        log "Output: $dest"
        found=1
    done < <(find "$BUILD_DIR" -path '*/build/outputs/*' -name "*.${PACKAGE}" -newer "$BUILD_DIR/CMakeCache.txt" -print0)
    [[ $found -eq 1 ]] || die "no .$PACKAGE produced under $BUILD_DIR"
}

# ------------------------------------------------------------------ main ---
install_system_deps
setup_java
install_qt
install_android_sdk
install_android_openssl
[[ $SETUP_ONLY -eq 1 ]] && { log "Setup complete"; exit 0; }
build
