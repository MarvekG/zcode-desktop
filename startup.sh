#!/bin/bash
# Start VNC (XFCE) + noVNC, trust the MITM CA, bring up the local proxy relay,
# and point shell env / ZCode / Firefox at it.
set -e

VNC_PW="${VNC_PASSWORD:-zcode123}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_DISPLAY=":1"
RESOLUTION="${RESOLUTION:-1920x1080}"

# Single local entry point that every component uses when a proxy is wanted.
RELAY_ADDR="127.0.0.1"
RELAY_PORT="8118"
RELAY_URL="http://${RELAY_ADDR}:${RELAY_PORT}"

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
    # Firefox enterprise policy: auto-imports the CA into every profile at launch.
    local policies
    policies=$(jq -n --arg cert /usr/local/share/ca-certificates/mitm-ca.crt \
        '{policies:{Certificates:{Install:[$cert]},Preferences:{"security.enterprise_roots.enabled":{Value:true,Status:"locked"}}}}')
    mkdir -p /etc/firefox/policies /usr/lib/firefox/distribution
    printf '%s' "$policies" > /etc/firefox/policies/policies.json
    printf '%s' "$policies" > /usr/lib/firefox/distribution/policies.json
    CA_PATH=/usr/local/share/ca-certificates/mitm-ca.crt
    echo "MITM CA installed into system store + NSS + Firefox policies: $src"
}

CA_PATH=""
if [ -f /mitm-ca.pem ]; then
    install_ca /mitm-ca.pem || exit 1
fi

# --- ZCode setting.json -------------------------------------------------------
# ZCode ignores system proxy env vars; it reads httpProxy/httpProxyNoProxy/
# httpProxyCaCertPath from /root/.zcode/v2/setting.json instead. The values we
# manage here are set or removed according to the current mode (proxy-less or
# via the relay), so switching modes never leaves stale config behind.
write_zcode_settings() { # $1=proxy url ('' = none) $2=no_proxy $3=ca path ('' = none)
    mkdir -p /root/.zcode/v2
    [ -f /root/.zcode/v2/setting.json ] || echo '{}' > /root/.zcode/v2/setting.json
    jq --arg p "$1" --arg n "$2" --arg c "$3" '
        if ($p | length) > 0 then . + {httpProxy: $p} else del(.httpProxy, .httpProxyNoProxy) end
        | if ($p | length) > 0 and ($n | length) > 0 then . + {httpProxyNoProxy: $n} else . end
        | if ($c | length) > 0 then . + {httpProxyCaCertPath: $c} else del(.httpProxyCaCertPath) end
    ' /root/.zcode/v2/setting.json > /tmp/setting.json.$$ \
      && mv /tmp/setting.json.$$ /root/.zcode/v2/setting.json \
      || { rm -f /tmp/setting.json.$$; echo "WARNING: failed to update setting.json" >&2; }
}

# --- Proxy relay (optional) ---------------------------------------------------
# ZCODE_HTTP_PROXY is the single source of truth for the whole container, e.g.
#   http://user:pass@proxy.example.com:55666
#   socks5://user:pass@proxy.example.com:1080
# When set, a local unauthenticated relay (tinyproxy) is started on
# 127.0.0.1:8118: it forwards everything to the upstream proxy and injects
# Basic auth when the URL carries user:pass@. Shell env vars, ZCode and
# Firefox all point at the relay, so nothing inside the container ever sees
# credentials. Unset or empty = the whole container runs proxy-less.
# The relay speaks HTTP proxy protocol to clients and can use HTTP, SOCKS4, or
# SOCKS5 for the upstream. An https:// URL prefix means HTTP proxy protocol
# over a plain connection; TLS to an HTTPS proxy is not implemented.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy \
      no_proxy NO_PROXY

