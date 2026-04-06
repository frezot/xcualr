# Changelog

All notable changes to this project will be documented in this file.

## 0.1.2

- Added the CLI version to the export start log line and reformatted it onto two lines for easier CI log reading.
- Simplified the startup logging code by removing terminal color handling from the export banner.

## 0.1.1

- Split the former monolithic `main.swift` into focused Swift source files by responsibility.
- Added path-namespaced deterministic result and attachment file names to reduce collisions when combining exports from different `.xcresult` bundles.
- Changed export finalization so repeated exports into an existing output directory append artifacts when `--force` is not used.

## 0.1.0

- First public release of the native Swift `.xcresult` to Allure exporter.
- Added attachment export with HEIC and HEIF conversion to PNG unless `--raw-attachments` is used.
- Added image downscaling and passed-step PNG palette reduction controls.
- Kept output format close to the existing `xcresults` tool while focusing on native Swift execution on macOS.
