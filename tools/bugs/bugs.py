#!/usr/bin/env python3
"""The bug register from the command line (contract/bug-pipeline-2026-10-18.md). Talks to the `bugs` edge function
with the runner secret from the macOS Keychain (service "table1-bug-runner"). Python 3.9, stdlib only.

  bugs.py status                          open bugs by severity, what's being fixed, what needs John, builds due
  bugs.py list [STATUS ...]               the register (default: everything not closed or fully shipped)
  bugs.py get ID                          one bug as JSON, with its latest sample (exception, frames, breadcrumbs)
  bugs.py next [S1|S2|S3|S4]              claim the most severe open bug at or above that (default S4 = any)
  bugs.py fixed ID COMMIT --summary S --test T [--platforms ios,web]
                                          record a merged fix; platforms default to what COMMIT's changes touch
  bugs.py release|needs-john|wontfix ID NOTES
  bugs.py duplicate ID OF
  bugs.py set ID [--severity S2] [--status open|wontfix|needs_john] [--notes N]
  bugs.py file TITLE --platform P [--detail JSON]      file one by hand (from a session or a report)
  bugs.py shipped PLATFORM [VERSION] [--commit SHA]    a build/deploy went out; only fixes SHA contains count
  bugs.py platforms COMMIT                which platforms a commit's changes ship on
  bugs.py init-secret                     make the runner secret (Keychain) and print the SQL that registers its hash
  bugs.py setup-sentry                    store the Sentry integration's client secret (asks for it, never echoes)
"""
import getpass
import hashlib
import json
import os
import secrets
import subprocess
import sys
import urllib.error
import urllib.request

URL = os.environ.get("T1_BUGS_URL", "https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/bugs")
KEYCHAIN = "table1-bug-runner"
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Path prefix → where a change ships. The rules engine lives in both the edge function and web.
SHIPS_ON = [
    ("apps/ios/", "ios"),
    ("apps/android/", "android"),
    ("table-1-events-web/", "web"),
    ("supabase/migrations/", "server"),
    ("supabase/functions/", "server"),
]


def secret():
    s = os.environ.get("T1_BUG_RUNNER_SECRET")
    if s:
        return s
    try:
        return subprocess.check_output(["security", "find-generic-password", "-s", KEYCHAIN, "-w"],
                                       stderr=subprocess.DEVNULL, text=True).strip()
    except subprocess.CalledProcessError:
        sys.exit("No runner secret: run `tools/bugs/bugs.py init-secret` first.")


def call(action, **body):
    body["action"] = action
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "x-t1-runner": secret()})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        sys.exit("bugs %s failed: HTTP %s %s" % (action, e.code, e.read().decode(errors="replace")[:500]))


def platforms_of(commit):
    files = subprocess.check_output(["git", "-C", REPO, "diff-tree", "--no-commit-id", "--name-only", "-r", "-m", commit],
                                    text=True).split()
    if not files:  # a merge commit: what it brought in over its first parent
        files = subprocess.check_output(["git", "-C", REPO, "diff", "--name-only", commit + "^1", commit], text=True).split()
    out = set()
    for f in files:
        for prefix, platform in SHIPS_ON:
            if f.startswith(prefix):
                out.add(platform)
        if f.startswith("supabase/functions/events-engine/"):
            out.add("web")  # the web copy must match (engine parity)
    return sorted(out)


