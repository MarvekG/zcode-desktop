import contextlib
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest

import proxy_config as config


class ProxyURLTests(unittest.TestCase):
    def test_defaults_and_ipv6(self):
        for value, scheme, host, port in [
            ("proxy.example", "http", "proxy.example", 80),
            ("HTTP://proxy.example:8080", "http", "proxy.example", 8080),
            ("socks5://[2001:db8::1]", "socks5", "2001:db8::1", 1080),
        ]:
            with self.subTest(value=value):
                proxy = config.parse_proxy(value)
                self.assertEqual((proxy.scheme, proxy.host, proxy.port), (scheme, host, port))
                self.assertIsNone(proxy.username)

    def test_decode_once_and_preserve_plus_and_bytes(self):
        proxy = config.parse_proxy("http://user%40name:p%3Ass%252F+%FF@host:8080")
        self.assertEqual(proxy.username, "user@name")
        self.assertEqual(proxy.password.encode("utf-8", "surrogateescape"), b"p:ss%2F+\xff")
        self.assertNotIn("user@name", proxy.summary)
        self.assertNotIn("user@name", repr(proxy))

    def test_invalid_urls(self):
        for value in ["https://host", "socks4://host", "http://host:0", "http://host:65536",
                      "http://host:abc", "http://[broken]", "http://host/path", "http://host?",
                      "http://host#", "http://a:b@c@host", "http://user@host", "http://host\n",
                      "http://host\tname", "http://", "http://a:p:ss@host"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                config.parse_proxy(value)

    def test_invalid_credentials(self):
        for value in ["%", "%0", "%GG", "%00", "%0a", "%0D", "raw space", "raw@sign"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                config.decode_credential(value)


class RelayConfigTests(unittest.TestCase):
    def test_domain_boundaries_and_order(self):
        proxy = config.parse_proxy("http://proxy.example:8080")
        for entry in ["internal.example", ".internal.example", "internal.example:443"]:
            with self.subTest(entry=entry):
                entries = config.no_proxy_entries(entry)
                three = config.render_3proxy(proxy, entries)
                self.assertIn("auth iponly\n", three)
                self.assertIn('allow * * "internal.example"\n', three)
                self.assertIn('allow * * "*.internal.example"\n', three)
                self.assertNotIn('"*internal.example"', three)
                self.assertLess(three.index('"*.internal.example"'), three.index("parent 1000"))
                tiny = config.render_tinyproxy(proxy, entries)
                self.assertIn('upstream none ".internal.example"', tiny)
                self.assertLess(tiny.index("upstream http"), tiny.index('upstream none "internal.example"'))

    def test_ip_network_and_normalization(self):
        entries = config.no_proxy_entries(" 127.0.0.1,127.0.0.1,192.0.2.0/24,[::1]:80,Example.COM ")
        self.assertEqual(entries.count("127.0.0.1"), 1)
        self.assertIn("localhost", entries)
        self.assertEqual(config.no_proxy_target("[::1]:80"), "::1")
        self.assertEqual(config.no_proxy_target("Example.COM"), "example.com")
        output = config.render_3proxy(config.parse_proxy("socks5://host"), entries)
        for target in ["127.0.0.1", "192.0.2.0/24", "::1"]:
            self.assertIn(f'allow * * "{target}"', output)
            self.assertNotIn(f'"*.{target}"', output)

    def test_backend_credentials_and_quoting(self):
        proxy = config.parse_proxy("http://user%40name:p%3Ass%25@host")
        self.assertIn('"user@name" "p:ss%"', config.render_3proxy(proxy, []))
        self.assertIn("user@name:p:ss%@host:80", config.render_tinyproxy(proxy, []))
        proxy = config.parse_proxy("http://user:p%22a%20ss%40%24@host")
        self.assertIn('"p""a ss@$"', config.render_3proxy(proxy, []))
        with self.assertRaisesRegex(ValueError, "use ZCODE_PROXY_BACKEND=3proxy"):
            config.render_tinyproxy(proxy, [])


class ApplicationConfigTests(unittest.TestCase):
    def test_files_metadata_and_switch_to_direct(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            firefox = root / "usr/lib/firefox/mozilla.cfg"
            firefox.parent.mkdir(parents=True)
            firefox.touch()
            settings = root / "root/.zcode/v2/setting.json"
            settings.parent.mkdir(parents=True)
            settings.write_text('{"theme": "dark"}')
            env = {"ZCODE_HTTP_PROXY": "http://user:secret%25@host", "ZCODE_PROXY_BACKEND": "3PROXY"}
            state = config.configure(env, root, "/mitm-ca.crt")
            self.assertEqual(state["backend"], "3proxy")
            self.assertNotIn("secret", json.dumps(state))
            self.assertEqual(stat.S_IMODE(Path(state["config_path"]).stat().st_mode), 0o600)
            self.assertIn('"network.proxy.type", 1', firefox.read_text())
            self.assertEqual(json.loads(settings.read_text())["httpProxy"], config.RELAY_URL)
            policy = json.loads((root / "etc/firefox/policies/policies.json").read_text())
            self.assertEqual(policy["policies"]["Certificates"]["Install"], ["/mitm-ca.crt"])
            state = config.configure({}, root)
            self.assertFalse(state["enabled"])
            self.assertEqual(json.loads(settings.read_text()), {"theme": "dark"})
            self.assertIn('"network.proxy.type", 0', firefox.read_text())
            self.assertNotIn("network.proxy.http", firefox.read_text())

    def test_reject_before_writing_and_preserve_invalid_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(ValueError):
                config.configure({"ZCODE_HTTP_PROXY": "https://host"}, root)
            self.assertEqual(list(root.iterdir()), [])
            settings = root / "root/.zcode/v2/setting.json"
            settings.parent.mkdir(parents=True)
            settings.write_text("invalid json")
            with contextlib.redirect_stderr(io.StringIO()) as error:
                config.configure({}, root)
            self.assertIn("WARNING", error.getvalue())
            self.assertEqual(settings.read_text(), "invalid json")


if __name__ == "__main__":
    unittest.main()
