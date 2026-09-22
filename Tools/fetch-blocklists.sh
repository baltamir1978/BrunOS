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
# Los trozos de una generación anterior se borran: si ahora salen menos, los
# que sobraran se seguirían compilando.
rm -f "$DEST"/blocklist-*.json "$DEST"/manifest-blocklists.json

echo "==> Descargando listas"
curl -fsSL "https://easylist.to/easylist/easylist.txt" -o "$TMP/easylist.txt"
curl -fsSL "https://easylist.to/easylist/easyprivacy.txt" -o "$TMP/easyprivacy.txt"

echo "==> Convirtiendo"
python3 - "$TMP/easylist.txt" "$TMP/easyprivacy.txt" "$DEST" <<'PY'
import json, os, re, sys

sources, dest = sys.argv[1:-1], sys.argv[-1]

# WebKit se atraganta por encima de unas 150.000 reglas por lista, así que se
# trocea. Cada trozo se compila por separado y se aplican todos a la vez.
CHUNK = 40_000

# WebKit es muy quisquilloso con estas reglas y, cuando algo no le gusta,
# rechaza la lista ENTERA con un escueto WKErrorDomain 7 sin decir qué regla
# era. De ahí que aquí se descarte con generosidad: más vale bloquear un poco
# menos que quedarse sin bloquear nada.
#
# Las restricciones que costaron el primer intento:
#   - `url-filter` tiene que ser ASCII puro.
#   - `if-domain` y `unless-domain` NO pueden ir juntos en el mismo trigger.
#   - los dominios van en minúsculas.
#   - `resource-type` sólo admite una lista cerrada de valores.

RESOURCE_TYPES = {
    'script': 'script', 'image': 'image', 'stylesheet': 'style-sheet',
    'font': 'font', 'media': 'media', 'popup': 'popup',
    'document': 'document', 'subdocument': 'document',
    'xmlhttprequest': 'fetch', 'websocket': 'websocket', 'ping': 'ping',
}

def convert(line):
    line = line.strip()
    if not line or line.startswith('!') or line.startswith('['):
        return None
    # Reglas cosméticas: la sintaxis de selectores de EasyList no se traduce
    # en general a css-display-none. Fuera.
    if '##' in line or '#@#' in line or '#?#' in line or '#$#' in line:
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
            elif option in RESOURCE_TYPES:
                options.setdefault('types', []).append(option)
            elif option in ('match-case', 'all', 'other'):
                pass
            else:
                # Cualquier opción que no se sepa traducir tumba la regla:
                # traducirla a medias cambiaría lo que hace.
                return None

    if not line:
        return None
    # Expresiones regulares en crudo: no se intentan.
    if line.startswith('/') and line.endswith('/'):
        return None
    # WebKit exige ASCII. Las reglas con dominios internacionales se van.
    if not line.isascii():
        return None

    anchored_domain = line.startswith('||')
    if anchored_domain:
        line = line[2:]
    line = line.lstrip('|').rstrip('|')
    if not line:
        return None

    pattern = re.escape(line)
    pattern = pattern.replace(r'\*', '.*').replace(r'\^', r'[/:?=&]')
    if anchored_domain:
        pattern = r'^https?://([^/]+\.)?' + pattern

    if not pattern.isascii():
        return None

    trigger = {'url-filter': pattern}

    if 'types' in options:
        kinds = sorted({RESOURCE_TYPES[t] for t in options['types']})
        if kinds:
            trigger['resource-type'] = kinds

    if options.get('third-party') == 'third-party':
        trigger['load-type'] = ['third-party']
    elif options.get('third-party') == '~third-party':
        trigger['load-type'] = ['first-party']

    if 'domain' in options:
        included, excluded = [], []
        for domain in options['domain'].split('|'):
            domain = domain.strip().lower()
            if not domain or not domain.isascii():
                continue
            if domain.startswith('~'):
                excluded.append('*' + domain[1:])
            else:
                included.append('*' + domain)
        # **Nunca los dos a la vez**: WebKit rechaza la lista entera si un
        # trigger lleva `if-domain` y `unless-domain` juntos.
        if included:
            trigger['if-domain'] = included
        elif excluded:
            trigger['unless-domain'] = excluded

    action = {'type': 'ignore-previous-rules'} if exception else {'type': 'block'}
    return {'trigger': trigger, 'action': action}

# Cada fuente va en sus propios ficheros, `blocklist-<fuente>-NN.json`, para
# que en Ajustes se pueda apagar una sin la otra: quitar los rastreadores y
# dejar los anuncios, o al revés. El manifiesto dice cuántas reglas lleva cada
# una, que contarlas en la app obligaría a leer megas de JSON al arrancar.
manifest, total = {}, 0
for source in sources:
    name = os.path.splitext(os.path.basename(source))[0]
    rules, seen = [], set()
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

    # Las excepciones tienen que ir después de los bloqueos: WebKit aplica
    # las reglas en orden y `ignore-previous-rules` sólo anula lo anterior.
    rules.sort(key=lambda r: r['action']['type'] == 'ignore-previous-rules')

    for index in range(0, len(rules), CHUNK):
        chunk = rules[index:index + CHUNK]
        path = f"{dest}/blocklist-{name}-{index // CHUNK:02d}.json"
        with open(path, 'w', encoding='utf-8') as handle:
            json.dump(chunk, handle, separators=(',', ':'))
        print(f"    {path}: {len(chunk)} reglas")

    manifest[name] = len(rules)
    total += len(rules)

with open(f"{dest}/manifest-blocklists.json", 'w', encoding='utf-8') as handle:
    json.dump(manifest, handle)

print(f"==> {total} reglas en total")
PY

echo
echo "Recuerda recompilar para que entren en el bundle."
