# Objective-C Architecture Reference

> **Historical reference:** The Objective-C sources cited below were removed in the Swift migration. The document is retained for legacy context when comparing the former implementation against the new Swift modules.

## OsiriXBackup UI and Automation Surface

### User Interface Composition
- The plugin subclasses `PluginFilter` and declares IBOutlets for its configuration window, input fields, buttons, and verification checkboxes, defining the Objective-C UI surface that needs Swift counterparts.【F:Sources/ObjectiveC/OsiriXBackup.h†L11-L55】
- `initPlugin` builds the entire configuration window in code when a XIB is unavailable, wiring text fields for host/port/AETs, progress controls, start/pause/stop/close buttons, and both verification toggles.【F:Sources/ObjectiveC/OsiriXBackup.m†L51-L125】

### Settings and Session State Management
- User choices (destination host/port, AE titles, verification flags, findscu path) are persisted through `NSUserDefaults`, loaded into the UI, and saved whenever the user commits or toggles a backup, ensuring continuity across sessions.【F:Sources/ObjectiveC/OsiriXBackup.m†L400-L472】
- Runtime state is tracked through collections for pending studies, active transfers, retry counters, and synchronization primitives (locks), all initialized before the UI is shown.【F:Sources/ObjectiveC/OsiriXBackup.h†L35-L55】【F:Sources/ObjectiveC/OsiriXBackup.m†L51-L66】

### Backup Lifecycle Automation
- `startBackupProcess` validates settings, resolves the local DICOM database, populates the study queue, updates UI affordances, and kicks off processing in the background queue.【F:Sources/ObjectiveC/OsiriXBackup.m†L490-L567】
- `processNextStudy` enforces concurrency limits, drains the queue, updates progress labels, and decides whether to skip or send each study based on verification results before spawning transfers via `DCMTKStoreSCU` threads.【F:Sources/ObjectiveC/OsiriXBackup.m†L923-L1065】
- Pause, resume, and stop operations update UI state, gate new transfers, and coordinate finalization after existing DCMTK jobs finish.【F:Sources/ObjectiveC/OsiriXBackup.m†L569-L636】【F:Sources/ObjectiveC/OsiriXBackup.m†L639-L736】
- Progress reporting and paused-state messaging read from the DICOM database and internal queues to keep the UI in sync, which is critical when mirroring the behavior in Swift.【F:Sources/ObjectiveC/OsiriXBackup.m†L1524-L1587】

### DCMTK Integration Points
- `detectFindscuPath`, `testFindscuExecutable`, and `findscuExecutablePath` locate the DCMTK CLI, while `studyExistsOnDestination` and `verifyStudyTransferSuccess` shell out via `NSTask`/`N2Shell` to drive `findscu` queries for pre/post-transfer validation.【F:Sources/ObjectiveC/OsiriXBackup.m†L127-L200】【F:Sources/ObjectiveC/OsiriXBackup.m†L592-L635】
- Transfer threads wrap `DCMTKStoreSCU` to push image files, then perform repeated verification cycles (simplified or full) before marking success or re-queueing studies for retries.【F:Sources/ObjectiveC/OsiriXBackup.m†L1041-L1502】

### Advanced Feature Hooks
- `initializeAdvancedFeatures` wires in cache, transfer queue, statistics, integrity, network, error recovery, incremental backup, realtime monitor, compression, and deduplication helpers from the core/advanced libraries for richer automation.【F:Sources/ObjectiveC/OsiriXBackup.m†L1592-L1640】
- Dedicated entry points leverage those helpers to optimize per-modality transfers, validate integrity manifests, generate reports, schedule automatic backups, and start realtime monitoring, forming the higher-level automation surface.【F:Sources/ObjectiveC/OsiriXBackup.m†L1858-L1968】

## Core Library Inventory (`OsiriXBackupCore`)