noproxy_entries() {
    # Normalized NO_PROXY list (comma-split), loopbacks always included,
    # duplicates removed but order kept.
    printf '%s\n' "$ZCODE_HTTP_PROXY_NO_PROXY" localhost 127.0.0.1 ::1 \
        | tr ',' '\n' | awk 'NF && !seen[$0]++'
}

if [ -n "${ZCODE_HTTP_PROXY:-}" ]; then
    PROXY_SCHEME=$(sed -nE 's#^([a-zA-Z][a-zA-Z0-9+.-]*)://.*#\1#p' <<<"$ZCODE_HTTP_PROXY")
    PROXY_SCHEME=${PROXY_SCHEME:-http}
    PROXY_SCHEME=${PROXY_SCHEME,,}
    case "$PROXY_SCHEME" in
        http|https) UPSTREAM_TYPE=http ;;
        socks4|socks5) UPSTREAM_TYPE="$PROXY_SCHEME" ;;
        *) echo "ERROR: unsupported proxy scheme '$PROXY_SCHEME' (expected http, https, socks4, or socks5)" >&2; exit 1 ;;
    esac
    REST=$(sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' <<<"$ZCODE_HTTP_PROXY" | cut -d/ -f1)
    PROXY_USERPASS=$(sed -nE 's#^([^/@]+)@.*#\1#p' <<<"$REST")
    HOSTPORT=$(sed -E 's#^[^/@]+@##' <<<"$REST")
    PROXY_HOST_CONFIG=""
    if [[ "$HOSTPORT" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
        PROXY_HOST="${BASH_REMATCH[1]}"
        PROXY_PORT="${BASH_REMATCH[3]}"
        PROXY_HOST_CONFIG="[${PROXY_HOST}]"
    else
        PROXY_HOST="${HOSTPORT%%:*}"
        PROXY_PORT="${HOSTPORT#*:}"
        [ "$PROXY_PORT" = "$HOSTPORT" ] && PROXY_PORT=""
    fi
    if [ -z "$PROXY_PORT" ]; then
        case "$PROXY_SCHEME" in
            https) PROXY_PORT=443 ;;
            socks4|socks5) PROXY_PORT=1080 ;;
            *) PROXY_PORT=80 ;;
        esac
    fi
    if [ -z "$PROXY_HOST" ] || ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || [ "$PROXY_PORT" -lt 1 ] || [ "$PROXY_PORT" -gt 65535 ]; then
        echo "ERROR: cannot parse ZCODE_HTTP_PROXY='$ZCODE_HTTP_PROXY' (expected http(s)://[user:pass@]host:port)" >&2
        exit 1
    fi
    if [ -n "$PROXY_USERPASS" ] && { [[ "$PROXY_USERPASS" != *:* ]] || [[ "$PROXY_USERPASS" == *$'\n'* || "$PROXY_USERPASS" == *$'\r'* || "$PROXY_USERPASS" == *'"'* || "$PROXY_USERPASS" == *' '* ]]; }; then
        echo "ERROR: proxy credentials contain invalid characters or lack ':'" >&2
        exit 1
    fi
    if [ "$PROXY_SCHEME" = "https" ]; then
        echo "WARNING: TLS to the upstream proxy is not supported; connecting to ${PROXY_HOST}:${PROXY_PORT} with plain HTTP proxy protocol" >&2
    fi

    # Standard distro config path. No LogFile/Syslog on purpose: tinyproxy
    # runs in the foreground (-d) and logs to stderr, which the container
    # runtime collects (docker logs) - no self-managed log files anywhere.
    cat > /etc/tinyproxy/tinyproxy.conf <<EOF
