# .NET Libraries in .NET 11 Preview 3 - Release Notes

.NET 11 Preview 3 includes new .NET Libraries features & enhancements:

- [System.Text.Json: PascalCase naming policy](#systemtextjson-pascalcase-naming-policy)
- [System.Text.Json: Per-member naming policy attribute](#systemtextjson-per-member-naming-policy-attribute)
- [System.Text.Json: Type-level JsonIgnore conditions](#systemtextjson-type-level-jsonignore-conditions)
- [System.Text.Json: Byref constructor parameters](#systemtextjson-byref-constructor-parameters)
- [System.IO: RandomAccess on non-seekable files](#systemio-randomaccess-on-non-seekable-files)
- [System.IO: Anonymous pipe API with per-end async support](#systemio-anonymous-pipe-api-with-per-end-async-support)
- [System.Diagnostics: Null arguments in ProcessStartInfo](#systemdiagnostics-null-arguments-in-processstartinfo)
- [Tracing: Declaring type name in assembly load handler events](#tracing-declaring-type-name-in-assembly-load-handler-events)

.NET Libraries updates in .NET 11:

- [What's new in .NET 11](https://learn.microsoft.com/dotnet/core/whats-new/dotnet-11/overview) documentation

## System.Text.Json: PascalCase Naming Policy

A new `JsonNamingPolicy.PascalCase` converts property names using word-boundary detection, capitalizing the first letter of each word. This mirrors how `JsonNamingPolicy.CamelCase` works but produces `PascalCase` instead of `camelCase` output ([dotnet/runtime#124644](https://github.com/dotnet/runtime/pull/124644)).

```csharp
var options = new JsonSerializerOptions
{
    PropertyNamingPolicy = JsonNamingPolicy.PascalCase
};

var obj = new { firstName = "Jane", lastName = "Doe" };
string json = JsonSerializer.Serialize(obj, options);
// → {"FirstName":"Jane","LastName":"Doe"}
```

The policy is also available as `JsonKnownNamingPolicy.PascalCase` for use with `[JsonSourceGenerationOptions]` in source-generated contexts.

## System.Text.Json: Per-Member Naming Policy Attribute

A new `[JsonNamingPolicy]` attribute lets you override the serializer's naming policy on a per-member or per-type basis without affecting the entire `JsonSerializerOptions` ([dotnet/runtime#124645](https://github.com/dotnet/runtime/pull/124645)).

```csharp
public class Config
{
    // This member uses snake_case regardless of global policy
    [JsonNamingPolicy(JsonKnownNamingPolicy.SnakeCaseLower)]
    public string ServerName { get; set; }

    // This member uses the global policy (or default)
    public string ApiKey { get; set; }
}
```

When applied to a type, the policy applies to all members of that type unless overridden at the member level.

## System.Text.Json: Type-Level JsonIgnore Conditions

`[JsonIgnore(Condition = ...)]` can now be applied at the class, struct, or interface level, setting a default ignore condition for all members of that type. Previously, you could only apply `[JsonIgnore]` per-member ([dotnet/runtime#124646](https://github.com/dotnet/runtime/pull/124646)).

```csharp
// Ignore all null members across the entire type
[JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
public class ApiResponse
{
    public string? Message { get; set; }
    public string? ErrorCode { get; set; }
    public int StatusCode { get; set; } // never null, always written
}
```

Member-level attributes take precedence over the type-level default, allowing fine-grained opt-out.

## System.Text.Json: Byref Constructor Parameters

`System.Text.Json` now correctly handles constructors that use `in`, `ref`, or `out` parameters. Previously, attempting to deserialize a type whose constructor included byref parameters would fail at runtime with a confusing error ([dotnet/runtime#122950](https://github.com/dotnet/runtime/pull/122950)).

```csharp
public readonly struct Measurement
{
    public Measurement(in double value, in string unit)
    {
        Value = value;
        Unit = unit;
    }

    public double Value { get; }
    public string Unit { get; }
}

// Now works correctly
var m = JsonSerializer.Deserialize<Measurement>("""{"Value":3.14,"Unit":"kg"}""");
```

## System.IO: RandomAccess on Non-Seekable Files

`RandomAccess.Read` and `RandomAccess.Write` now work with non-seekable file handles such as pipes, sockets, and character devices. Previously, calling these methods on a non-seekable handle threw `NotSupportedException` ([dotnet/runtime#125512](https://github.com/dotnet/runtime/pull/125512)).

When the handle is non-seekable, the `fileOffset` parameter is ignored and I/O is performed sequentially at the current position, matching the behavior of `FileStream` on non-seekable streams.

```csharp
// Works with pipe handles, not just regular files
using var pipe = new AnonymousPipeServerStream(PipeDirection.Out);
SafeFileHandle handle = pipe.SafePipeHandle;

byte[] data = [1, 2, 3, 4];
// fileOffset is ignored for non-seekable handles
RandomAccess.Write(handle, data, fileOffset: 0);
```

## System.IO: Anonymous Pipe API with Per-End Async Support

`SafeFileHandle.CreateAnonymousPipe()` is a new low-level API for creating anonymous pipes with independent async-capability settings per end ([dotnet/runtime#125220](https://github.com/dotnet/runtime/pull/125220)).

The existing `AnonymousPipeServerStream` and `AnonymousPipeClientStream` both require either both ends to be synchronous, or work around Windows limitations where async I/O is only available on the server end. The new API allows each end to independently opt into asynchronous I/O:

```csharp
SafeFileHandle.CreateAnonymousPipe(
    inheritability: HandleInheritability.None,
    readerOpenAsynchronous: true,
    writerOpenAsynchronous: false,
    out SafeFileHandle readerHandle,
    out SafeFileHandle writerHandle);

// Reader is async-capable, writer is synchronous
var reader = new FileStream(readerHandle, FileAccess.Read, bufferSize: 4096, isAsync: true);
var writer = new FileStream(writerHandle, FileAccess.Write, bufferSize: 4096, isAsync: false);
```

## System.Diagnostics: Null Arguments in ProcessStartInfo

`ProcessStartInfo(string fileName, string? arguments)` and `Process.Start(string fileName, string? arguments)` now accept `null` for the `arguments` parameter. Previously, passing `null` caused a `NullReferenceException`; the fix makes `null` equivalent to an empty string ([dotnet/runtime#126076](https://github.com/dotnet/runtime/pull/126076)).

```csharp
string? args = GetOptionalArguments(); // may return null

// No longer throws when args is null
var process = Process.Start("myapp.exe", args);
```

## Tracing: Declaring Type Name in Assembly Load Handler Events

Assembly load handler tracing events now include the declaring type name alongside the method name, making it easier to identify which handler was invoked when diagnosing assembly binding issues ([dotnet/runtime#125881](https://github.com/dotnet/runtime/pull/125881)).

Previously the event payload included only the method name (e.g., `OnAssemblyResolve`). It now includes the fully qualified declaring type (e.g., `MyApp.AssemblyLoader.OnAssemblyResolve`), which is essential when multiple classes register handlers with the same method name.

## Bug fixes

This release includes bug fixes and quality improvements across several areas:

<!-- Filtered features -->

## Community contributors

Thank you contributors! ❤️
