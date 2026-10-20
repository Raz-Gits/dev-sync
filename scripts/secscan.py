#!/usr/bin/env python3
"""secscan - daily secret and security-posture sweep for this machine.

    python3 secscan.py                          scan, write the vault report, exit 1 on anything new
    python3 secscan.py --full                   rescan all history and every loose file, not just what's new
    python3 secscan.py accept <ID> <reason>     mark one finding as reviewed (from the report's ID column)
    python3 secscan.py accept-path <repo> <glob> [<rule>] <reason>
                                                mark every finding under a path as reviewed
    python3 secscan.py approve-plugin <id>      allow an Obsidian community plugin

What it checks:
  - every git repo under $HOME: new commits on every branch, plus uncommitted
    and untracked files (the ones a /handoff `git add -A` would commit next)
  - loose files in Downloads / Desktop / Documents that hold credentials
  - GitHub: repo visibility, open Dependabot alerts, secret-scanning alerts
  - the Obsidian vault: secret hook on, only approved community plugins

Nothing secret is ever printed or stored: gitleaks runs with --redact and only
rule, file, line and commit are kept. Findings you've reviewed go in the
vault's Security/baseline.txt, which syncs to every machine, so only new
problems alert. Python 3.8+, stdlib only; works under Git Bash on Windows.
"""
import fnmatch
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

HOME = Path.home()
VAULT = Path(os.environ.get("DEVSYNC_VAULT", str(HOME / "Main Brain")))
SEC_DIR = VAULT / "Security"
BASELINE = SEC_DIR / "baseline.txt"
APPROVED_PLUGINS = SEC_DIR / "approved-plugins.txt"
DEVSYNC_HOME = Path(__file__).resolve().parent.parent
STATE_FILE = Path(os.environ.get("DEVSYNC_SECSCAN_STATE",
                                 str(HOME / ".local" / "state" / "devsync" / "secscan.json")))

PRUNE = {"node_modules", ".venv", "venv", "Library", ".Trash", "vendor", ".cache", ".codex",
         ".cursor", ".claude", "AppData", ".npm", ".npm-global", ".local", "graphify-out",
         "dist", "build", ".next", "__pycache__", ".git", "Applications", "VirtualBox VMs"}
LOOSE_DIRS = [HOME / d for d in ("Downloads", "Desktop", "Documents")]
LOOSE_DEPTH = 3
TEXT_EXT = {".txt", ".csv", ".tsv", ".json", ".env", ".md", ".yaml", ".yml", ".ini", ".cfg",
            ".conf", ".toml", ".xml", ".sh", ".ps1", ".bat", ".py", ".js", ".ts", ".pem", ".key"}
CRED_NAME = re.compile(r"(passw|credential|secret|api[_-]?key|token|smtp|private[_-]?key|"
                       r"id_rsa|id_ed25519|\.pem$|\.p12$|\.pfx$|\.key$|keys\.txt$|\.env$)", re.I)
MAX_BYTES = 5 * 1024 * 1024
GITHUB_EVERY = timedelta(hours=20)


# ------------------------------------------------------------------ helpers

def machine_name():
    if os.environ.get("DEVSYNC_MACHINE"):
        return os.environ["DEVSYNC_MACHINE"]
    return re.sub(r"[^a-z0-9]", "-", socket.gethostname().lower())[:24]


def run(cmd, cwd=None, timeout=900):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 99, "", str(e)


def short_id(fingerprint):
    return hashlib.sha1(fingerprint.encode()).hexdigest()[:8]


def load_json(path, default):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def save_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def ignored_repo(rel):
    """monitor-ignore(.local).txt `repo:` rules apply here too."""
    for f in (DEVSYNC_HOME / "monitor-ignore.txt", DEVSYNC_HOME / "monitor-ignore.local.txt"):
        try:
            lines = f.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            if line.startswith("repo:") and line[5:].strip() and line[5:].strip() in rel:
                return True
    return False


