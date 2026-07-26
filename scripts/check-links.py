#!/usr/bin/env python3
"""Valida links markdown relativos e âncoras, seguindo a regra de slug do GitHub."""
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()

# Regra do GitHub para gerar o id de um heading:
#   1. lowercase
#   2. remove tudo que não seja letra, número, espaço, hífen ou underscore
#      (acentos SÃO preservados)
#   3. espaços -> hífen
def slug(text: str) -> str:
    text = text.strip().lower()
    # remove markdown inline (código, negrito, links) antes de slugificar
    text = re.sub(r'`([^`]*)`', r'\1', text)
    text = re.sub(r'\*\*([^*]*)\*\*', r'\1', text)
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)
    out = []
    for ch in text:
        if ch.isalnum() or ch in ' -_':
            out.append(ch)
        elif unicodedata.category(ch).startswith('M'):
            out.append(ch)
    return ''.join(out).replace(' ', '-')


def headings_of(path: Path) -> set:
    ids, in_fence = set(), False
    for line in path.read_text(encoding='utf-8').splitlines():
        if line.lstrip().startswith('```'):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = re.match(r'^(#{1,6})\s+(.*)$', line)
        if m:
            ids.add(slug(m.group(2)))
    return ids


LINK = re.compile(r'\[([^\]]+)\]\(([^)\s]+)\)')
errors, checked = [], 0

for md in sorted(ROOT.rglob('*.md')):
    text = md.read_text(encoding='utf-8')
    for label, dest in LINK.findall(text):
        if dest.startswith(('http://', 'https://', 'mailto:')):
            continue
        checked += 1
        path_part, _, anchor = dest.partition('#')
        rel = md.parent / path_part if path_part else md
        target = rel.resolve()

        if not target.exists():
            errors.append(f'{md.relative_to(ROOT)}: alvo inexistente -> {dest}  [{label}]')
            continue
        if anchor:
            ids = headings_of(target)
            if anchor not in ids:
                near = [i for i in ids if anchor.split('-')[0] in i][:3]
                hint = f'  (parecidos: {near})' if near else ''
                errors.append(
                    f'{md.relative_to(ROOT)}: âncora não existe -> {dest}{hint}')

print(f'links relativos verificados: {checked}')
if errors:
    print(f'\nPROBLEMAS ({len(errors)}):')
    for e in errors:
        print('  ' + e)
    sys.exit(1)
print('todos OK')
