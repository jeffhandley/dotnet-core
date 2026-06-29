# Editorial Rules

Tone, attribution, and content guidelines for .NET release notes.

## Tone

- **Positive** — highlight what's new, don't dwell on what was missing
  - ✅ `ProcessExitStatus provides a unified representation of how a process terminated.`
  - ❌ `Previously, there was no way to determine how a process terminated.`
- When context about the prior state is needed, keep it brief — one clause, then pivot to the new capability
- **Don't editorialize beyond the facts** — state what concretely changed ("enabled by default", "no longer requires opt-in") rather than making claims you can't back up ("ready for production use", "signals maturity"). If a PR removes a preview attribute, say that. Don't interpret it as a promise.
  - ✅ `Runtime-async is now enabled by default for anyone targeting net11.0.`
  - ❌ `This signals that runtime-async is ready for production use.`
- **Prefer concrete deltas over inferred outcomes** — say what changed and, if useful, the direct consequence for a real scenario. Avoid claims about trust, confidence, convenience, or behavior unless the source explicitly supports them.
  - ✅ `Regex recognizes all Unicode newline sequences.`
  - ✅ `Tar extraction now rejects entries that would write outside the destination directory.`
  - ✅ `Tar extraction now rejects path traversal entries, helping applications avoid overwriting files outside the target folder.`
  - ❌ `Compression and archive handling are easier to trust.`
  - ❌ `You can extract archives without worrying about attacks.`
- **Prefer short, direct sentences** — If a sentence has a parenthetical clause (`which...`, `where...`, `that...`) longer than a few words, split it into two sentences. Lead with the news, follow with context. Long sentences are fine when they flow as a single continuous thought (what → why); they're not fine when a subordinate clause interrupts the main verb.
  - ✅ `Runtime-async is now enabled for NativeAOT. This eliminates the state-machine overhead of async/await for ahead-of-time compiled applications.`
  - ❌ `The runtime-async feature, which eliminates the state-machine overhead of async/await, is now enabled for NativeAOT.`
  - ✅ `The JIT now generates ARM64 SM4 and SHA3 instructions directly, enabling hardware-accelerated implementations on capable processors.` (long but flows — one thought)

## Familiar comparisons

- When a feature matches a workflow developers already know from another tool, say so. A short comparison can make the value obvious faster than a longer explanation.
- Use the comparison to **anchor the mental model**, not to claim perfect parity. Say what is similar, then explain the .NET-specific behavior.
- Prefer common tools and workflows the reader is likely to know already (for example Docker, GitHub Actions, shell usage, or package managers). Skip the comparison if it feels forced or more obscure than the feature itself.

  - ✅ `dotnet run -e FOO=BAR` gives you Docker-style CLI environment-variable injection for local app runs, so you can test configuration changes without editing shell state or launch profiles.
  - ❌ `dotnet run` now works just like Docker. (overstates the similarity)

## Entry naming

- Prefer a **brief description** of what the feature does over the API name alone
  - ✅ `## Support for Zstandard compression`
  - ✅ `## Faster time zone conversions`
  - ❌ `## ZstandardStream`
  - ❌ `## TimeZoneInfo performance`
- Prefer **specific, customer-facing verbs** over generic `gets` phrasing. Name the capability the customer now has: `offers`, `adds`, `supports`, `recognizes`, `enables`, and similar verbs are usually stronger.
  - ✅ `## System.Text.Json offers more control over naming and ignore defaults`
  - ✅ `## Regex recognizes all Unicode newline sequences`
  - ❌ `## System.Text.Json gets more control over naming and ignore defaults`
- Avoid anthropomorphic or club-like transition verbs such as `joins` or `gains` when a more literal term is available — features and components do not have agency. Prefer `moves to`, `is now in`, `adds support for`, `supports`, `now includes`, `has been updated to`, or `is updated to`.
  - ✅ `## Zstandard moved to System.IO.Compression and ZIP reads validate CRC32`
  - ✅ `The Virtualize<TItem> component now supports variable-height items for its AnchorMode parameter.`
  - ✅ `Virtualize<TItem> has been updated to anchor scroll position correctly when items have varying heights.`
  - ❌ `## Zstandard joins System.IO.Compression and ZIP reads validate CRC32`
  - ❌ `The Virtualize<TItem> component gains variable-height support for its AnchorMode parameter.`
