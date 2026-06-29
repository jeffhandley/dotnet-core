#!/usr/bin/env bash
# release-notes-servicing-preload.sh
#
# Deterministic preload for the Release Notes Servicing Producer. Runs on the
# host before the agent and gathers the notable-fix candidate data for the
# consolidated servicing target so the agent consumes pre-gathered data instead
# of querying it itself.
#
# Servicing fixes are sourced from the CONSTITUENT REPOS (dotnet/runtime,
# dotnet/aspnetcore, dotnet/efcore, ...) -- NOT the dotnet/dotnet VMR -- because
# 8.0/9.0 servicing ships directly from the constituent repos. For each pending
# GA patch this gathers the pull requests merged into each constituent repo's
# release branch during that patch's window; the agent then editorially filters
# the result (dropping dependency bumps, branding, CI, test-only changes, and
# branch merges) down to the notable non-security fixes. CVE/security content is
# added by humans after release.
#
# Writes, for the single consolidated SERVICING target in $TARGET:
#   $AGENT_DIR/target.json                 the servicing target (single-element)
#   $AGENT_DIR/servicing/<version>/fixes.json
#                                          merged-PR candidates per constituent
#                                          repo for that pending patch
#   $AGENT_DIR/components.json             copy of the components source of truth
#   $AGENT_DIR/release-notes-branches.txt  snapshot of existing release-notes/*
#   $AGENT_DIR/release-notes-prs.json + pr-comments/*  this target's PR context
#   $AGENT_DIR/context-index.json          index of the preloaded context files
#
# Requires `gh` and `jq` on PATH.
#
# Inputs (env):
#   TARGET      required  consolidated servicing target (JSON) from discovery
#   AGENT_DIR   optional  agent context dir (default /tmp/gh-aw/agent)
#   CONTENT_ROOT optional release-notes content root (default release-notes)
#   GH_TOKEN    required  token for the GitHub API
#   WINDOW_FALLBACK_DAYS optional  window lower bound when the previous patch
#                                  date cannot be resolved (default 45)
set -euo pipefail

TARGET="${TARGET:?TARGET (consolidated servicing JSON) is required}"
AGENT_DIR="${AGENT_DIR:-/tmp/gh-aw/agent}"
CONTENT_ROOT="${CONTENT_ROOT:-release-notes}"
WINDOW_FALLBACK_DAYS="${WINDOW_FALLBACK_DAYS:-45}"

mode="$(jq -r '.mode' <<<"$TARGET")"
if [ "$mode" != "servicing" ]; then
	echo "::error::release-notes-servicing-preload.sh handles SERVICING targets; got mode='$mode'" >&2
	exit 1
fi

mkdir -p "$AGENT_DIR/pr-comments" "$AGENT_DIR/publish" "$AGENT_DIR/servicing"

# Constituent repos: flatten components.json .components[].repos, drop empties,
# and de-duplicate (several components share dotnet/runtime).
components_path="${CONTENT_ROOT}/components.json"
if [ -f "$components_path" ]; then
	cp "$components_path" "$AGENT_DIR/components.json"
	mapfile -t REPOS < <(jq -r '.components[].repos // [] | .[]' "$components_path" | sort -u)
else
	echo "::warning::components source of truth not found: ${components_path}; using a default repo set" >&2
	REPOS=(dotnet/runtime dotnet/aspnetcore dotnet/efcore dotnet/sdk dotnet/roslyn dotnet/fsharp dotnet/winforms dotnet/wpf)
fi
echo "Constituent repos: ${REPOS[*]}"

