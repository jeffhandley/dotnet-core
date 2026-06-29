#!/usr/bin/env bash
# release-notes-producer-preload.sh
#
# Deterministic, single-target preload for the Release Notes Producer (FEATURE
# mode). Runs on the host before the agent (the agent's sandbox cannot reach or
# execute the release-notes tool), and writes the full agent context under
# $AGENT_DIR so the agent consumes pre-generated data instead of producing it.
#
# Split out of the release-notes-preload composite action (kept off the agentic
# `steps:` block because gh-aw v0.80.9 cannot pin a local composite action). The
# discovery half lives in the manager (release-notes-discover.sh); this is the
# per-target generation + context half.
#
# Writes, for the single FEATURE target in $TARGET:
#   $AGENT_DIR/target.json               single-element array in the shape the
#                                        agent body reads (branch_features, the
#                                        new release-notes/{channel}-{milestone}
#                                        base, plus generated_* paths and refs)
#   $AGENT_DIR/generated/<slug>/changes.json + build-metadata.json
#   $AGENT_DIR/components.json            copy of the components source of truth
#   $AGENT_DIR/release-notes-branches.txt snapshot of existing release-notes/*
#   $AGENT_DIR/release-notes-prs.json + pr-comments/*  this target's PR context
#   $AGENT_DIR/context-index.json        index of the preloaded context files
#                                        (the agent body reads this first)
#
# Requires `release-notes`, `git`, `gh`, and `jq` on PATH.
#
# Inputs (env):
#   TARGET      required  single target object (JSON) from release-notes-discover.sh
#   VMR_PATH    optional  VMR clone path   (default /tmp/dotnet)
#   AGENT_DIR   optional  agent context dir (default /tmp/gh-aw/agent)
#   GH_TOKEN    required for PR-context preload
set -euo pipefail

TARGET="${TARGET:?TARGET (single target JSON) is required}"
VMR_PATH="${VMR_PATH:-/tmp/dotnet}"
AGENT_DIR="${AGENT_DIR:-/tmp/gh-aw/agent}"
CONTENT_ROOT="${CONTENT_ROOT:-release-notes}"

mode="$(jq -r '.mode' <<<"$TARGET")"
if [ "$mode" != "feature" ]; then
	echo "::error::release-notes-producer-preload.sh handles FEATURE targets; got mode='$mode'" >&2
	exit 1
fi

major="$(jq -r '.major' <<<"$TARGET")"
milestone="$(jq -r '.milestone' <<<"$TARGET")"
milestone_dotted="$(jq -r '.milestone_dotted // empty' <<<"$TARGET")"
last_shipped="$(jq -r '.last_shipped' <<<"$TARGET")"
support_phase="$(jq -r '.support_phase' <<<"$TARGET")"
base_branch="$(jq -r '.base_branch' <<<"$TARGET")"
content_dir="$(jq -r '.content_dir' <<<"$TARGET")"
base_tag="$(jq -r '.vmr_base_tag' <<<"$TARGET")"
head_ref="$(jq -r '.vmr_head_ref' <<<"$TARGET")"
version="$(jq -r '.release_version' <<<"$TARGET")"

slug="${base_branch#release-notes/}"
gen_dir="${AGENT_DIR}/generated/${slug}"
gen_changes="${gen_dir}/changes.json"
gen_build_metadata="${gen_dir}/build-metadata.json"
mkdir -p "$gen_dir" "$AGENT_DIR/pr-comments" "$AGENT_DIR/publish"

# ---- 1. VMR clone ----------------------------------------------------------
if [ ! -d "$VMR_PATH/.git" ]; then
	echo "::group::clone VMR -> $VMR_PATH"
	git clone --filter=blob:none https://github.com/dotnet/dotnet "$VMR_PATH"
	echo "::endgroup::"
fi
git -C "$VMR_PATH" rev-parse --verify HEAD >/dev/null

# ---- 2. resolve refs -------------------------------------------------------
if ! git -C "$VMR_PATH" rev-parse --verify "$base_tag" >/dev/null 2>&1; then
	echo "::error::VMR base ref '$base_tag' for $major does not resolve in $VMR_PATH" >&2
	git -C "$VMR_PATH" for-each-ref --format='%(refname:short)' 'refs/tags/v*' | grep -F "${major%.*}" | tail -10 || true
	exit 1
fi

head="$head_ref"
if [ "$head" != "main" ]; then
	if git -C "$VMR_PATH" rev-parse --verify --quiet "origin/$head^{commit}" >/dev/null 2>&1; then
		git -C "$VMR_PATH" branch -f "$head" "origin/$head" >/dev/null 2>&1 || true
		echo "::notice::$major head pinned to milestone branch '$head'."
	elif git -C "$VMR_PATH" rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1; then
		echo "::notice::$major head pinned to '$head'."
	else
		echo "::notice::$major head branch '$head' not present yet; drafting against 'main'."
		head="main"
	fi
fi

# ---- 3. deterministic generation -------------------------------------------
echo "::group::generate changes ($major $version): base=$base_tag head=$head"
release-notes generate changes "$VMR_PATH" \
	--base "$base_tag" \
	--head "$head" \
	--version "$version" \
	--labels \
	--output "$gen_changes"
echo "::endgroup::"

echo "::group::generate build-metadata ($major): base=$base_tag head=$head"
if release-notes generate build-metadata "$VMR_PATH" \
	--base "$base_tag" \
	--head "$head" \
	--output "$gen_build_metadata"; then
	echo "build-metadata generated."
