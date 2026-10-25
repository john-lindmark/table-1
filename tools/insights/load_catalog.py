# Scryfall default_cards (jsonl.gz) + /sets → tab-separated files for a local catalog
# (card_oracles, cards, mtg_sets), so the Insights SQL can run on real cards. Used by demo_packs.sh.
#   python3 -I tools/insights/load_catalog.py <default-cards.jsonl.gz> <sets.json> <out dir>
import gzip, json, os, sys

src, sets_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
FORMATS = ('standard', 'pioneer', 'modern', 'pauper', 'legacy', 'vintage', 'premodern')

def esc(v):
    if v is None: return '\\N'
    return str(v).replace('\\', '\\\\').replace('\t', ' ').replace('\n', ' ')
def arr(xs): return '{' + ','.join('"' + x.replace('\\', '\\\\').replace('"', '\\"') + '"' for x in xs) + '}'

oracles, seen_cards = {}, set()
with open(os.path.join(out, 'cards.tsv'), 'w') as cards:
    for line in gzip.open(src, 'rt'):
        line = line.strip().rstrip(',')
        if not line.startswith('{'): continue
        c = json.loads(line)
        if 'paper' not in c.get('games', []) or c.get('layout') in ('token', 'emblem', 'art_series', 'double_faced_token'): continue
        oid = c.get('oracle_id') or (c.get('card_faces') or [{}])[0].get('oracle_id')
        if not oid: continue
        faces = c.get('card_faces') or []
        if oid not in oracles or (c.get('lang') == 'en' and oracles[oid]['lang'] != 'en'):
            oracles[oid] = {
                'name': c['name'], 'faces': [f['name'] for f in faces] if len(faces) > 1 else [],
                'layout': c.get('layout', 'normal'), 'type': c.get('type_line') or (faces[0].get('type_line') if faces else None),
                'cost': c.get('mana_cost') or (faces[0].get('mana_cost') if faces else None), 'cmc': c.get('cmc', 0),
                'colors': c.get('colors') if 'colors' in c else (faces[0].get('colors', []) if faces else []),
                'ci': c.get('color_identity', []),
                'legal': {k: v for k, v in c.get('legalities', {}).items() if k in FORMATS and v in ('legal', 'restricted', 'banned')},
                'src': c['id'], 'lang': c.get('lang'),
            }
        key = (c['set'], c['collector_number'], c.get('lang', 'en'))
        if key in seen_cards: continue
        seen_cards.add(key)
        cards.write('\t'.join(esc(x) for x in [c['id'], oid, c['set'], c['collector_number'], c.get('lang', 'en'), c.get('rarity', 'common'),
                                               arr(c.get('finishes', ['nonfoil'])), c.get('layout', 'normal'), None, c.get('released_at'), None, 1, 'h']) + '\n')

with open(os.path.join(out, 'oracles.tsv'), 'w') as f:
    for oid, o in oracles.items():
        f.write('\t'.join(esc(x) for x in [oid, o['name'], '', arr(o['faces']), o['layout'], o['type'], o['cost'], o['cmc'],
                                           arr(o['colors']), arr(o['ci']), json.dumps(o['legal']), o['src'], 'a', 'h']) + '\n')

with open(os.path.join(out, 'sets.tsv'), 'w') as f:
    for s in json.load(open(sets_path))['data']:
        f.write('\t'.join(esc(x) for x in [s['code'], s['name'], s['set_type'], s.get('released_at'), s.get('icon_svg_uri'), s.get('card_count'),
                                           't' if s.get('digital') else 'f']) + '\n')
print(len(oracles), 'oracles', len(seen_cards), 'printings')
