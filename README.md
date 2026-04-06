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

## Design notes

- native Swift implementation with no required runtime dependencies
- `pngquant` is used for PNG optimization when available and the native Swift quantizer is used as a fallback
- raw export is available when you want original attachments without image conversion or palette optimization
- the project is intended to stay simple to run in CI on macOS

## Credits

Inspired by the original [xcresults](https://github.com/eroshenkoam/xcresults) by [@eroshenkoam](https://github.com/eroshenkoam)