else
	echo "::warning::build-metadata generation failed for $major (head=$head) — most likely the head build's packages are not published on the feed yet. The agent should preserve any existing build-metadata.json on the features branch."
	rm -f "$gen_build_metadata"
fi
echo "::endgroup::"

# ---- 3b. api-diff (best-effort, conditional, time-bounded) -----------------
# Generate the before/after public-API diff for this milestone into
# CONTENT_ROOT/<major>/.../api-diff/ so the agent can stage it onto the features
# branch. This is expensive (downloads ref packs + diffs every assembly), so it
# runs only when the milestone does not already have an api-diff on its features
# branch (set FORCE_API_DIFF=1 to regenerate). It is time-bounded and best-effort
# so it never blocks or hangs the run; the head milestone's ref packs may also
# not be published on the feed yet (same timing caveat as build-metadata).
cur_label="$milestone_dotted"
prev_label="$(printf '%s' "$last_shipped" | grep -oE '(preview|rc)\.[0-9]+' | head -1 || true)"
prev_mm="$(printf '%s' "$last_shipped" | grep -oE '^[0-9]+\.[0-9]+' | head -1 || true)"
[ -n "$prev_mm" ] || prev_mm="$major"
skip_api_diff=0
if [ "${FORCE_API_DIFF:-0}" != "1" ] &&
	git fetch --no-tags --depth=1 origin "$base_branch" >/dev/null 2>&1 &&
	git ls-tree -d "origin/${base_branch}" "${content_dir}/api-diff" 2>/dev/null | grep -q .; then
	echo "::notice::api-diff already present on ${base_branch}; skipping regeneration (set FORCE_API_DIFF=1 to override)."
	skip_api_diff=1
fi
if [ "$skip_api_diff" = "0" ] && command -v pwsh >/dev/null 2>&1 && [ -f "${CONTENT_ROOT}/RunApiDiff.ps1" ]; then
	echo "::group::api-diff ($prev_mm ${prev_label:-ga} -> $major ${cur_label:-ga})"
	if timeout "${API_DIFF_TIMEOUT:-1500}" pwsh "${CONTENT_ROOT}/RunApiDiff.ps1" \
		-PreviousMajorMinor "$prev_mm" ${prev_label:+-PreviousPrereleaseLabel "$prev_label"} \
		-CurrentMajorMinor "$major" ${cur_label:+-CurrentPrereleaseLabel "$cur_label"} \
		-CoreRepo "$(pwd)" -InstallApiDiff; then
		echo "api-diff generated under ${content_dir}/api-diff/."
	else
		echo "::warning::api-diff generation failed or timed out (best-effort) — likely the head milestone's ref packs are not published yet, or the diff exceeded the time budget; the agent should leave any existing api-diff in place and note it as pending."
	fi
	echo "::endgroup::"
elif [ "$skip_api_diff" = "0" ]; then
	echo "::notice::pwsh or ${CONTENT_ROOT}/RunApiDiff.ps1 not available; skipping api-diff."
fi

# ---- 4. agent target.json (single element, body-compatible shape) ----------
# The agent body jq-reads .branch_features, .generated_changes,
# .generated_build_metadata and reads the rest from the file. branch_features is
# the NEW base branch name; component branches become <branch_features>-<id>.
jq -n \
	--arg branch_features "$base_branch" \
	--arg content_dir "$content_dir" \
	--arg major "$major" \
	--arg milestone "$milestone" \
	--arg last_shipped "$last_shipped" \
	--arg support_phase "$support_phase" \
	--arg vmr_base_tag "$base_tag" \
	--arg vmr_head_ref "$head" \
	--arg release_version "$version" \
	--arg generated_changes "$gen_changes" \
	--arg generated_build_metadata "$gen_build_metadata" \
	'[{
     branch_features: $branch_features,
     content_dir: $content_dir,
     major: $major,
     milestone: $milestone,
     last_shipped: $last_shipped,
     support_phase: $support_phase,
     vmr_base_tag: $vmr_base_tag,
     vmr_head_ref: $vmr_head_ref,
     release_version: $release_version,
     generated_changes: $generated_changes,
     generated_build_metadata: $generated_build_metadata
   }]' >"$AGENT_DIR/target.json"

# components source of truth, copied for the agent
if [ -s "${CONTENT_ROOT}/components.json" ]; then
	cp "${CONTENT_ROOT}/components.json" "$AGENT_DIR/components.json"
else
	echo "::warning::components source of truth not found: ${CONTENT_ROOT}/components.json" >&2
fi

# ---- 5. PR + branch context preload ----------------------------------------
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
	echo "::notice::GH_TOKEN not set — skipping PR-context preload."
fi

# ---- 6. Context index (the body reads this first; it is a required prerequisite) ----
jq -n \
	--arg prs "$AGENT_DIR/release-notes-prs.json" \
	--arg branches "$AGENT_DIR/release-notes-branches.txt" \
	--arg comment_dir "$AGENT_DIR/pr-comments" \
	--arg publish_dir "$AGENT_DIR/publish" \
	--arg target "$AGENT_DIR/target.json" \
	--arg components "$AGENT_DIR/components.json" \
	'{
    release_notes_prs: $prs,
    release_notes_branches: $branches,
    pr_comment_directory: $comment_dir,
    publish_directory: $publish_dir,
    target: $target,
    components: $components
  }' >"$AGENT_DIR/context-index.json"

echo "Producer preload complete for ${base_branch}:"
jq -c '.[0] | {branch_features, vmr_base_tag, vmr_head_ref}' "$AGENT_DIR/target.json"
find "$gen_dir" -type f 2>/dev/null | sort
