# XCUALR

The High-Quality way to render Xcode results.

**XCUALR** (pronounced *ex-qual-er*) stands for **XCode Ultimate ALlure Renderer**.

XCUALR is a native Swift command-line tool for turning `.xcresult` bundles into polished Allure-compatible output. It is designed to be fast, deterministic, and easy to run in CI without extra runtime helpers.

---

## Runtime Options

- `--image-scale <int>` controls image downscaling before export. Default is `3`.
- `--passed-step-image-palette-colors <int>` controls palette quantization for passed-step screenshots. Default is `64`.
- `--raw-attachments` keeps attachments in their original format and skips image conversion.
- `--broken-config-path <path>` lets you mark known failure patterns as `broken`.

---

## Why XCUALR?

- **Fast**: native Swift implementation, no Ruby or Python wrapper.
- **Precise**: focuses on attachment handling, step mapping, and stable output.
- **Lightweight**: one binary, no runtime dependencies.
- **Deterministic**: predictable staging and output layout.

---

## Status

Public build and usage instructions will land closer to release.
For now, this repository is focused on the exporter itself and regression-safe output.

## Credits

Inspired by the original [xcresults](https://github.com/eroshenkoam/xcresults) by @eroshenkoam.
Rebuilt in Swift for better performance and stability.
