#!/usr/bin/env bash
# release-notes-reactive-sweep.sh
#
# Hourly reactive sweep for the Release Notes Manager. pull_request_review does
# not fire for draft PRs, and an issue_comment trigger is too noisy (it runs on
# every comment across the repo), so instead the manager polls. This script:
#
#   1. lists open DRAFT release-notes PRs ([release-notes] title, release-notes/ head)
#   2. inspects each PR's reviews, review comments, replies, and issue comments
#      for human feedback that has not yet been processed (no :eyes: reaction
#      from the workflow actor)
#   3. leaves a :eyes: reaction on each newly-seen comment as a processed marker
#   4. emits a JSON array of the PR heads that have unprocessed feedback to stdout
#
# The manager maps each emitted head to a discovery target and dispatches the
# matching producer. Already-marked comments are skipped next hour, so a PR only
# triggers a producer run when new feedback has arrived.
#
# Requires: gh (GH_TOKEN), jq. Usage: release-notes-reactive-sweep.sh
# SWEEP_MODE: feature (skip release-notes/servicing), servicing (only that head),
# or all (default).
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
MARK="eyes"
MODE="${SWEEP_MODE:-all}"

# Bot/self comments never count as feedback and are never marked.
self_login() { gh api user -q '.login' 2>/dev/null || echo "github-actions[bot]"; }
SELF="$(self_login)"

# True if a comment's reactions already include our :eyes: marker.
marked() { jq -e --arg c "$MARK" 'any(.[]; .content == $c)' >/dev/null 2>&1; }

# Restrict the head set to the sweep mode so the feature and servicing managers
# never mark or claim each other's PRs.
case "$MODE" in
servicing) sel='.headRefName == "release-notes/servicing"' ;;
feature) sel='(.headRefName | startswith("release-notes/")) and .headRefName != "release-notes/servicing"' ;;
*) sel='.headRefName | startswith("release-notes/")' ;;
esac

heads_with_feedback="[]"

prs="$(gh pr list --repo "$REPO" --state open --draft --limit 100 \
	--json number,headRefName,title \
	-q "[.[] | select((.title | startswith(\"[release-notes]\")) and ($sel))]")"

while read -r pr head; do
	[ -n "$pr" ] || continue
	unprocessed=0

	# Review comments + their replies (pulls/comments) and PR-level issue comments.
	for kind in "pulls/$pr/comments" "issues/$pr/comments"; do
		ids="$(gh api "repos/$REPO/$kind" --paginate -q '.[] | "\(.id)\t\(.user.login)\t\(.user.type)"' 2>/dev/null || true)"
		while IFS=$'\t' read -r id login type; do
			[ -n "$id" ] || continue
			[ "$type" = "Bot" ] && continue
			[ "$login" = "$SELF" ] && continue
			path="pulls/comments/$id"
			[ "$kind" = "issues/$pr/comments" ] && path="issues/comments/$id"
			if gh api "repos/$REPO/$path/reactions" -q '.' 2>/dev/null | marked; then continue; fi
			gh api -X POST "repos/$REPO/$path/reactions" -f content="$MARK" >/dev/null 2>&1 || true
			unprocessed=$((unprocessed + 1))
		done <<<"$ids"
	done

	# Submitted reviews (no reactions API) count as feedback when newer than seen.
	reviews="$(gh api "repos/$REPO/pulls/$pr/reviews" --paginate \
		-q "[.[] | select(.user.login != \"$SELF\" and .user.type != \"Bot\" and .state != \"PENDING\")] | length" 2>/dev/null || echo 0)"

	if [ "$unprocessed" -gt 0 ]; then
		echo "PR #$pr ($head): $unprocessed new comment(s); $reviews review(s)" >&2
		heads_with_feedback="$(jq -c --arg h "$head" '. + [$h]' <<<"$heads_with_feedback")"
	fi
done <<<"$(jq -r '.[] | "\(.number)\t\(.headRefName)"' <<<"$prs")"

jq -cn --argjson h "$heads_with_feedback" '$h | unique'