- Use the **established feature name** when one exists, especially for long-running preview features. If `release-notes/features.json` lists an `official_name`, use that in headings and prose. Treat aliases as match-only metadata, not as the default wording.
  - ✅ `## Unsafe Evolution remains a preview feature in .NET 11`
  - ✅ `## Unsafe Evolution adds clearer diagnostics in Preview 3`
  - ❌ `## Memory Safety v2 adds clearer diagnostics in Preview 3`
  - ❌ `## Unsafe code adds clearer diagnostics and annotations`
- Keep headings concise — 3–8 words
- **Backtick all code identifiers in headings and link text** — type names (`Virtualize<TItem>`), method names (`Random.NextInteger<T>`), directives (`#:ref`, `#:package`), namespaces (`System.Net.Http.Json`), and constants. Unticked code-like text in headings breaks the GitHub-compatible heading-slug algorithm that markdownlint MD051 enforces — e.g. `## File-based apps: #:ref directive` is rejected because the inline parser drops `#:ref`; `## File-based apps: \`#:ref\` directive` is accepted and slugs cleanly. The publish-step TOC regenerator can fix wrong anchors but cannot fix wrong headings.
  - ✅ `## \`#:ref\` directive for file-based app dependencies`
  - ✅ `## \`Virtualize<TItem>\` supports variable-height items in AnchorMode`
  - ✅ `## \`System.Net.Http.Json\` added to implicit usings`
  - ❌ `## File-based apps: #:ref directive for NuGet packages`
  - ❌ `## Virtualize<TItem> supports variable-height items in AnchorMode`
- **Always specify a language on fenced code blocks** — markdownlint MD040 blocks publish on any unlabeled ` ``` ` fence. Use the actual language for runnable snippets (`csharp`, `bash`, `json`, `xml`, `powershell`, `console`, `diff`), and use `text` for plain output, file trees, or pseudo-code where no language fits. This includes README.md tables of contents, runtime.md JIT codegen snippets, and every other fenced block — there is no exception.
  - ✅ ` ```csharp `, ` ```bash `, ` ```json `, ` ```text `
  - ❌ ` ``` ` (bare triple-backtick with no language)

## Benchmarks

- Use **exact data** from PR descriptions — never round, approximate, or paraphrase
- State what was measured and the hardware/workload context
- Include specific before/after measurements when compelling
- Do **not** embed full BenchmarkDotNet tables — summarize in prose

## What to include

- **Shared audience filter** — apply the 80/20 rule from `editorial-scoring`; don't redefine a competing threshold here. Keep narrower items only when the broader audience can still see why they matter.
- **The two-sentence test** — if you can only write two sentences about a feature, it's probably an engineering fix, not a feature. Cut it. A community contribution or breaking change can lift a borderline entry, but "fixed an internal bug that happened to be visible" is not a feature.
- **Bug-fix titles are bug fixes by default** — if the PR title starts with or contains `Fix`, `Fixed`, `Fixes`, `bugfix`, `correct`, `resolve`, or describes patching incorrect behavior, treat the change as a bug fix and route it to the **Bug fixes** section. Do **not** promote it into a top-level feature heading, do **not** dress it up with a feature-style heading (e.g. "`Component X` security fix" or "`Component X` reliability fix"), and do **not** include "fix" in the heading. Override this default only when **all three** of the following are true:
  1. The change introduces a new public API surface, a new user-visible option, or a new default behavior — not just corrected existing behavior.
  2. A typical upgrader needs to know about it (not just the small set of users who hit the original bug).
  3. You can write more than two sentences of meaningful guidance — what to do with it, when to use it, what changes for the reader.
  If any of those fail, the entry belongs in **Bug fixes**.
