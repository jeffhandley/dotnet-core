#!/usr/bin/env bash
# release-notes-discover.sh
#
# Deterministic discovery for the Release Notes Manager. Reads the local
# release-notes/releases-index.json and emits the set of in-scope targets the
# manager dispatches a producer for:
#
#   - FEATURE targets: one per in-development major (support-phase preview|go-live),
#     the natural successor milestone. Adapted from the proven compute-target logic
#     in release-notes-preload, with the new branch naming.
#   - SERVICING target: at most one consolidated target listing every supported GA
#     channel (support-phase active|maintenance) whose latest-release is not yet
#     documented under release-notes/<channel>/<version>/.
#
# Pure jq/bash: no VMR clone and no release-notes tool required, so it runs
# locally and inside a manager run: step. Emits a JSON array to stdout.
#
# Usage: release-notes-discover.sh [index-path] [content-root]
set -euo pipefail

INDEX_PATH="${1:-release-notes/releases-index.json}"
CONTENT_ROOT="${2:-release-notes}"
COMPONENTS_PATH="${CONTENT_ROOT}/components.json"

if [ ! -s "$INDEX_PATH" ]; then
	echo "::error::releases index not found: $INDEX_PATH" >&2
	exit 1
fi

# ---- helpers (FEATURE) ------------------------------------------------------

# "11.0.0-preview.2" -> "preview3"; "11.0.0-rc.1" -> "rc2"; else "" (skip/override).
succ_milestone() {
	local latest="$1"
	if [[ "$latest" =~ -preview\.([0-9]+) ]]; then
		echo "preview$((BASH_REMATCH[1] + 1))"
		return
	fi
	if [[ "$latest" =~ -rc\.([0-9]+) ]]; then
		echo "rc$((BASH_REMATCH[1] + 1))"
		return
	fi
	echo ""
}

