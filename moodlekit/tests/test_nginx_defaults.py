#!/usr/bin/env python3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from nginx_defaults import generate


class NginxDefaultsTests(unittest.TestCase):
    def test_includes_scopes_and_repeatability(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'conf.d').mkdir()
            main = root / 'nginx.conf'
            managed = root / 'conf.d/10-moodlekit-global.conf'
            main.write_text('events {} http { include conf.d/*.conf; client_max_body_size 64M; }')
            (root / 'conf.d/admin.conf').write_text(
                '# keepalive_timeout 123;\nkeepalive_requests 200;\n'
                'server { client_body_buffer_size 32k; location / { server_tokens on; } }')
            managed.write_text('client_max_body_size 256M;')
            original = main.read_text()
            result = generate(main, managed)
            self.assertNotIn('client_max_body_size', result)
            self.assertNotIn('keepalive_requests', result)
            self.assertIn('client_body_buffer_size 128k;', result)
            self.assertIn('server_tokens off;', result)
            self.assertIn('keepalive_timeout 65;', result)
            managed.write_text(result)
            self.assertEqual(generate(main, managed), result)
            self.assertEqual(main.read_text(), original)

    def test_nested_include_and_gzip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'nginx.conf').write_text('http { include settings; }')
            (root / 'settings').write_text('include gzip.conf;')
            (root / 'gzip.conf').write_text('gzip_vary off; gzip_types "text/plain";')
            result = generate(root / 'nginx.conf', root / 'managed.conf')
            self.assertNotIn('gzip_vary', result)
            self.assertNotIn('gzip_types', result)

    def test_recursive_include_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / 'nginx.conf'
            main.write_text('http { include nginx.conf; }')
            with self.assertRaises(ValueError):
                generate(main, main.parent / 'managed.conf')


if __name__ == '__main__':
    unittest.main()
