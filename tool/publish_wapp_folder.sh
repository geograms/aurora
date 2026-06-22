#!/usr/bin/env bash
# =============================================================================
# publish_wapp_folder.sh — publish the wapp store into a signed Reticulum
# folder, on the always-on publisher node.
#
# The Aurora wapp store can be shared peer-to-peer the same way updates are: the
# publisher owns a signed mutable folder holding the .wapp packages plus an
# index.json catalog. Consumers browse the folder by its npub (signature-
# verified), fetch each .wapp by sha256 over Reticulum, and re-seed it. No web
# host. This script (re)builds index.json from the .wapp files in the watched
# dir and asks the local node to rescan so it signs the changes and serves them.
#
# One-time setup on the always-on node (creates the .folder.json master key —
# back it up, never commit it; the returned folderId is the npub to share):
#   curl -s -XPOST $API/api/rns/folder/adddisk -d '{"path":"/srv/aurora-wapps"}'
# Share that npub; users paste it into Settings -> Sharing folders -> Wapp store
# folder (or it can be set as PreferencesService.wappStoreSource).
#
# Usage:
#   publish_wapp_folder.sh <wapp-dir>
#     <wapp-dir>  the watched dir holding aurora's *.wapp packages
#
# Filenames must be  <id>-<version>.wapp  (e.g. maps-2.1.0.wapp). Descriptions
# are read from each package's manifest.json when `unzip` is available.
#
# Env (with defaults):
#   AURORA_API=http://127.0.0.1:3456     (the always-on node's JSON API)
# =============================================================================
set -euo pipefail

DIR="${1:-}"
if [[ -z "$DIR" || ! -d "$DIR" ]]; then
  echo "usage: publish_wapp_folder.sh <wapp-dir>" >&2
  exit 2
fi
API="${AURORA_API:-http://127.0.0.1:3456}"

shopt -s nullglob
wapps=("$DIR"/*.wapp)
shopt -u nullglob
if [[ "${#wapps[@]}" -eq 0 ]]; then
  echo "error: no .wapp files in $DIR" >&2
  exit 1
fi

index="$DIR/index.json"

# Build the catalog with python3 (reads each .wapp as a zip — no `unzip`
# dependency). Each entry mirrors exactly what the Wapp Store consumes:
#   file, id, version, size, title, description, kind, icon
# `icon` is the wapp's authored SVG inlined from its manifest's `icon` path, so
# the store shows the real icon BEFORE the wapp is installed. Descriptions are
# scrubbed to ASCII (em/en dashes -> '-', smart quotes -> ASCII): the host
# pushes catalog text byte-truncated into the wasm sandbox, so a non-ASCII char
# would arrive mangled (e.g. U+2014 -> 0x14). Keep catalog text ASCII.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$DIR" "$index" <<'PY'
import sys, os, json, re, zipfile
DIR, INDEX = sys.argv[1], sys.argv[2]

def ascii_fix(s):
    return (s.replace('—','-').replace('–','-')
             .replace('…','...').replace('·','-')
             .replace('‘',"'").replace('’',"'")
             .replace('“','"').replace('”','"'))

out = []
for base in sorted(os.listdir(DIR)):
    if not base.endswith('.wapp'):
        continue
    path = os.path.join(DIR, base)
    stem = base[:-5]
    m = re.match(r'^(.+)-(\d+\.\d+(?:\.\d+)?(?:[-.][0-9A-Za-z.]+)?)$', stem)
    fid, ver = (m.group(1), m.group(2)) if m else (stem, '1.0.0')
    title, desc, kind, icon_svg = fid, fid, 'app', None
    try:
        with zipfile.ZipFile(path) as z:
            man = json.loads(z.read('manifest.json').decode('utf-8'))
            fid = man.get('id', fid)
            ver = man.get('version', ver)
            title = man.get('title', title)
            desc = man.get('description', desc)
            kind = man.get('kind', kind)
            ip = man.get('icon', '')
            if ip and ip.lower().endswith('.svg'):
                try:
                    icon_svg = z.read(ip).decode('utf-8').strip()
                except KeyError:
                    icon_svg = None
    except Exception as e:
        sys.stderr.write('   ! %s: %s\n' % (base, e))
    entry = {
        'file': base, 'id': fid, 'version': ver,
        'size': os.path.getsize(path),
        'title': title, 'description': ascii_fix(desc), 'kind': kind,
    }
    if icon_svg:
        entry['icon'] = icon_svg
    out.append(entry)
    sys.stderr.write('   + %s  (id=%s v=%s%s)\n'
                     % (base, fid, ver, '' if icon_svg else ' NO-ICON'))

open(INDEX, 'w', encoding='utf-8').write(json.dumps(out, indent=2, ensure_ascii=True))
sys.stderr.write('>> %d wapp(s)\n' % len(out))
PY
else
  echo "error: python3 is required to build the catalog" >&2
  exit 1
fi

echo ">> wrote catalog: $index (${#wapps[@]} wapp(s))"

echo ">> rescanning owned folders via $API"
if command -v curl >/dev/null 2>&1; then
  curl -fsS -X POST "$API/api/rns/folder/rescan" \
    -H 'Content-Type: application/json' -d '{}' \
    && echo "" && echo ">> done — wapp store is live on Reticulum." \
    || { echo "error: rescan failed (is the node running on $API?)" >&2; exit 1; }
else
  echo "warn: curl not found — trigger the rescan yourself:" >&2
  echo "  POST $API/api/rns/folder/rescan  {}" >&2
fi
