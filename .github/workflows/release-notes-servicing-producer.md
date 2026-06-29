---
if: (!github.event.repository.fork) || github.event_name == 'workflow_dispatch'

permissions:
  actions: read
  contents: read
  pull-requests: read
  issues: read

runtimes:
  dotnet:
    version: "11.0"
network:
  allowed:
    - defaults
    - dotnet
safe-outputs:
  add-comment:
    max: 20
    target: "*"
tools:
  bash:
    - gh
    - git
    - jq
    - mkdir
    - cp
    - mv
    - rm
    - chmod
    - cat
    - ls
    - pwd
    - echo
    - grep
    - sort
    - uniq
    - head
    - tail
    - wc
timeout-minutes: 120

on:
  permissions: {}
  workflow_dispatch:
    inputs:
      target:
        description: "Single discovery target (JSON) from release-notes-discover.sh."
        required: true
        type: string
      milestone:
        description: "Optional milestone override (rc1, ga) for phase-boundary transitions."
        required: false
        type: string
  workflow_call:
    inputs:
      target:
        description: "Single discovery target (JSON) from release-notes-discover.sh."
        required: true
        type: string
      milestone:
        description: "Optional milestone override (rc1, ga) for phase-boundary transitions."
        required: false
        type: string

steps:
  - name: Preload servicing fix candidates from constituent repos
    shell: bash
    env:
      TARGET: ${{ inputs.target }}
      GH_TOKEN: ${{ github.token }}
    run: |
      set -euo pipefail
      bash .github/scripts/release-notes-servicing-preload.sh

