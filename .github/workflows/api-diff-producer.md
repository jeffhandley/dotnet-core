---
name: Write API Diff
description: >
  Generate or refresh the public API diff report for a single in-flight .NET
  release milestone (incremental or major-to-major) from real published builds and
  open/update its draft pull request. Invoked per-target by the API Diff Manager
  (workflow_call) or manually (workflow_dispatch).

if: (!github.event.repository.fork) || github.event_name == 'workflow_dispatch'

permissions:
  actions: read
  contents: read
  pull-requests: read
  issues: read

network:
  allowed:
    - defaults
    - dotnet
safe-outputs:
  noop:
    report-as-issue: false
  add-comment:
    max: 5
    target: "*"
tools:
  bash:
    - pwsh
    - dotnet
    - dnx
    - gh
    - git
    - jq
    - find
    - sed
    - cp
    - mv
    - rm
    - mkdir
    - cat
    - ls
    - pwd
    - echo
    - grep
    - head
    - tail
    - wc
timeout-minutes: 90

on:
  permissions: {}
  workflow_dispatch:
    inputs:
      target:
        description: "Single discovery target (JSON) from api-diff-manager-discover.cs."
        required: true
        type: string
  workflow_call:
    inputs:
      target:
        description: "Single discovery target (JSON) from api-diff-manager-discover.cs."
        required: true
        type: string

steps:
  - name: Set up target context and generate the API diff
    shell: bash
    env:
      TARGET: ${{ inputs.target }}
      GH_TOKEN: ${{ github.token }}
      GH_RUN_ID: ${{ github.run_id }}
    run: |
      set -euo pipefail
      bash .github/scripts/api-diff-producer-setup.sh