| Component | Responsibilities & Key APIs | Public Entry Points |
| --- | --- | --- |
| `OsiriXBackupCacheManager` | Shared cache of `DicomStudy` instances and SHA256 hashes persisted to disk for deduplication/skip decisions.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L55-L71】【F:Sources/ObjectiveC/OsiriXBackupCore.m†L24-L87】 | `sharedManager`, `cacheStudy:withHash:`, `cachedHashForStudy:`, `invalidateCache`, `persistCacheToDisk`, `cacheStatistics` |
| `OsiriXTransferQueueItem` | Encapsulates a queued transfer, tracking study metadata, progress, retries, timing, and derived metrics.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L76-L99】【F:Sources/ObjectiveC/OsiriXBackupCore.m†L90-L140】 | Initializer, `elapsedTime`, `estimatedTimeRemaining`, `progressPercentage` |
| `OsiriXTransferQueue` | Priority-aware queue limiting concurrent transfers and producing queue statistics for UI/reporting.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L101-L115】【F:Sources/ObjectiveC/OsiriXBackupCore.m†L143-L236】 | `addItem:`, `nextItemToProcess`, `itemsWithStatus:`, `prioritizeItem:`, `cancelAllTransfers`, `queueStatistics` |
| `OsiriXBackupSchedule` & `OsiriXBackupScheduler` | Cron-like scheduling of backups with filters and destination lists; singleton orchestrates timers for active schedules.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L118-L153】 | `shouldRunNow`, `calculateNextRunDate`, `matchesStudy:`; scheduler’s `sharedScheduler`, `addSchedule:`, `startScheduler` |
| `OsiriXIntegrityValidator` | Hash and manifest generation/validation over `DicomStudy`/`DicomSeries` graphs to guarantee transfer fidelity.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L155-L166】【F:Sources/ObjectiveC/OsiriXBackupCore.m†L238-L327】 | `sha256HashForStudy:`, `validateStudyIntegrity:expectedHash:`, `generateStudyManifest:` |
| `OsiriXNetworkOptimizer` | Network tuning heuristics for chunk/window sizes, adaptive bandwidth measurement, and statistics export.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L168-L183】 | `optimizeForNetwork:`, `measureBandwidthToHost:port:completion:`, `adjustTransferParameters`, `networkStatistics` |
| `OsiriXBackupStatistics` | Aggregates counts, timings, and reports of transfer outcomes with CSV/JSON export support.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L186-L205】【F:Sources/ObjectiveC/OsiriXBackupCore.m†L329-L416】 | `recordTransfer:`, `recordFailure:error:`, `generateReport`, `exportToCSV:`, `exportToJSON:`, `reset` |
| `OsiriXBackupDestination` & `OsiriXDestinationManager` | Models remote endpoints (TLS, compression, concurrency) and manages active/primary destination selection with persistence hooks.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L209-L247】【F:Sources/ObjectiveC/OsiriXBackupCore.m†L418-L538】 | Destination `testConnection:`/`measureLatency:`; manager’s `sharedManager`, `addDestination:`, `activeDestinations`, `selectOptimalDestination`, `loadDestinationsFromConfig` |
| `OsiriXBackupReportGenerator` | Produces HTML/text/PDF reports and distribution helpers for statistics output.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L249-L259】【F:Sources/ObjectiveC/OsiriXBackupCore.m†L540-L611】 | `generateHTMLReport:`, `generateTextReport:`, `generatePDFReport:`, `emailReport:toRecipients:`, `saveReportToFile:` |
| `OsiriXErrorRecoveryManager` | Centralizes retry policies with exponential backoff, shared singleton state, and pluggable strategies.【F:Sources/ObjectiveC/OsiriXBackupCore.h†L261-L277】【F:Sources/ObjectiveC/OsiriXBackupCore.m†L613-L704】 | `sharedManager`, `nextRetryIntervalForAttempt:`, `shouldRetryError:`, `handleError:forItem:`, `registerRecoveryStrategy:forErrorCode:` |

## Advanced Library Inventory (`OsiriXBackupAdvanced`)

