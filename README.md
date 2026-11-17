# XCUALR

__xcualr__ (pronounced *ex-qual-er*) stands for **XCode Ultimate ALlure Renderer**.

__xcualr__ is a native Swift command-line tool that exports Xcode `.xcresult` bundles into Allure-compatible test results and attachments.

The output directory can be used as regular Allure results:

- run `allure serve "$ALLURE_RESULTS"` to inspect the report locally
- run `allurectl upload "$ALLURE_RESULTS"` to upload it to Allure TestOps

## Why this exists

The existing [`xcresults`](https://github.com/eroshenkoam/xcresults) project already solves this problem for many teams, but it still has rough edges with some attachment types, especially HEIC images.

__xcualr__ is a native Swift rework focused on fixing those attachment-export gaps while staying as compatible as possible with the shape and format of the existing Allure output.

## What xcualr does

- converts `.xcresult` into Allure-compatible result JSON
- optionally writes a JUnit XML report in the same export
- exports screenshots, logs, screen recordings, and other test attachments
- keeps the export format close to the existing `xcresults` output
- handles HEIC and HEIF attachments by converting them to PNG (unless raw export is requested)
- can downscale large images so modern-device screenshots do not dominate report size
- can reduce palette depth for passed-step screenshots to keep reports smaller

## Attachment handling

Modern iPhone screenshots can be large enough to make Allure results heavy and slow to work with. 
__xcualr__ includes two pragmatic controls for that:

- `--image-scale <int>` downsizes exported images before they are written to the Allure results directory
- `--passed-step-image-palette-colors <int>` reduces palette depth for passed-step screenshots, where rough visual context is often more important than pixel-perfect fidelity

If size and format preservation matter more than optimization, use `--raw-attachments` to export attachments as-is.

## Installation

### Apple Silicon (`arm64`)

```sh
sudo sh -c 'curl -L https://github.com/frezot/xcualr/releases/latest/download/xcualr -o /usr/local/bin/xcualr && chmod +x /usr/local/bin/xcualr'
```

### Intel (`x86_64`)

```sh
sudo sh -c 'curl -L https://github.com/frezot/xcualr/releases/latest/download/xcualr-x86_64 -o /usr/local/bin/xcualr && chmod +x /usr/local/bin/xcualr'
```

### Build from source

```sh
swift build -c release
```

The binary will be available at:

```sh
.build/release/xcualr
```

## Usage

```sh
xcualr export <path-to-xcresult> -o <output-dir> [options]
```

Options:

- `--junit <file.xml>`: also write JUnit XML (replaces the file; creates parent directories)
- `--image-scale <int>`: downscale exported images, default `3`
- `--passed-step-image-palette-colors <int>`: palette size for passed-step screenshots, default `64`
- `--raw-attachments`: keep attachments as-is; HEIC and HEIF stay in their original format
- `-f`, `--force`: clear the output directory before exporting

Example:

```sh
xcualr export <path-to-xcresult> -o build/allure-results

allure serve build/allure-results
```

Example for Allure TestOps:

```sh
xcualr export <path-to-xcresult> -o build/allure-results

allurectl upload --ignore-passed-test-attachments build/allure-results
```

Example for JUnit and Allure together:

```sh
xcualr export <path-to-xcresult> -o build/allure-results --junit build/junit.xml
```

JUnit uses real per-test durations, counts expected failures as passed, and combines
all failure messages and the trace in one failure element per test. Failure text
uses typographic quotes and arrows. The report describes the current bundle only,
even when Allure artifacts are appended to an existing directory. Unknown test
statuses cause JUnit export to fail rather than being reported as passed.

A JUnit file inside the Allure directory is staged with the Allure artifacts,
including with `--force`. The path must not overwrite an exported artifact or a
file inside the input bundle. An external JUnit file and the Allure directory are
published independently; a report write error leaves the existing Allure output intact.

## Design notes

- native Swift implementation with no required runtime dependencies
- `pngquant` is used for PNG optimization when available and the native Swift quantizer is used as a fallback
- raw export is available when you want original attachments without image conversion or palette optimization
- the project is intended to stay simple to run in CI on macOS

## Verification

```sh
swift test
./package.sh
python3 Tests/check_junit.py
```

The integration check uses the release binary and the bundles in `examples/`,
including a fresh merged bundle for each run. It validates XML, counts, durations,
failure text, deterministic output, append/replace behavior, preservation of old
output on report errors, and byte-for-byte Allure parity with and without
`--junit` using raw attachments. Generated files stay in `examples/tmp/junit-check/`.

Pass `--reference /path/to/previous/xcualr` to also compare Allure artifacts with
a previous release (exact file contents; no fields ignored). Optional bundle
paths select specific fixtures without creating a merged bundle.

## Credits

Inspired by the original [xcresults](https://github.com/eroshenkoam/xcresults) by [@eroshenkoam](https://github.com/eroshenkoam)
