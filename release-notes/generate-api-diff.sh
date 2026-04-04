#!/usr/bin/env bash
# generate-api-diff.sh — Deterministic wrapper for RunApiDiff.ps1
#
# Maps workflow dispatch inputs to script parameters, handles feed fallback,
# and writes metadata JSON for the agent to consume.
#
# Environment variables (from workflow dispatch inputs):
#   INPUT_PREVIOUS_MAJOR_MINOR  — e.g. "10.0" or ""
#   INPUT_PREVIOUS_LABEL        — e.g. "preview.2", "rc.1", "ga", or ""
#   INPUT_CURRENT_MAJOR_MINOR   — e.g. "11.0" or ""
#   INPUT_CURRENT_LABEL         — e.g. "preview.3", "rc.1", "ga", or ""
#
# This script always exits 0. Metadata records success/failure for the agent.

set -uo pipefail

AGENT_DIR="/tmp/gh-aw/agent"
mkdir -p "$AGENT_DIR"
METADATA="$AGENT_DIR/metadata.json"

PREV_MM="${INPUT_PREVIOUS_MAJOR_MINOR:-}"
PREV_LABEL="${INPUT_PREVIOUS_LABEL:-}"
CURR_MM="${INPUT_CURRENT_MAJOR_MINOR:-}"
CURR_LABEL="${INPUT_CURRENT_LABEL:-}"

# ── helpers ──────────────────────────────────────────────────────────────────

write_metadata() {
  python3 -c "
import json, sys
json.dump({
    'status': sys.argv[1],
    'reason': sys.argv[2],
    'previous': sys.argv[3],
    'current': sys.argv[4],
    'is_release_to_release': sys.argv[5] == 'true',
    'feed_used': sys.argv[6],
    'branch_name': sys.argv[7],
    'pr_title': sys.argv[8],
    'explicit_inputs': sys.argv[9] == 'true'
}, open(sys.argv[10], 'w'), indent=2)
" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "$METADATA"
  echo "::group::Metadata"
  cat "$METADATA"
  echo "::endgroup::"
}

friendly_name() {
  local mm="$1" label="$2"
  if [ -z "$mm" ]; then echo "inferred"; return; fi
  if [ -z "$label" ] || [ "$label" = "ga" ]; then echo ".NET $mm"; return; fi
  local kind num
  kind="${label%%.*}"
  num="${label##*.}"
  case "$kind" in
    preview) echo ".NET $mm Preview $num" ;;
    rc)      echo ".NET $mm RC $num" ;;
    *)       echo ".NET $mm $label" ;;
  esac
}

branch_segment() {
  local mm="$1" label="$2"
  local seg="net${mm//.}"
  if [ -n "$label" ] && [ "$label" != "ga" ]; then
    seg="${seg}-${label//.}"
  fi
  echo "$seg"
}

# Probe NuGet flat-container for the latest version matching a major.minor
probe_latest_version() {
  local mm="$1"
  local feed_url="${2:-https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json}"

  local base_url
  base_url=$(curl -sL "$feed_url" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('resources', []):
    if 'PackageBaseAddress' in r.get('@type', ''):
        print(r['@id']); break
" 2>/dev/null) || true

  if [ -z "$base_url" ]; then return 1; fi

  curl -sL "${base_url}microsoft.netcore.app.ref/index.json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
versions = [v for v in data.get('versions', []) if v.startswith('${mm}.')]
if versions:
    print(versions[-1])
else:
    sys.exit(1)
" 2>/dev/null
}

# ── input validation ─────────────────────────────────────────────────────────

has_any=false
has_all=true
for var in "$PREV_MM" "$PREV_LABEL" "$CURR_MM" "$CURR_LABEL"; do
  if [ -n "$var" ]; then has_any=true; else has_all=false; fi
done

if [ "$has_any" = true ] && [ "$has_all" = false ]; then
  write_metadata "skipped" \
    "All four inputs are required for an explicit run. Provide previous_major_minor, previous_label, current_major_minor, and current_label together." \
    "" "" "false" "" "" "" "true"
  exit 0
fi

# ── build script parameters ──────────────────────────────────────────────────

PARAMS=("-InstallApiDiff")
IS_RELEASE_TO_RELEASE=false
FEED_USED="dotnet-public"
CURR_EFFECTIVE_LABEL="$CURR_LABEL"

if [ "$has_all" = true ]; then
  # Explicit run — map all inputs to script parameters
  PARAMS+=("-PreviousMajorMinor" "$PREV_MM")
  PARAMS+=("-CurrentMajorMinor" "$CURR_MM")

  # Previous side: ga means omit PrereleaseLabel
  if [ "$PREV_LABEL" != "ga" ]; then
    PARAMS+=("-PreviousPrereleaseLabel" "$PREV_LABEL")
  fi

  # Current side
  if [ "$CURR_LABEL" = "ga" ]; then
    if [ "$PREV_LABEL" = "ga" ] && [ "$PREV_MM" != "$CURR_MM" ]; then
      # GA-to-GA cross-major: discover latest available version for the current line
      IS_RELEASE_TO_RELEASE=true
      echo "GA-to-GA cross-major comparison: probing for latest ${CURR_MM} on dotnet-public..."

      latest=$(probe_latest_version "$CURR_MM") || true
      if [ -n "$latest" ]; then
        echo "Latest ${CURR_MM} version on dotnet-public: $latest"
        if [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+-(preview|rc)\.([0-9]+) ]]; then
          CURR_EFFECTIVE_LABEL="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
          PARAMS+=("-CurrentPrereleaseLabel" "$CURR_EFFECTIVE_LABEL")
          echo "Resolved current to prerelease: $CURR_EFFECTIVE_LABEL"
        else
          echo "Resolved current to GA: $latest"
          # No prerelease param needed
        fi
      else
        echo "::warning::Could not probe latest version for ${CURR_MM} — will try script with GA params"
      fi
    fi
    # else: single-major GA comparison — just omit prerelease label
  else
    PARAMS+=("-CurrentPrereleaseLabel" "$CURR_LABEL")
  fi
