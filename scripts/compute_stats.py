#!/usr/bin/env python3
"""Local mirror of the GitHub Actions compute step.

Counts every commit (across all branches, deduped by SHA), all PRs (any state),
and per-contributor totals with alias merging.

Requires: gh CLI authenticated (no jq dependency).

Run:
    python scripts/compute_stats.py
"""

from __future__ import annotations

import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ORG = "BurkimbIA"
ROOT = Path(__file__).resolve().parent.parent
META_PATH = ROOT / ".github" / "workflows" / "metadata.json"
OUT_PATH = ROOT / "metrics_renders" / "org-stats.json"


def gh_api(path: str, paginate: bool = True) -> list[dict]:
    cmd = ["gh", "api"]
    if paginate:
        cmd.append("--paginate")
    cmd.append(path)
    res = subprocess.run(
        cmd,
        capture_output=True,
        check=False,
        encoding="utf-8",
        errors="replace",
    )
    if res.returncode != 0 or res.stdout is None:
        return []
    out = res.stdout.strip()
    if not out:
        return []
    if paginate:
        items: list = []
        for chunk in out.replace("][", "]\n[").splitlines():
            chunk = chunk.strip()
            if not chunk:
                continue
            try:
                data = json.loads(chunk)
            except json.JSONDecodeError:
                continue
            if isinstance(data, list):
                items.extend(data)
            else:
                items.append(data)
        return items
    return json.loads(out)


def main() -> None:
    meta = json.loads(META_PATH.read_text())
    contributors: list[str] = meta["contributors"]
    aliases: dict[str, list[str]] = meta.get("aliases", {})

    # login -> canonical contributor key
    login_to_key: dict[str, str] = {}
    for c in contributors:
        login_to_key[c] = c
        for a in aliases.get(c, []):
            login_to_key[a] = c

    public_repos = 0
    private_repos = 0
    total_commits = 0
    total_prs = 0
    contrib_counts: dict[str, int] = {c: 0 for c in contributors}

    repos = gh_api(f"/orgs/{ORG}/repos?per_page=100")
    print(f"Found {len(repos)} repositories in {ORG}")

    for r in repos:
        name = r["name"]
        is_priv = r.get("private", False)
        if is_priv:
            private_repos += 1
        else:
            public_repos += 1

        print(f"\n[{name}] private={is_priv}")
        seen_sha: dict[str, str] = {}  # sha -> author login
        branches = gh_api(f"/repos/{ORG}/{name}/branches?per_page=100")
        for b in branches:
            br = b["name"]
            commits = gh_api(f"/repos/{ORG}/{name}/commits?sha={br}&per_page=100")
            for c in commits:
                sha = c["sha"]
                if sha in seen_sha:
                    continue
                author = (c.get("author") or {}).get("login") or ""
                seen_sha[sha] = author

        repo_commit_count = len(seen_sha)
        total_commits += repo_commit_count
        print(f"  unique commits across all branches: {repo_commit_count}")

        for sha, author in seen_sha.items():
            key = login_to_key.get(author)
            if key is not None:
                contrib_counts[key] += 1

        prs = gh_api(f"/repos/{ORG}/{name}/pulls?state=all&per_page=100")
        total_prs += len(prs)
        print(f"  PRs (all states): {len(prs)}")

    total_contributors = len(contributors)
    commits_per_contributor = total_commits // total_contributors if total_contributors else 0

    payload = {
        "organization": ORG,
        "public_repositories": public_repos,
        "private_repositories": private_repos,
        "total_repositories": public_repos + private_repos,
        "total_commits": total_commits,
        "total_pull_requests": total_prs,
        "total_contributors": total_contributors,
        "commits_per_contributor": commits_per_contributor,
        "contributor_commits": contrib_counts,
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(payload, indent=2) + "\n")
    print("\n--- org-stats.json ---")
    print(OUT_PATH.read_text())


if __name__ == "__main__":
    main()
