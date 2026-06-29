#!/usr/bin/env bash
# Shared helpers used by both release-notes.md (post-step publish) and
# fix-release-notes-lint.md (fixup workflow). Sourced, not executed.
#
# Provides:
#   setup_toc_tool                  — install github-slugger and emit
#                                     /tmp/toctool/regen-toc.js and
#                                     /tmp/toctool/normalize-md.js
#   regenerate_tocs BRANCH          — regenerate `<!-- toc -->` blocks in files
#                                     this branch added/modified vs origin/main,
#                                     amending the tip commit
#   normalize_markdown_files BRANCH — deterministic tier-1 normalizer: runs
#                                     component-branch pruning, regenerate_tocs,
#                                     then a body-level fixer for MD040 (bare
#                                     fences) and MD051 (anchor fragments), then
#                                     markdownlint --fix; amends the tip commit
#                                     if changed
#   lint_branch BRANCH OUT          — run markdownlint against each .md this
#                                     branch added/modified vs origin/main;
#                                     writes violations to OUT; returns 0 if
#                                     clean, 1 if any file failed
#   validate_branch_placement BRANCH — hard placement guard: rejects a branch
#                                     whose changed files violate the
#                                     features/component branch invariants
#                                     (see release-notes.README.md). Prints the
#                                     reason and returns 1 on violation, else 0.

setup_toc_tool() {
	mkdir -p /tmp/toctool
	(cd /tmp/toctool && npm init -y >/dev/null 2>&1 && npm install --silent github-slugger >/dev/null 2>&1)

	# Body-level normalizer that fixes the two most common deterministic
	# lint failures agent-generated markdown produces:
	#   - MD040: fenced code blocks without a language. Bare ``` opens get
	#     `text` appended (chosen because it is universally safe and renders
	#     as a plain code block on GitHub).
	#   - MD051: body links of the form `[label](#anchor)` whose anchor does
	#     not match any heading slug in the file. The fixer recomputes the
	#     correct slug from the link label, falling back to a normalized
	#     lookup against the heading slug table. Anchors that cannot be
	#     resolved to an existing heading are left alone so markdownlint
	#     surfaces them rather than the normalizer silently making them
	#     look "correct".
	cat >/tmp/toctool/normalize-md.js <<'NORM_JS_EOF'
const fs = require('fs');
const GithubSlugger = require('github-slugger').default || require('github-slugger');
const path = process.argv[2];
if (!path) { console.error('usage: normalize-md.js FILE.md'); process.exit(2); }

const original = fs.readFileSync(path, 'utf8');
const lines = original.split('\n');

// Pass 1: collect heading slugs and a normalized lookup table.
const slugger = new GithubSlugger();
const headingSlugs = new Set();
const normToSlug = new Map();
let inCode = false;
for (const line of lines) {
  if (/^```/.test(line)) { inCode = !inCode; continue; }
  if (inCode) continue;
  const m = /^#{1,6}\s+(.+)$/.exec(line);
  if (!m) continue;
  // Strip closed-ATX trailing hashes (MD003) so slugs match the open-ATX form.
  const heading = m[1].trim().replace(/\s+#+$/, '').trim();
  const plain = heading.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/`/g, '');
  const slug = slugger.slug(plain);
  headingSlugs.add(slug);
  const key = plain.toLowerCase().replace(/[^a-z0-9]+/g, '');
  if (!normToSlug.has(key)) normToSlug.set(key, slug);
}

// Pass 2: rewrite bad anchors (MD051) and bare fences (MD040).
const out = [];
inCode = false;
for (let line of lines) {
  const fenceOpen = /^(\s*)```\s*$/.exec(line);
  if (fenceOpen) {
    if (!inCode) {
      // Bare opening fence — give it a default language.
      line = `${fenceOpen[1]}\`\`\`text`;
    }
    inCode = !inCode;
    out.push(line);
    continue;
  }
  if (/^\s*```/.test(line)) {
    // Fence with language, or closing fence.
    inCode = !inCode;
    out.push(line);
    continue;
  }
  if (inCode) { out.push(line); continue; }

  // MD003: normalize closed-ATX headings (### x ###) to plain ATX (### x).
  line = line.replace(/^(\s{0,3}#{1,6}\s+\S.*?)\s+#+\s*$/, '$1');

  // Rewrite [label](#anchor) where the anchor doesn't resolve.
  line = line.replace(/(\[([^\]]+)\])\(#([^)]+)\)/g, (full, label, text, anchor) => {
    if (headingSlugs.has(anchor)) return full;
    const plain = text.replace(/`/g, '');
    const recomputed = new GithubSlugger().slug(plain);
    if (headingSlugs.has(recomputed)) return `${label}(#${recomputed})`;
    const key = plain.toLowerCase().replace(/[^a-z0-9]+/g, '');
    const viaText = normToSlug.get(key);
    if (viaText) return `${label}(#${viaText})`;
    const lc = anchor.toLowerCase();
    if (headingSlugs.has(lc)) return `${label}(#${lc})`;
    return full;
  });

  out.push(line);
}