def repo_slug(repo):
    code, out, _ = run(["git", "remote", "get-url", "origin"], cwd=repo)
    if code != 0:
        return None
    m = re.search(r"github\.com[:/](.+?)(?:\.git)?/?$", out.strip())
    return m.group(1) if m else None


# ----------------------------------------------------------------- baseline

def load_baseline():
    """Lines: `fp:<ID>  # reason`  or  `path:<repo>:<glob>[:<rule>]  # reason`."""
    ids, paths = set(), []
    try:
        lines = BASELINE.read_text(encoding="utf-8").splitlines()
    except OSError:
        return ids, paths
    for line in lines:
        entry = line.split("#", 1)[0].strip()
        if entry.startswith("fp:"):
            ids.add(entry[3:].strip())
        elif entry.startswith("path:"):
            parts = entry[5:].split(":")
            if len(parts) >= 2:
                paths.append((parts[0], parts[1], parts[2] if len(parts) > 2 else None))
    return ids, paths


def is_accepted(f, ids, paths):
    if f["id"] in ids:
        return True
    for repo, glob, rule in paths:
        if repo in (f["repo"], "*") and fnmatch.fnmatch(f["file"], glob) and rule in (None, "", f["rule"]):
            return True
    return False


def append_baseline(line):
    SEC_DIR.mkdir(parents=True, exist_ok=True)
    if not BASELINE.exists():
        BASELINE.write_text(
            "# Reviewed secscan findings. Synced by the vault, so every machine agrees.\n"
            "# fp:<ID>  # reason                      one finding (ID from the report)\n"
            "# path:<repo>:<glob>[:<rule>]  # reason  everything under a path\n", encoding="utf-8")
    with open(BASELINE, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(line.rstrip() + "\n")


# ------------------------------------------------------------------ gitleaks

def gitleaks(args, cwd=None):
    """Run gitleaks with a JSON report; return its findings (values redacted)."""
    with tempfile.TemporaryDirectory() as td:
        rp = os.path.join(td, "r.json")
        code, _, err = run(["gitleaks"] + args + ["--redact=100", "--no-banner", "--log-level", "error",
                                                  "--exit-code", "0", "--report-format", "json",
                                                  "--report-path", rp], cwd=cwd)
        if code != 0:
            raise RuntimeError(err.strip()[:300] or "gitleaks failed")
        return load_json(rp, [])


def find_repos():
    repos = []
    for root, dirs, _ in os.walk(HOME):
        if ".git" in dirs or os.path.isfile(os.path.join(root, ".git")):
            if os.path.isdir(os.path.join(root, ".git")):   # worktrees are covered by --all
                repos.append(Path(root))
        dirs[:] = [d for d in dirs if d not in PRUNE and not d.startswith(".Trash")]
    return repos


def scan_repo(repo, state, full):
    rel = str(repo.relative_to(HOME)) if repo != HOME else "~"
    key = repo_slug(repo) or rel
    rs = state.setdefault("repos", {}).setdefault(key, {})
    findings = []

    # 1. History: only commits not reachable from the tips we scanned last time.
    code, out, _ = run(["git", "for-each-ref", "--format=%(objectname)"], cwd=repo)
    tips = sorted(set(out.split())) if code == 0 else []
    old = [] if full else [t for t in rs.get("tips", [])
                           if run(["git", "cat-file", "-e", t], cwd=repo)[0] == 0]
    log_opts = "--all" + "".join(" ^" + t for t in old)
    for g in gitleaks(["git", ".", "--log-opts=" + log_opts], cwd=repo):
        fp = "hist:%s:%s:%s:%s" % (key, g.get("Commit", ""), g.get("File", ""), g.get("RuleID", ""))
        findings.append({"id": short_id(fp), "kind": "history", "repo": key, "file": g.get("File", ""),
                         "line": g.get("StartLine"), "rule": g.get("RuleID", ""),
                         "commit": (g.get("Commit") or "")[:7], "date": (g.get("Date") or "")[:10]})
    rs["tips"] = tips

    # 2. Uncommitted and untracked files: what the next `git add -A` would publish.
    _, untracked, _ = run(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=repo)
    _, modified, _ = run(["git", "ls-files", "--modified", "-z"], cwd=repo)
    pending = sorted({p for p in (untracked + modified).split("\0") if p})
    with tempfile.TemporaryDirectory() as td:
        n = 0
        for p in pending:
            src = repo / p
            try:
                if not src.is_file() or src.stat().st_size > MAX_BYTES:
                    continue
            except OSError:
                continue
            dst = Path(td) / p
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            n += 1
        if n:
            args = ["dir", td]
            if (repo / ".gitleaks.toml").is_file():
                args += ["--config", str(repo / ".gitleaks.toml")]
            for g in gitleaks(args):
                f = os.path.relpath(g.get("File", ""), td).replace(os.sep, "/")
                fp = "pending:%s:%s:%s" % (key, f, g.get("RuleID", ""))
                findings.append({"id": short_id(fp), "kind": "uncommitted", "repo": key, "file": f,
                                 "line": g.get("StartLine"), "rule": g.get("RuleID", ""),
                                 "commit": "", "date": ""})
    # History findings persist (they don't go away by being scanned once).
    known = {f["id"]: f for f in rs.get("history", [])}
    for f in findings:
        if f["kind"] == "history":
            known[f["id"]] = f
    if full:
        known = {f["id"]: f for f in findings if f["kind"] == "history"}
    rs["history"] = list(known.values())
    return key, rs["history"] + [f for f in findings if f["kind"] == "uncommitted"]


def scan_loose(state, full):
    ls = state.setdefault("loose", {})
    last = 0 if full else ls.get("_last_scan", 0)
    prev = ls.setdefault("files", {})
    # Forget files that were deleted or moved.
    for p in list(prev):
        if not Path(p).exists():
            del prev[p]
    cands = []
    for base in LOOSE_DIRS:
        if not base.is_dir():
            continue
        base_depth = len(base.parts)
        for root, dirs, files in os.walk(base):
            if len(Path(root).parts) - base_depth >= LOOSE_DEPTH or os.path.isdir(os.path.join(root, ".git")):
                dirs[:] = []
                if os.path.isdir(os.path.join(root, ".git")):
                    continue
            dirs[:] = [d for d in dirs if d not in PRUNE and not d.startswith(".")]
            for name in files:
                p = Path(root) / name
                try:
                    st = p.stat()
                except OSError:
                    continue
                if st.st_size > MAX_BYTES or (st.st_mtime <= last and str(p) in prev):
                    continue
                if st.st_mtime <= last and not full and str(p) not in prev:
                    continue
                if p.suffix.lower() in TEXT_EXT or CRED_NAME.search(name):
                    cands.append(p)
    with tempfile.TemporaryDirectory() as td:
        mapping = {}
        for i, p in enumerate(cands):
            prev[str(p)] = []
            if CRED_NAME.search(p.name):
                prev[str(p)].append("credential-like filename")
            if p.suffix.lower() in TEXT_EXT:
                dst = Path(td) / ("%d%s" % (i, p.suffix.lower()))
                try:
                    shutil.copy2(p, dst)
                    mapping[str(dst)] = str(p)
                except OSError:
                    pass
        if mapping:
            for g in gitleaks(["dir", td]):
                src = mapping.get(g.get("File", ""))
                if src and g.get("RuleID") not in prev[src]:
                    prev[src].append(g.get("RuleID", ""))
    ls["_last_scan"] = datetime.now().timestamp()
    out = []
    for p, rules in sorted(prev.items()):
        if not rules:
            continue
        rel = os.path.relpath(p, HOME).replace(os.sep, "/")
        for rule in rules:
            fp = "loose:%s:%s" % (rel, rule)
            out.append({"id": short_id(fp), "kind": "loose", "repo": "~", "file": rel, "line": None,
                        "rule": rule, "commit": "", "date": ""})
    return out


# -------------------------------------------------------------- GitHub posture

def github_posture(state, slugs, full):
    gs = state.setdefault("github", {})
    last = gs.get("_checked")
    if not full and last and datetime.now() - datetime.fromisoformat(last) < GITHUB_EVERY:
        return gs.get("repos", {}), []
    if not shutil.which("gh") or run(["gh", "auth", "status"])[0] != 0:
        return gs.get("repos", {}), ["gh not installed or not logged in: GitHub checks skipped"]
    code, out, _ = run(["gh", "repo", "list", "--limit", "300", "--json", "nameWithOwner,visibility"])
    vis = {r["nameWithOwner"]: r["visibility"] for r in (json.loads(out) if code == 0 else [])}
    for s in slugs:
        if s not in vis:
            c, o, _ = run(["gh", "api", "repos/" + s, "--jq", ".visibility"])
            if c == 0:
                vis[s] = o.strip().upper()
    old = gs.get("repos", {})
    repos, notes = {}, []
    for s, v in sorted(vis.items()):
        r = {"visibility": v}
        c, o, _ = run(["gh", "api", "-X", "GET", "repos/%s/dependabot/alerts" % s, "-f", "state=open",
                       "-f", "per_page=100", "--paginate", "--jq", ".[].security_advisory.severity"])
        r["dependabot"] = ({sev: o.split().count(sev) for sev in ("critical", "high", "medium", "low")}
                           if c == 0 else None)
        if v == "PUBLIC":
            c, o, _ = run(["gh", "api", "-X", "GET", "repos/%s/secret-scanning/alerts" % s,
                           "-f", "state=open", "--jq", "length"])
            r["secret_scanning"] = int(o.strip() or 0) if c == 0 else None
        was = old.get(s, {})
        if was.get("visibility") == "PRIVATE" and v == "PUBLIC":
            notes.append("%s became PUBLIC since the last check" % s)
        if (r["dependabot"] or {}).get("critical", 0) > ((was.get("dependabot") or {}).get("critical", 0)):
            notes.append("%s has new critical Dependabot alerts" % s)
        if r.get("secret_scanning"):
            notes.append("%s has %d open GitHub secret-scanning alert(s)" % (s, r["secret_scanning"]))
        repos[s] = r
    gs["repos"], gs["_checked"] = repos, datetime.now().isoformat(timespec="seconds")
    return repos, notes


# ------------------------------------------------------------- vault checks

def vault_checks():
    issues = []
    if not (VAULT / ".git").is_dir():
        return ["vault not found at %s" % VAULT]
    code, out, _ = run(["git", "config", "core.hooksPath"], cwd=VAULT)
    if out.strip() != ".githooks":
        issues.append("vault secret hook is off on this machine: run scripts/setup-machine.sh in the vault")
    plugins = load_json(VAULT / ".obsidian" / "community-plugins.json", [])
    try:
        approved = {l.split("#")[0].strip() for l in APPROVED_PLUGINS.read_text(encoding="utf-8").splitlines()}
    except OSError:
        approved = set()
    for pid in plugins:
        if pid not in approved:
            issues.append("unapproved Obsidian community plugin `%s` (plugins run with full access to your "
                          "files). Review it, then: devsync secscan approve-plugin %s" % (pid, pid))
    return issues


# ------------------------------------------------------------------- report

FIX = {
    "history": "Rotate it if it's a real, paid or private key, then accept or scrub history. Free or public-by-design: accept with a reason",
    "uncommitted": "Not committed yet. Move the value to `.env` (sealed by /handoff) or gitignore the file before the next /handoff",
    "loose": "Move it into a password manager and delete the file. Rotate if it was ever shared",
}


def cell(s):
    return str(s).replace("|", "\\|")


def write_report(machine, new, known, posture, notes, vault_issues, errors, trend):
    SEC_DIR.mkdir(parents=True, exist_ok=True)
    public = {s for s, r in posture.items() if r.get("visibility") == "PUBLIC"}
    critical = [f for f in new if f["kind"] == "history" and f["repo"] in public]
    status = "danger" if critical else ("warning" if new or notes or vault_issues else "success")
    headline = ("%d new finding(s) need review" % len(new)) if new else "No new findings"
    if critical:
        headline += ", %d in a PUBLIC repo: rotate those keys now" % len(critical)
    L = ["---", "type: security-report", "machine: %s" % machine,
         "last_run: %s" % datetime.now().strftime("%Y-%m-%d %H:%M"),
         "new_findings: %d" % len(new), "known_findings: %d" % len(known), "tags:", "  - security", "---", "",
         "# Security Report (%s)" % machine, "",
         "> [!%s] %s" % (status, headline),
         "> Written by `devsync secscan` (daily with the devsync monitor, or run it any time). "
         "Secret values are never shown or stored. What to do: [[Security practices]].", ""]

    L += ["## New or unreviewed findings", ""]
    if new:
        L += ["| ID | Repo | Where | What | Kind | Fix |", "|---|---|---|---|---|---|"]
        for f in sorted(new, key=lambda f: (f["repo"] not in public, f["kind"], f["repo"], f["file"])):
            where = "`%s`%s" % (cell(f["file"]), ":%s" % f["line"] if f["line"] else "")
            if f["commit"]:
                where += " (%s, %s)" % (f["commit"], f["date"])
            repo = ("**%s (PUBLIC)**" % f["repo"]) if f["repo"] in public else f["repo"]
            L.append("| `%s` | %s | %s | %s | %s | %s |" % (f["id"], cell(repo), where, cell(f["rule"]),
                                                          f["kind"], FIX[f["kind"]]))
        L += ["", "Reviewed one and it's fine? `devsync secscan accept <ID> \"why\"`. "
              "A whole folder of false positives? `devsync secscan accept-path <repo> '<glob>' \"why\"`.", ""]
    else:
        L += ["Nothing new. 👍", ""]

    if notes or vault_issues or errors:
        L += ["## Alerts", ""] + ["- [ ] %s" % n for n in notes + vault_issues] + \
             ["- ⚠️ scan error: %s" % e for e in errors] + [""]

    if posture:
        L += ["## GitHub", "", "| Repo | Visibility | Dependabot (crit / high / med / low) | Secret scanning |",
              "|---|---|---|---|"]
        for s, r in sorted(posture.items(), key=lambda kv: -((kv[1].get("dependabot") or {}).get("critical", 0) * 100
                                                              + (kv[1].get("dependabot") or {}).get("high", 0))):
            d = r.get("dependabot")
            dep = "off or no access" if d is None else " / ".join(str(d[k]) for k in ("critical", "high", "medium", "low"))
            ss = "" if r.get("visibility") != "PUBLIC" else ("n/a" if r.get("secret_scanning") is None
                                                             else str(r["secret_scanning"]))
            L.append("| %s | %s | %s | %s |" % (s, r.get("visibility", "?").lower(), dep, ss))
        L.append("")

    if known:
        L += ["> [!note]- Reviewed and accepted (%d)" % len(known), ">",
              "> | ID | Repo | Where | What |", "> |---|---|---|---|"]
        for f in sorted(known, key=lambda f: (f["repo"], f["file"])):
            L.append("> | `%s` | %s | `%s` | %s |" % (f["id"], cell(f["repo"]), cell(f["file"]), cell(f["rule"])))
        L.append("")

    L += ["## Trend", "", "| Run | New | Accepted | Dependabot critical | Alerts |", "|---|---|---|---|---|"]
    for t in trend[-14:]:
        L.append("| %s | %d | %d | %d | %d |" % (t["at"], t["new"], t["known"], t["crit"], t["alerts"]))
    L.append("")
    path = SEC_DIR / ("Report - %s.md" % machine)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(L))
    return path, critical