- **Security and reliability work is usually a bug fix** — CVE-class fixes, input-validation hardening, and crash/hang/leak repairs almost always belong in the Bug fixes section. Lift them into a feature heading only when the work *also* introduces a new public option or a new default behavior the reader should know about.
- **Headlines should convey value** — a heading like "GC regions on macOS" doesn't tell the reader whether this is good or bad. Prefer headings that hint at the benefit: "GC regions enabled on macOS" or "Server GC memory model now available on macOS."
- **Product-boundary rule** — exclude higher-level IDE, editor, or design-time tooling features from product notes unless the release is specifically about that tooling surface. For example, a Razor editor code action should not be presented as an ASP.NET Core feature just because it is adjacent to the web stack.
- **TODO for borderline entries** — when a feature might deserve inclusion but you lack data to justify it (benchmark numbers, real-world impact, user demand), keep the entry but add an HTML `<!-- TODO -->` comment asking for the missing information. This is better than silently including a vague claim or silently cutting something that might matter. The TODO should state what's needed and link to the PR where the data might live.
- **Breaking changes are separate from hype** — a breaking change can be important even when it is not exciting. Keep the score honest; use `breaking_changes: true` to preserve a short callout instead of inflating the item into a headline feature.
- **Clusters can be stronger than the parts** — several related low-score items can justify one section when together they tell a clear story. Keep the individual scores honest, then merge them into one writeup instead of emitting several weak mini-features. Good examples include a group of "Unsafe evolution" changes or multiple runtime entries prefixed with `[browser]`.
- **Merge incremental work into a single "[Area] improvements" section** — when a milestone contains **three or more** small, related changes within the same long-running feature or subsystem (e.g. multiple JIT optimizations, multiple Runtime-async refinements, multiple Native AOT size wins, multiple GC tuning changes), emit **one** section titled `## <Area> improvements` (or `## <Feature> improvements`) instead of one heading per PR. Reserve standalone headings for items that genuinely warrant their own story (a new public API, a default behavior change, a major perf claim with benchmarks). Prefer the simpler `improvements` name over invented umbrella terms — readers scan for the area, not for clever phrasing.

  **Choose the right shape for the cluster:**

  - **Code-pattern clusters (JIT, codegen, runtime perf, GC tuning, AOT size, vectorization, intrinsics)** — these almost always benefit from **showing the pattern**. Use a brief intro paragraph, then either short prose-with-snippets paragraphs (one per change, with the PR link inline) or `###` sub-headings when each item warrants more than one paragraph. Include a small `csharp` (and occasionally `asm`) snippet that illustrates **what the developer would write or observe**, not the implementation detail. Prefer minimal, runnable-looking examples over excerpted PR descriptions.

    Example (prose-with-snippets):

    ```markdown
    ## JIT improvements

    Several JIT optimizations landed this preview that benefit normal C# without any source changes.

    Common patterns like multi-target `switch` expressions now fold into simpler branchless checks ([dotnet/runtime #124567](...)), index-from-end access can drop more redundant bounds checks ([dotnet/runtime #124571](...)), and `uint` → `float`/`double` casts are faster on pre-AVX-512 x86 hardware ([dotnet/runtime #124114](...)).

    ```csharp
    bool isSmall = x is 0 or 1 or 2 or 3 or 4;
    int tail = values[^1] + values[^2];
    double d = someUint;
    ```
    ```

    Use `###` sub-headings (as in past `## JIT optimizations` sections) when individual items merit a paragraph of explanation plus a code sample — for example, an inlining improvement with a before/after pattern, or a bounds-check elimination that needs a few lines of C# to make the pattern recognizable.

  - **Behavioral / library clusters (Runtime-async refinements, AsyncLocal flow, EventSource additions, etc.)** — a bullet list is fine when each item is a small behavior tweak without a meaningful code pattern to show. One bullet per PR with a one-line summary and the linked PR reference.

    ```markdown
    ## Runtime-async improvements

    Several refinements landed this preview that reduce overhead and improve diagnostics for runtime-async:

    - Lower suspend/resume overhead on the common path ([dotnet/runtime #12345](...))
    - `AsyncLocal<T>` values are now preserved across runtime-async awaits ([dotnet/runtime #12346](...))
    - `EventSource` tracing now reports runtime-async transitions ([dotnet/runtime #12347](...))
    ```

  The threshold is **three or more** related items. Two related items can stay as two short adjacent sections if each tells a meaningful story on its own; collapse them only when both would otherwise be two-sentence stubs. When in doubt for code-pattern clusters, look at the past two milestones' `runtime.md` for the established shape and match it.

## Feature ordering

Order features using three tiers, applied in order:

