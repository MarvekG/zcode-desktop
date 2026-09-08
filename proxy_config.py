#!/usr/bin/env python3
"""Generate relay and application configuration from ZCode proxy variables."""

import argparse
from dataclasses import dataclass, field
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import unquote_to_bytes, urlsplit

RELAY_ADDR = "127.0.0.1"
RELAY_PORT = 8118
RELAY_URL = f"http://{RELAY_ADDR}:{RELAY_PORT}"


@dataclass(frozen=True)
class Proxy:
    scheme: str
    host: str
    port: int
    username: str | None = field(default=None, repr=False)
    password: str | None = field(default=None, repr=False)

    @property
    def authority(self):
        host = f"[{self.host}]" if ":" in self.host else self.host
        return f"{host}:{self.port}"

    @property
    def summary(self):
        auth = " (auth configured internally)" if self.username is not None else ""
        return f"{self.scheme}://{self.authority}{auth}"


def decode_credential(value):
    # unquote alone tolerates malformed escapes; reject them before decoding.
    if re.search(r"%(?![0-9a-fA-F]{2})", value):
        raise ValueError("proxy credentials contain invalid URL percent-encoding")
    if re.search(r"[^a-zA-Z0-9._~!$&'()*+,;=%-]", value):
        raise ValueError("proxy credential special characters must be URL-encoded")
    decoded = unquote_to_bytes(value).decode("utf-8", errors="surrogateescape")
    if any(char in decoded for char in "\x00\r\n"):
        raise ValueError("decoded proxy credentials contain a NUL or newline")
    return decoded


def validate_host(host):
    if "%" in host and not re.fullmatch(r"[0-9a-fA-F:]+%[a-zA-Z0-9_.-]+", host):
        raise ValueError("invalid IPv6 scope identifier")
    try:
        ipaddress.ip_address(host)
        return
    except ValueError:
        pass
    if not re.fullmatch(r"[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\.?", host):
        raise ValueError("invalid proxy hostname or IP address")