# "preview6" -> "preview.6"; "rc1" -> "rc.1"; "ga" -> "ga".
to_dotted_milestone() {
	local m="$1"
	if [[ "$m" =~ ^(preview|rc)([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; else echo "$m"; fi
}

# "preview6" -> "preview"; "rc1" -> "rc"; "ga" -> "ga".
to_phase_dir() {
	local m="$1"
	if [[ "$m" =~ ^(preview|rc)[0-9]+$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "$m"; fi
}

# Durable VMR base tag: the previously shipped preview/rc build TAG. Preview
# branches are deleted after a milestone ships but tags persist, so the tag is
# the stable inclusive lower bound. release "11.0.0-preview.5" + sdk
# "11.0.100-preview.5.26302.115" -> "v11.0.0-preview.5.26302.115".
base_tag_from() {
	local release="$1" sdk="$2"
	if [[ "$sdk" =~ -(preview|rc)\.[0-9]+\.(.+)$ ]]; then echo "v${release}.${BASH_REMATCH[2]}"; else echo ""; fi
}

# Release version for `release-notes generate changes --version`.
# "11.0"+"preview3" -> "11.0.0-preview.3"; "11.0"+"rc1" -> "11.0.0-rc.1"; "11.0"+"ga" -> "11.0.0".
release_version_from() {
	local channel="$1" m="$2"
	if [[ "$m" =~ ^(preview|rc)([0-9]+)$ ]]; then echo "${channel}.0-${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; else echo "${channel}.0"; fi
}

# In-flight VMR head branch, e.g. "11.0"+sdk+"preview6" -> "release/11.0.1xx-preview6".
# head=main is the leading edge until the milestone branches; the producer
# resolves this candidate against the clone and falls back to main when absent.
head_branch_from() {
	local channel="$1" sdk="$2" milestone="$3"
	local feature band
	feature="${sdk#"${channel}."}" # "100-preview.5.26302.115"
	feature="${feature%%[-.]*}"    # "100"
	band="${feature:0:1}xx"        # "1xx"
	echo "release/${channel}.${band}-${milestone}"
}

# ---- FEATURE targets --------------------------------------------------------

targets="[]"
while IFS=$'\t' read -r channel latest_release latest_sdk support_phase; do
	[ -n "$channel" ] || continue

	milestone=$(succ_milestone "$latest_release")
	if [ -z "$milestone" ]; then
		echo "::notice::Skipping $channel — no automatic successor for $latest_release (use the producer milestone input for rc1/ga boundaries)." >&2
		continue
	fi

	dotted=$(to_dotted_milestone "$milestone")
	phase_dir=$(to_phase_dir "$milestone")
	vmr_base_tag=$(base_tag_from "$latest_release" "$latest_sdk")
	if [ -z "$vmr_base_tag" ]; then
		echo "::error::Cannot derive VMR base tag for $channel (latest_release=$latest_release, latest_sdk=$latest_sdk)" >&2
		exit 1
	fi
	release_version=$(release_version_from "$channel" "$milestone")
	vmr_head_ref=$(head_branch_from "$channel" "$latest_sdk" "$milestone")
	base_branch="release-notes/${channel}-${dotted}"

	target=$(jq -n \
		--arg mode "feature" \
		--arg major "$channel" \
		--arg milestone "$milestone" \
		--arg milestone_dotted "$dotted" \
		--arg last_shipped "$latest_release" \
		--arg support_phase "$support_phase" \
		--arg base_branch "$base_branch" \
		--arg content_dir "${CONTENT_ROOT}/${channel}/${phase_dir}/${milestone}" \
		--arg vmr_base_tag "$vmr_base_tag" \
		--arg vmr_head_ref "$vmr_head_ref" \
		--arg release_version "$release_version" \
		'{mode:$mode, major:$major, milestone:$milestone, milestone_dotted:$milestone_dotted,
      last_shipped:$last_shipped, support_phase:$support_phase, base_branch:$base_branch,
      content_dir:$content_dir, vmr_base_tag:$vmr_base_tag, vmr_head_ref:$vmr_head_ref,
      release_version:$release_version}')
	targets=$(jq --argjson t "$target" '. += [$t]' <<<"$targets")
done < <(jq -r '."releases-index"[]
  | select(."support-phase" == "preview" or ."support-phase" == "go-live")
  | [."channel-version", ."latest-release", ."latest-sdk", ."support-phase"] | @tsv' "$INDEX_PATH")

# Invariant: at most one active feature milestone per major.
dup=$(jq -r '[.[] | select(.mode=="feature") | .major] | group_by(.) | map(select(length > 1)) | length' <<<"$targets")
if [ "$dup" -gt 0 ]; then
	echo "::error::Invariant violated — more than one active feature milestone per major." >&2
	exit 1
fi

# ---- SERVICING target (consolidated) ----------------------------------------

pending="[]"
while IFS=$'\t' read -r channel latest_release support_phase; do
	[ -n "$channel" ] || continue
	# Pending when the latest GA patch has no documented release-notes directory.
	if [ ! -d "${CONTENT_ROOT}/${channel}/${latest_release}" ]; then
		entry=$(jq -n --arg major "$channel" --arg version "$latest_release" --arg phase "$support_phase" \
			'{major:$major, version:$version, support_phase:$phase}')
		pending=$(jq --argjson e "$entry" '. += [$e]' <<<"$pending")
	fi
done < <(jq -r '."releases-index"[]
  | select(."support-phase" == "active" or ."support-phase" == "maintenance")
  | [."channel-version", ."latest-release", ."support-phase"] | @tsv' "$INDEX_PATH")

if [ "$(jq 'length' <<<"$pending")" -gt 0 ]; then
	servicing=$(jq -n --argjson releases "$pending" \
		'{mode:"servicing", base_branch:"release-notes/servicing", releases:$releases}')
	targets=$(jq --argjson t "$servicing" '. += [$t]' <<<"$targets")
fi

# components.json presence is required for the producer; surface it early.
if [ ! -s "$COMPONENTS_PATH" ]; then
	echo "::warning::components source of truth not found: $COMPONENTS_PATH" >&2
fi

jq '.' <<<"$targets"
