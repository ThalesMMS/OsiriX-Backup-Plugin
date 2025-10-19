# OsiriX Backup Plugin Test Plans

This document consolidates the automated coverage introduced with the Swift migration and the manual validation steps required inside OsiriX.

## Automated Regression Suite

| Area | Scenario | Entry Point |
| ---- | -------- | ----------- |
| Findscu discovery | `FindscuLocatorTests` validates cached path reuse, fallback discovery across candidate paths, bundled executable detection, and error handling for corrupted binaries. | `Tests/OsiriXBackupPluginTests/FindscuLocatorTests.swift` |
| Transfer queue | `OsiriXBackupCoreTests` exercises priority-aware scheduling, progress aggregation, retry gating, and cancellation logic. | `Tests/OsiriXBackupPluginTests/OsiriXBackupCoreTests.swift` |
| Incremental verification | `testIntegrityValidatorDetectsIncrementalChanges` confirms that hash mismatches are detected when study content changes, preventing redundant uploads. | `Tests/OsiriXBackupPluginTests/OsiriXBackupCoreTests.swift` |
| Manifest generation | `testIntegrityValidatorGeneratesValidManifest` ensures manifests include hashes, series metadata, and image totals before persistence. | `Tests/OsiriXBackupPluginTests/OsiriXBackupCoreTests.swift` |

Run all automated checks with:

```bash
swift test
```

## Manual Validation in OsiriX

Perform these steps in a staging OsiriX environment with the Swift plugin build:

1. **Install and launch**
   - Build the plugin with Xcode (Release configuration) and copy the bundle into `~/Library/Application Support/OsiriX/Plugins`.
   - Start OsiriX and confirm that the "Backup DICOM" menu entry is visible under *Plugins*.
2. **Configuration window smoke test**
   - Open *Configurações de Backup* and verify that host, port, AE titles, and verification toggles persist after closing and reopening the window.
   - Toggle "Pular verificação" and confirm that the UI disables the findscu picker.
3. **findscu detection workflow**
   - With a valid DCMTK installation, start a backup and ensure the UI does not prompt for the executable.
   - Temporarily rename the binary and restart the backup to confirm that the missing findscu alert appears and offers to skip verification.
4. **Queue processing and progress**
   - Select multiple studies and trigger a backup.
   - Observe that at most two transfers run concurrently, the progress indicator advances, and the status label updates with the active study UID.
   - Pause and resume the backup, confirming that queued items retain their order and retry counters.
5. **Incremental verification**
   - Complete a transfer, run the job again, and confirm that already-uploaded studies are skipped quickly (cache hit).
   - Modify a series (delete an image) and rerun the backup to ensure the study re-queues and reports a hash mismatch in the log.
6. **Manifest export and reporting**
   - After a successful batch, inspect the generated manifest file (if configured) and verify that the reported image count matches OsiriX.
   - Review the summary alert/log and confirm that failures are highlighted with actionable messaging.
7. **UI regression sweep**
   - Exercise the close, pause, stop, and resume buttons to ensure they enable/disable according to the current state.
   - Resize the configuration window and verify that controls stay anchored.

> **Note:** Capture logs (`~/Library/Logs/OsiriXBackup.log`) during testing to document the run and attach them to migration QA reports.