| Component | Responsibilities & Key APIs | Public Entry Points |
| --- | --- | --- |
| `OsiriXIncrementalBackupManager` | Tracks historical snapshots and computes incremental/differential study sets, emitting manifests for auditability.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L12-L33】【F:Sources/ObjectiveC/OsiriXBackupAdvanced.m†L16-L198】 | `studiesForIncrementalBackup:sinceDate:`, `studiesForDifferentialBackup:sinceFullBackupDate:`, `recordBackupSnapshot:type:date:`, `lastFullBackupDate`, `studyNeedsBackup:`, `createBackupManifest:forStudies:` |
| `OsiriXMultiDestinationManager` | Balances load/failover/mirroring across configured destinations, tuning compression per modality and exposing live statistics.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L36-L53】【F:Sources/ObjectiveC/OsiriXBackupAdvanced.m†L201-L359】 | `configureDestination:forStudy:`, `selectDestinationsForStudy:`, `balanceLoadAcrossDestinations`, `failoverToBackupDestination:`, `destinationLoadStatistics` |
| `OsiriXRealtimeMonitor` | Polls active transfers, collects metrics/alerts, and surfaces status via handlers with export support for dashboards.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L56-L76】【F:Sources/ObjectiveC/OsiriXBackupAdvanced.m†L362-L447】 | `startMonitoring`, `stopMonitoring`, `trackTransfer:`, `updateTransferProgress:progress:speed:`, `currentSystemStatus`, `exportMetricsToFile:` |
| `OsiriXSmartScheduler` | Learns usage patterns to propose predictive backup windows and adjust cron schedules dynamically.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L79-L95】 | `analyzeBackupPatterns`, `optimalBackupTimeForStudy:`, `createSmartScheduleBasedOnUsagePatterns`, `suggestedBackupTimesForNext:` |
| `OsiriXStudyClassifier` | Assigns priorities/criticality using rule-based or ML-enhanced classification driven by historical studies.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L97-L111】 | `classifyStudyPriority:`, `isStudyCritical:`, `predictStudyImportance:`, `trainClassifierWithHistoricalData:`, `classificationStatistics` |
| `OsiriXBandwidthManager` | Manages QoS, throttling, and available bandwidth accounting for transfer prioritization.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L113-L129】 | `allocateBandwidthForTransfer:`, `throttleTransfer:toSpeed:`, `prioritizeUrgentTransfers`, `availableBandwidth`, `bandwidthStatistics` |
| `OsiriXCompressionEngine` | Applies adaptive compression strategies aligned with modality characteristics and exposes metrics.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L131-L146】 | `compressData:withType:`, `decompressData:fromType:`, `optimalCompressionForModality:`, `shouldCompressFile:`, `compressionStatistics` |
| `OsiriXDeduplicationEngine` | Maintains fingerprint database for block-level deduplication, enabling savings estimates and rebuild workflows.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L148-L164】 | `generateFingerprint:`, `isDuplicate:`, `findDuplicates:`, `deduplicateStudy:`, `deduplicationStatistics` |
| `OsiriXDisasterRecovery` | Governs recovery points and validation to support DR parity in Swift.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L166-L181】 | `createRecoveryPoint:`, `restoreFromRecoveryPoint:`, `listRecoveryPoints`, `scheduleAutomaticRecoveryPoints`, `disasterRecoveryStatus` |
| `OsiriXAuditLogger` | Captures detailed backup/security events with export and rotation hooks.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L183-L200】 | `logBackupEvent:forStudy:withInfo:`, `logSecurityEvent:user:`, `logError:context:`, `exportAuditLog:toPath:`, `rotateLogFiles` |
| `OsiriXCloudIntegration` | Abstracts provider-specific upload/download/sync paths for hybrid cloud strategies.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L204-L222】 | `configureCloudStorage:`, `uploadStudyToCloud:completion:`, `downloadStudyFromCloud:completion:`, `syncWithCloud`, `cloudStorageStatistics` |
| `OsiriXPerformanceAnalyzer` | Profiles operations, analyzes bottlenecks, and generates performance recommendations.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L224-L239】 | `startProfiling`, `measureOperationTime:block:`, `analyzeBottlenecks`, `generatePerformanceReport` |
| `OsiriXNotificationManager` | Centralizes multi-channel notification preferences and delivery for backup outcomes.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L241-L258】 | `sendNotification:type:priority:`, `sendBackupCompleteNotification:`, `sendFailureAlert:forStudy:`, `configureNotificationPreferences:`, `testNotificationChannels` |
| `OsiriXDataEncryption` | Handles symmetric/asymmetric encryption flows, key management, and validation for secured backups.【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L260-L275】 | `encryptData:`, `decryptData:`, `generateEncryptionKey`, `rotateEncryptionKeys`, `encryptionStatus` |

## Bridging Header Exposure and SDK Usage
- Swift targets gain visibility into `PluginFilter`, `BrowserController`, `DicomStudy`/`DicomSeries`, `DicomDatabase`, and a suite of WebPortal/network helpers via `OsiriXTestPlugin-Bridging-Header.h`.【F:Sources/Shared/OsiriXTestPlugin-Bridging-Header.h†L1-L26】
- `OsiriXBackup` consumes `PluginFilter` inheritance, queries `DicomDatabase`, iterates `DicomStudy`/`DicomSeries`, and relies on `DCMTKStoreSCU`, reflecting the minimum SDK surface Swift implementations must replicate.【F:Sources/ObjectiveC/OsiriXBackup.h†L1-L56】【F:Sources/ObjectiveC/OsiriXBackup.m†L490-L1065】
- Core and advanced managers use `DicomStudy`/`DicomSeries` heavily for hashing, manifest generation, modality-aware routing, and historical classification, implying Swift modules need those model types exposed through the bridging header as well.【F:Sources/ObjectiveC/OsiriXBackupCore.m†L33-L118】【F:Sources/ObjectiveC/OsiriXBackupAdvanced.m†L28-L198】【F:Sources/ObjectiveC/OsiriXBackupAdvanced.m†L226-L340】
- Although WebPortal, AsyncSocket, and QueryController headers are exposed, the current Objective-C code paths in these files do not invoke them, leaving room to prune or adopt them during Swift parity work.【F:Sources/Shared/OsiriXTestPlugin-Bridging-Header.h†L15-L26】

## Swift Parity Considerations
- Recreate the configuration window programmatically or via SwiftUI/AppKit nibs with the same controls, bindings, and validation logic to preserve behavior described above.【F:Sources/ObjectiveC/OsiriXBackup.m†L51-L125】【F:Sources/ObjectiveC/OsiriXBackup.m†L400-L567】
- Mirror the asynchronous queueing model, including concurrency limits, retry logic, and DCMTK integration (via wrappers or direct C APIs) to maintain transfer reliability.【F:Sources/ObjectiveC/OsiriXBackup.m†L923-L1502】
- Port the core/advanced helper classes to Swift modules or Swift-friendly wrappers so higher-level automation (`initializeAdvancedFeatures`, scheduling, reporting) can be reconstituted with minimal behavioral drift.【F:Sources/ObjectiveC/OsiriXBackup.m†L1592-L1968】【F:Sources/ObjectiveC/OsiriXBackupCore.h†L55-L277】【F:Sources/ObjectiveC/OsiriXBackupAdvanced.h†L12-L275】
