# Changelog

All notable changes to this project will be documented in this file.

## 0.1.5

- Changed JUnit suite durations to wall-clock time using the same test start/stop timestamps as Allure, with the previous summed duration as fallback when timestamps are incomplete. Individual testcase durations and counts are unchanged.

## 0.1.4

- Added optional `--junit <file.xml>` export alongside Allure using the same parsed test details.
- Preserved real test durations and full failure text in flat JUnit reports with consistent counts and expected failures treated as passed.
- Rejected unknown JUnit test statuses and conflicting report paths, and retained failure messages from repeated runs without duplicating them across data sources.
- Staged reports inside the Allure directory and preserved existing output when report creation failed.
- Fixed forced directory replacement and preserved nested report siblings when appending exports.
- Loaded issue and activity catalogs after xcresulttool initialized fresh merged bundles, keeping the first export consistent with later exports.
- Fixed missing Allure failure messages for merged multi-device bundles by sharing failure collection with JUnit, preserving assertion order and repeated failures.

## 0.1.3

- Added a per-test `host` label derived from each test's run device, so Allure's timeline separates results by device even for merged multi-device `.xcresult` bundles.
- Set the `runDestination` label per test from the same device info instead of the summary's first device.

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
