# Swift Migration Notes

This document highlights the relevant API adjustments introduced during the Swift consolidation so that integrators embedding the backup engine outside of OsiriX can plan their upgrades.

## Public & `@objc` APIs

| Area | Previous Entry Point | Swift Replacement | Notes |
| ---- | -------------------- | ----------------- | ----- |
| Plugin bootstrap | `OsiriXBackup` Objective-C singleton | `OsiriXBackupSwift` (`Plugin.swift`) | The Swift entry point preserves the same menu registration semantics. Objective-C consumers should continue to load the bundle and message `OsiriXBackupSwift` indirectly via OsiriX plugin hooks. |
| Backup queue management | `OsiriXTransferQueue` (Objective-C) | `OsiriXTransferQueue` (Swift) | API signature remains the same. Existing Objective-C plugins linking against the queue should import the generated Swift interface; enums (`OsiriXTransferPriority`, `OsiriXTransferStatus`) now live in Swift but retain raw values. |
| Integrity helpers | `OsiriXIntegrityValidator` (Objective-C) | `OsiriXIntegrityValidator` (Swift) | The methods keep the same selectors thanks to `@objcMembers`. Hashing and manifest generation behave identically; the return types are still Foundation collections for interoperability. |
| Cache manager | `OsiriXBackupCacheManager` (Objective-C) | `OsiriXBackupCacheManager` (Swift) | Method names are unchanged. Persistence now uses Swift’s `Codable` + `Compression` but the disk format remains a binary property list compressed with zlib. |

## New Swift-Only APIs

- `FindscuLocator` (internal) centralises `findscu` discovery. Consumers embedding the engine in headless tools can instantiate it with custom `FileManager` or `FindscuProcessRunning` implementations to override search paths or mock DCMTK.
- `FindscuProcessRunning` protocol abstracts process execution. Provide a custom runner when sandboxing or integrating with remote execution environments.

## Behavioural Changes

- `findscu` resolution now caches the discovered path in `UserDefaults` and re-validates it before each run. If you previously injected custom paths through Objective-C ivars, prefer updating the defaults key `OsiriXBackupFindscuPath` so the locator honours it.
- Integrity verification short-circuits when the cached SHA-256 hash matches the current study payload. Modifying a study invalidates the cache entry, triggering a retransfer. External tools should call `OsiriXBackupCacheManager.invalidateCache()` when they mutate studies outside the plugin.

## Testing Expectations

- Continuous integration should execute `swift test` to cover the new unit tests, including `FindscuLocatorTests` and the incremental verification checks in `OsiriXBackupCoreTests`.
- Manual validation (UI workflows, progress monitoring, manifest inspection) is documented in [`Docs/TestPlans.md`](Docs/TestPlans.md). Bundle these scenarios into your release QA checklists.

## Compatibility Guidance

- **Minimum Swift version:** 5.9. Earlier toolchains may fail to compile due to concurrency primitives used in `OsiriXBackupController`.
- **Objective-C headers:** Re-run `swiftc` with the `-emit-objc-header-path` flag if you distribute the Swift framework to Objective-C consumers; the exposed APIs mirror the pre-migration names.
- **Binary distribution:** The plugin bundle layout (`Contents/Resources`, `Info.plist`) is unchanged. Custom deployment scripts that copied auxiliary tools (e.g., DCMTK) remain valid.

For additional questions, open an issue in the repository with the affected APIs and the integration context.
