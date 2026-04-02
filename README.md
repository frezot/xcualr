# XCUALR

The High-Quality way to render Xcode results.

**xcualr** (pronounced *ex-qual-er*) stands for **XCode Ultimate ALlure Renderer**.

xcualr is a native Swift command-line tool for turning `.xcresult` bundles into polished Allure-compatible output. It is designed to be fast, deterministic, and easy to run in CI without extra runtime helpers.

---

## Installation

### For Apple Silicon Macs (`arm64`)

1. Download the executable file:
```sh
wget https://github.com/frezot/xcualr/releases/latest/download/xcualr
```

2. Make the file executable:
```sh
chmod +x xcualr
```

### For Intel Macs (`x86_64`)

1. Download the executable file:
```sh
wget https://github.com/frezot/xcualr/releases/latest/download/xcualr-x86_64 -O xcualr
```

2. Make the file executable:
```sh
chmod +x xcualr
```

### Homebrew

If you want a `brew install xcualr` formula sooner, give the repo a star ⭐️ on GitHub.

It helps show demand and makes it easier to prioritize publishing and maintaining the formula.

## Usage

- `--image-scale <int>` controls image downscaling before export. Default is `3`.
- `--passed-step-image-palette-colors <int>` controls palette quantization for passed-step screenshots. Default is `64`.
- If `pngquant` is installed, xcualr will use it for PNG palette optimization and fall back to the native Swift quantizer otherwise.
- Installing `pngquant` gives faster PNG quantization and usually better compression than the native fallback, while keeping the binary usable without it.
- `--raw-attachments` keeps attachments as-is; HEIC/HEIF stay in their original format and image conversion is skipped.
- `-f, --force` removes the output directory before exporting.

Example:

```sh
./xcualr export build/Logs/Test/TestRunner.xcresult -o build/Allure -f
```

---

## What xcualr improves

xcualr exists to make `.xcresult` exports predictable, fast, and low-maintenance:

- native Swift instead of Ruby or Python wrappers
- deterministic staging and output layout
- focused attachment handling and step mapping
- stable image processing with a fast path for PNG optimization
- no runtime dependencies unless you opt into the helper-assisted path

## Credits

Inspired by the original [xcresults](https://github.com/eroshenkoam/xcresults) by @eroshenkoam.
Rebuilt in Swift for better performance and stability.