def is_ancestor(commit, of):
    return subprocess.call(["git", "-C", REPO, "merge-base", "--is-ancestor", commit, of],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def opt(args, name, default=None):
    if name in args:
        i = args.index(name)
        v = args[i + 1]
        del args[i:i + 2]
        return v
    return default


def show(x):
    print(json.dumps(x, indent=2, ensure_ascii=False))


def print_status(s):
    o = s.get("open") or {}
    print("Open:", ", ".join("%s %s" % (k, o[k]) for k in sorted(o)) or "none")
    for b in s.get("fixing") or []:
        print("Fixing: #%s %s %s (%s)" % (b["id"], b["severity"], b["title"], b["claimed_by"]))
    for b in s.get("needs_john") or []:
        print("Needs John: #%s %s %s: %s" % (b["id"], b["severity"], b["title"], (b.get("notes") or "").splitlines()[-1:]))
    for p in s.get("pending") or []:
        print("%s %s: %s unshipped fix(es), worst %s, ids %s" % (
            "BUILD DUE" if p["due"] else "Waiting", p["platform"], p["fixes"], p["worst"], p["ids"]))


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    cmd, args = argv[0], argv[1:]
    as_json = "--json" in args
    if as_json:
        args.remove("--json")
    if cmd == "status":
        s = call("status")
        show(s) if as_json else print_status(s)
    elif cmd == "list":
        show(call("list", status=args or None, limit=200))
    elif cmd == "get":
        show(call("get", id=int(args[0])))
    elif cmd == "next":
        show(call("next", max=args[0] if args else "S4", runner=os.environ.get("T1_RUNNER_NAME", "runner@" + os.uname()[1])))
    elif cmd == "fixed":
        summary, test, plats = opt(args, "--summary", ""), opt(args, "--test", ""), opt(args, "--platforms")
        bug_id, commit = int(args[0]), args[1]
        commit = subprocess.check_output(["git", "-C", REPO, "rev-parse", commit], text=True).strip()
        if not is_ancestor(commit, "main"):
            sys.exit("%s is not on main yet: merge first, then record the fix." % commit[:10])
        platforms = plats.split(",") if plats else platforms_of(commit)
        if not platforms:
            sys.exit("That commit changes nothing that ships (no app, web or server files). Pass --platforms if it does.")
        show(call("done", id=bug_id, outcome="fixed", commit=commit, summary=summary, test=test, platforms=platforms))
    elif cmd in ("release", "needs-john", "wontfix"):
        show(call("done", id=int(args[0]), outcome=cmd.replace("-", "_"), notes=" ".join(args[1:])))
    elif cmd == "duplicate":
        show(call("done", id=int(args[0]), outcome="duplicate", of=int(args[1])))
    elif cmd == "set":
        changes = {k: v for k, v in (("severity", opt(args, "--severity")), ("status", opt(args, "--status")),
                                     ("notes", opt(args, "--notes"))) if v}
        show(call("set", id=int(args[0]), **changes))
    elif cmd == "file":
        platform, detail = opt(args, "--platform", "unknown"), opt(args, "--detail")
        title = " ".join(args)
        report = {"fingerprint": "manual:" + hashlib.sha1(title.lower().encode()).hexdigest()[:12], "title": title,
                  "platform": platform, "level": "error", "environment": "production"}
        if detail:
            report["detail"] = json.loads(detail)
        show(call("file", report=report))
    elif cmd == "shipped":
        commit = opt(args, "--commit")
        platform, version = args[0], (args[1] if len(args) > 1 else None)
        ids = None
        if commit:
            pending = [b for b in call("list", status=["fixed"], limit=500)
                       if platform in (b.get("fix_platforms") or []) and platform not in (b.get("shipped") or [])]
            ids = [b["id"] for b in pending if b.get("fix_commit") and is_ancestor(b["fix_commit"], commit)]
        show(call("shipped", platform=platform, version=version, ids=ids))
    elif cmd == "platforms":
        print(",".join(platforms_of(args[0])))
    elif cmd == "init-secret":
        s = secrets.token_urlsafe(32)
        subprocess.check_call(["security", "add-generic-password", "-U", "-s", KEYCHAIN, "-a", "table1", "-w", s])
        print("Stored in the Keychain as %r. Register it on the server (once) with:" % KEYCHAIN)
        print("insert into t1_private.settings (name, value) values ('bug_runner_secret_sha256', '%s') "
              "on conflict (name) do update set value = excluded.value;" % hashlib.sha256(s.encode()).hexdigest())
    elif cmd == "setup-sentry":
        s = getpass.getpass("Sentry integration client secret: ").strip()
        show(call("setup-sentry", secret=s))
    else:
        sys.exit("Unknown command %r. bugs.py --help" % cmd)


if __name__ == "__main__":
    main(sys.argv[1:])