Port $RELAY_PORT
Listen $RELAY_ADDR
Allow $RELAY_ADDR
Timeout 600
MaxClients 128
# tinyproxy: last matching rule wins, so the catch-all comes first.
upstream $UPSTREAM_TYPE ${PROXY_USERPASS:+${PROXY_USERPASS}@}${PROXY_HOST_CONFIG:-${PROXY_HOST}}:${PROXY_PORT}
upstream none "."
EOF
    noproxy_entries | while IFS= read -r entry; do
        entry="${entry// /}"
        entry="${entry//\"/}"
        [ -z "$entry" ] && continue
        if [[ "$entry" == */* ]]; then
            # IP with prefix length: pass through (tinyproxy supports CIDR)
            printf 'upstream none "%s"\n' "$entry"
        else
            if [[ "$entry" =~ ^\[([^]]+)\](:[0-9]+)?$ ]]; then
                host="${BASH_REMATCH[1]}"
            elif [[ "$entry" == *:*:* ]]; then
                # An unbracketed IPv6 literal (for example ::1) has colons
                # but no unambiguous port separator.
                host="$entry"
            else
                host="${entry%%:*}"     # drop an optional :port
            fi
            host="${host#.}"        # drop a leading dot
            [ -z "$host" ] && continue
            printf 'upstream none "%s"\n' "$host"
            [[ "$host" == *:* ]] || printf 'upstream none ".%s"\n' "$host"
        fi
    done >> /etc/tinyproxy/tinyproxy.conf
    chmod 600 /etc/tinyproxy/tinyproxy.conf

    # Foreground process as a supervised child of this script: if it dies,
    # the trailing wait -n tears the whole container down.
    tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf &
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
        echo "ERROR: local proxy relay failed to start; see tinyproxy stderr in the container log (docker logs)" >&2
        exit 1
    fi
    echo "Proxy relay up: $RELAY_URL -> ${PROXY_SCHEME}://${PROXY_HOST}:${PROXY_PORT}${PROXY_USERPASS:+ (auth injected here)}"

    NOPROXY_ENV=$(noproxy_entries | sed '/^$/d' | paste -sd, -)
    export http_proxy="$RELAY_URL" https_proxy="$RELAY_URL"
    export HTTP_PROXY="$RELAY_URL" HTTPS_PROXY="$RELAY_URL"
    export no_proxy="$NOPROXY_ENV" NO_PROXY="$NOPROXY_ENV"

    # Firefox ignores proxy env vars; configure via enterprise autoconfig.
    FF_CFG=/usr/lib/firefox/mozilla.cfg
    if [ -f "$FF_CFG" ]; then
        printf '%s\n' \
            '// Firefox enterprise config (generated by /root/startup.sh)' \
            'defaultPref("security.enterprise_roots.enabled", true);' \
            'defaultPref("network.proxy.type", 1);' \
            "defaultPref(\"network.proxy.http\", \"$RELAY_ADDR\");" \
            "defaultPref(\"network.proxy.http_port\", $RELAY_PORT);" \
            "defaultPref(\"network.proxy.ssl\", \"$RELAY_ADDR\");" \
            "defaultPref(\"network.proxy.ssl_port\", $RELAY_PORT);" \
            'defaultPref("network.proxy.share_proxy_settings", true);' \
            "defaultPref(\"network.proxy.no_proxies_on\", \"$NOPROXY_ENV\");" \
            > "$FF_CFG"
        echo "Firefox proxy: $RELAY_URL (no_proxies_on: $NOPROXY_ENV)"
    fi

    write_zcode_settings "$RELAY_URL" "$NOPROXY_ENV" "$CA_PATH"
    echo "ZCode proxy: $RELAY_URL"
else
    echo "ZCODE_HTTP_PROXY not set: running proxy-less"
    # Any proxy vars passed via docker -e were unset above, so shell tools stay direct.
    FF_CFG=/usr/lib/firefox/mozilla.cfg
    if [ -f "$FF_CFG" ]; then
        printf '%s\n' \
            '// Firefox enterprise config (generated by /root/startup.sh)' \
            'defaultPref("security.enterprise_roots.enabled", true);' \
            'defaultPref("network.proxy.type", 0);' \
            > "$FF_CFG"
    fi
    write_zcode_settings "" "" "$CA_PATH"
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