const next = out.join('\n');
if (next !== original) {
  fs.writeFileSync(path, next);
}
NORM_JS_EOF

	cat >/tmp/toctool/regen-toc.js <<'TOC_JS_EOF'
const fs = require('fs');
const GithubSlugger = require('github-slugger').default || require('github-slugger');
const path = process.argv[2];
if (!path) { console.error('usage: regen-toc.js FILE.md'); process.exit(2); }
let content = fs.readFileSync(path, 'utf8');
const startMarker = '<!-- toc -->';
const endMarker = '<!-- tocstop -->';
const start = content.indexOf(startMarker);
const end = content.indexOf(endMarker);
if (start === -1 || end === -1 || end < start) process.exit(0);
const slugger = new GithubSlugger();
const lines = content.split('\n');
const entries = [];
let inCode = false;
for (const line of lines) {
  if (/^```/.test(line)) { inCode = !inCode; continue; }
  if (inCode) continue;
  const m = /^##\s+([^#].*)$/.exec(line);
  if (!m) continue;
  const text = m[1].trimEnd();
  const plain = text.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/`/g, '');
  const slug = slugger.slug(plain);
  entries.push(`- [${text}](#${slug})`);
}
const toc = entries.length
  ? `${startMarker}\n\n${entries.join('\n')}\n\n${endMarker}`
  : `${startMarker}\n${endMarker}`;
const out = content.slice(0, start) + toc + content.slice(end + endMarker.length);
fs.writeFileSync(path, out);
TOC_JS_EOF
}

# Regenerate auto-TOCs in every .md this branch added/modified vs origin/main.
# Amends the tip commit if anything changed. Working tree must be checked out on BRANCH.
regenerate_tocs() {
	local branch="$1"
	local touched=0
	local md_files
	md_files=$(git diff --name-only "origin/main...$branch" -- '*.md' 2>/dev/null || true)
	[ -z "$md_files" ] && return 0
	while IFS= read -r md_path; do
		[ -z "$md_path" ] && continue
		[ -f "$md_path" ] || continue
		grep -q '<!-- toc -->' "$md_path" || continue
		grep -q '<!-- tocstop -->' "$md_path" || continue
		(cd /tmp/toctool && node regen-toc.js "$GITHUB_WORKSPACE/$md_path") || true
		if ! git diff --quiet -- "$md_path"; then
			touched=1
			git add "$md_path"
		fi
	done <<<"$md_files"
	if [ "$touched" -eq 1 ]; then
		git -c user.email="${GIT_AUTHOR_EMAIL:-actions@github.com}" \
			-c user.name="${GIT_AUTHOR_NAME:-github-actions[bot]}" \
			commit --amend --no-edit >/dev/null
		echo "  TOC regenerated for $branch"
	fi
}

# Run markdownlint against each .md this branch added/modified vs origin/main.
# Writes violations to OUT (one section per failing file). Returns 0 if all clean.
lint_branch() {
	local branch="$1"
	local out="$2"
	: >"$out"
	local md_files
	md_files=$(git diff --name-only "origin/main...$branch" -- '*.md' 2>/dev/null || true)
	[ -z "$md_files" ] && return 0
	local any_failed=0
	local tmpdir
	tmpdir=$(mktemp -d)
	while IFS= read -r md_path; do
		[ -z "$md_path" ] && continue
		[ -f "$md_path" ] || continue
		local dest="$tmpdir/$md_path"
		mkdir -p "$(dirname "$dest")"
		cp "$md_path" "$dest"
	done <<<"$md_files"
	# shellcheck disable=SC2046,SC2015  # word-split file list into args on purpose; `|| true` guards npx exit
	(cd "$tmpdir" && npx --yes markdownlint-cli \
		--config "$GITHUB_WORKSPACE/.github/linters/.markdown-lint.yml" \
		$(echo "$md_files" | tr '\n' ' ') 2>"$out.raw" || true)
	if [ -s "$out.raw" ]; then
		sed "s|$tmpdir/||g" "$out.raw" >"$out"
		any_failed=1
	fi
	rm -rf "$tmpdir" "$out.raw" 2>/dev/null || true
	return $any_failed
}

