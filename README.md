# OsiriX Backup Plugin

An advanced backup plugin for OsiriX that automates sending DICOM studies to remote PACS or storage destinations with integrity checks, adaptive networking, and scheduling heuristics. The project combines a mature Objective-C core with Swift-based UI elements to deliver both rich functionality and an accessible configuration experience.

## Highlights
- Multi-strategy backups: full, incremental, differential, and smart prioritisation helpers
- Intelligent queueing with priority, retry, and monitoring capabilities
- SHA-256 integrity manifests and duplicate avoidance safeguards
- Adaptive compression, bandwidth tuning, and deduplication engines
- Comprehensive reporting, statistics export, and recovery tooling

## Repository Layout
- `Sources/ObjectiveC/` – Objective-C entry points (`OsiriXBackup`), core services, and advanced backup modules
- `Sources/Swift/Plugin.swift` – Swift glue that loads the shared settings UI and bridges into the Objective-C layer
- `Sources/Shared/OsiriXTestPlugin-Bridging-Header.h` – Exposes Objective-C symbols to the Swift code
- `Resources/Info.plist` – OsiriX plugin metadata (bundle identifiers, menu registration)
- `Resources/Settings.xib` – Interface Builder resource for the configuration window (used by both ObjC and Swift entry points)
- `Scripts/` – Repository automation helpers (code collection and listing tools)
- `docs/` – Generated reference material, including `all_project_code.txt`
- `OsiriXTestPlugin.xcodeproj` – Xcode project targeting the OsiriX plugin SDK

## Architecture Overview

The plugin is grouped into three cooperating layers:

1. **UI & Control Layer** – `OsiriXBackup` (Objective-C) and `OsiriXBackupSwift` (Swift) respond to menu actions, render the configuration window, persist user defaults, and trigger backup executions. The UI wiring is contained in `Settings.xib`, which exposes host/port/AET fields, progress indicators, and verification toggles.

2. **Core Services Layer** – Utility classes provide caching, queue management, integrity validation, network optimization, statistics tracking, and error recovery. These services are aggregated via singleton-style managers to coordinate study processing.

3. **Advanced Capabilities Layer** – Optional modules add incremental/differential backups, intelligent scheduling, real-time monitoring, deduplication, compression, cloud syncing, disaster recovery, and notification hooks. These modules plug into the core queue and statistics systems to extend behavior without rewriting the base workflow.

Key class responsibilities:

```120:207:OsiriXBackupCore.h
// ... existing code ...
@interface OsiriXBackupCacheManager : NSObject
// Maintains in-memory and persisted study fingerprints to skip unchanged datasets
@end

@interface OsiriXTransferQueue : NSObject
// Coordinates concurrent transfers with priority-aware scheduling and statistics
@end

@interface OsiriXIntegrityValidator : NSObject
// Generates SHA-256 hashes and manifests for study, series, and file-level validation
@end

@interface OsiriXNetworkOptimizer : NSObject
// Tunes chunk size, windowing, and bandwidth targets per network type
@end

@interface OsiriXBackupStatistics : NSObject
// Records throughput, success ratios, and exports CSV/JSON reports
@end
```

```16:203:OsiriXBackupAdvanced.h
// ... existing code ...
@interface OsiriXIncrementalBackupManager : NSObject
// Determines deltas between snapshots for incremental/differential runs
@end

@interface OsiriXRealtimeMonitor : NSObject
// Streams live transfer speed, CPU, memory, and disk telemetry with alert hooks
@end

@interface OsiriXCompressionEngine : NSObject
// Applies modality-aware compression and ratio estimation
@end

@interface OsiriXDeduplicationEngine : NSObject
// Generates SHA-256 fingerprints and prunes duplicate payloads
@end

@interface OsiriXBackupScheduler : NSObject
// Cron-inspired scheduler with enable/disable controls and notifications
@end
```

## Prerequisites
- macOS with OsiriX (MD or non-MD) and its plugin SDK installed
- Xcode (recommended 14+) with command line tools
- DCMTK utilities (e.g., `findscu`) available either on `$PATH` or bundled inside the plugin resources
- Access to a DICOM destination (AE Title, host, port) for backup testing

## Building the Plugin
1. Open `OsiriXTestPlugin.xcodeproj` in Xcode.
2. Select the desired scheme (e.g., `OsiriXTestPlugin`).
3. Ensure the target SDK matches the OsiriX version you are extending.
4. Build the project. Xcode produces a plugin bundle (`.osirixplugin`).
5. Copy the built bundle into OsiriX’s plugin directory, for example:
   - `~/Library/Application Support/OsiriX/Plugins`
   - `/Applications/OsiriX MD.app/Contents/PlugIns`
6. Relaunch OsiriX; the plugin registers menu items defined in `Info.plist` under *Iniciar Backup DICOM* and *Configurações de Backup*.

## Configuration Workflow

The `Settings` window collects connection and verification options:

