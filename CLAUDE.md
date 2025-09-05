# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an OsiriX plugin project that provides DICOM backup functionality. The plugin is built as a macOS bundle (.osirixplugin) that integrates with OsiriX medical imaging software. The codebase includes both Objective-C and Swift components, using a bridging header for interoperability.

## Build Commands

```bash
# Build the plugin for Release configuration
xcodebuild -project OsiriXTestPlugin.xcodeproj -scheme OsiriXTestPlugin -configuration Release build

# Build for Debug configuration
xcodebuild -project OsiriXTestPlugin.xcodeproj -scheme OsiriXTestPlugin -configuration Debug build

# Clean build artifacts
xcodebuild -project OsiriXTestPlugin.xcodeproj -scheme OsiriXTestPlugin clean
```

The built plugin will be located at:
`build/Release/OsiriXTestPlugin.osirixplugin` or `build/Debug/OsiriXTestPlugin.osirixplugin`

## Architecture

### Core Components

1. **OsiriXBackup (.h/.m)** - Main Objective-C plugin implementation
   - Handles DICOM study backup to remote PACS servers
   - Manages backup queue, transfer status, and verification
   - Uses DCMTKStoreSCU for DICOM transfers
   - Implements retry logic and concurrent transfer management

2. **Plugin.swift** - Swift plugin filter base class
   - Currently contains placeholder implementation (YOURPLUGINCLASS)
   - Uses PluginFilter base class from OsiriXAPI framework
   - Handles menu actions and window management

3. **OsiriXTestPlugin-Bridging-Header.h** - Swift/Objective-C bridge
   - Imports OsiriXAPI headers for Swift usage
   - Includes BrowserController, DicomStudy, DicomDatabase, WebPortal components

### Key Plugin Configuration

- **Principal Class**: OsiriXBackup (defined in Info.plist)
- **Plugin Type**: Database
- **Menu Items**: 
  - "Iniciar Backup DICOM" (Start DICOM Backup)
  - "Configurações de Backup" (Backup Settings)

### OsiriX API Integration

The plugin uses the OsiriXAPI.framework which provides:
- Access to DICOM database (DicomDatabase, DicomStudy, DicomSeries)
- DICOM network operations (DCMTKStoreSCU, QueryController)
- UI integration (BrowserController, PluginFilter)
- Web portal functionality (WebPortal, WebPortalUser)

## Development Notes

- The project uses Xcode 13.0+ compatibility
- Swift/Objective-C interoperability is handled through the bridging header
- The plugin expects OsiriX to be installed at standard locations (/Applications/OsiriX MD.app or /Applications/OsiriX.app)
- Settings UI is defined in Settings.xib
- Maximum 2 simultaneous DICOM transfers are configured (MAX_SIMULTANEOUS_TRANSFERS)