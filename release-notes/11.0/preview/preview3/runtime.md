# .NET Runtime in .NET 11 Preview 3 - Release Notes

.NET 11 Preview 3 includes new .NET Runtime features & enhancements:

- [GC regions enabled on macOS](#gc-regions-enabled-on-macos)
- [Runtime-async continuation optimizations](#runtime-async-continuation-optimizations)

.NET Runtime updates in .NET 11:

- [What's new in .NET 11](https://learn.microsoft.com/dotnet/core/whats-new/dotnet-11/overview) documentation

## GC Regions Enabled on macOS

The .NET GC regions model is now enabled on macOS for server GC, completing the rollout that already covers Windows and Linux ([dotnet/runtime#125416](https://github.com/dotnet/runtime/pull/125416)).

The regions model replaces the older segments model for heap management. In the segments model, the GC manages memory in fixed-size segments that must be compacted across the entire segment when reclaiming space. In the regions model, the heap is divided into smaller, equal-sized regions that can be individually reclaimed, reused across generations, and collected independently. This yields lower peak memory usage, more consistent pause times, and better heap compaction efficiency — especially for applications with bursty allocation patterns.

macOS was intentionally excluded from the initial regions rollout in .NET 7 due to a platform-specific issue with memory allocation that has since been resolved. With this change, server GC on macOS now uses the same efficient regions model as other platforms.

> **Note:** Workstation GC already used regions on macOS. This change only affects server GC (enabled via `<ServerGarbageCollection>true</ServerGarbageCollection>` or `DOTNET_GCConserveMemory`).

## Runtime-Async Continuation Optimizations

Preview 3 delivers two performance improvements to the runtime-async feature (introduced in Preview 1, expanded in Preview 2):

**Skip saving unmutated locals** — When an async method suspends at an `await`, the runtime previously saved all local variables to the async frame on the heap. With this optimization, locals that have not been mutated since the last suspension point are not re-saved, reducing heap writes and allocation pressure ([dotnet/runtime#125615](https://github.com/dotnet/runtime/pull/125615)).

**Continuation reuse** — When a suspended async continuation resumes immediately (i.e., the awaited task completed synchronously), the runtime can now reuse the existing continuation object rather than allocating a new one, eliminating a common source of short-lived heap allocations in async-heavy code ([dotnet/runtime#125556](https://github.com/dotnet/runtime/pull/125556)).

These optimizations are automatically applied to methods compiled with `MethodImplOptions.Async` (the runtime-async opt-in). No application changes are required.

```xml
<!-- Opt in to runtime-async in your project file -->
<PropertyGroup>
  <Features>runtime-async=on</Features>
  <EnablePreviewFeatures>true</EnablePreviewFeatures>
</PropertyGroup>
```

## Bug fixes

This release includes bug fixes and quality improvements across the runtime:

<!-- Filtered features -->

## Community contributors

Thank you contributors! ❤️
