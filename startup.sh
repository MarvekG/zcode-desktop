#!/bin/bash
# Start VNC (XFCE) + noVNC, trust the MITM CA, bring up the local proxy relay,
# and point shell env / ZCode / Firefox at it.
set -e

VNC_PW="${VNC_PASSWORD:-zcode123}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_DISPLAY=":1"
RESOLUTION="${RESOLUTION:-1920x1080}"

# --- MITM CA ------------------------------------------------------------------
# The MITM root CA is trusted by: the system store (curl/git/Electron/openssl),
# the NSS database + Firefox enterprise policy, and ZCode (httpProxyCaCertPath).
# It comes from the FIXED path /mitm-ca.pem - bind-mounted at runtime, or baked
# in at build time from certs/mitm-ca.pem. PEM or DER. More than one cert or an
# unparseable file aborts startup - failing loud beats silently trusting the
# wrong CA.
install_ca() { # $1 = source cert file (exactly one cert, PEM or DER); sets CA_PATH
    local src="$1"
    local n
    # grep -c exits 1 on count 0 (DER files have no PEM marker)
    n=$(grep -c -- "-----BEGIN CERTIFICATE-----" "$src" || true)
    if [ "$n" -gt 1 ]; then
        echo "ERROR: $src contains $n certificates; exactly one MITM CA is required" >&2
        return 1
    fi
    mkdir -p /usr/local/share/ca-certificates
    # Normalize: DER and other binary encodings get converted to PEM, because
    # update-ca-certificates / Node / ZCode all require PEM.
    if [ "$n" -eq 1 ]; then
        if ! openssl x509 -in "$src" -noout >/dev/null 2>&1; then
            echo "ERROR: cannot parse PEM certificate $src" >&2
            return 1
        fi
        cp "$src" /usr/local/share/ca-certificates/mitm-ca.crt
    elif openssl x509 -inform DER -in "$src" -out /usr/local/share/ca-certificates/mitm-ca.crt 2>/dev/null; then
        echo "Converted DER cert to PEM: $src"
    else
        echo "ERROR: cannot parse certificate $src (neither PEM nor DER)" >&2
        return 1
    fi
    if ! update-ca-certificates >/tmp/ca-install.log 2>&1; then
        echo "ERROR: failed to install certificate into the system trust store" >&2
        cat /tmp/ca-install.log >&2 || true
        return 1
    fi
    # NSS database: what Firefox enterprise roots actually reads on Linux;
    # /etc/ssl/certs alone is NOT enough for Firefox. Recreate from scratch so
    # reruns stay idempotent (certutil -N loops forever prompting on an
    # existing db when stdin is not a terminal).
    mkdir -p /etc/pki/nssdb
    rm -f /etc/pki/nssdb/*.db /etc/pki/nssdb/pkcs11.txt
    if ! certutil -d sql:/etc/pki/nssdb -N --empty-password </dev/null >/dev/null 2>&1; then
        echo "ERROR: failed to initialize the Firefox NSS database" >&2
        return 1
    fi
    certutil -d sql:/etc/pki/nssdb -A -t "C,," -n "mitm-ca" -i /usr/local/share/ca-certificates/mitm-ca.crt </dev/null \
        || { echo "ERROR: failed to import the MITM CA into the Firefox NSS database" >&2; return 1; }
    # Python writes the Firefox certificate policy with the proxy settings below.
    CA_PATH=/usr/local/share/ca-certificates/mitm-ca.crt
    echo "MITM CA installed into system store + NSS: $src"
}

CA_PATH=""
if [ -f /mitm-ca.pem ]; then
    install_ca /mitm-ca.pem || exit 1
fi

# --- Proxy relay and application configuration -------------------------------
# Python owns URL decoding, NO_PROXY normalization and all proxy config files.
# Its JSON output contains only non-secret metadata used to launch the relay.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy \
      no_proxy NO_PROXY
SCRIPT_DIR=/root
PROXY_STATE=$(python3 "$SCRIPT_DIR/proxy_config.py" --ca-path "$CA_PATH")

if [ "$(jq -r '.enabled' <<<"$PROXY_STATE")" = true ]; then
    PROXY_BACKEND=$(jq -r '.backend' <<<"$PROXY_STATE")
    PROXY_CONFIG=$(jq -r '.config_path' <<<"$PROXY_STATE")
    RELAY_ADDR=$(jq -r '.relay_addr' <<<"$PROXY_STATE")
    RELAY_PORT=$(jq -r '.relay_port' <<<"$PROXY_STATE")
    RELAY_URL=$(jq -r '.relay_url' <<<"$PROXY_STATE")
    NOPROXY_ENV=$(jq -r '.no_proxy' <<<"$PROXY_STATE")
    UPSTREAM_SUMMARY=$(jq -r '.upstream_summary' <<<"$PROXY_STATE")

    # Both relays run in the foreground as supervised children of this script.
    if [ "$PROXY_BACKEND" = tinyproxy ]; then
        tinyproxy -d -c "$PROXY_CONFIG" &
    else
        3proxy "$PROXY_CONFIG" &
    fi
    RELAY_PID=$!

    # Wait for the relay to accept connections. Deliberately a pure liveness
    # check (TCP connect on the listen port): probing through the relay would
    # depend on upstream behavior, and a slow upstream must not fail startup.
    RELAY_OK=""
    for _ in $(seq 1 40); do
        if timeout 1 bash -c "exec 3<>/dev/tcp/${RELAY_ADDR}/${RELAY_PORT}" 2>/dev/null; then
            RELAY_OK=1
            break
        fi
        sleep 0.25
    done
    if [ -z "$RELAY_OK" ]; then
        kill "$RELAY_PID" 2>/dev/null || true
        echo "ERROR: local $PROXY_BACKEND relay failed to start; see the container log (docker logs)" >&2
        exit 1
    fi
    echo "Proxy relay up: $RELAY_URL via $PROXY_BACKEND -> $UPSTREAM_SUMMARY"
    export http_proxy="$RELAY_URL" https_proxy="$RELAY_URL"
    export HTTP_PROXY="$RELAY_URL" HTTPS_PROXY="$RELAY_URL"
    export no_proxy="$NOPROXY_ENV" NO_PROXY="$NOPROXY_ENV"
    echo "Firefox / ZCode proxy: $RELAY_URL (no_proxy: $NOPROXY_ENV)"
else
    echo "ZCODE_HTTP_PROXY not set: running proxy-less"
fi

# --- VNC + noVNC ----------------------------------------------------------
mkdir -p ~/.vnc ~/Desktop
echo "$VNC_PW" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

cat > ~/.vnc/xstartup <<'EOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR=/tmp/runtime-root
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
# Input method (fcitx5 pinyin); ZCode/Firefox inherit these env vars
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
fcitx5 -d >/dev/null 2>&1
# ZCode does NOT auto-start; launch it from the desktop icon on demand.
# startxfce4 must stay in the foreground; if xstartup exits, the whole VNC session dies
exec dbus-launch --exit-with-session startxfce4
EOF
chmod +x ~/.vnc/xstartup

vncserver $VNC_DISPLAY -geometry "$RESOLUTION" -localhost no -xstartup ~/.vnc/xstartup
VNC_PID_FILE=$(find ~/.vnc -maxdepth 1 -type f -name "*:1.pid" -print -quit)
if [ -z "$VNC_PID_FILE" ] || ! VNC_PID=$(cat "$VNC_PID_FILE") || ! [[ "$VNC_PID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: unable to locate the VNC server PID" >&2
    exit 1
fi

cleanup() {
    [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null || true
    [ -n "${NOVNC_PID:-}" ] && kill "$NOVNC_PID" 2>/dev/null || true
    vncserver -kill "$VNC_DISPLAY" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Turn a detached Xvnc failure into a container failure visible to wait -n.
( while kill -0 "$VNC_PID" 2>/dev/null; do sleep 2; done; exit 1 ) &
VNC_MONITOR_PID=$!

# noVNC: open http://<server-ip>:6080/vnc.html in a browser
websockify --web=/usr/share/novnc/ "$NOVNC_PORT" localhost:5901 &
NOVNC_PID=$!

echo "========================================================="
echo " Desktop is up"
echo "  VNC   : <server-ip>:5901  (password: $VNC_PW)"
echo "  Browser: http://<server-ip>:$NOVNC_PORT/vnc.html"
echo "========================================================="

# Stay in the foreground; exit the container if any component dies
wait -n
