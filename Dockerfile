# Reusable build image: Node + JDK + Android SDK + eas-cli.
# Project source is NOT baked in here — it's copied into the container at
# build time by scripts/build.sh, keeping this image project-agnostic.
FROM node:20-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

ENV PATH=${JAVA_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless \
        unzip \
        curl \
        git \
    && rm -rf /var/lib/apt/lists/*

# Android cmdline-tools (pinned version — bump deliberately, not on a schedule)
ARG ANDROID_CMDLINE_TOOLS_VERSION=11076708
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools \
    && curl -fsSL -o /tmp/cmdline-tools.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
    && unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_HOME}/cmdline-tools \
    && mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest \
    && rm /tmp/cmdline-tools.zip

# Pinned platform/build-tools versions — bump alongside Expo SDK upgrades.
ARG ANDROID_PLATFORM_VERSION=34
ARG ANDROID_BUILD_TOOLS_VERSION=34.0.0
RUN yes | sdkmanager --licenses > /dev/null \
    && sdkmanager \
        "platform-tools" \
        "platforms;android-${ANDROID_PLATFORM_VERSION}" \
        "build-tools;${ANDROID_BUILD_TOOLS_VERSION}"

RUN npm install -g eas-cli@latest

WORKDIR /workspace
COPY scripts/build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

ENTRYPOINT ["/usr/local/bin/build.sh"]
