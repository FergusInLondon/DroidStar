# Toolchain image for building DroidStar Android packages.
# Built and used by scripts/build-android-docker.sh; the source tree is
# mounted at run time, so this image only holds the toolchains.
ARG BASE_IMAGE=registry.fedoraproject.org/fedora:45
FROM ${BASE_IMAGE}

# Qt for Android is installed for these ABIs only; building others needs a
# new image (set IMAGE_ABIS for the wrapper).
ARG ANDROID_ABIS="arm64-v8a;armeabi-v7a"

ENV QT_ROOT=/opt/Qt \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JDK_DIR=/opt/jdk-21

COPY build-android.sh /usr/local/bin/build-android.sh

RUN /usr/local/bin/build-android.sh --setup-only --abis "$ANDROID_ABIS" \
 && dnf clean all \
 && rm -rf /opt/Qt/.aqt-venv /root/.cache /tmp/*

LABEL org.opencontainers.image.title="droidstar-android-build"