# --------------------------------------------------------------------- main

def cmd_scan(full):
    if not shutil.which("gitleaks"):
        # Exit 3 = skipped: a machine that hasn't caught up yet must not raise a
        # daily false alarm. The monitor logs it without notifying.
        print("secscan: skipped, gitleaks is not installed (re-run ~/dev-sync/install.sh)")
        return 3
    state = load_json(STATE_FILE, {})
    machine = machine_name()
    findings, errors, slugs = [], [], set()
    for repo in find_repos():
        rel = str(repo.relative_to(HOME)).replace(os.sep, "/")
        if ignored_repo(rel):
            continue
        try:
            key, fs = scan_repo(repo, state, full)
            findings += fs
            if "/" in key and not key.startswith("~"):
                slugs.add(key)
        except RuntimeError as e:
            errors.append("%s: %s" % (rel, e))
    try:
        findings += scan_loose(state, full)
    except RuntimeError as e:
        errors.append("loose files: %s" % e)
    posture, notes = github_posture(state, slugs, full)
    vault_issues = vault_checks()

    ids, paths = load_baseline()
    new = [f for f in findings if not is_accepted(f, ids, paths)]
    known = [f for f in findings if is_accepted(f, ids, paths)]
    crit = sum((r.get("dependabot") or {}).get("critical", 0) for r in posture.values())
    trend = state.setdefault("trend", [])
    trend.append({"at": datetime.now().strftime("%Y-%m-%d %H:%M"), "new": len(new), "known": len(known),
                  "crit": crit, "alerts": len(notes) + len(vault_issues)})
    del trend[:-60]
    path, critical = write_report(machine, new, known, posture, notes, vault_issues, errors, trend)
    save_json(STATE_FILE, state)

    problems = len(new) + len(notes) + len(vault_issues)
    print("secscan: %d new finding(s), %d accepted, %d alert(s), %d error(s). Report: %s"
          % (len(new), len(known), len(notes) + len(vault_issues), len(errors), path))
    if critical:
        print("secscan: %d finding(s) in a PUBLIC repo - rotate those keys now" % len(critical))
    if problems:
        print("secscan: %d issue(s) need attention" % problems)
        return 1
    return 0


