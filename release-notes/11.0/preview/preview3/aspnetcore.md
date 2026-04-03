# ASP.NET Core in .NET 11 Preview 3 - Release Notes

Here's a summary of what's new in ASP.NET Core in this preview release:

- [Blazor Virtualize: variable-height item support](#blazor-virtualize-variable-height-item-support)

ASP.NET Core updates in .NET 11:

- [What's new in ASP.NET Core in .NET 11](https://learn.microsoft.com/aspnet/core/release-notes/aspnetcore-11) documentation.
- [Roadmap](https://github.com/dotnet/aspnetcore/issues/64787)

## Blazor Virtualize: Variable-Height Item Support

The `Virtualize` component now supports rendering lists where items have different heights. Previously, `Virtualize` required all items to have the same height (set via `ItemSize`) — variable-height content would cause incorrect scroll behavior and visible layout artifacts ([dotnet/aspnetcore#64964](https://github.com/dotnet/aspnetcore/pull/64964)).

The new approach uses a **walking average**: the component estimates placeholder height based on the average of items it has already rendered. As the user scrolls and more items are measured, the estimate improves, and placeholder sizes stabilize. This avoids requiring developers to pre-compute item heights while still maintaining smooth virtual scrolling.

```razor
@* Variable-height items: no need to set ItemSize *@
<Virtualize Items="@items">
    <ItemContent Context="item">
        <div class="item">
            <h3>@item.Title</h3>
            @if (item.HasDescription)
            {
                <p>@item.Description</p>
            }
        </div>
    </ItemContent>
    <Placeholder>
        <div class="item placeholder">Loading...</div>
    </Placeholder>
</Virtualize>
```

For lists where you know all items have the same height, the existing `ItemSize` parameter still works and provides optimal performance since no measurement is needed.

## Bug fixes

This release includes bug fixes and quality improvements:

<!-- Filtered features -->

## Community contributors

Thank you contributors! ❤️