fi

# ── compute descriptive names for metadata ───────────────────────────────────

PREV_DESC=$(friendly_name "$PREV_MM" "$PREV_LABEL")
CURR_DESC=$(friendly_name "$CURR_MM" "$CURR_EFFECTIVE_LABEL")

if [ "$has_all" = true ]; then
  BRANCH_NAME="api-diff/$(branch_segment "$PREV_MM" "$PREV_LABEL")_$(branch_segment "$CURR_MM" "$CURR_LABEL")"
  if [ "$IS_RELEASE_TO_RELEASE" = true ]; then
    PR_TITLE="$PREV_DESC -> $(friendly_name "$CURR_MM" "ga")"
  else
    PR_TITLE="$PREV_DESC -> $CURR_DESC"
  fi
else
  BRANCH_NAME=""
  PR_TITLE=""
fi

# ── run the script ───────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  Previous: $PREV_DESC"
echo "  Current:  $CURR_DESC"
echo "  Params:   ${PARAMS[*]}"
echo "============================================"
echo ""

script_exit=0
pwsh -File ./release-notes/RunApiDiff.ps1 "${PARAMS[@]}" 2>&1 || script_exit=$?

# ── feed fallback for preview-to-preview ─────────────────────────────────────

if [ "$script_exit" -ne 0 ] && [ "$has_all" = true ] && [ "$CURR_EFFECTIVE_LABEL" != "ga" ]; then
  MAJOR="${CURR_MM%%.*}"
  FALLBACK_FEED="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet${MAJOR}/nuget/v3/index.json"
  echo ""
  echo "::warning::Default feed failed (exit $script_exit). Retrying with dotnet${MAJOR} feed..."
  echo ""

  PARAMS_RETRY=("${PARAMS[@]}" "-PreviousNuGetFeed" "$FALLBACK_FEED" "-CurrentNuGetFeed" "$FALLBACK_FEED")
  script_exit=0
  pwsh -File ./release-notes/RunApiDiff.ps1 "${PARAMS_RETRY[@]}" 2>&1 || script_exit=$?

  if [ "$script_exit" -eq 0 ]; then
    FEED_USED="dotnet${MAJOR}"
  fi
fi

# ── feed fallback for inferred runs ──────────────────────────────────────────

if [ "$script_exit" -ne 0 ] && [ "$has_all" = false ]; then
  # For inferred runs: try to discover the next comparison and retry with
  # the release-specific feed for the discovered major version.
  echo ""
  echo "::warning::Inferred run failed (exit $script_exit). Attempting to discover target and retry with release feed..."

  # Find latest api-diff folder to guess the target major version
  latest_version_dir=$(find ./release-notes -maxdepth 1 -type d -name '[0-9]*.[0-9]*' | sort -V | tail -1)
  if [ -n "$latest_version_dir" ]; then
    MAJOR=$(basename "$latest_version_dir" | cut -d. -f1)
    NEXT_MAJOR=$((MAJOR + 1))

    # Try current major first, then next major
    for try_major in "$MAJOR" "$NEXT_MAJOR"; do
      FALLBACK_FEED="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet${try_major}/nuget/v3/index.json"
      echo "Trying dotnet${try_major} feed..."
      script_exit=0
      pwsh -File ./release-notes/RunApiDiff.ps1 -InstallApiDiff -PreviousNuGetFeed "$FALLBACK_FEED" -CurrentNuGetFeed "$FALLBACK_FEED" 2>&1 || script_exit=$?
      if [ "$script_exit" -eq 0 ]; then
        FEED_USED="dotnet${try_major}"
        break
      fi
    done
  fi
fi

# ── write metadata ───────────────────────────────────────────────────────────

if [ "$script_exit" -ne 0 ]; then
  write_metadata "failed" \
    "RunApiDiff.ps1 exited with code $script_exit" \
    "$PREV_DESC" "$CURR_DESC" "$IS_RELEASE_TO_RELEASE" "$FEED_USED" "$BRANCH_NAME" "$PR_TITLE" \
    "$([ "$has_all" = true ] && echo true || echo false)"
else
  write_metadata "success" "" \
    "$PREV_DESC" "$CURR_DESC" "$IS_RELEASE_TO_RELEASE" "$FEED_USED" "$BRANCH_NAME" "$PR_TITLE" \
    "$([ "$has_all" = true ] && echo true || echo false)"
fi

exit 0