# resolve_window <major> <version>
# Prints "<lo-date> <hi-date>" (YYYY-MM-DD) for the patch's gathering window.
# Lower bound = the previous patch's release date; upper = this patch's release
# date when known, else today. Falls back to a fixed-length window.
resolve_window() {
	local major="$1" version="$2" releases="${CONTENT_ROOT}/${1}/releases.json"
	local this_date="" prev_date=""
	if [ -f "$releases" ]; then
		this_date="$(jq -r --arg v "$version" '.releases[]? | select(."release-version" == $v) | ."release-date" // empty' "$releases" | head -1)"
		# Previous patch = the most recent release strictly older than this version.
		prev_date="$(jq -r --arg v "$version" '
      [.releases[]? | select((."release-version" // "") < $v)
        | ."release-date" // empty] | sort | last // empty' "$releases")"
	fi
	local hi="${this_date:-$(date -u +%F)}"
	local lo="$prev_date"
	if [ -z "$lo" ]; then
		lo="$(date -u -d "-${WINDOW_FALLBACK_DAYS} days" +%F 2>/dev/null || date -u -v-"${WINDOW_FALLBACK_DAYS}"d +%F)"
	fi
	printf '%s %s\n' "$lo" "$hi"
}

# gather_fixes <repo> <release-branch> <lo> <hi> -> JSON array of PR candidates
gather_fixes() {
	local repo="$1" branch="$2" lo="$3" hi="$4" out
	out="$(gh pr list --repo "$repo" \
		--search "base:${branch} merged:${lo}..${hi}" \
		--state merged --limit 200 \
		--json number,title,url,labels,mergedAt \
		--jq '[.[] | {repo: "'"$repo"'", number, title, url, mergedAt, labels: [.labels[].name]}]' \
		2>/dev/null || echo "[]")"
	printf '%s' "${out:-[]}"
}

# ---- per-release gathering --------------------------------------------------
jq -c '.releases[]' <<<"$TARGET" | while IFS= read -r rel; do
	major="$(jq -r '.major' <<<"$rel")"
	version="$(jq -r '.version' <<<"$rel")"
	band="release/${major}"
	read -r lo hi < <(resolve_window "$major" "$version")
	echo "::group::gather $version (repos x {$band, ${band}-staging}) window ${lo}..${hi}"
	dir="$AGENT_DIR/servicing/${version}"
	mkdir -p "$dir"
	all="[]"
	if [ -n "${GH_TOKEN:-}" ]; then
		for repo in "${REPOS[@]}"; do
			for b in "$band" "${band}-staging"; do
				part="$(gather_fixes "$repo" "$b" "$lo" "$hi")"
				all="$(jq -c --argjson a "$all" --argjson b "$part" '$a + $b' <<<'null')"
			done
		done
		# De-duplicate by repo+number (a PR can match both base branches) and sort.
		all="$(jq -c 'unique_by([.repo, .number]) | sort_by(.repo, .number)' <<<"$all")"
	else
		echo "::notice::GH_TOKEN not set -- skipping fix gathering for $version"
	fi
	jq -n --arg version "$version" --arg major "$major" \
		--arg lo "$lo" --arg hi "$hi" --argjson fixes "$all" \
		'{version: $version, major: $major, window: {from: $lo, to: $hi},
      candidate_count: ($fixes | length), candidates: $fixes}' >"$dir/fixes.json"
	echo "  $version: $(jq '.candidate_count' "$dir/fixes.json") candidate PR(s)"
	echo "::endgroup::"
done

# ---- agent target.json (single consolidated servicing target) ---------------
jq -n --argjson target "$TARGET" \
	'[($target + {
      content_root: "'"$CONTENT_ROOT"'",
      servicing_dir: "'"$AGENT_DIR"'/servicing"
    })]' >"$AGENT_DIR/target.json"

# ---- PR + branch context preload (mirrors the feature preload) --------------
: >"$AGENT_DIR/release-notes-branches.txt"
if [ -n "${GH_TOKEN:-}" ]; then
	echo "::group::preload PR + branch context"
	gh pr list \
		--repo "$GITHUB_REPOSITORY" \
		--search "[release-notes] in:title" \
		--state all \
		--limit 100 \
		--json number,title,body,headRefName,baseRefName,state,isDraft,url,updatedAt,author \
		>"${AGENT_DIR}/release-notes-prs.json" 2>/dev/null || echo "[]" >"${AGENT_DIR}/release-notes-prs.json"

	git ls-remote --heads origin 'release-notes/*' 2>/dev/null | awk '{print $2}' | while IFS= read -r ref; do
		[ -n "$ref" ] || continue
		printf 'origin/%s\n' "${ref#refs/heads/}" >>"$AGENT_DIR/release-notes-branches.txt"
	done

	jq -r '.[] | select(.state == "OPEN") | .number' "${AGENT_DIR}/release-notes-prs.json" | while IFS= read -r pr; do
		[ -n "$pr" ] || continue
		gh api "repos/$GITHUB_REPOSITORY/issues/$pr/comments?per_page=100" >"$AGENT_DIR/pr-comments/${pr}-issue-comments.json" 2>/dev/null || true
		gh api "repos/$GITHUB_REPOSITORY/pulls/$pr/comments?per_page=100" >"$AGENT_DIR/pr-comments/${pr}-review-comments.json" 2>/dev/null || true
		gh api "repos/$GITHUB_REPOSITORY/pulls/$pr/reviews?per_page=100" >"$AGENT_DIR/pr-comments/${pr}-reviews.json" 2>/dev/null || true
	done
	echo "::endgroup::"
else
	echo "[]" >"${AGENT_DIR}/release-notes-prs.json"
fi

# ---- context index ----------------------------------------------------------
jq -n \
	--arg prs "$AGENT_DIR/release-notes-prs.json" \
	--arg branches "$AGENT_DIR/release-notes-branches.txt" \
	--arg comment_dir "$AGENT_DIR/pr-comments" \
	--arg publish_dir "$AGENT_DIR/publish" \
	--arg target "$AGENT_DIR/target.json" \
	--arg components "$AGENT_DIR/components.json" \
	--arg servicing_dir "$AGENT_DIR/servicing" \
	'{
    release_notes_prs: $prs,
    release_notes_branches: $branches,
    pr_comment_directory: $comment_dir,
    publish_directory: $publish_dir,
    target: $target,
    components: $components,
    servicing_directory: $servicing_dir
  }' >"$AGENT_DIR/context-index.json"

echo "Servicing preload complete:"
jq -c '.[0] | {base_branch, releases: [.releases[].version]}' "$AGENT_DIR/target.json"
find "$AGENT_DIR/servicing" -name fixes.json | sort
