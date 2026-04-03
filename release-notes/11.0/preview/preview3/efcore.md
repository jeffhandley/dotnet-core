# Entity Framework Core & Data in .NET 11 Preview 3 - Release Notes

Entity Framework Core 11 updates:

- [What's new in Entity Framework Core 11](https://learn.microsoft.com/ef/core/what-is-new/ef-core-11.0/whatsnew) documentation
- [Breaking changes in Entity Framework Core 11](https://learn.microsoft.com/ef/core/what-is-new/ef-core-11.0/breaking-changes)

Here's a summary of what's new in EF Core & Data in this Preview 3 release:

- [ChangeTracker.GetEntriesForState()](#changetrackergetentriesforstate)
- [Provider swapping APIs for testing](#provider-swapping-apis-for-testing)

## ChangeTracker.GetEntriesForState()

A new `ChangeTracker.GetEntriesForState(EntityState)` method returns all tracked entities in a specific state without triggering `DetectChanges()`. The existing `ChangeTracker.Entries()` always calls `DetectChanges()` first — expensive in change-heavy scenarios and unwanted when you already know the state is accurate ([dotnet/efcore#37847](https://github.com/dotnet/efcore/pull/37847)).

```csharp
// Get all Added entities without triggering DetectChanges
var newEntities = context.ChangeTracker
    .GetEntriesForState(EntityState.Added)
    .Select(e => e.Entity)
    .ToList();

// Equivalent for modified entities
var modifiedEntities = context.ChangeTracker
    .GetEntriesForState(EntityState.Modified);

// Works with generic overload for type filtering
var addedOrders = context.ChangeTracker
    .GetEntriesForState<Order>(EntityState.Added);
```

This is particularly useful in bulk operation scenarios, event sourcing patterns, and performance-sensitive code paths where you control when state detection happens.

## Provider Swapping APIs for Testing

Three new APIs make it easier to swap database providers in test scenarios — a common need when writing integration tests that run against an in-memory or SQLite provider but configure a production SQL Server context ([dotnet/efcore#37891](https://github.com/dotnet/efcore/pull/37891)):

- **`IDbContextOptionsBuilderInfrastructure.RemoveExtension<T>()`** — removes a specific extension from the options builder
- **`DbContextOptions.WithoutExtension<T>()`** — returns a new options instance with the specified extension removed
- **`IServiceCollection.RemoveDbContext<TContext>()`** — removes a previously registered `DbContext` registration from the DI container

Together, these enable a clean pattern for overriding provider configuration in test fixtures:

```csharp
// In your test fixture
services.RemoveDbContext<AppDbContext>();
services.AddDbContext<AppDbContext>(options =>
    options.UseSqlite("Data Source=:memory:"));

// Or using the builder approach
var testOptions = productionOptions
    .WithoutExtension<SqlServerOptionsExtension>()
    .UseSqlite("Data Source=:memory:")
    .Options;
```

## Bug fixes

<!-- Filtered features -->

## Community contributors

Thank you contributors! ❤️
