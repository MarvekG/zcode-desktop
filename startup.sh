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
        cp "$src" /usr/local/share/ca-certificates/mitm-ca.crt
    elif openssl x509 -inform DER -in "$src" -out /usr/local/share/ca-certificates/mitm-ca.crt 2>/dev/null; then
        echo "Converted DER cert to PEM: $src"
    else
        echo "ERROR: cannot parse certificate $src (neither PEM nor DER)" >&2
        return 1
    fi
    update-ca-certificates >/tmp/ca-install.log 2>&1 || true
    # NSS database: what Firefox enterprise roots actually reads on Linux;
    # /etc/ssl/certs alone is NOT enough for Firefox. Recreate from scratch so
    # reruns stay idempotent (certutil -N loops forever prompting on an
    # existing db when stdin is not a terminal).
    mkdir -p /etc/pki/nssdb
    rm -f /etc/pki/nssdb/*.db /etc/pki/nssdb/pkcs11.txt
    certutil -d sql:/etc/pki/nssdb -N --empty-password </dev/null >/dev/null 2>&1 || true
    certutil -d sql:/etc/pki/nssdb -A -t "C,," -n "mitm-ca" -i /usr/local/share/ca-certificates/mitm-ca.crt </dev/null \
        || echo "WARNING: NSS import failed" >&2
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
# When set, a local unauthenticated relay (tinyproxy) is started on
# 127.0.0.1:8118: it forwards everything to the upstream proxy and injects
# Basic auth when the URL carries user:pass@. Shell env vars, ZCode and
# Firefox all point at the relay, so nothing inside the container ever sees
# credentials. Unset or empty = the whole container runs proxy-less.
# The relay speaks plain HTTP proxy protocol to the upstream (standard for
# squid-style proxies); an https:// URL prefix is accepted but the connection
# to the upstream stays plain.
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
    REST=$(sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' <<<"$ZCODE_HTTP_PROXY" | cut -d/ -f1)
    PROXY_USERPASS=$(sed -nE 's#^([^/@]+)@.*#\1#p' <<<"$REST")
    HOSTPORT=$(sed -E 's#^[^/@]+@##' <<<"$REST")
    PROXY_HOST="${HOSTPORT%%:*}"
    PROXY_PORT="${HOSTPORT#*:}"
    [ "$PROXY_PORT" = "$HOSTPORT" ] && PROXY_PORT=""
    if [ -z "$PROXY_PORT" ]; then
        case "$PROXY_SCHEME" in https) PROXY_PORT=443 ;; *) PROXY_PORT=80 ;; esac
    fi
    if [ -z "$PROXY_HOST" ] || ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
        echo "ERROR: cannot parse ZCODE_HTTP_PROXY='$ZCODE_HTTP_PROXY' (expected http(s)://[user:pass@]host:port)" >&2
        exit 1
    fi
    if [ "$PROXY_SCHEME" = "https" ]; then
        echo "WARNING: TLS to the upstream proxy is not supported; connecting to ${PROXY_HOST}:${PROXY_PORT} with plain HTTP proxy protocol" >&2
    fi

    {
        echo "Port $RELAY_PORT"
        echo "Listen $RELAY_ADDR"
        echo "Allow $RELAY_ADDR"
        echo "Timeout 600"
        echo 'LogFile "/var/log/tinyproxy-relay.log"'
        echo 'PidFile "/run/tinyproxy-relay.pid"'
        echo "MaxClients 128"
        # tinyproxy: last matching rule wins, so the catch-all comes first.
        if [ -n "$PROXY_USERPASS" ]; then
            echo "upstream http ${PROXY_USERPASS}@${PROXY_HOST}:${PROXY_PORT}"
        else
            echo "upstream http ${PROXY_HOST}:${PROXY_PORT}"
        fi
        echo 'upstream none "."'
        noproxy_entries | while IFS= read -r entry; do
            entry="${entry// /}"
            entry="${entry//\"/}"
            [ -z "$entry" ] && continue
            if [[ "$entry" == */* ]]; then
                # IP with prefix length: pass through (tinyproxy supports CIDR)
                printf 'upstream none "%s"\n' "$entry"
            else
                host="${entry%%:*}"     # drop an optional :port
                host="${host#.}"        # drop a leading dot
                [ -z "$host" ] && continue
                printf 'upstream none "%s"\n' "$host"
                printf 'upstream none ".%s"\n' "$host"
            fi
        done
    } > /etc/tinyproxy-zcode.conf

    tinyproxy -c /etc/tinyproxy-zcode.conf

    # Wait for the relay to answer; fail loudly if it did not come up.
    RELAY_OK=""
    for _ in $(seq 1 40); do
        # Any HTTP response (even an upstream error page) proves the relay is up.
        if curl -sx "$RELAY_URL" --max-time 2 -o /dev/null "http://relay-probe.invalid/" 2>/dev/null; then
            RELAY_OK=1
            break
        fi
        sleep 0.25
    done
    if [ -z "$RELAY_OK" ]; then
        echo "ERROR: local proxy relay failed to start; tinyproxy log:" >&2
        tail -20 /var/log/tinyproxy-relay.log >&2 || true
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

# noVNC: open http://<server-ip>:6080/vnc.html in a browser
websockify --web=/usr/share/novnc/ "$NOVNC_PORT" localhost:5901 &

echo "========================================================="
echo " Desktop is up"
echo "  VNC   : <server-ip>:5901  (password: $VNC_PW)"
echo "  Browser: http://<server-ip>:$NOVNC_PORT/vnc.html"
echo "========================================================="

# Stay in the foreground; exit the container if any component dies
wait -n
