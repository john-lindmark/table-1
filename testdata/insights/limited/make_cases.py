# Fixtures and expected sums for limited-sync's parser (parse.test.ts): 300 FRA Premier Draft games and 300 picks
# from 17Lands' public data (CC BY 4.0, https://www.17lands.com/public_datasets), the picks written as two gzip
# members like 17Lands' own draft files, both with small deflate blocks so the tests can read them in small slices. Reference sums are computed here with the csv module.
#   python3 -I testdata/insights/limited/make_cases.py <game csv slice> <draft csv slice>
import csv, gzip, io, json, sys, zlib
from datetime import datetime, timezone
here = 'testdata/insights/limited'
RELEASED = datetime(2026, 10, 2, tzinfo=timezone.utc)

def head(path, n):
    r = csv.reader(open(path, newline=''))
    h = next(r); rows = []
    for x in r:
        if len(x) != len(h): break
        rows.append(x)
        if len(rows) == n: break
    return h, rows

def gz(data, every=2000):
    """One gzip member with a deflate block boundary every `every` input bytes, so tests can slice it small."""
    c = zlib.compressobj(6, zlib.DEFLATED, 31)
    out = b''.join(c.compress(data[i:i + every]) + c.flush(zlib.Z_FULL_FLUSH) for i in range(0, len(data), every))
    return out + c.flush()

def to_csv(h, rows):
    buf = io.StringIO(); w = csv.writer(buf, lineterminator='\n'); w.writerow(h); w.writerows(rows); return buf.getvalue().encode()

gh, grows = head(sys.argv[1], 300)
open(f'{here}/game.csv.gz', 'wb').write(gz(to_csv(gh, grows)))
dh, drows = head(sys.argv[2], 300)
body = to_csv(dh, drows)
cut = body.index(b'\n', len(body) // 2) + 1
open(f'{here}/draft.csv.gz', 'wb').write(gz(body[:cut]) + gz(body[cut:]))

ix = {c: i for i, c in enumerate(gh)}
def top(x, h=ix): return float(x[h['user_game_win_rate_bucket']]) >= 0.6 and float(x[h['user_n_games_bucket']]) >= 50
exp = {}
def add(k, won, w=None):
    g, ww = exp.get(k, (0, 0)); exp[k] = (g + 1, ww + (w if w is not None else (1 if won else 0)))
cards = sorted({c[len('deck_'):] for c in gh if c.startswith('deck_')})
watch = cards[:40]
for x in grows:
    won = x[ix['won']] == 'True'
    mc = x[ix['main_colors']]; pair = '3C' if len(mc) >= 3 else (mc or 'C')
    t = datetime.strptime(x[ix['game_time']], '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc)
    week = max(1, (t - RELEASED).days // 7 + 1) if t >= RELEASED else 1
    for g in (['a', 't'] if top(x) else ['a']):
        add(f'T|{g}', won); add(f"{'P' if x[ix['on_play']] == 'True' else 'D'}|{g}", won)
        add(f'p|{pair}|{g}', won); add(f'pw|{pair}|{week}|{g}', won)
        add(f"dc|{mc or 'C'}|{x[ix['splash_colors']]}|{g}", won)
        for c in watch:
            deck = int(x[ix['deck_' + c]]); oh = int(x[ix['opening_hand_' + c]]); dr = int(x[ix['drawn_' + c]]); tu = int(x[ix['tutored_' + c]])
            if not deck: continue
            add(f'cd|{c}|{g}', won)
            if oh or dr: add(f'ch|{c}|{g}', won)
            if not (oh or dr or tu): add(f'cn|{c}|{g}', won)
dix = {c: i for i, c in enumerate(dh)}
for x in drows:
    for g in (['a', 't'] if top(x, dix) else ['a']):
        add(f"a|{x[dix['pick']]}|{g}", False, int(x[dix['pick_number']]) + 1)
json.dump({'released': '2026-10-02', 'game_rows': len(grows), 'draft_rows': len(drows), 'cards': len(cards),
           'expect': {k: list(v) for k, v in sorted(exp.items())}}, open(f'{here}/cases.json', 'w'), indent=0)
print(len(exp), 'expected sums')