post-steps:
  - name: Translate publish manifest to publish-items.json
    run: |
      set -euo pipefail
      manifest_dir=/tmp/gh-aw/agent/publish
      items_file=/tmp/gh-aw/agent/publish-items.json
      mkdir -p /tmp/gh-aw/agent
      echo '{"items":[]}' > "$items_file"

      if [ ! -d "$manifest_dir" ]; then
        echo "No publish manifest was written (nothing to publish)"; exit 0
      fi
      shopt -s nullglob
      manifests=("$manifest_dir"/*.json)
      if [ ${#manifests[@]} -eq 0 ]; then
        echo "No publish manifest was written (nothing to publish)"; exit 0
      fi

      # ---- Validate the agent's manifest against the host-authored target.json ----
      # The agent is instructed to echo several target.json fields verbatim; enforce that
      # here so a drifted or hallucinated manifest is rejected loudly instead of publishing
      # a PR onto the wrong branch / number / readiness or with a broken identity marker.
      tgt=/tmp/gh-aw/agent/target.json
      if [ ! -f "$tgt" ]; then
        echo "::error::target.json is missing but a publish manifest exists — refusing to publish"; exit 1
      fi
      t_produce=$(jq -r '.produce' "$tgt")
      t_branch=$(jq -r '.target_branch' "$tgt")
      t_pr=$(jq -r '.existing_pr_number // ""' "$tgt")
      t_title=$(jq -r '.pr_title' "$tgt")
      t_marker=$(jq -r '.marker' "$tgt")
      t_cur=$(jq -r '.current_version' "$tgt")
      t_genat=$(jq -r '.generated_at' "$tgt")
      t_status=$(jq -r '.status' "$tgt")
      expected_ready=false; [ "$t_status" = "code-complete" ] && expected_ready=true
      if [ "$t_produce" != "true" ]; then
        echo "::error::target.json has produce=$t_produce but the agent wrote a publish manifest — refusing to publish"; exit 1
      fi

      validate_manifest() {
        local branch="$1" pr="$2" title="$3" body="$4" ready="$5"
        [ "$branch" = "$t_branch" ] || { echo "::error::manifest branch '$branch' != target_branch '$t_branch'"; return 1; }
        [ "${pr:-}" = "$t_pr" ]     || { echo "::error::manifest pr_number '${pr:-}' != existing_pr_number '$t_pr'"; return 1; }
        [ "$title" = "$t_title" ]   || { echo "::error::manifest title != pr_title"; return 1; }
        [ "$ready" = "$expected_ready" ] || { echo "::error::manifest ready '$ready' != expected '$expected_ready' (status=$t_status)"; return 1; }
        case "$body" in *"$t_marker"*) ;; *) echo "::error::manifest body is missing the identity marker"; return 1 ;; esac
        case "$body" in *"$t_cur"*)    ;; *) echo "::error::manifest body is missing current_version"; return 1 ;; esac
        case "$body" in *"$t_genat"*)  ;; *) echo "::error::manifest body is missing generated_at"; return 1 ;; esac
        return 0
      }

      append_item() {
        local tmp; tmp=$(mktemp)
        jq --argjson item "$1" '.items += [$item]' "$items_file" > "$tmp"
        mv "$tmp" "$items_file"
      }

      for manifest in "${manifests[@]}"; do
        branch=$(jq -r '.branch // empty' "$manifest")
        title=$(jq -r '.title // empty' "$manifest")
        body=$(jq -r '.body // empty' "$manifest")
        comment=$(jq -r '.comment // empty' "$manifest")
        ready=$(jq -r '.ready // false' "$manifest")
        pr=$(jq -r '.pr_number // empty' "$manifest")

        if [ -z "$branch" ]; then
          echo "Publish manifest is missing branch: $manifest" >&2; exit 1
        fi

        if ! validate_manifest "$branch" "$pr" "$title" "$body" "$ready"; then
          echo "::error::Publish manifest failed validation against target.json: $manifest" >&2; exit 1
        fi

        bundle_path=""
        remote_only="false"
        if git show-ref --verify --quiet "refs/heads/$branch"; then
          safe_branch=$(printf '%s' "$branch" | tr '/[:space:]' '__')
          bundle_path="/tmp/gh-aw/aw-${safe_branch}.bundle"
          rm -f "$bundle_path"
          git bundle create "$bundle_path" "refs/heads/$branch"
        elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          remote_only="true"
        else
          echo "Publish manifest references unknown branch: $branch" >&2; exit 1
        fi

        if [ -n "$pr" ]; then
          # Update an existing marker PR. Emit the branch push whenever a local
          # branch was staged (bundle_path set); push_branch below rebuilds the
          # PR branch as origin/main + the api-diff delta and no-ops when the
          # delta is empty. (A `git rev-list origin/$branch..$branch` check is
          # unreliable here: the agent job's single-branch checkout has no
          # origin/$branch ref, so it always reports 0 and the push is skipped,
          # dropping feedback edits and build-advance report regenerations.)
          if [ -n "$bundle_path" ]; then
            append_item "$(jq -cn --arg branch "$branch" --arg bundle_path "$bundle_path" \
              --arg message "${comment:-Refreshed API diff.}" --argjson pr "$pr" \
              '{type:"push_to_pull_request_branch", branch:$branch, bundle_path:$bundle_path, message:$message, pull_request_number:$pr}')"
          fi
          if [ -n "$body" ] || [ -n "$title" ]; then
            append_item "$(jq -cn --arg title "$title" --arg body "$body" --argjson pr "$pr" --argjson ready "$ready" \
              '{type:"update_pr_body", title:$title, body:$body, pull_request_number:$pr, ready:$ready}')"
          fi
          if [ -n "$comment" ]; then
            append_item "$(jq -cn --arg body "$comment" --argjson n "$pr" \
              '{type:"add_comment", body:$body, item_number:$n}')"
          fi
        else
          # Open a new draft PR.
          if [ -z "$title" ] || [ -z "$body" ]; then
            echo "New PR manifest must include title and body: $manifest" >&2; exit 1
          fi
          append_item "$(jq -cn --arg branch "$branch" --arg bundle_path "$bundle_path" \
            --arg title "$title" --arg body "$body" --arg comment "$comment" \
            --argjson remote_only "$remote_only" --argjson ready "$ready" \
            '{type:"create_pull_request", branch:$branch, bundle_path:$bundle_path, title:$title, body:$body, comment:$comment, remote_only:$remote_only, ready:$ready}')"
        fi
      done

      echo "publish-items.json:"; jq '.' "$items_file"

jobs:
  publish_api_diff:
    name: Publish API diff branch
    needs: [agent, activation]
    if: always() && needs.agent.result == 'success'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      issues: write
    steps:
      - name: Checkout repository
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}
          persist-credentials: true
      - name: Download agent artifact
        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          name: ${{ needs.activation.outputs.artifact_prefix }}agent
          path: /tmp/gh-aw/
      - name: Configure git identity
        run: |
          git config --global user.email "github-actions[bot]@users.noreply.github.com"
          git config --global user.name "github-actions[bot]"
      - name: Set up Node.js for markdownlint
        # The publish job lints every generated report with markdownlint-cli and refuses
        # to push (so no PR is created/updated) on any violation. Set Node up explicitly
        # here -- rather than relying on the runner's ambient Node -- so that gate runs
        # reliably and reproducibly before any PR is created.
        uses: actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e # v6.4.0
        with:
          node-version: '24'
          package-manager-cache: false
      - name: Publish API diff PR from agent output
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          items=/tmp/gh-aw/agent/publish-items.json
          if [ ! -f "$items" ]; then
            echo "::notice::No publish-items.json — nothing to publish"; exit 0
          fi
          count=$(jq '.items | length' "$items")
          if [ "$count" -eq 0 ]; then
            echo "::notice::publish-items.json had 0 items — nothing to publish"; exit 0
          fi
          publish_failed=0
          failed_prs=" "
          lint_dirty_prs=" "

          # Prepended to a PR description when markdownlint reported violations that --fix
          # could not resolve. The reports are still published (see push_branch) so the diff
          # is visible and progresses; this note explains that the repo's markdown-lint CI
          # check is expected to fail on the PR until a team member resolves the violations.
          with_lint_note() {
            printf '> [!NOTE]\n> Markdownlint found issues in the generated API diff reports that could not be auto-fixed,\n> so the reports were published as-is. The **markdown-lint CI check will fail** on this PR\n> until a team member resolves the flagged violations.\n\n%s' "$1"
          }

          resolve_bundle() {
            local p="/tmp/gh-aw/$(basename "$1")"
            [ -f "$p" ] || { echo "::error::Bundle not found: $p" >&2; return 1; }
            printf '%s' "$p"
          }

          # Our automation PRs are tagged `automation` + `api-diff`; the setup step finds
          # them again by the `api-diff` label. Ensure both labels exist (idempotent) and
          # apply them without ever failing the publish if labeling is denied.
          ensure_labels() {
            gh label create automation --color ededed --description "Automated PR" 2>/dev/null || true
            gh label create api-diff --color 1d76db --description "Public API diff report" 2>/dev/null || true
          }
          apply_labels() {
            gh pr edit "$1" --add-label automation --add-label api-diff 2>/dev/null \
              || echo "::warning::could not apply automation/api-diff labels to PR #$1"
          }
          ensure_labels

          mark_ready_if_requested() {
            local num="$1" ready="$2" is_draft
            [ "$ready" = "true" ] || return 0
            is_draft=$(gh pr view "$num" --json isDraft -q '.isDraft' 2>/dev/null || echo false)
            if [ "$is_draft" = "true" ]; then
              if gh pr ready "$num"; then
                echo "::notice::PR #$num marked Ready for Review (code complete)"
              else
                echo "::warning::could not mark PR #$num ready; will retry next run"
              fi
            fi
            # Never propagate a non-zero status (e.g. a transient `gh pr ready` failure)
            # to the caller under `set -e`.
            return 0
          }

          push_branch() {
            local branch="$1" bundle="$2" files disallowed changed md allow
            lint_violation=0
            local bundle_local; bundle_local=$(resolve_bundle "$bundle")
            git fetch "$bundle_local" "+refs/heads/$branch:refs/remotes/aw-bundle/$branch"
            # File allowlist: an api-diff branch may only touch api-diff reports in the
            # expected folders plus the two global ApiDiff*ToExclude.txt files. Scope to
            # release-notes/ so unrelated files inherited from main are never considered
            # (they always come from origin/main below); reject any other release-notes file.
            allow='^release-notes/[0-9]+\.[0-9]+/(preview/[^/]+|[0-9]+\.[0-9]+\.0)/api-diff/.*\.md$|^release-notes/ApiDiff(Attributes|Assemblies)ToExclude\.txt$'
            files=$(git diff --name-only origin/main "refs/remotes/aw-bundle/$branch" -- release-notes/ || true)
            if [ -z "$files" ]; then
              echo "::notice::$branch has no changes vs origin/main; nothing to push"; return 0
            fi
            disallowed=$(grep -vE "$allow" <<<"$files" || true)
            if [ -n "$disallowed" ]; then
              echo "::error::$branch touches files outside the api-diff allowlist — refusing to push:"
              printf '%s\n' "$disallowed"
              return 1
            fi
            # Rebuild the branch as current origin/main + only the allowed-file delta.
            # This keeps the PR current with main and is robust to main moving (no rebase
            # conflicts), and naturally drops reports the agent removed this run.
            git checkout -B "$branch" origin/main
            if ! git diff origin/main "refs/remotes/aw-bundle/$branch" -- release-notes/ | git apply --index --whitespace=nowarn; then
              echo "::error::Could not apply the api-diff delta onto origin/main for $branch"; return 1
            fi
            # Capture the report markdown just added/modified (exclude deletions, which must
            # not be linted) for the verification pass below, then commit the generated
            # reports as their OWN commit -- before any markdownlint normalization -- so the
            # api-diff content is a distinct, reviewable change.
            changed=$(git diff --cached --diff-filter=ACMR --name-only -- '*.md' 2>/dev/null || true)
            git diff --cached --quiet && { echo "::notice::$branch delta is empty; nothing to push"; return 0; }
            git commit -qm "API diff: $branch"
            # Verify markdown and apply fixes as a SEPARATE commit. markdownlint --fix resolves
            # what it can (collapsing blank-line runs via cat -s, trailing whitespace, list
            # markers, ...); committing those fixes on their own makes it clear, on the PR, that
            # the generated reports needed separate markdownlint resolution. Pin markdownlint-cli
            # so the gate is reproducible.
            if [ -n "$changed" ]; then
              while IFS= read -r md; do
                [ -f "$md" ] || continue
                cat -s "$md" > "$md.sq" && mv "$md.sq" "$md"
                npx --yes markdownlint-cli@0.49.0 --config .github/linters/.markdown-lint.yml --fix "$md" >/dev/null 2>&1 || true
              done <<< "$changed"
              if ! git diff --quiet -- release-notes/; then
                git add -A release-notes/
                git commit -qm "Apply markdownlint fixes to API diff reports"
              fi
              # Re-verify. A violation --fix could not resolve does NOT block publishing: push
              # the reports anyway so the PR is still created/updated and progress stays visible.
              # The repo's markdown-lint CI check will fail on the PR, and a team member resolves
              # the remaining violations. Signal lint_violation so the caller adds a [!NOTE] to
              # the PR description explaining the expected CI failure.
              if ! printf '%s\n' "$changed" | xargs npx --yes markdownlint-cli@0.49.0 --config .github/linters/.markdown-lint.yml; then
                lint_violation=1
                echo "::warning::Markdownlint violations remain on $branch after --fix; publishing anyway (markdown-lint CI will fail for a team member to resolve). A note will be added to the PR description."
              fi
            fi
            git push origin "refs/heads/$branch:refs/heads/$branch" --force-with-lease
          }

          for i in $(seq 0 $((count - 1))); do
            item=$(jq -c ".items[$i]" "$items")
            type=$(jq -r '.type' <<<"$item")
            lint_violation=0
            case "$type" in
              create_pull_request)
                branch=$(jq -r '.branch' <<<"$item")
                title=$(jq -r '.title' <<<"$item")
                body=$(jq -r '.body // empty' <<<"$item")
                comment=$(jq -r '.comment // empty' <<<"$item")
                ready=$(jq -r '.ready // false' <<<"$item")
                remote_only=$(jq -r '.remote_only // false' <<<"$item")
                bundle=$(jq -r '.bundle_path // empty' <<<"$item")
                echo "→ create_pull_request branch=$branch ready=$ready"
                if [ "$remote_only" != "true" ]; then
                  if ! push_branch "$branch" "$bundle"; then publish_failed=1; continue; fi
                fi
                # A markdownlint violation that --fix could not resolve does not block the PR;
                # prepend the explanatory note so the description reflects that CI will fail.
                if [ "${lint_violation:-0}" = "1" ]; then body="$(with_lint_note "$body")"; fi
                existing=$(gh pr list --head "$branch" --base main --state open --json number --jq '.[0].number')
                if [ -n "$existing" ] && [ "$existing" != "null" ]; then
                  num="$existing"
                  echo "::notice::Branch $branch already has PR #$num; refreshing"
                  [ -n "$body" ] && gh pr edit "$num" --title "$title" --body "$body" || true
                else
                  num=$(gh pr create --draft --base main --head "$branch" --title "$title" --body "$body" --json number -q '.number' 2>/dev/null \
                    || { gh pr create --draft --base main --head "$branch" --title "$title" --body "$body" >/dev/null && gh pr list --head "$branch" --base main --state open --json number -q '.[0].number'; }) || true
                  if [ -z "$num" ] || [ "$num" = "null" ]; then
                    echo "::error::Failed to create PR for $branch"
                    publish_failed=1
                    continue
                  fi
                  echo "::notice::Opened draft PR #$num for $branch"
                fi
                apply_labels "$num"
                [ -n "$comment" ] && gh pr comment "$num" --body "$comment" || true
                mark_ready_if_requested "$num" "$ready"
                ;;
              push_to_pull_request_branch)
                branch=$(jq -r '.branch' <<<"$item")
                bundle=$(jq -r '.bundle_path' <<<"$item")
                pr=$(jq -r '.pull_request_number // empty' <<<"$item")
                # If the branch push fails, record the PR so its body update + comment are
                # skipped below — that keeps the body's generated_at marker from advancing,
                # so the unprocessed feedback is retried (not silently dropped) next run.
                if push_branch "$branch" "$bundle"; then
                  # Push succeeded; if reports still fail markdownlint, remember this PR so the
                  # matching body refresh below prepends the [!NOTE] about the expected CI failure.
                  if [ "${lint_violation:-0}" = "1" ] && [ -n "$pr" ]; then lint_dirty_prs="${lint_dirty_prs}${pr} "; fi
                else
                  publish_failed=1
                  [ -n "$pr" ] && failed_prs="${failed_prs}${pr} "
                fi
                ;;
              update_pr_body)
                num=$(jq -r '.pull_request_number' <<<"$item")
                case "$failed_prs" in *" $num "*)
                  echo "::warning::Skipping body update for #$num — its branch push failed."; continue ;;
                esac
                title=$(jq -r '.title // empty' <<<"$item")
                body=$(jq -r '.body // empty' <<<"$item")
                ready=$(jq -r '.ready // false' <<<"$item")
                # Refresh the description to the CURRENT state on every update. If this run's
                # reports still fail markdownlint, prepend the [!NOTE]; because the agent
                # regenerates the body from target.json each run, the note is re-evaluated and
                # naturally disappears again once a clean run refreshes the description without it.
                case "$lint_dirty_prs" in *" $num "*) body="$(with_lint_note "$body")" ;; esac
                if [ -n "$body" ]; then
                  if [ -n "$title" ]; then
                    gh pr edit "$num" --title "$title" --body "$body" || echo "::warning::could not update PR #$num title/body; will retry next run"
                  else
                    gh pr edit "$num" --body "$body" || echo "::warning::could not update PR #$num body; will retry next run"
                  fi
                fi
                apply_labels "$num"
                mark_ready_if_requested "$num" "$ready"
                ;;
              add_comment)
                num=$(jq -r '.item_number' <<<"$item")
                case "$failed_prs" in *" $num "*)
                  echo "::warning::Skipping comment for #$num — its branch push failed."; continue ;;
                esac
                body=$(jq -r '.body' <<<"$item")
                gh pr comment "$num" --body "$body"
                ;;
            esac
          done

          if [ "$publish_failed" -ne 0 ]; then
            echo "::error::One or more api-diff branch pushes failed (see above)."; exit 1
          fi

# ###############################################################
# Override COPILOT_GITHUB_TOKEN with a random PAT from the pool.
# This stop-gap will be removed when org billing is available.
# See: .github/workflows/shared/pat_pool.README.md for more info.
# ###############################################################
imports:
  - shared/pat_pool.md

environment: copilot-pat-pool

engine:
  id: copilot
  version: "1.0.60"
  env:
    # We cannot use line breaks in this expression as it leads to a syntax error in the compiled workflow
    COPILOT_GITHUB_TOKEN: ${{ case(needs.pat_pool.outputs.pat_number == '0', secrets.COPILOT_PAT_0, needs.pat_pool.outputs.pat_number == '1', secrets.COPILOT_PAT_1, needs.pat_pool.outputs.pat_number == '2', secrets.COPILOT_PAT_2, needs.pat_pool.outputs.pat_number == '3', secrets.COPILOT_PAT_3, needs.pat_pool.outputs.pat_number == '4', secrets.COPILOT_PAT_4, needs.pat_pool.outputs.pat_number == '5', secrets.COPILOT_PAT_5, needs.pat_pool.outputs.pat_number == '6', secrets.COPILOT_PAT_6, needs.pat_pool.outputs.pat_number == '7', secrets.COPILOT_PAT_7, needs.pat_pool.outputs.pat_number == '8', secrets.COPILOT_PAT_8, needs.pat_pool.outputs.pat_number == '9', secrets.COPILOT_PAT_9, secrets.COPILOT_GITHUB_TOKEN) }}
    GITHUB_TOKEN: ${{ github.token }}
---

<!-- markdownlint-disable-next-line MD025 -->
# Write API Diff

You maintain a **public API diff report** for one in-flight .NET release diff in this
repository (dotnet/core). The report is factual: the `api-diff` skill's `RunApiDiff.ps1`
already generated it during setup from **real published builds** and staged it into the
working tree. Your job is to publish it as a pull request and keep its description
accurate — not to author prose. **Never merge**; humans merge.

## 1. Read your context

Read `/tmp/gh-aw/agent/target.json`:

- `track` — `incremental` (milestone-over-milestone) or `major-to-major` (cumulative vs prior major)
- `major`, `previous_version_milestone`, `current_version_milestone` — the diff identity (e.g. `11.0`, `10.0-ga`, `11.0-preview.7`)
- `previous_version`/`previous_feed`, `current_version`/`current_feed` — exact build versions + feeds
- `status` — `in-development` (PR stays DRAFT) or `code-complete` (PR is Ready for Review)
- `content_dir` — where the generated reports live
- `temporary_attributes_file` — the per-report `ApiDiffAttributesToExclude.txt` (temporary, diff-scoped)
- `permanent_attributes_file` — the global `release-notes/ApiDiffAttributesToExclude.txt`
- `permanent_assemblies_file` — the global `release-notes/ApiDiffAssembliesToExclude.txt`
- `marker`, `pr_title`, `tldr`, `status_note` — PR identity + description pieces (use verbatim)
- `target_branch` — the branch you publish to (already resolved, including any collision suffix)
- `existing_pr_number` — the open PR to update (empty = open a new one). Treat it as yours and
  (re)write the identity marker into its body on this refresh.
- `produce` — **if `false`, STOP: write no manifest and open no PR**
- `noop` — **if `true`, STOP: nothing changed (build unchanged, same status); write no manifest and post no comment**
- `metadata_only` — the build is unchanged but the status flipped (draft→Ready). **Do
  not regenerate reports** (the staged reports are already correct); only refresh the
  body (advancing `generated_at`), flip draft→Ready if `status` is `code-complete`, and
  publish — even when no report file changed.
- `blocked` — a human already owns this diff (a non-automation `api-diff` PR touches this content).
  Treated as a no-op: do nothing.
- `generated_at` — this run's report-generation timestamp, captured before generation began. Stamp it
  into the PR body's yaml block; the manifest validation checks the refreshed body carries this exact value.
- `report_count`, `temp_excluded_attributes`

**If `produce` is `false` or `noop` is `true`, do nothing**: write no manifest, open/disturb no PR,
post no comment. A no-op is the typical scheduled outcome and must be silent.

## 2. Stage the branch — allowed files only

You may add/modify **only** these paths (the publish job rejects anything else):

- the api-diff reports under `content_dir` (and, **only when temporary attribute exclusions
  apply this run**, the per-report `ApiDiffAttributesToExclude.txt` -- never commit an empty one)
- `release-notes/ApiDiffAttributesToExclude.txt`
- `release-notes/ApiDiffAssembliesToExclude.txt`

```bash
git fetch origin main
git checkout -B "<target_branch>" "origin/<target_branch>" 2>/dev/null || git checkout -B "<target_branch>" origin/main
git add "<content_dir>" release-notes/ApiDiffAttributesToExclude.txt release-notes/ApiDiffAssembliesToExclude.txt
# No-op guard: if nothing changed vs the branch AND this is not a metadata_only refresh,
# STOP — write no manifest, post no comment. When metadata_only is true you MUST still
# publish (to flip draft→Ready and/or advance generated_at), so do NOT stop here even
# when no file changed; the manifest's body/ready update carries the change.
if [ "$(jq -r .metadata_only /tmp/gh-aw/agent/target.json)" != "true" ]; then
  git diff --cached --quiet "origin/<target_branch>" 2>/dev/null && { echo "no changes; no-op"; exit 0; }
fi
git commit -m "API diff <previous_version_milestone> -> <current_version_milestone>" 2>/dev/null || echo "no file changes to commit (metadata-only refresh)"
```

Commit only the allowed files. When `metadata_only` is `false` and `git diff --cached --quiet` shows
no change versus the existing branch, this is a no-op: **write no manifest and post no comment.** When
`metadata_only` is `true`, always continue to write the manifest (body/ready refresh) even if no report
file changed.

The publish job verifies every changed report with `markdownlint-cli` and applies `--fix` as a
**separate** commit ("Apply markdownlint fixes to API diff reports"), so the generated content and any
markdownlint resolution stay distinct on the PR. A violation `--fix` cannot resolve does **not** block
publishing: the reports are pushed and the PR is still created/updated, the publish job prepends a
`> [!NOTE]` to the description, and the repo's markdown-lint CI check fails for a team member to resolve.
You do not need to run markdownlint here; just stage the allowed files, and always write the full PR
body (see the publish manifest section below) so the description is refreshed to the current state on every update.

## 3. Write the publish manifest

Write one JSON file to `/tmp/gh-aw/agent/publish/<safe-branch>.json` (`<safe-branch>` =
`target_branch` with `/` replaced by `_`):

```json
{
  "branch": "<target_branch>",
  "pr_number": "<existing_pr_number or empty>",
  "title": "<pr_title from target.json, verbatim>",
  "body": "<the full PR description, see below>",
  "comment": "<short summary of what changed this run>",
  "ready": <true if status == code-complete, else false>
}
```

Use `pr_title` from `target.json` **verbatim** as the title (it already follows the
dotnet/core convention — e.g. `API diff between .NET 11 Preview 6 and .NET 11 Preview 7`
for incremental, or `API diff between .NET 10 and .NET 11` for major-to-major). Do not
add a milestone to a major-to-major title; the floating milestone belongs in the body.

Always write the **full** body from the current `target.json`, on every run — new PR,
report refresh, feedback application, or metadata-only/status change. The publish job
replaces the PR description with this body each update, so it must reflect the current
state (versions, `generated_at`, `report_count`, exclusions, status). Never carry over a
stale description or write a partial one.

Do **not** call the `add_comment` safe-output tool directly — the publish job posts your
`comment` deterministically.

### PR description (`body`)

**Start the body with a `> [!NOTE]` block**: the `tldr` from `target.json`, then a blank
quote line, then the `status_note` on its own line (verbatim from `target.json`):

```text
> [!NOTE]
> <tldr from target.json>
>
> <status_note from target.json>
```

Then, succinct and factual:

1. One line: what this diffs — `<previous_version_milestone>` (`previous_version`) -> `<current_version_milestone>` (`current_version`), and the track.
2. **How this was generated** — the `api-diff` skill / `RunApiDiff.ps1`; the exact
   `previous_version`@`previous_feed` and `current_version`@`current_feed`;
   `generated_at`; `report_count` files. For **major-to-major**, note
   it is the cumulative diff vs the prior major and refreshes as the head advances.
3. **Status** — `in-development` (draft while the major is still the in-development
   frontier on `main`) or `code-complete` (Ready for Review, once `main` has forked
   to the next major).
4. **Exclusions applied** — the exclusions now in effect. List **temporary attribute**
   exclusions (`temp_excluded_attributes`), and separately note any **permanent attribute** or
   **permanent assembly** exclusions in the global files. "None." only if all are empty.
5. A fenced ```yaml``` block. **The first line inside the block is the identity marker as a YAML
   comment**, verbatim from `target.json`'s `marker` (i.e. `# <marker>` — a visible comment, never an
   HTML comment: hidden markers trip content scanners). This is the stable handle the automation uses
   to find this diff's PR, so it must be present and exact:

   ```yaml
   # <marker from target.json>
   track: "<track>"
   previous-version-milestone: "<previous_version_milestone>"
   current-version-milestone: "<current_version_milestone>"
   previous-version: "<previous_version>"
   current-version: "<current_version>"
   previous-feed: "<previous_feed>"
   current-feed: "<current_feed>"
   status: "<status>"
   report-count: <report_count>
   generated-at: "<generated_at>"
   temporary-attributes-excluded: [<the per-report temporary attribute exclusions, T: form>]
   ```

   The `# <marker>`, `current-version`, and `generated-at` lines are required and machine-parsed; the
   publish job rejects a manifest whose body is missing any of them.

## Invariants

- PRs are **always created as drafts**; flip to Ready for Review only when `status` is
  `code-complete` (`"ready": true`). Never un-ready; never merge.
- `produce == false` **or** `noop == true` **or** `blocked == true` -> no manifest, no PR, no comment.
- `metadata_only == true` -> publish the body/ready refresh even when no report file changed
  (do not treat "no file change" as a no-op); do not regenerate reports.
- Add/modify **only** the allowed files (reports under `content_dir`, the per-report
  `ApiDiffAttributesToExclude.txt` **only when temporary exclusions apply**, and the two global
  `release-notes/ApiDiff*ToExclude.txt` files). One PR per diff, identified by the marker.
- The identity marker lives as a **visible YAML comment** in the body's state block — never an HTML
  comment. The publish job re-validates the manifest against `target.json` (branch, pr_number, title,
  ready, and body marker/current_version/generated_at) and rejects any drift.
