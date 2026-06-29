---
name: validate-code-samples
description: >
  Extract fenced C# code samples from markdown (such as .NET release notes) and
  verify they compile and run against a specific .NET SDK build. Installs the
  target SDK side-by-side (no machine-wide install) from build metadata, or
  respects a currently-installed SDK. Catches API typos, missing usings, and
  incorrect signatures before the content is published.
---

# Validate Code Samples

Verify that the C# code samples in a markdown document actually compile and (where
runnable) execute, against a specific .NET SDK build. Standalone utility; the
release-notes pipeline invokes it after authoring a component file, but it works
on any markdown with `csharp` code fences.

## Inputs

- One or more markdown files containing fenced ` ```csharp ` blocks.
- A target SDK, resolved in this order:
  1. **`build-metadata.json`** for the release (preferred) — use `build.sdk_version`
     and `build.sdk_url`; ref-pack packages come from `nuget.source`.
  2. A **currently-installed SDK**, when explicitly requested.
- Scope: validate only the **documented/announced** surface. Do not infer or
  surface behavior beyond what the samples and prose describe.

## 1. Acquire the target SDK (local, scoped)

Prefer a **side-by-side, local** install of the exact build SDK — never a
machine-wide install:

```bash
# from build-metadata.json: build.sdk_version (e.g. 11.0.100-preview.6.NNNNN.NN)
curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
bash /tmp/dotnet-install.sh --version "$SDK_VERSION" --install-dir "$PWD/.dotnet"
export DOTNET_ROOT="$PWD/.dotnet"
export PATH="$DOTNET_ROOT:$PATH"
dotnet --version    # confirm the target SDK is active
```

If preview/daily packages are needed (common for `Microsoft.Extensions.*` and
preview APIs), point NuGet at the build feed from `build-metadata.json`
`nuget.source` (the dnceng `dotnet<major>` feed) via a local `NuGet.config` or
`--source`.

To **respect a currently-installed SDK** instead, skip the install and confirm
`dotnet --list-sdks` shows a compatible version; note in the report that samples
were validated against the installed SDK, not the exact build.

If no compatible SDK is available and installing one is not possible, **skip
validation** and report that samples were not verified — do not guess.

## 2. Set up the samples folder

Use a `samples/` directory alongside the document (e.g. for
`release-notes/11.0/preview/preview6/libraries.md` use
`release-notes/11.0/preview/preview6/samples/`). Ensure `release-notes/.gitignore`
excludes samples so they are never committed:

```
# Code sample validation apps created during validation
**/samples/
```

## 3. Extract and classify each sample

Scan for fenced `csharp` blocks. For each:

1. **Feature** — use the nearest preceding `##`/`###` heading as the name.
2. **Classify**:
   - **runnable** — executable statements; wrap as a console app (most common).
   - **API signature** — a type/member declaration; validate it compiles inside a
     stub class with a reference that exercises it.
   - **fragment** — incomplete (a lambda, a partial body); wrap in the necessary
     context to compile.

## 4. Scaffold file-based C# programs

Prefer **file-based programs** (single `.cs`, no project) built/run with
`dotnet <file>.cs`:

```csharp
#:property PublishAot=false
// Sample validation for: <Feature Name>
// Source: <document path>

<extracted code, wrapped as needed>
```

- `#:property PublishAot=false` forces the installed SDK build path (not NativeAOT).
- For NuGet dependencies, add `#:package Name@Version` directives (use the build's
  preview versions where applicable).
- Combine logically-sequential blocks for one feature into a single file.
- **Fallback to a project** (`<Feature>.csproj` + `Program.cs` in a subfolder) only
  when a file-based program can't express it (multiple files, custom MSBuild props).

## 5. Build and run

```bash
dotnet samples/<FeatureSlug>.cs        # file-based: builds and runs
# or: dotnet run --project samples/<feature-slug>/   # project fallback
```

- **Build succeeds + runs clean** -> validated.
- **Build fails** -> diagnose: missing using (add it), wrong API name/signature
  (the sample is incorrect — see step 6), missing package (add `#:package`).
- **Requires unavailable infra** (network/db/OS) -> validate as *compilable* and
  note it could not be run.
- **Throws** -> decide if the exception is expected (e.g. missing test file) or a
  real defect in the sample.

## 6. Corrections require confirmation

If a sample needs a fix, **never edit the document silently**. Show the original
and corrected versions and get confirmation (or, in an automated pipeline, record
the proposed correction and flag it for human review) before changing source.

## 7. Report

Summarize as a table; highlight any sample that required a correction:

| Feature | Build | Run | Notes |
|---------|-------|-----|-------|
| Zstandard compression | pass | pass | |
| Faster timezone conversions | pass | warn | Expected: no tzdata in sandbox |

## Notes

- **Partial validation is acceptable** — middleware pipelines, GUI, and
  platform-specific code may only be validated as compilable.
- The `samples/` folder is gitignored; leave it in place for inspection but never
  commit it.
