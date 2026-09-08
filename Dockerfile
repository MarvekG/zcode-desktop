# ZCode desktop + XFCE for linux/arm64 and linux/amd64 servers
# Build either platform with Buildx; the AppImage architecture is selected
# automatically from TARGETARCH below.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=zh_CN.UTF-8

ARG ZCODE_VERSION=3.11.2
ARG TARGETARCH

# Bootstrap trust BEFORE the main install: the bare base has neither
# ca-certificates nor /usr/local/share/ca-certificates, so install those first
# (ubuntu archives are plain http), then put the optional MITM CA into the
# system trust store. The CA comes from the build context as ONE file at
# certs/mitm-ca.pem (bind-mounted into the build, never baked into a layer);
# from here on every build-time fetch (https apt sources, wget/curl) is trusted
# when building behind a MITM proxy, and the CA is also left at /mitm-ca.pem so
# the runtime startup picks it up (runtime -v mount of /mitm-ca.pem overrides).
RUN --mount=type=bind,source=certs,target=/build-certs \
    apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && if [ -f /build-certs/mitm-ca.pem ]; then \
        n=$(grep -c -- "-----BEGIN CERTIFICATE-----" /build-certs/mitm-ca.pem || true); \
        [ "${n:-0}" -le 1 ] || { echo "ERROR: certs/mitm-ca.pem contains $n certificates; exactly one is required" >&2; exit 1; }; \
        mkdir -p /usr/local/share/ca-certificates; \
        cp /build-certs/mitm-ca.pem /usr/local/share/ca-certificates/mitm-ca.crt; \
        cp /build-certs/mitm-ca.pem /mitm-ca.pem; \
        update-ca-certificates; \
        echo "Build-time MITM CA installed from certs/mitm-ca.pem"; \
    fi; rm -rf /var/lib/apt/lists/*

# Main apt dependencies in one front layer:
# - desktop: XFCE, VNC (TigerVNC), noVNC, fonts, CJK locale
# - input:   fcitx5 pinyin
# - network: ping/traceroute/mtr/dig/telnet/nc/net-tools/iproute2/lsof/rsync
# - proxy:   tinyproxy and 3proxy = selectable local unauthenticated relays;
#            Python for configuration; jq for reading startup metadata
RUN install -d -m 0755 /usr/share/keyrings \
    && curl -fsSL https://3proxy.org/repo/3proxy-release-key.asc \
        -o /usr/share/keyrings/3proxy.asc \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: https://3proxy.org/repo/deb' \
        'Suites: lts' \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/3proxy.asc' \
        > /etc/apt/sources.list.d/3proxy.sources \
    && apt-get update && apt-get install -y --no-install-recommends \
        locales ca-certificates curl wget git openssh-client gpg sudo jq python3 rsync \
        less vim unzip zip file tree ripgrep procps psmisc \
        htop tmux ncdu fzf bat bash-completion \
        xdg-utils dbus-x11 x11-xserver-utils xauth \
        tigervnc-standalone-server tigervnc-common tigervnc-tools fuse3 \
        novnc websockify \
        xfce4 xfce4-terminal xfce4-goodies \
        fonts-noto-cjk fonts-noto-color-emoji \
        libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 \
        libatspi2.0-0 libsecret-1-0 libgbm1 libasound2t64 libfuse2 \
        iputils-ping net-tools iproute2 traceroute mtr-tiny dnsutils telnet \
        netcat-openbsd lsof tinyproxy 3proxy \
        fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 \
        fcitx5-frontend-qt5 fcitx5-config-qt im-config \
        libnss3-tools \
    && sed -i 's/^# zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# Firefox in its own layer (deb from Mozilla official repo; snap does not work
# in containers) so a Mozilla-side failure does not invalidate the package
# layer above, plus enterprise autoconfig: proxy is injected into mozilla.cfg
# at container start (Firefox ignores HTTPS_PROXY/http_proxy env vars).
RUN install -d -m 0755 /etc/apt/keyrings \
    && wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O /etc/apt/keyrings/packages.mozilla.org.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list \
    && printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla \
    && apt-get update && apt-get install -y --no-install-recommends firefox firefox-l10n-zh-cn \
    && mkdir -p /etc/firefox/policies \
    && printf '%s' '{"policies":{"Preferences":{"security.enterprise_roots.enabled":{"Value":true,"Status":"locked"}}}}' \
        > /etc/firefox/policies/policies.json \
    && printf '%s\n' \
        'pref("general.config.filename", "mozilla.cfg");' \
        'pref("general.config.obscure_value", 0);' \
        > /usr/lib/firefox/defaults/pref/autoconfig.js \
    && printf '%s\n' \
        '// Firefox enterprise config (rewritten by /root/startup.sh at boot)' \
        'defaultPref("security.enterprise_roots.enabled", true);' \
        'defaultPref("network.proxy.type", 0);' \
        > /usr/lib/firefox/mozilla.cfg \
    && rm -rf /var/lib/apt/lists/*

# ZCode desktop app (AppImage kept as-is; runs via FUSE mount, no unpacked install).
# The vendor calls amd64 "x64", so derive its download directory from BuildKit's
# target architecture instead of using one build-arg for both platforms.
RUN case "$TARGETARCH" in \
      amd64) ZCODE_ARCH=x64 ;; \
      arm64) ZCODE_ARCH=arm64 ;; \
      *) echo "unsupported target architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fL --retry 3 \
      "https://cdn-zcode.z.ai/zcode/electron/releases/${ZCODE_VERSION}/linux-${ZCODE_ARCH}/ZCode-${ZCODE_VERSION}-linux-${ZCODE_ARCH}.AppImage" \
      -o /opt/ZCode.AppImage
COPY zcode-launcher.sh /usr/local/bin/zcode
RUN chmod 755 /opt/ZCode.AppImage /usr/local/bin/zcode \
    && mkdir -p /usr/local/share/applications /root/Desktop /root/.config/fcitx5 \
    && printf '%s\n' \
        '[Desktop Entry]' \
        'Type=Application' \
        'Name=ZCode' \
        'Comment=ZCode Desktop' \
        'Exec=/usr/local/bin/zcode' \
        'Terminal=false' \
        'Categories=Development;' \
        > /usr/local/share/applications/zcode.desktop \
    && cp /usr/local/share/applications/zcode.desktop /root/Desktop/ \
    && chmod +x /root/Desktop/zcode.desktop \
    && printf '%s\n' \
        '[Groups/0]' \
        'Name=Default' \
        'Default Layout=us' \
        'DefaultIM=pinyin' \
        '' \
        '[Groups/0/Items/0]' \
        'Name=keyboard-us' \
        'Layout=' \
        '' \
        '[Groups/0/Items/1]' \
        'Name=pinyin' \
        'Layout=' \
        '' \
        '[GroupOrder]' \
        '0=Default' \
        > /root/.config/fcitx5/profile

# Everything runs as root
WORKDIR /root
ENV HOME=/root \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    NODE_USE_ENV_PROXY=1 \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

COPY startup.sh proxy_config.py /root/
RUN chmod +x /root/startup.sh

EXPOSE 5901 6080

CMD ["/root/startup.sh"]
