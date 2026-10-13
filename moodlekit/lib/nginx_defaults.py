#!/usr/bin/env python3
"""Generate missing HTTP defaults without overwriting administrator settings."""
import glob
from pathlib import Path
import re
import sys

TOKEN = re.compile(r'''\s+|\#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[{};]|(?:\$\{[^}]*\}|\\.|[^\s{};"'#])+''')
DEFAULTS = {
    "client_max_body_size": "256M",
    "client_body_buffer_size": "128k",
    "server_tokens": "off",
    "keepalive_timeout": "65",
    "keepalive_requests": "100",
    "gzip_vary": "on",
    "gzip_proxied": "any",
    "gzip_comp_level": "5",
    "gzip_types": "text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript",
}


def generate(main, managed):
    main, managed = Path(main).resolve(), Path(managed).resolve()
    found = set()
    active = set()

    def scan(path, context):
        path = path.resolve()
        if path == managed:
            return
        if path in active:
            raise ValueError(f"Recursive Nginx include: {path}")
        active.add(path)
        tokens = [m.group() for m in TOKEN.finditer(path.read_text())
                  if not m.group().isspace() and not m.group().startswith('#')]
        stack = list(context)
        statement = []
        for token in tokens:
            if token == '{':
                stack.append(statement[0] if statement else '')
                statement = []
            elif token == '}':
                if not stack:
                    raise ValueError(f"Unmatched closing brace in {path}")
                stack.pop()
                statement = []
            elif token == ';':
                if statement:
                    if statement[0] == 'include':
                        pattern = Path(statement[1].strip('\"\''))
                        if not pattern.is_absolute():
                            pattern = main.parent / pattern
                        matches = sorted(glob.glob(str(pattern)))
                        if not matches and not glob.has_magic(str(pattern)):
                            raise FileNotFoundError(pattern)
                        for included in matches:
                            scan(Path(included), stack)
                    elif stack == ['http']:
                        found.add(statement[0])
                statement = []
            else:
                statement.append(token)
        if stack != list(context) or statement:
            raise ValueError(f"Incomplete Nginx configuration in {path}")
        active.remove(path)

    scan(main, [])
    lines = ['# MoodleKit HTTP defaults; existing administrator settings take precedence.']
    lines += [f'{name} {value};' for name, value in DEFAULTS.items() if name not in found]
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    print(generate(*sys.argv[1:]), end='')