- **Host** – Destination server hostname or IP
- **Port** – DICOM port (default 104)
- **Destination AE Title** – Remote AE
- **Local AE Title** – Calling AE used by DCMTK `storeSCU`
- **Skip existence verification** – Bypass `findscu` queries (faster but risks duplication)
- **Use simplified verification** – Default-enabled check using lightweight study-level counts

Values persist through `NSUserDefaults` keys (`OsiriXBackupHostAddress`, `OsiriXBackupPortNumber`, etc.), allowing the Swift and Objective-C entry points to share configuration.

## Running Backups
1. Launch OsiriX and open the *Iniciar Backup DICOM* menu item.
2. Confirm configuration or adjust settings before starting.
3. The plugin enumerates studies from the active `DicomDatabase`, queues transfers, and displays live progress via the status label and determinate progress bar.
4. Verification options determine how the plugin prevents duplicates:
   - **Simplified** – Uses `studyExistsWithCountCheck:` to issue a single C-FIND for study presence.
   - **Full integrity** – Builds per-series counts, compares hashes, and inspects manifests before resending.
   - **Skip** – Disables verification (not recommended unless the destination is authoritative for deduplication).
5. Transfers execute through `DCMTKStoreSCU`, supporting up to `MAX_SIMULTANEOUS_TRANSFERS` (2 by default). A retry map guards against transient failures, with exponential backoff managed by `OsiriXErrorRecoveryManager`.

Pausing or stopping allows in-flight transfers to finish gracefully while new ones are deferred. On completion, the plugin exports statistics to `/tmp/osirix_backup_stats.(csv|json)` and an HTML report, opening the latter in the default browser.

## Advanced Features
- **Incremental & Differential Backups** – `OsiriXIncrementalBackupManager` snapshots hashes per study to compute deltas (`recordBackupSnapshot:`, `studiesForIncrementalBackup:`).
- **Smart (Rule-Based) Backup** – `OsiriXStudyClassifier` prioritises studies using modality-specific rules and study age heuristics before enqueuing them in `OsiriXTransferQueue`.
- **Network Optimization** – `OsiriXNetworkOptimizer` adapts chunk sizes and windowing for Wi-Fi, Ethernet, or cellular contexts and can measure bandwidth against destinations.
- **Deduplication** – `OsiriXDeduplicationEngine` fingerprints images to skip duplicates and optionally rebuilds its database across sessions.
- **Compression** – `OsiriXCompressionEngine` selects a compression algorithm per modality (e.g., JPEG2000 lossless for CT/MR) and estimates savings before applying.
- **Real-Time Monitoring** – `OsiriXRealtimeMonitor` aggregates live metrics (speed, CPU, disk) and emits alerts when thresholds are breached (e.g., stalled transfers, low disk space).
- **Scheduling** – `OsiriXBackupScheduler` and `OsiriXSmartScheduler` support cron-like triggers (daily incremental at 02:00, weekly full at 03:00) and can pause during peak hours.
- **Reporting & Recovery** – `OsiriXBackupStatistics` exports CSV/JSON, `OsiriXBackupReportGenerator` produces styled HTML, and `OsiriXDisasterRecovery` (stubbed) prepares recovery points.
- **Extensibility Hooks** – Cloud integration, bandwidth QoS, notification channels (email/push/SMS), data encryption, and audit logging classes provide scaffolding for future integrations.

## Deployment Checklist
- Verify `findscu` availability: the plugin first looks for a bundled copy at `Contents/Resources/findscu`; otherwise configure a Homebrew or manual path.
- Confirm the destination AE accepts C-STORE requests from the configured local AE.
- Ensure `/tmp` is writable for report and statistics exports.
- Grant OsiriX the necessary macOS permissions to launch helper tasks (DCMTK tools) and read from the DICOM database.

## Troubleshooting
- **Cannot locate `findscu`** – Use *Configurações de Backup* to browse for the executable or install DCMTK. The plugin logs warnings and offers to skip verification if unavailable.
- **Duplicate studies on destination** – Disable *Skip verification* and enable *Use simplified verification* (default). For stricter checks, ensure full verification is active.
- **Stalled progress** – Inspect OsiriX logs for `Transfer may be stalled` alerts; adjust network optimizer settings or reduce concurrent transfers.
- **Access denied to destination** – Confirm TLS certificates and credentials in `OsiriXBackupDestination.authenticationCredentials` are populated if the PACS requires authentication.

## Development Tips
- The plugin targets the OsiriX SDK: add the framework to Xcode’s *Frameworks and Libraries* section if missing.
- Update `Info.plist` to localize menu titles or expose additional configuration commands.
- Swift and Objective-C components share the same nib; customize it once to affect both entry points.
- When adding new modules, register them in `initializeAdvancedFeatures` within `OsiriXBackup.m` to ensure state is prepared during plugin initialization.

## Roadmap Ideas
- Implement real cloud upload/download flows in `OsiriXCloudIntegration`
- Complete encryption pipeline in `OsiriXDataEncryption` with key rotation policy
- Surface advanced scheduling and monitoring controls directly in the UI
- Add automated unit/integration tests for manifest validation and retry logic

## License

This project is released under the [MIT License](LICENSE).

