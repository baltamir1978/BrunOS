#!/bin/bash
# Descarga EasyList y EasyPrivacy y las convierte al formato de WKContentRuleList.
#
# LO GENERADO NO SE VERSIONA. EasyList y EasyPrivacy tienen licencia propia
# (GPLv3 / CC BY-SA) y no se redistribuyen en este repositorio: cada uno se las
# baja en local. Por eso BrunOS/Resources/Blocklists/*.json está en .gitignore.
#
# El conversor es propio y deliberadamente sencillo: traduce las reglas de
# bloqueo de red, que son la inmensa mayoría y las que más pesan, e ignora las
# de ocultación cosmética (##) y las opciones que WebKit no sabe expresar. No se
# añade SafariConverterLib de AdGuard porque eso serían dependencias nuevas, y
# las dependencias se consultan antes de meterlas.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="BrunOS/Resources/Blocklists"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"

echo "==> Descargando listas"
curl -fsSL "https://easylist.to/easylist/easylist.txt" -o "$TMP/easylist.txt"
curl -fsSL "https://easylist.to/easylist/easyprivacy.txt" -o "$TMP/easyprivacy.txt"

echo "==> Convirtiendo"
python3 - "$TMP/easylist.txt" "$TMP/easyprivacy.txt" "$DEST" <<'PY'
import json, re, sys

sources, dest = sys.argv[1:-1], sys.argv[-1]

# WebKit se atraganta por encima de unas 150.000 reglas por lista, así que se
# trocea. Cada trozo se compila por separado y se aplican todos a la vez.
CHUNK = 40_000

def convert(line):
    line = line.strip()
    if not line or line.startswith('!') or line.startswith('['):
        return None
    # Reglas cosméticas: WebKit las admite con css-display-none, pero la
    # sintaxis de selectores de EasyList no se traduce en general. Fuera.
    if '##' in line or '#@#' in line or '#?#' in line:
        return None

    exception = line.startswith('@@')
    if exception:
        line = line[2:]

    options = {}
    if '$' in line:
        line, _, raw = line.partition('$')
        for option in raw.split(','):
            option = option.strip()
            if option.startswith('domain='):
                options['domain'] = option[len('domain='):]
            elif option in ('third-party', '~third-party'):
                options['third-party'] = option
            elif option in ('script', 'image', 'stylesheet', 'font', 'media',
                            'popup', 'document', 'subdocument', 'xmlhttprequest'):
                options.setdefault('types', []).append(option)
            elif option.startswith(('~', 'redirect', 'rewrite', 'csp', 'removeparam')):
                # Opciones que WebKit no sabe expresar: descartar la regla
                # entera es más honrado que traducirla a medias.
                return None

    if not line or line.startswith('/') and line.endswith('/'):
        return None  # expresiones regulares en crudo, fuera

    # || al principio significa "este dominio y subdominios".
    anchored_domain = line.startswith('||')
    if anchored_domain:
        line = line[2:]
    line = line.lstrip('|').rstrip('|')

    pattern = re.escape(line)
    pattern = pattern.replace(r'\*', '.*').replace(r'\^', r'[/:?=&]')
    if anchored_domain:
        pattern = r'^https?://([^/]+\.)?' + pattern

    trigger = {'url-filter': pattern}

    if 'types' in options:
        mapping = {
            'script': 'script', 'image': 'image', 'stylesheet': 'style-sheet',
            'font': 'font', 'media': 'media', 'popup': 'popup',
            'document': 'document', 'subdocument': 'document',
            'xmlhttprequest': 'raw',
        }
        kinds = sorted({mapping[t] for t in options['types'] if t in mapping})
        if kinds:
            trigger['resource-type'] = kinds

    if options.get('third-party') == 'third-party':
        trigger['load-type'] = ['third-party']
    elif options.get('third-party') == '~third-party':
        trigger['load-type'] = ['first-party']

    if 'domain' in options:
        included, excluded = [], []
        for domain in options['domain'].split('|'):
            if domain.startswith('~'):
                excluded.append('*' + domain[1:])
            elif domain:
                included.append('*' + domain)
        if included:
            trigger['if-domain'] = included
        if excluded:
            trigger['unless-domain'] = excluded

    action = {'type': 'ignore-previous-rules'} if exception else {'type': 'block'}
    return {'trigger': trigger, 'action': action}

rules, seen = [], set()
for source in sources:
    with open(source, encoding='utf-8', errors='ignore') as handle:
        for line in handle:
            rule = convert(line)
            if not rule:
                continue
            key = json.dumps(rule, sort_keys=True)
            if key in seen:
                continue
            seen.add(key)
            rules.append(rule)

# Las excepciones tienen que ir después de los bloqueos: WebKit aplica las
# reglas en orden y `ignore-previous-rules` sólo anula lo anterior.
rules.sort(key=lambda r: r['action']['type'] == 'ignore-previous-rules')

for index in range(0, len(rules), CHUNK):
    chunk = rules[index:index + CHUNK]
    path = f"{dest}/blocklist-{index // CHUNK:02d}.json"
    with open(path, 'w', encoding='utf-8') as handle:
        json.dump(chunk, handle, separators=(',', ':'))
    print(f"    {path}: {len(chunk)} reglas")

print(f"==> {len(rules)} reglas en total")
PY

echo
echo "Recuerda recompilar para que entren en el bundle."
