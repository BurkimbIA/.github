#!/usr/bin/env bash
# Local mirror of the workflow's compute step. Run with gh CLI authenticated.
set -uo pipefail

ORG=${ORG:-BurkimbIA}
META="$(dirname "$0")/../.github/workflows/metadata.json"
OUT_DIR="$(dirname "$0")/../metrics_renders"
mkdir -p "$OUT_DIR"

public_repos=0
private_repos=0
total_commits=0
total_prs=0

mapfile -t contributors_list < <(jq -r '.contributors[]' "$META")
TMP=$(mktemp -d)
for c in "${contributors_list[@]}"; do echo 0 > "$TMP/contrib_${c}.txt"; done

gh api --paginate "/orgs/$ORG/repos?per_page=100" \
  --jq '.[] | {name: .name, private: .private}' > "$TMP/repos.jsonl"

while IFS= read -r line; do
  [ -z "$line" ] && continue
  repo=$(echo "$line" | jq -r '.name')
  is_private=$(echo "$line" | jq -r '.private')

  if [ "$is_private" = "true" ]; then
    private_repos=$((private_repos + 1))
  else
    public_repos=$((public_repos + 1))
  fi

  echo "Processing $repo (private=$is_private)"
  : > "$TMP/repo_commits.tsv"
  mapfile -t branches < <(gh api --paginate "/repos/$ORG/$repo/branches?per_page=100" --jq '.[].name' 2>/dev/null || true)
  for br in "${branches[@]}"; do
    [ -z "$br" ] && continue
    gh api --paginate "/repos/$ORG/$repo/commits?sha=$br&per_page=100" \
      --jq '.[] | [.sha, (.author.login // "")] | @tsv' 2>/dev/null \
      >> "$TMP/repo_commits.tsv" || true
  done

  awk -F'\t' '!seen[$1]++' "$TMP/repo_commits.tsv" > "$TMP/repo_unique.tsv"
  repo_commit_count=$(wc -l < "$TMP/repo_unique.tsv")
  total_commits=$((total_commits + repo_commit_count))
  echo "  unique commits: $repo_commit_count"

  for contributor in "${contributors_list[@]}"; do
    logins_json=$(jq -c --arg c "$contributor" '[$c] + (.aliases[$c] // [])' "$META")
    n=$(awk -F'\t' -v logins="$logins_json" '
      BEGIN {
        gsub(/[\[\]"]/, "", logins);
        split(logins, a, ",");
        for (i in a) m[a[i]] = 1;
        c = 0;
      }
      ($2 in m) { c++ }
      END { print c+0 }
    ' "$TMP/repo_unique.tsv")
    current=$(cat "$TMP/contrib_${contributor}.txt")
    echo $((current + n)) > "$TMP/contrib_${contributor}.txt"
  done

  pr_count=$(gh api --paginate "/repos/$ORG/$repo/pulls?state=all&per_page=100" --jq '.[].number' 2>/dev/null | wc -l)
  total_prs=$((total_prs + pr_count))
  echo "  PRs: $pr_count"
done < "$TMP/repos.jsonl"

total_contributors=${#contributors_list[@]}
commits_per_contributor=0
if [ "$total_contributors" -gt 0 ]; then
  commits_per_contributor=$((total_commits / total_contributors))
fi

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
contributors_json="{"
first=true
for contributor in "${contributors_list[@]}"; do
  contrib_count=$(cat "$TMP/contrib_${contributor}.txt")
  if [ "$first" = true ]; then first=false; else contributors_json+=","; fi
  contributors_json+="\"$contributor\": $contrib_count"
done
contributors_json+="}"

cat > "$OUT_DIR/org-stats.json" <<EOF
{
  "organization": "$ORG",
  "public_repositories": $public_repos,
  "private_repositories": $private_repos,
  "total_repositories": $((public_repos + private_repos)),
  "total_commits": $total_commits,
  "total_pull_requests": $total_prs,
  "total_contributors": $total_contributors,
  "commits_per_contributor": $commits_per_contributor,
  "contributor_commits": $contributors_json,
  "updated_at": "$timestamp"
}
EOF

cat "$OUT_DIR/org-stats.json"
rm -rf "$TMP"
