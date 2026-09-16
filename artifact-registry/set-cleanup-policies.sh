#!/usr/bin/env bash
# Cleanup policies for the Artifact Registry repos that no Terraform state owns
# (D4). Every other repo declares its policy in its owning Terraform:
#   billing-exporter               infra terraform/main.tf
#   inbox, tasks, schedule,        each service repo's terraform/api.tf
#   people, docs
#
#   gcf-artifacts (us-central1)    auto-created by Cloud Functions gen2 builds
#   devbox                         created by hand, see README.md
#
# Usage: ./set-cleanup-policies.sh --dry-run   # report only (audit logs)
#        ./set-cleanup-policies.sh --no-dry-run
set -euo pipefail

mode=${1:?usage: $0 --dry-run|--no-dry-run}
case "$mode" in --dry-run|--no-dry-run) ;; *) echo "bad mode: $mode" >&2; exit 2 ;; esac

project=bens-project-462804
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The general rule: untagged versions go after 7 days, and the 3 most recent
# versions of each package are always kept.
cat >"$tmp/standard.json" <<'EOF'
[
  {"name": "delete-untagged-after-7d", "action": {"type": "Delete"},
   "condition": {"tagState": "untagged", "olderThan": "7d"}},
  {"name": "keep-3-most-recent", "action": {"type": "Keep"},
   "mostRecentVersions": {"keepCount": 3}}
]
EOF

# gcf-artifacts holds Cloud Functions build output, rebuilt on every deploy.
# A function serves the newest image of its package, so only that one is kept.
# Older ones have no rollback value, and each inbox build adds a ~3 GiB layer.
cat >"$tmp/gcf.json" <<'EOF'
[
  {"name": "delete-untagged-after-1d", "action": {"type": "Delete"},
   "condition": {"tagState": "untagged", "olderThan": "1d"}},
  {"name": "keep-most-recent", "action": {"type": "Keep"},
   "mostRecentVersions": {"keepCount": 1}}
]
EOF

set_policy() {
  local location=$1 repo=$2 policy=$3
  gcloud artifacts repositories set-cleanup-policies "$repo" \
    --project="$project" --location="$location" \
    --policy="$tmp/$policy.json" "$mode"
}

set_policy us-central1 gcf-artifacts gcf
set_policy us-central1 devbox standard