# Deterministic tier-1 markdown normalizer. For every .md this branch
# added/modified vs origin/main, runs:
#   1. component-branch pruning (removes sibling component .md files)
#   2. regenerate_tocs (handles <!-- toc --> blocks the agent typed by hand)
#   3. /tmp/toctool/normalize-md.js (fixes MD003 closed-ATX headings,
#      MD040 bare fences and MD051
#      bad anchor links anywhere in the file body)
#   4. markdownlint-cli --fix (auto-fixable rules: MD009 trailing-spaces,
#      MD010 tabs, MD012 blank-line groups, MD018-021 ATX spacing,
#      MD023 heading start, MD026 trailing punct, MD027 blockquote spaces,
#      MD030 list-marker spaces, MD031/MD032 fence/list surrounds,
#      MD034 bare urls, MD044 proper names, MD047 file end newline)
# Each step is idempotent. If any file changed, the tip commit is amended.
# Working tree must be checked out on $branch.
normalize_markdown_files() {
	local branch="$1"
	local touched=0
	local md_files

	# Component branches are named <features-branch>-<component-id> and must only
	# carry that component's markdown file. Prune stale sibling files and
	# feature-branch-only metadata (notably hints/) left behind by earlier bad
	# runs before linting and pushing.
	if [[ "$branch" == *-features-* ]]; then
		local component_id="${branch##*-features-}"
		local changed_release_paths
		changed_release_paths=$(git diff --name-only "origin/main...$branch" -- 'release-notes' 2>/dev/null || true)
		while IFS= read -r release_path; do
			[ -z "$release_path" ] && continue
			if [[ "$release_path" == */hints/* || "$release_path" == */.hints/* ]] && [ -f "$release_path" ]; then
				git rm -f "$release_path" >/dev/null
				touched=1
				echo "  Removed feature-branch-only hint from $branch: $release_path"
			fi
		done <<<"$changed_release_paths"

		local changed_release_md
		changed_release_md=$(git diff --name-only "origin/main...$branch" -- 'release-notes' 2>/dev/null | grep '\.md$' || true)
		while IFS= read -r md_path; do
			[ -z "$md_path" ] && continue
			local md_name
			md_name=$(basename "$md_path")
			if [ "$md_name" = "README.md" ] || [ "$md_name" = "$component_id.md" ]; then
				continue
			fi
			if [ -f "$md_path" ]; then
				git rm -f "$md_path" >/dev/null
				touched=1
				echo "  Removed stale component file from $branch: $md_path"
			fi
		done <<<"$changed_release_md"
	fi

	md_files=$(git diff --name-only "origin/main...$branch" -- '*.md' 2>/dev/null || true)
	if [ -z "$md_files" ]; then
		if [ "$touched" -eq 1 ]; then
			git -c user.email="${GIT_AUTHOR_EMAIL:-actions@github.com}" \
				-c user.name="${GIT_AUTHOR_NAME:-github-actions[bot]}" \
				commit --amend --no-edit >/dev/null
			echo "  Markdown normalized for $branch"
		fi
		return 0
	fi

	# Step 2: TOC regen (only touches files with explicit markers).
	regenerate_tocs "$branch"

	# Refresh the diff in case regen amended the tip commit.
	md_files=$(git diff --name-only "origin/main...$branch" -- '*.md' 2>/dev/null || true)
	if [ -z "$md_files" ]; then
		if [ "$touched" -eq 1 ]; then
			git -c user.email="${GIT_AUTHOR_EMAIL:-actions@github.com}" \
				-c user.name="${GIT_AUTHOR_NAME:-github-actions[bot]}" \
				commit --amend --no-edit >/dev/null
			echo "  Markdown normalized for $branch"
		fi
		return 0
	fi

	# Step 3: body-level normalizer (MD003 + MD040 + MD051).
	while IFS= read -r md_path; do
		[ -z "$md_path" ] && continue
		[ -f "$md_path" ] || continue
		(cd /tmp/toctool && node normalize-md.js "$GITHUB_WORKSPACE/$md_path") || true
		if ! git diff --quiet -- "$md_path"; then
			touched=1
			git add "$md_path"
		fi
	done <<<"$md_files"

	# Step 4: markdownlint --fix for the rules it can auto-correct.
	while IFS= read -r md_path; do
		[ -z "$md_path" ] && continue
		[ -f "$md_path" ] || continue
		npx --yes markdownlint-cli \
			--config "$GITHUB_WORKSPACE/.github/linters/.markdown-lint.yml" \
			--fix "$md_path" >/dev/null 2>&1 || true
		if ! git diff --quiet -- "$md_path"; then
			touched=1
			git add "$md_path"
		fi
	done <<<"$md_files"

	if [ "$touched" -eq 1 ]; then
		git -c user.email="${GIT_AUTHOR_EMAIL:-actions@github.com}" \
			-c user.name="${GIT_AUTHOR_NAME:-github-actions[bot]}" \
			commit --amend --no-edit >/dev/null
		echo "  Markdown normalized for $branch"
	fi
}

# Hard placement guard. Verifies that the files a branch added/modified vs
# origin/main obey the features/component branch invariants documented in
# .github/workflows/release-notes.README.md:
#
#   1. A component branch (<features>-<id>) may only add/modify its own
#      <id>.md (and an optional README.md) under release-notes/. Stray sibling
#      component files, hints, and metadata (changes.json, features.json, …)
#      are rejected.
#   2. The features branch (<…>-features) must not add/modify any component
#      <id>.md file (component markdown belongs on component branches).
#   3. Component markdown filenames must be a known components.json id.
#
# normalize_markdown_files auto-prunes the common self-healing cases first;
# this guard is the final check that refuses to push anything still misplaced.
# Prints a human-readable reason for each violation and returns 1 if the
# branch must be rejected, 0 otherwise. Working tree must be on $branch.
validate_branch_placement() {
	local branch="$1"
	local components_json="${COMPONENTS_JSON:-$GITHUB_WORKSPACE/release-notes/components.json}"
	local ids id_set changed path base stem violations=0

	# Known component ids (space-padded for whole-word matching).
	if [ -f "$components_json" ]; then
		ids=$(jq -r '.components[].id' "$components_json" 2>/dev/null | tr '\n' ' ')
	else
		ids=""
	fi
	id_set=" $ids "

	changed=$(git diff --name-only "origin/main...$branch" -- 'release-notes' 2>/dev/null || true)
	[ -z "$changed" ] && return 0

	if [[ "$branch" == *-features-* ]]; then
		# Component branch: only <id>.md (+ optional README.md) allowed.
		local component_id="${branch##*-features-}"
		if [[ "$id_set" != *" $component_id "* ]]; then
			echo "::error::Placement guard: '$branch' has unknown component id '$component_id' (not in components.json)"
			return 1
		fi
		while IFS= read -r path; do
			[ -z "$path" ] && continue
			base=$(basename "$path")
			if [[ "$path" == */hints/* || "$path" == */.hints/* ]]; then
				echo "::error::Placement guard: hints must not live on component branch '$branch': $path"
				violations=$((violations + 1))
				continue
			fi
			if [ "$base" = "README.md" ] || [ "$base" = "$component_id.md" ]; then
				continue
			fi
			echo "::error::Placement guard: '$branch' may only carry $component_id.md, found: $path"
			violations=$((violations + 1))
		done <<<"$changed"
	elif [[ "$branch" == *-features ]]; then
		# Features branch: no component <id>.md files.
		while IFS= read -r path; do
			[ -z "$path" ] && continue
			[[ "$path" == *.md ]] || continue
			[[ "$path" == */hints/* || "$path" == */.hints/* ]] && continue
			base=$(basename "$path")
			[ "$base" = "README.md" ] && continue
			stem="${base%.md}"
			if [[ "$id_set" == *" $stem "* ]]; then
				echo "::error::Placement guard: component markdown '$base' must live on the '$branch-$stem' branch, not the features branch: $path"
				violations=$((violations + 1))
			fi
		done <<<"$changed"
	fi

	if [ "$violations" -gt 0 ]; then
		echo "::error::Placement guard: $branch has $violations placement violation(s)"
		return 1
	fi
	return 0
}