1. **Broad interest first** — features most developers will care about go at the top. A new `RegexOptions` value ranks above an ARM64-only instruction set.
2. **Cluster related features** — group related items together even if they differ in importance. All Regex work in one block, all System.Text.Json work in another, all JIT work together. Readers scan by area.
3. **Alphabetical within a cluster** — when features within a cluster have roughly equal weight, alphabetical order makes them scannable.

Use PR and issue reaction counts as a signal for tier 1, but apply judgment — a niche feature with 100 reactions may still rank below a broadly useful one with 10.

## Community attribution

### Inline

When a documented feature was contributed externally:

```markdown
Thank you [@username](https://github.com/username) for this contribution!
```

### Community contributors section

At the bottom of each component's notes, list ALL external contributors — not just those with documented features. Any community contributor with **one or more merged PRs** in the milestone should get a mention exactly once in the **Community contributors** section, even if none of their work was promoted into a feature writeup. Use the `community-contribution` label as a strong signal, but do not rely on it exclusively if the merged PR history shows a clear external contribution.

**Vet the list** — the `community-contribution` label is sometimes wrong. Exclude usernames containing `-msft`, `-microsoft`, or other Microsoft suffixes. When in doubt about whether someone is a Microsoft employee, leave them out of the community list.

```markdown
## Community contributors

Thank you contributors! ❤️

- [@username](https://github.com/<owner>/<repo>/pulls?q=is%3Apr+is%3Amerged+author%3Ausername)
```

## Bug fixes section

After features but before community contributors, include a grouped bug fix summary when there are noteworthy fixes. When citing the source work, use linked `org/repo #number` references with a space before `#`:

```markdown
## Bug fixes

- **System.Net.Http**
  - Fixed authenticated proxy credential handling ([dotnet/runtime #123363](https://github.com/dotnet/runtime/issues/123363))
- **System.Collections**
  - Fixed integer overflow in ImmutableArray range validation ([dotnet/runtime #124042](https://github.com/dotnet/runtime/pull/124042))
```

Group by namespace/area. Don't include test-only, CI, or infra fixes.

## Preview-to-preview feedback fixes

Include a bug fix when ALL of these apply:

1. The issue was filed after the previous preview shipped
2. It was reported by someone outside the team
3. A fix shipped in the current preview

Frame positively: "Based on community feedback, X now does Y."

If the fix is for a feature that was never really announced or is still obscure to most readers, do **not** turn that fix into a standalone feature entry. It usually belongs in the bug-fix bucket, and often scores around `1`.

## Preview-to-preview deduplication

When prior previews already documented a feature, don't repeat the same information. But **do** document significant state changes in the current preview. A feature that was introduced as opt-in in P1 and is now enabled by default in P3 is new news — document the change in state, not the feature from scratch.

Ask: "What changed about this feature since the last preview's release notes?" If the answer is meaningful to users (enabled by default, no longer experimental, major perf improvement, new sub-features), write about that. If the answer is just "more PRs landed in the same area," skip it.

Examples:

- ✅ "Runtime-async is now enabled by default for anyone targeting `net11.0`." (state change: opt-in → default)
- ✅ "The Regex source generator now handles alternations 3× faster." (new perf data)
- ❌ Repeating the full explanation of what runtime-async is from P1 (already documented)
- ❌ "More JIT optimizations landed this preview." (no specific news)

## Filtered features

When you cut a feature for failing the 20/80 rule or two-sentence test, record it in an HTML comment block in the output file. This creates a learning record — future runs and human reviewers can see what was considered and why it was excluded.

Place the comment block immediately before the Bug fixes section:

```html
<!-- Filtered features (significant engineering work, but too niche for release notes):
  - Feature name: one-sentence description of the work. Why it was cut.
  - Another feature: description. Reason.
-->
```

Good filter reasons:

- **Internal infrastructure** — "Implementation detail of the Mono → CoreCLR unification. Developers don't target the interpreter."
- **Too narrow** — "Only affects COM interop startup — very narrow audience."
- **Engineering fix, not a feature** — "Two sentences max. No user-visible behavior change beyond a perf number."
- **Provider extensibility** — "Only matters to database provider authors, not EF Core users."

The comment is invisible to readers but preserved in the file for the next person (or agent) who reviews the notes.