def main(argv):
    if not argv or argv[0] in ("scan", "--full"):
        return cmd_scan(full="--full" in argv)
    if argv[0] == "accept" and len(argv) >= 3:
        append_baseline("fp:%s  # %s (%s, %s)" % (argv[1], " ".join(argv[2:]), machine_name(),
                                                  datetime.now().strftime("%Y-%m-%d")))
        print("accepted %s - it won't alert again on any machine" % argv[1])
        return 0
    if argv[0] == "accept-path" and len(argv) >= 4:
        repo, glob = argv[1], argv[2]
        rule = argv[3] if len(argv) >= 5 and re.match(r"^[a-z0-9-]+$", argv[3]) else ""
        reason = " ".join(argv[4:] if rule else argv[3:])
        append_baseline("path:%s:%s%s  # %s (%s, %s)" % (repo, glob, ":" + rule if rule else "", reason,
                                                         machine_name(), datetime.now().strftime("%Y-%m-%d")))
        print("accepted everything under %s in %s%s" % (glob, repo, " for " + rule if rule else ""))
        return 0
    if argv[0] == "approve-plugin" and len(argv) == 2:
        SEC_DIR.mkdir(parents=True, exist_ok=True)
        with open(APPROVED_PLUGINS, "a", encoding="utf-8", newline="\n") as fh:
            fh.write("%s  # approved %s on %s\n" % (argv[1], datetime.now().strftime("%Y-%m-%d"), machine_name()))
        print("approved Obsidian plugin %s" % argv[1])
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