def parse_proxy(value):
    # urlsplit removes some control characters, so validate the original input.
    if any(char.isspace() or ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("proxy URL contains whitespace or control characters")
    try:
        parts = urlsplit(value if "://" in value else "http://" + value)
        host, port = parts.hostname, parts.port
    except ValueError:
        raise ValueError("cannot parse proxy host/port") from None
    if parts.scheme not in ("http", "socks5"):
        raise ValueError("unsupported proxy scheme (expected http or socks5)")
    if parts.path or "?" in value or "#" in value:
        raise ValueError("proxy URL must not contain a path, query, or fragment")
    if not host or port == 0:
        raise ValueError("cannot parse proxy host/port")
    validate_host(host)
    username = password = None
    if "@" in parts.netloc:
        if parts.netloc.count("@") != 1:
            raise ValueError("proxy URL has an invalid userinfo section")
        userinfo = parts.netloc.split("@", 1)[0]
        if ":" not in userinfo:
            raise ValueError("proxy credentials must be URL-encoded user:password")
        username, password = map(decode_credential, userinfo.split(":", 1))
    return Proxy(parts.scheme, host, port or (1080 if parts.scheme == "socks5" else 80), username, password)


def no_proxy_entries(value):
    entries = []
    for entry in value.split(",") + ["localhost", "127.0.0.1", "::1"]:
        entry = entry.strip().replace(" ", "").replace('"', "")
        if not entry:
            continue
        if any(char.isspace() or ord(char) < 32 for char in entry):
            raise ValueError("NO_PROXY contains control characters")
        no_proxy_target(entry)  # Validate before writing any files.
        entries.append(entry)
    return list(dict.fromkeys(entries))


def no_proxy_target(entry):
    if "/" in entry:
        try:
            ipaddress.ip_network(entry, strict=False)
        except ValueError:
            raise ValueError("invalid NO_PROXY network") from None
        return entry
    if entry.startswith("["):
        match = re.fullmatch(r"\[([^]]+)\](?::[0-9]+)?", entry)
        if not match:
            raise ValueError("invalid NO_PROXY IPv6 address")
        target = match[1]
    elif entry.count(":") > 1:
        target = entry
    else:
        target = entry.split(":", 1)[0]
    target = target.removeprefix(".").lower()
    if target != "*":
        validate_host(target.removeprefix("*."))
    return target


def is_domain(target):
    if any(char in target for char in ":/*"):
        return False
    try:
        ipaddress.ip_address(target)
        return False
    except ValueError:
        return True


def threeproxy_quote(value):
    return '"' + value.replace('"', '""') + '"'


def render_3proxy(proxy, entries):
    # ACL authorization is required for parent redirection, even without login.
    lines = ["auth iponly", "log", "maxconn 128", "timeouts 1 5 30 60 180 600 15 60 15 5 5"]
    # First matching ACL wins: direct exceptions precede the catch-all parent.
    for entry in entries:
        target = no_proxy_target(entry)
        lines.append(f"allow * * {threeproxy_quote(target)}")
        if is_domain(target):
            lines.append(f"allow * * {threeproxy_quote('*.' + target)}")
    lines.append("allow *")
    parent = f"parent 1000 {proxy.scheme} {threeproxy_quote(proxy.host)} {proxy.port}"
    if proxy.username is not None:
        parent += f" {threeproxy_quote(proxy.username)} {threeproxy_quote(proxy.password)}"
    lines.extend([parent, f"proxy -p{RELAY_PORT} -i{RELAY_ADDR}"])
    return "\n".join(lines) + "\n"


def render_tinyproxy(proxy, entries):
    upstream = proxy.authority
    if proxy.username is not None:
        if (":" in proxy.username or "@" in proxy.password
                or any(char.isspace() or char == '"' for char in proxy.username + proxy.password)):
            raise ValueError("decoded proxy credentials cannot be represented by tinyproxy; use ZCODE_PROXY_BACKEND=3proxy")
        upstream = f"{proxy.username}:{proxy.password}@{upstream}"
    # Last matching rule wins: the parent precedes all direct exceptions.
    lines = [f"Port {RELAY_PORT}", f"Listen {RELAY_ADDR}", f"Allow {RELAY_ADDR}",
             "Timeout 600", "MaxClients 128", f"upstream {proxy.scheme} {upstream}",
             'upstream none "."']
    for entry in entries:
        target = no_proxy_target(entry)
        lines.append(f'upstream none "{target}"')
        if is_domain(target):
            lines.append(f'upstream none ".{target}"')
    return "\n".join(lines) + "\n"


def write_file(path, content, mode=0o600):
    """Replace complete files atomically; credentials are never world-readable."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure_apps(root, enabled, no_proxy, ca_path):
    if ca_path:
        policy = {"policies": {"Certificates": {"Install": [ca_path]},
                               "Preferences": {"security.enterprise_roots.enabled": {
                                   "Value": True, "Status": "locked"}}}}
        for relative in ("etc/firefox/policies/policies.json", "usr/lib/firefox/distribution/policies.json"):
            write_file(root / relative, json.dumps(policy) + "\n", 0o644)
    firefox = root / "usr/lib/firefox/mozilla.cfg"
    if firefox.exists():
        preferences = {"security.enterprise_roots.enabled": True, "network.proxy.type": int(enabled)}
        if enabled:
            preferences.update({"network.proxy.http": RELAY_ADDR, "network.proxy.http_port": RELAY_PORT,
                                "network.proxy.ssl": RELAY_ADDR, "network.proxy.ssl_port": RELAY_PORT,
                                "network.proxy.share_proxy_settings": True, "network.proxy.no_proxies_on": no_proxy})
        lines = ["// Firefox enterprise config (generated by proxy_config.py)"]
        lines.extend(f"defaultPref({json.dumps(key)}, {json.dumps(value)});" for key, value in preferences.items())
        write_file(firefox, "\n".join(lines) + "\n", 0o644)

    settings = root / "root/.zcode/v2/setting.json"
    try:
        current = json.loads(settings.read_text()) if settings.exists() else {}
        if not isinstance(current, dict):
            raise ValueError("expected a JSON object")
        for key in ("httpProxy", "httpProxyNoProxy", "httpProxyCaCertPath"):
            current.pop(key, None)
        if enabled:
            current.update(httpProxy=RELAY_URL, httpProxyNoProxy=no_proxy)
        if ca_path:
            current["httpProxyCaCertPath"] = ca_path
        write_file(settings, json.dumps(current, ensure_ascii=False, indent=2) + "\n")
    except (OSError, ValueError):
        print("WARNING: failed to update setting.json", file=sys.stderr)


def configure(environ, root=Path("/"), ca_path=""):
    enabled = bool(environ.get("ZCODE_HTTP_PROXY"))
    backend = (environ.get("ZCODE_PROXY_BACKEND") or "tinyproxy").lower()
    state = dict(enabled=enabled, backend=backend, relay_addr=RELAY_ADDR,
                 relay_port=RELAY_PORT, relay_url=RELAY_URL, no_proxy="", upstream_summary="", config_path="")
    if enabled:
        if backend not in ("tinyproxy", "3proxy"):
            raise ValueError("unsupported ZCODE_PROXY_BACKEND (expected tinyproxy or 3proxy)")
        proxy = parse_proxy(environ["ZCODE_HTTP_PROXY"])
        entries = no_proxy_entries(environ.get("ZCODE_HTTP_PROXY_NO_PROXY", ""))
        if backend == "tinyproxy":
            config = render_tinyproxy(proxy, entries)
            path = root / "etc/tinyproxy/tinyproxy.conf"
        else:
            config = render_3proxy(proxy, entries)
            path = root / "etc/3proxy/zcode-3proxy.cfg"
        write_file(path, config)
        state.update(no_proxy=",".join(entries), upstream_summary=proxy.summary, config_path=str(path))
    configure_apps(root, enabled, state["no_proxy"], ca_path)
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ca-path", default="")
    args = parser.parse_args()
    try:
        state = configure(os.environ, ca_path=args.ca_path)
    except (ValueError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    # Only non-secret metadata crosses back into the shell; never emit shell code.
    print(json.dumps(state))
    return 0


if __name__ == "__main__":
    sys.exit(main())
