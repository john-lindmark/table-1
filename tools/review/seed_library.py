# Seeds the review account's Library from the iOS demo fixture (run by tools/review/seed.sh). Idempotent: one
# collection batch key and fixed list ids, so a rerun changes nothing.
import json, os, sys, uuid, urllib.request
url, key, tok, fixture = os.environ["URL"], os.environ["KEY"], os.environ["TOK"], sys.argv[1]
def rpc(name, body):
    req = urllib.request.Request(f"{url}/rest/v1/rpc/{name}", data=json.dumps(body).encode(), method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r: return json.load(r)
    except urllib.error.HTTPError as e: sys.exit(f"{name}: {e.code} {e.read().decode()[:300]}")
d = json.load(open(fixture))
ops = [{"card_id": c, "finish": f, "condition": cond, "lang": lang, "delta": q} for c, f, cond, lang, q in d["items"][:400]]
res = rpc("collection_apply", {"p_ops": ops, "p_source": "import", "p_source_id": None, "p_idempotency_key": str(uuid.uuid5(uuid.NAMESPACE_URL, "t1-review-collection"))})
print("collection", res.get("summary") or res)
for l in d["lists"]:
    if l["kind"] == "deck" and l["name"] not in ("Boros Energy", "Izzet Murktide"): continue
    lid = str(uuid.uuid5(uuid.NAMESPACE_URL, "t1-review-" + l["id"]))
    out = rpc("list_create", {"p_id": lid, "p_kind": l["kind"], "p_name": l["name"], "p_format": l["format"], "p_entries": l["entries"]})
    print(l["kind"], l["name"], "saved")
