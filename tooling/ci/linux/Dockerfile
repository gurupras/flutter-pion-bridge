# Release CI builder for pion_bridge: runs the host test layers, builds the
# Android (gomobile), Linux amd64/arm64 and Windows binaries, sidecars and
# shared libraries alike, and runs the example app's e2e test on Linux (Xvfb)
# and an Android emulator (needs --device /dev/kvm). Pinned inputs; bump them
# deliberately.
FROM ubuntu:24.04

ARG GO_VERSION=1.26.2
ARG FLUTTER_VERSION=3.41.6
ARG ANDROID_CMDLINE_TOOLS=13114758
ARG ANDROID_PLATFORM=android-34
# What Flutter 3.41 apps compile against, and the emulator image the e2e runs.
ARG ANDROID_APP_PLATFORM=android-36
ARG ANDROID_BUILD_TOOLS=36.0.0
ARG ANDROID_SYSTEM_IMAGE=system-images;android-34;google_apis;x86_64
ARG ANDROID_NDK_VERSION=28.2.13676358

ENV DEBIAN_FRONTEND=noninteractive
# CI runs a rootless Docker daemon, where container root maps to an unprivileged
# host uid: tar cannot restore the ownership recorded in Flutter's archives and
# fails ("Cannot change ownership to uid ..., Invalid argument"), taking
# `flutter precache` down with it. GNU tar reads TAR_OPTIONS from the
# environment, which covers Flutter's own tar calls at build and at run time.
ENV TAR_OPTIONS=--no-same-owner
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git unzip xz-utils zip python3 \
        build-essential \
        gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
        gcc-mingw-w64-x86-64 \
        openjdk-17-jdk-headless \
        clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
        xvfb xauth libgl1-mesa-dri \
        libpulse0 libnss3 libxcomposite1 libxcursor1 libxdamage1 libxi6 \
        libxtst6 libxkbfile1 libasound2t64 libgbm1 libdrm2 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_NDK_HOME=/opt/android-sdk/ndk/${ANDROID_NDK_VERSION}
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && curl -fsSL -o /tmp/cmdline-tools.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
    && unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools" \
    && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip \
    && yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses > /dev/null \
    && "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
        "platforms;${ANDROID_PLATFORM}" "ndk;${ANDROID_NDK_VERSION}" \
        "platforms;${ANDROID_APP_PLATFORM}" "build-tools;${ANDROID_BUILD_TOOLS}" \
        platform-tools emulator "${ANDROID_SYSTEM_IMAGE}" > /dev/null

RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git /opt/flutter \
    && git config --global --add safe.directory '*' \
    && /opt/flutter/bin/flutter config --no-analytics \
    && /opt/flutter/bin/flutter precache --universal --linux --android

ENV ANDROID_SYSTEM_IMAGE=${ANDROID_SYSTEM_IMAGE}
ENV PATH=/usr/local/go/bin:/root/go/bin:/opt/flutter/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:$PATH