post-steps:
  - name: Translate publish manifests to publish-items.json
    run: |
      set -euo pipefail
      manifest_dir=/tmp/gh-aw/agent/publish
      prs_json=/tmp/gh-aw/agent/release-notes-prs.json
      items_file=/tmp/gh-aw/agent/publish-items.json

      mkdir -p /tmp/gh-aw/agent

      # Build a standalone publish-items.json consumed by the
      # publish_release_notes job. We deliberately do NOT touch the gh-aw
      # safe-output files (outputs.jsonl / agent_output.json): outputs.jsonl is
      # owned by the sandbox user (truncating it fails with permission denied)
      # and agent_output.json is integrity-checked by gh-aw. PR/branch
      # publishing is handled entirely by the custom publish_release_notes job;
      # gh-aw native create-pull-request is intentionally not declared, so no
      # competing hash-suffixed branches are created.
      echo '{"items":[]}' > "$items_file"

      if [ ! -d "$manifest_dir" ]; then
        echo "No publish manifests were written"
        exit 0
      fi

      shopt -s nullglob
      manifests=("$manifest_dir"/*.json)
      if [ ${#manifests[@]} -eq 0 ]; then
        echo "No publish manifests were written"
        exit 0
      fi

      # append_item <json-object>
      # Appends a JSON object to publish-items.json's .items array, which the
      # publish_release_notes job consumes from the uploaded agent artifact.
      append_item() {
        local item_json="$1"
        local tmp
        tmp=$(mktemp)
        jq --argjson item "$item_json" '.items += [$item]' "$items_file" > "$tmp"
        mv "$tmp" "$items_file"
      }

      for manifest in "${manifests[@]}"; do
        branch=$(jq -r '.branch // empty' "$manifest")
        title=$(jq -r '.title // empty' "$manifest")
        body=$(jq -r '.body // empty' "$manifest")
        comment=$(jq -r '.comment // empty' "$manifest")

        if [ -z "$branch" ]; then
          echo "Publish manifest is missing branch: $manifest" >&2
          exit 1
        fi

        # Determine source of the branch content. Three cases:
        #   1. local branch exists      -> bundle from local, push to origin
        #   2. only origin/<branch>     -> branch is already on origin, no
        #                                  push needed; just open PR if missing
        #   3. neither exists           -> hard error
        bundle_path=""
        remote_only="false"
        if git show-ref --verify --quiet "refs/heads/$branch"; then
          safe_branch=$(printf '%s' "$branch" | tr '/[:space:]' '__')
          bundle_path="/tmp/gh-aw/aw-${safe_branch}.bundle"
          rm -f "$bundle_path"
          git bundle create "$bundle_path" "refs/heads/$branch"
        elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          echo "Branch $branch only exists on origin; will open PR without pushing"
          remote_only="true"
        else
          echo "Publish manifest references unknown branch (no local or remote): $branch" >&2
          exit 1
        fi

        open_pr=$(jq -c --arg branch "$branch" '[.[] | select(.headRefName == $branch and .state == "OPEN")] | first' "$prs_json")
        non_open_pr=$(jq -c --arg branch "$branch" '[.[] | select(.headRefName == $branch and .state != "OPEN")] | first' "$prs_json")

        if [ "$open_pr" != "null" ]; then
          pr_number=$(jq -r '.number' <<<"$open_pr")
          ahead_count=$(git rev-list --count "origin/$branch..$branch" 2>/dev/null || echo 0)

          if [ "$ahead_count" -gt 0 ]; then
            push_item=$(jq -cn \
              --arg branch "$branch" \
              --arg bundle_path "$bundle_path" \
              --arg message "${comment:-Updated release notes content.}" \
              --argjson pull_request_number "$pr_number" \
              '{
                type: "push_to_pull_request_branch",
                branch: $branch,
                bundle_path: $bundle_path,
                message: $message,
                pull_request_number: $pull_request_number
              }')
            append_item "$push_item"
          fi

          # Always refresh the PR body+title so the live checklist and reference
          # codefence stay current even when no branch commits changed.
          if [ -n "$body" ] || [ -n "$title" ]; then
            edit_item=$(jq -cn \
              --arg title "$title" \
              --arg body "$body" \
              --argjson pull_request_number "$pr_number" \
              '{
                type: "update_pr_body",
                title: $title,
                body: $body,
                pull_request_number: $pull_request_number
              }')
            append_item "$edit_item"
          fi

          if [ -n "$comment" ]; then
            comment_item=$(jq -cn \
              --arg body "$comment" \
              --argjson item_number "$pr_number" \
              '{
                type: "add_comment",
                body: $body,
                item_number: $item_number
              }')
            append_item "$comment_item"
          fi

          continue
        fi

        if [ "$non_open_pr" != "null" ]; then
          state=$(jq -r '.state' <<<"$non_open_pr")
          echo "::warning::Skipping $branch: a non-open PR already exists ($state); not creating a replacement" >&2
          continue
        fi

        if [ -z "$title" ] || [ -z "$body" ]; then
          echo "New PR manifest must include title and body: $manifest" >&2
          exit 1
        fi

        create_item=$(jq -cn \
          --arg branch "$branch" \
          --arg bundle_path "$bundle_path" \
          --arg title "$title" \
          --arg body "$body" \
          --argjson remote_only "$remote_only" \
          '{
            type: "create_pull_request",
            branch: $branch,
            bundle_path: $bundle_path,
            title: $title,
            body: $body,
            remote_only: $remote_only
          }')
        append_item "$create_item"
      done
jobs:
  publish_release_notes:
    name: Publish release-notes branches
    needs: [agent, activation]
    if: always() && needs.agent.result == 'success'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
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
          # gh-aw prefixes artifact names (non-empty in workflow_call mode) to
          # avoid matrix collisions; match the prefix used by the agent upload.
          name: ${{ needs.activation.outputs.artifact_prefix }}agent
          path: /tmp/gh-aw/

      - name: Configure git identity
        run: |
          git config --global user.email "github-actions[bot]@users.noreply.github.com"
          git config --global user.name "github-actions[bot]"

      - name: Publish PRs from agent output
        env:
          # Requires repo Settings → Actions → General →
          # "Allow GitHub Actions to create and approve pull requests" to be on.
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          agent_output=/tmp/gh-aw/agent/publish-items.json
          if [ ! -f "$agent_output" ]; then
            echo "::notice::No publish-items.json produced by the agent post-step — nothing to publish"
            exit 0
          fi
          items_count=$(jq '.items | length' "$agent_output")
          if [ "$items_count" -eq 0 ]; then
            echo "::notice::publish-items.json contained 0 items — nothing to publish"
            exit 0
          fi
          echo "Publishing $items_count item(s) from publish-items.json"

          # Bundles produced by the agent post-step are uploaded with absolute
          # paths under /tmp/gh-aw/. The download artifact extracts them to
          # /tmp/gh-aw/<basename>, so resolve by basename.
          resolve_bundle() {
            local bundle_path="$1"
            local local_path="/tmp/gh-aw/$(basename "$bundle_path")"
            if [ ! -f "$local_path" ]; then
              echo "::error::Bundle file not found in artifact: $local_path (manifest path was $bundle_path)" >&2
              return 1
            fi
            printf '%s' "$local_path"
          }

          # The job is intentionally branches-only. We don't call `gh pr
          # create` because that would require enabling the repo-level
          # "Allow GitHub Actions to create and approve pull requests"
          # setting, which also grants approval power. Instead, push the
          # branch and surface a one-click "compare" URL that a human can
          # use to open the PR.
          repo_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"

          # Emit a Markdown summary header for branch links.
          summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
          {
            echo "## Release notes branches published"
            echo ""
            echo "Open a PR for any of these from the link below:"
            echo ""
          } >> "$summary"

          # Track whether any branch was rejected by the markdownlint gate
          # so we can fail the run after processing all items.
          lint_failed=0

          # Source the shared prep helpers (setup_toc_tool, regenerate_tocs,
          # normalize_markdown_files, lint_branch). Keeping these in
          # .github/scripts/ rather than inline here means the same TOC
          # algorithm and tier-1 normalizer are used by both this publish
          # step and the fix-release-notes-lint workflow, so they cannot
          # drift.
          source "$GITHUB_WORKSPACE/.github/scripts/release-notes-publish-prep.sh"
          setup_toc_tool

          for i in $(seq 0 $((items_count - 1))); do
            item=$(jq -c ".items[$i]" "$agent_output")
            type=$(jq -r '.type' <<<"$item")
            case "$type" in
              create_pull_request)
                branch=$(jq -r '.branch' <<<"$item")
                title=$(jq -r '.title' <<<"$item")
                bundle=$(jq -r '.bundle_path // empty' <<<"$item")
                remote_only=$(jq -r '.remote_only // false' <<<"$item")
                body=$(jq -r '.body // empty' <<<"$item")
                echo "→ create_pull_request branch=$branch remote_only=$remote_only"

                if [ "$remote_only" = "true" ]; then
                  echo "  branch already on origin — skipping push"
                else
                  bundle_local=$(resolve_bundle "$bundle")
                  git fetch "$bundle_local" "+refs/heads/$branch:refs/heads/$branch"

                  # Rebase the agent's commits onto the CURRENT origin/main so
                  # the branch tree's `.github/workflows/` matches main. The
                  # workflow token lacks the `workflows: write` scope; GitHub
                  # rejects any push from a GitHub App where the branch's
                  # workflow tree differs from the default branch, even when
                  # the new commits don't touch workflow files. This happens
                  # whenever main moves forward (e.g., workflow edits land)
                  # while the agent is running — the agent's worktree was
                  # forked from an older main snapshot.
                  if ! git rebase origin/main "$branch"; then
                    git rebase --abort 2>/dev/null || true
                    echo "::error::Could not rebase $branch onto current origin/main"
                    echo "- ❌ \`$branch\` — push blocked: rebase conflict" >> "$summary"
                    lint_failed=1
                    continue
                  fi

                  # Rebase succeeded; run the tier-1 markdown normalizer
                  # on changed files: regenerates TOCs between markers,
                  # rewrites broken `#anchor` fragments (MD051), adds a
                  # language to bare code fences (MD040), then runs
                  # `markdownlint --fix` for the remaining auto-fixable
                  # rules. Amends the tip commit if anything changed.
                  normalize_markdown_files "$branch"

                  # Hard placement guard: refuse to push a branch whose files
                  # violate the features/component placement invariants
                  # (see release-notes.README.md). Runs after the normalizer's
                  # self-healing prune so only genuinely misplaced files fail.
                  if ! validate_branch_placement "$branch"; then
                    echo "::error::Placement violations on $branch — refusing to push. See log above."
                    echo "- ❌ \`$branch\` — push blocked: placement violations" >> "$summary"
                    lint_failed=1
                    continue
                  fi

                  # Lint the files this branch added or modified vs origin/main.
                  # markdownlint validates the whole file, not just the diff,
                  # so this catches structural problems anywhere in any file
                  # the agent wrote on this branch. If the gate fails, only
                  # this branch is blocked — other branches in the run still
                  # publish if their own files lint clean.
                  md_files=$(git diff --name-only "origin/main...$branch" -- '*.md' 2>/dev/null || true)
                  if [ -n "$md_files" ]; then
                    lint_dir=$(mktemp -d)
                    while IFS= read -r md_path; do
                      [ -z "$md_path" ] && continue
                      mkdir -p "$lint_dir/$(dirname "$md_path")"
                      git show "$branch:$md_path" > "$lint_dir/$md_path"
                    done <<< "$md_files"
                    if ! npx --yes markdownlint-cli --config .github/linters/.markdown-lint.yml "$lint_dir" 2>&1 | tee -a "$summary"; then
                      echo "::error::Markdownlint violations on $branch — refusing to push. See log above."
                      echo "- ❌ \`$branch\` — push blocked: markdownlint violations" >> "$summary"
                      rm -rf "$lint_dir"
                      lint_failed=1
                      continue
                    fi
                    rm -rf "$lint_dir"
                  fi

                  git push origin "refs/heads/$branch:refs/heads/$branch" --force-with-lease
                fi

                # If an open PR already exists for this branch, the push above
                # updated it. Otherwise open a NEW draft PR on this exact
                # branch. PRs are always created as drafts; a human flips them
                # to Ready for Review to take over (the automation never merges
                # and never marks Ready).
                existing=$(gh pr list --head "$branch" --state open --json number,url --jq '.[0]')
                if [ -n "$existing" ] && [ "$existing" != "null" ]; then
                  url=$(jq -r '.url' <<<"$existing")
                  num=$(jq -r '.number' <<<"$existing")
                  echo "::notice::Branch $branch updated; existing PR #$num: $url"
                  echo "- ✅ \`$branch\` — existing PR [#$num]($url) updated" >> "$summary"
                else
                  pr_body="${body:-Draft release notes for \`$branch\`.}"
                  if pr_url=$(gh pr create --draft --base main --head "$branch" \
                       --title "$title" --body "$pr_body" 2>&1); then
                    echo "::notice::Opened draft PR for $branch: $pr_url"
                    echo "- 🟢 \`$branch\` — opened draft PR $pr_url" >> "$summary"
                  else
                    # Fall back to a compare URL if PR creation is not permitted
                    # (e.g. the repo setting "Allow GitHub Actions to create and
                    # approve pull requests" is off). The branch is still pushed.
                    echo "::warning::Could not open PR for $branch ($pr_url); emitting compare URL"
                    compare="${repo_url}/compare/main...$(printf '%s' "$branch" | sed 's,/,%2F,g')?expand=1"
                    enc_title=$(printf '%s' "$title" | jq -sRr @uri)
                    echo "- 🌱 \`$branch\` — [open a PR](${compare}&title=${enc_title})" >> "$summary"
                  fi
                fi
                ;;
              push_to_pull_request_branch)
                branch=$(jq -r '.branch' <<<"$item")
                bundle=$(jq -r '.bundle_path' <<<"$item")
                bundle_local=$(resolve_bundle "$bundle")
                pr_number=$(jq -r '.pull_request_number' <<<"$item")
                echo "→ push_to_pull_request_branch branch=$branch pr=$pr_number"
                git fetch "$bundle_local" "+refs/heads/$branch:refs/heads/$branch"

                # Rebase onto current origin/main so the branch tree's
                # .github/workflows/ matches main (see longer comment above).
                if ! git rebase origin/main "$branch"; then
                  git rebase --abort 2>/dev/null || true
                  echo "::error::Could not rebase $branch onto current origin/main"
                  echo "- ❌ \`$branch\` — push blocked: rebase conflict" >> "$summary"
                  lint_failed=1
                  continue
                fi

                # Rebase succeeded; run the tier-1 markdown normalizer
                # (TOC regen + MD040/MD051 fixes + markdownlint --fix).
                normalize_markdown_files "$branch"

                # Hard placement guard (see release-notes.README.md).
                if ! validate_branch_placement "$branch"; then
                  echo "::error::Placement violations on $branch — refusing to push. See log above."
                  echo "- ❌ \`$branch\` — push blocked: placement violations" >> "$summary"
                  lint_failed=1
                  continue
                fi

                # Hard gate: refuse to push markdown that fails markdownlint.
                # Lint the files this branch added or modified vs origin/main.
                md_files=$(git diff --name-only "origin/main...$branch" -- '*.md' 2>/dev/null || true)
                if [ -n "$md_files" ]; then
                  lint_dir=$(mktemp -d)
                  while IFS= read -r md_path; do
                    [ -z "$md_path" ] && continue
                    mkdir -p "$lint_dir/$(dirname "$md_path")"
                    git show "$branch:$md_path" > "$lint_dir/$md_path"
                  done <<< "$md_files"
                  if ! npx --yes markdownlint-cli --config .github/linters/.markdown-lint.yml "$lint_dir" 2>&1 | tee -a "$summary"; then
                    echo "::error::Markdownlint violations on $branch — refusing to push. See log above."
                    echo "- ❌ \`$branch\` — push blocked: markdownlint violations" >> "$summary"
                    rm -rf "$lint_dir"
                    lint_failed=1
                    continue
                  fi
                  rm -rf "$lint_dir"
                fi

                git push origin "refs/heads/$branch:refs/heads/$branch" --force-with-lease
                pr_url="${repo_url}/pull/${pr_number}"
                echo "- 🔁 \`$branch\` — pushed update to PR [#$pr_number]($pr_url)" >> "$summary"
                ;;
              update_pr_body)
                # Refresh the PR body/title so the live checklist and reference
                # codefence stay current (the body is PR metadata, not a file,
                # so this runs even when no branch commits changed).
                num=$(jq -r '.pull_request_number' <<<"$item")
                ubody=$(jq -r '.body // empty' <<<"$item")
                utitle=$(jq -r '.title // empty' <<<"$item")
                if [ -z "$num" ] || [ "$num" = "null" ]; then
                  echo "→ update_pr_body skipped (missing pull_request_number)"
                else
                  args=()
                  if [ -n "$ubody" ]; then args+=(--body "$ubody"); fi
                  if [ -n "$utitle" ]; then args+=(--title "$utitle"); fi
                  if [ ${#args[@]} -gt 0 ] && gh pr edit "$num" "${args[@]}" 2>&1; then
                    echo "→ update_pr_body refreshed PR #$num"
                    echo "- ✏️ refreshed PR [#$num](${repo_url}/pull/$num) body" >> "$summary"
                  else
                    echo "::warning::Could not refresh body of PR #$num"
                  fi
                fi
                ;;
              add_comment)
                # Post the update comment on the existing PR so each automated
                # update is summarized for reviewers.
                num=$(jq -r '.item_number' <<<"$item")
                cbody=$(jq -r '.body // empty' <<<"$item")
                if [ -z "$num" ] || [ "$num" = "null" ] || [ -z "$cbody" ]; then
                  echo "→ add_comment skipped (missing item_number or body)"
                elif gh pr comment "$num" --body "$cbody" 2>&1; then
                  echo "→ add_comment posted on PR #$num"
                  echo "- 💬 commented on PR [#$num](${repo_url}/pull/$num)" >> "$summary"
                else
                  echo "::warning::Could not post comment on PR #$num"
                fi
                ;;
              *)
                echo "::warning::Unknown agent_output item type: $type"
                ;;
            esac
          done

          if [ "$lint_failed" -ne 0 ]; then
            echo "::error::One or more branches were blocked by the markdownlint gate. Re-run after fixing markdown."
            exit 1
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
    # If none of the `COPILOT_PAT_#` secrets were selected, then the default COPILOT_GITHUB_TOKEN is used
    COPILOT_GITHUB_TOKEN: ${{ case(needs.pat_pool.outputs.pat_number == '0', secrets.COPILOT_PAT_0, needs.pat_pool.outputs.pat_number == '1', secrets.COPILOT_PAT_1, needs.pat_pool.outputs.pat_number == '2', secrets.COPILOT_PAT_2, needs.pat_pool.outputs.pat_number == '3', secrets.COPILOT_PAT_3, needs.pat_pool.outputs.pat_number == '4', secrets.COPILOT_PAT_4, needs.pat_pool.outputs.pat_number == '5', secrets.COPILOT_PAT_5, needs.pat_pool.outputs.pat_number == '6', secrets.COPILOT_PAT_6, needs.pat_pool.outputs.pat_number == '7', secrets.COPILOT_PAT_7, needs.pat_pool.outputs.pat_number == '8', secrets.COPILOT_PAT_8, needs.pat_pool.outputs.pat_number == '9', secrets.COPILOT_PAT_9, secrets.COPILOT_GITHUB_TOKEN) }}
    # GITHUB_TOKEN is the workflow's run-scoped token (read-only per the `permissions:` block above). `release-notes generate changes` requires it to query PR metadata against dotnet/dotnet.
    GITHUB_TOKEN: ${{ github.token }}
---

<!-- markdownlint-disable-next-line MD025 -->
# Write Servicing Release Notes

You pre-draft the **non-security notable changes** for pending .NET servicing (GA patch) releases — for example 8.0.x, 9.0.x, 10.0.x. The fixes are sourced from the **constituent repositories** (dotnet/runtime, dotnet/aspnetcore, dotnet/efcore, dotnet/sdk, dotnet/roslyn, …), gathered for you during preload. This is a **multi-master live system**: humans edit branches and leave PR comments at any time; respect their changes and feedback.

Your output is a single **consolidated draft pull request** that pre-drafts the **Notable Changes** (non-security) section for each pending patch. You never author CVE/security content, the Downloads table, or the package-version table — humans and release-day tooling own those.

## Invariants (read first; these override everything below)

- **Never merge a PR, and never mark a PR Ready for Review.** Drafts only; a human flips a PR to Ready to take it over.
- **Never author security/CVE content, the Downloads table, or the "Packages updated in this release" table.** Those are added by humans/release tooling after the embargo lifts. Pre-draft only the **non-security Notable Changes**.
- **Only document publicly-merged, user-facing fixes.** When a change's significance is unclear, omit it — a shorter, accurate list is better than a padded one.
- **Preserve human edits.** Diff before writing; never clobber human-authored content. If a patch's `.md` already has human content, integrate without overwriting.
- **Never expand scope.** Author only the in-scope servicing patches; politely defer out-of-scope requests in the manifest `comment`. **Never call the `add_comment` safe-output tool** — put any comment in the manifest `comment` field and the publish pipeline posts it.

## Preloaded context

The workflow gathered everything for you before you started. Read these first:

- `/tmp/gh-aw/agent/context-index.json` — index of the preloaded files.
- `/tmp/gh-aw/agent/target.json` — a single-element array holding the consolidated servicing target. `.[0].base_branch` is the **only** valid publish branch; `.[0].releases[]` lists the pending patches `{major, version, support_phase}`; `.[0].content_root` is the repo's release-notes root.
- `/tmp/gh-aw/agent/servicing/<version>/fixes.json` — for each pending patch, the candidate PRs merged into the constituent repos' `release/<major>.0`(+`-staging`) branches within that patch's window. Shape: `{version, major, window:{from,to}, candidate_count, candidates:[{repo, number, title, url, mergedAt, labels}]}`.
- `/tmp/gh-aw/agent/components.json` — component → constituent-repo map, for grouping fixes by area.
- `/tmp/gh-aw/agent/release-notes-prs.json`, `release-notes-branches.txt`, `pr-comments/<pr>-*.json` — existing release-notes PR/branch/comment context.

If `target.json` or the preloaded files are absent or unusable, stop before making repo changes and explain the missing prerequisite in your final response.

## What to do each run

### 1. Read the target

Read `target.json`. If `.[0].releases` is empty, exit cleanly — there is nothing to do this run. Otherwise process each pending patch in `.[0].releases[]`.

### 2. For each pending patch, draft the non-security Notable Changes

Read `/tmp/gh-aw/agent/servicing/<version>/fixes.json`.

**Filter the candidates down to genuinely notable, non-security, user-facing fixes.** The gathered list is raw and noisy. **Drop**:

- dependency updates — label `Type: Dependency Update` or titles like `Update dependencies from …`, `[release/x.y] Update dependencies …`;
- branch merges and internal flow — `Merge release/…`, `Merging internal commits …`, `[manual] Merge …`;
- branding / version bumps — `Update branding …`;
- CI / infrastructure / pipeline-only and test-only changes — `[TestOnly]`, `Disable … CI`, queue/image swaps, `area-infrastructure` changes that touch only pipelines;
- anything that is clearly a security fix — leave **all** CVE/security content to humans.

**Keep** genuine bug fixes and behavioral corrections a .NET developer would care about: crashes, regressions, correctness fixes, compatibility fixes, and performance fixes with real user impact.

Group the kept fixes by component/area (use `components.json` to map repos → areas: dotnet/runtime → Runtime/Libraries, dotnet/aspnetcore → ASP.NET Core, dotnet/efcore → EF Core, dotnet/sdk & friends → SDK, dotnet/roslyn → C#, dotnet/fsharp → F#, dotnet/winforms → Windows Forms, dotnet/wpf → WPF). Write one concise bullet per fix, linking its PR. Example draft block:

````markdown
## Notable Changes (draft — non-security)

> Draft pre-authored from constituent-repo fixes merged in the `<from>..<to>` window. Security/CVE content, the Downloads table, and the package list are added separately by humans and release tooling.

### Runtime

- Fixed `<succinct description>` ([dotnet/runtime #NNNNN](https://github.com/dotnet/runtime/pull/NNNNN)).

### ASP.NET Core

- …
````

Write or update `<content_root>/<major>/<version>/<version>.md` with **only** this draft `## Notable Changes (draft — non-security)` block (plus a short `# .NET <version>` title line if the file is new). Do **not** fabricate the Downloads table, the `## Packages updated in this release` table, CVE entries, Docker/Visual Studio sections, or link reference definitions — those are added later. If the file already exists with human-authored content, **insert or refresh only your clearly-marked draft block** and leave everything else untouched.

**Markdown discipline — the publish pipeline runs a hard `markdownlint` gate that will reject the push if the file does not lint clean.** Follow these rules exactly:

- Use **real markdown headings** for every group: `###` for a component (Runtime, ASP.NET Core, …) and `####` for any sub-grouping (JIT, GC, Interop, …). **Never** use bold text (`**JIT / CodeGen**`) as a stand-in heading — that fails rule `MD036/no-emphasis-as-heading`.
- Put a blank line **before and after** every heading, list, and blockquote (`MD022`, `MD032`, `MD031`).
- Use exactly **one** top-level `#` heading (the title); everything else is `##`/`###`/`####` (`MD025`).
- Do not leave the `## Notable Changes` heading immediately followed by text on the next line with no blank line.

Keep the structure shallow and consistent across all patches so the gate passes on the first try.

### 3. Publication manifest

All pending patches go on the **single consolidated branch** `target.base_branch` (e.g. `release-notes/servicing`). Commit your `.md` changes locally on that branch, then write exactly one manifest to `/tmp/gh-aw/agent/publish/<branch_filename>.json` (replace `/` with `-` in the branch name):

- **No PR exists for the branch yet** → manifest with `branch`, `title`, `body`. Title: `[release-notes] Servicing — <comma-separated pending versions>`. Body: summarize which patches were drafted, how many notable fixes each, any open questions, plus the reference codefence below.
- **A PR already exists** → manifest with `branch`, `title`, the **full refreshed `body`** (regenerate it every run so the reference codefence and the live checklist stay current, preserving human checklist items), and a `comment` summarizing what changed since the last run. Provide `body` on **every** run even when no `.md` files changed, so the checklist/codefence refresh.

Include in the PR body a single fenced `yaml` **reference codefence** (regenerate it each run, replacing the previous one so the description never accumulates more than one):

```yaml
release-notes-servicing-reference:
  patches:
    - version: 9.0.17          # one entry per pending patch (illustrative)
      major: "9.0"
      window: 2026-05-12..2026-06-09
      candidates: 74           # gathered candidate PRs
      notable: 6               # fixes you kept after filtering
  run_id: <github.run_id>
  run_timestamp: <ISO-8601 UTC timestamp of this run>
```

Fill the values dynamically; never hardcode a version. Publication manifests are **required** for any branch you modified; the publish job opens or updates the PR as a **draft**.

#### Live management checklist (in the PR body, idempotent)

Also include a **live checklist** in the PR body that tracks the whole servicing-release management process, delimited by HTML-comment markers so it can be refreshed in place:

```markdown
<!-- release-notes-checklist:start -->
## Servicing release checklist

Automated items are kept current by this workflow. **Human** items are owned by the team — automation never toggles them.

- [x] Draft non-security notable changes from constituent-repo fixes _(auto)_
- [ ] Incorporate PR review feedback _(auto)_
- [ ] Add the Downloads tables _(human / release tooling)_
- [ ] Add the "Packages updated in this release" tables _(human / release tooling)_
- [ ] Add CVE / security content _(human — post-embargo)_
- [ ] **Ready for Review** — team takes over the PR _(human)_
- [ ] **Merge** _(human)_
<!-- release-notes-checklist:end -->
```

Rules for the checklist (critical — get this right):

- It lives **between the `<!-- release-notes-checklist:start -->` and `<!-- release-notes-checklist:end -->` markers** in the PR body. Never drop the markers.
- **Auto items** (`_(auto)_`) — set their `[x]`/`[ ]` state from what you actually did this run (e.g. check "Draft non-security notable changes" once you have drafted them; check "Incorporate PR review feedback" only if there was feedback and you addressed it).
- **Human items** (`_(human)_`, `_(human / release tooling)_`) — when the PR already exists, **preserve their existing `[x]`/`[ ]` state exactly** from the current PR body; when first creating the PR, leave them unchecked. **Never toggle a human item yourself.**
- Keep the item wording stable run-to-run so states map across runs. Put the checklist after the reference codefence in the body.
- **Always render the complete checklist every run** — include every item even when a step is not yet applicable (leave those unchecked). Never drop an item; the checklist is a stable end-to-end process tracker.

### 3a. Read and respond to PR comments

If the consolidated servicing PR already exists, read its preloaded comments (`pr-comments/<pr>-*.json`). Apply clear, in-scope feedback on the branch and summarize your reply in the manifest `comment`. On **conflicting** feedback, favor reviewers with **write access** — use each comment/review's `author_association` (`OWNER`/`MEMBER`/`COLLABORATOR` outrank `CONTRIBUTOR`/`NONE`). Do **not** act on feedback that expands scope or asks you to author security, downloads, or package-table content.

If `target.json` or the preloaded context files are missing, stop before making repo changes and explain the missing prerequisite in your final response.
