# OsiriX Backup Plugin

An advanced backup plugin for OsiriX that automates sending DICOM studies to remote PACS or storage destinations with integrity checks, adaptive networking, and scheduling heuristics. The project now ships as a pure Swift implementation that leverages `OsiriXAPI` for host integration while maintaining rich functionality and an accessible configuration experience.

## Highlights
- Multi-strategy backups: full, incremental, differential, and smart prioritisation helpers
- Intelligent queueing with priority, retry, and monitoring capabilities
- SHA-256 integrity manifests and duplicate avoidance safeguards
- Adaptive compression, bandwidth tuning, and deduplication engines
- Comprehensive reporting, statistics export, and recovery tooling

## Repository Layout
- `Sources/Swift/Core/` – Plugin entry point (`Plugin.swift`), backup engine (`OsiriXBackup.swift`), API wrappers, and foundational services
- `Sources/Swift/Advanced/` – Optional modules that extend the core workflow with incremental backups, scheduling, monitoring, compression, and reporting helpers
- `Sources/Swift/OsiriXBackupController.swift` – Central coordinator that wires the UI, user defaults, and backup engine together
- `Resources/Info.plist` – OsiriX plugin metadata (bundle identifiers, menu registration)
- `Resources/Settings.xib` – Interface Builder resource for the configuration window (used by both ObjC and Swift entry points)
- `Scripts/` – Repository automation helpers (code collection and listing tools)
- `docs/` – Generated reference material, including `all_project_code.txt`
- `OsiriXTestPlugin.xcodeproj` – Xcode project targeting the OsiriX plugin SDK

## Swift Architecture Overview

The Swift port consolidates the plugin into layered modules that isolate UI, orchestration, and reusable services:

1. **UI & Control Layer** – `OsiriXBackupSwift` (in `Plugin.swift`) responds to menu actions while `OsiriXBackupController` wires the settings UI, user defaults, and backup execution pipeline. The window still originates from `Settings.xib`, exposing host/port/AET fields, progress indicators, and verification toggles.

2. **Core Services Layer** – `OsiriXBackup` and `OsiriXBackupCore` provide caching, queue management, integrity validation, network optimization, statistics tracking, and error recovery through Swift value types and helper managers. Shared utilities such as the new `FindscuLocator` encapsulate discovery of the DCMTK toolchain and can be unit tested independently of the UI.

3. **Advanced Capabilities Layer** – `OsiriXBackupAdvanced` extends the core workflow with incremental/differential backups, intelligent scheduling, real-time monitoring, deduplication, compression, cloud syncing, disaster recovery, and notification hooks.

Key Swift types:

- `OsiriXBackupController` centralizes plugin initialization, menu dispatch, settings persistence, and `findscu` verification.
- `OsiriXBackup` orchestrates DICOM export requests, invoking verification and queue management services.
- `OsiriXBackupCore` houses transfer queues, hashing, compression, and manifest utilities used across backup strategies.
- `FindscuLocator` resolves and validates the DCMTK CLI across bundled and system paths, caching results in `UserDefaults`.
- `OsiriXBackupAdvanced` contributes optional schedulers, monitors, and policy engines that plug into the shared controller.

The Swift package now serves as the canonical source for both macOS builds and command-line unit tests, enabling CI coverage without requiring the OsiriX host.

## Prerequisites & Dependencies
- macOS with OsiriX (MD or non-MD) and its plugin SDK installed
- Xcode (recommended 14+) with command line tools
- Swift 5.9 or newer to build the Swift Package Manager test suite
- DCMTK utilities (e.g., `findscu`) available either on `$PATH` or bundled inside the plugin resources; the `FindscuLocator` service automatically tests and caches the path
- Access to a DICOM destination (AE Title, host, port) for backup testing
- Optional: Compression framework (`Compression.framework`) for manifest persistence optimisations

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

Values persist through `NSUserDefaults` keys (`OsiriXBackupHostAddress`, `OsiriXBackupPortNumber`, etc.), allowing the Swift entry point to share configuration with existing OsiriX preferences.

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

## Testing & Validation

- Automated coverage lives under `Tests/OsiriXBackupPluginTests`. Run `swift test` to execute queue management, integrity validation, and findscu discovery tests without launching OsiriX.
- Manual validation scenarios (UI walkthrough, progress monitoring, manifest inspection) are documented in [`Docs/TestPlans.md`](Docs/TestPlans.md) for execution inside OsiriX.

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
- The Swift controller loads `Settings.xib`, so customising it updates the plugin UI without additional wiring.
- When adding new modules, register them in `initializeAdvancedFeatures` within `OsiriXBackup.swift` to ensure state is prepared during plugin initialization.

## Roadmap Ideas
- Implement real cloud upload/download flows in `OsiriXCloudIntegration`
- Complete encryption pipeline in `OsiriXDataEncryption` with key rotation policy
- Surface advanced scheduling and monitoring controls directly in the UI
- Add automated unit/integration tests for manifest validation and retry logic

## License

This project is released under the [MIT License](LICENSE).

