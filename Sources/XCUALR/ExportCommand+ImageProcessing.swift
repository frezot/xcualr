import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib

extension ExportCommand {
    func convertHEICImage(at sourceURL: URL, to destinationURL: URL, scale: Int) throws {
        guard let sourceImage = NSImage(contentsOf: sourceURL) else {
            throw CLIError.processFailed("Failed to read image: \(sourceURL.path)")
        }

        guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CLIError.processFailed("Failed to decode image: \(sourceURL.path)")
        }

        let pixelScale = max(scale, 1)
        let targetWidth = max(cgImage.width / pixelScale, 1)
        let targetHeight = max(cgImage.height / pixelScale, 1)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CLIError.processFailed("Failed to create graphics context for: \(sourceURL.path)")
        }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let rendered = context.makeImage() else {
            throw CLIError.processFailed("Failed to render image: \(sourceURL.path)")
        }

        try writePNGImage(rendered, to: destinationURL)
    }

    func convertImage(at sourceURL: URL, to destinationURL: URL, format: ImageFormat, scale: Int) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw CLIError.processFailed("Failed to read image: \(sourceURL.path)")
        }

        let scale = max(scale, 1)
        let image: CGImage
        if scale > 1 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let maxPixelSize = max(max(sourceWidth, sourceHeight) / scale, 1)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw CLIError.processFailed("Failed to create image thumbnail: \(sourceURL.path)")
            }
            image = try normalizedImage(from: thumbnail, sourceName: sourceURL.lastPathComponent)
        } else {
            guard let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CLIError.processFailed("Failed to read image: \(sourceURL.path)")
            }
            image = fullImage
        }

        let destinationType = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, destinationType as CFString, 1, nil) else {
            throw CLIError.processFailed("Failed to create destination for \(destinationURL.lastPathComponent)")
        }
        if format == .png {
            CGImageDestinationAddImage(destination, opaqueImage(from: image) ?? image, nil)
        } else {
            let options = [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
            CGImageDestinationAddImage(destination, image, options)
        }
        if !CGImageDestinationFinalize(destination) {
            throw CLIError.processFailed("Failed to finalize image: \(destinationURL.lastPathComponent)")
        }
    }

    private func normalizedImage(from image: CGImage, sourceName: String) throws -> CGImage {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CLIError.processFailed("Failed to allocate image context for \(sourceName)")
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else {
            throw CLIError.processFailed("Failed to normalize image: \(sourceName)")
        }
        return normalized
    }

    private func writePNGImage(_ image: CGImage, to destinationURL: URL) throws {
        let destinationType = UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, destinationType, 1, nil) else {
            throw CLIError.processFailed("Failed to create destination for \(destinationURL.lastPathComponent)")
        }
        let opaqueImage = opaqueImage(from: image) ?? image
        CGImageDestinationAddImage(destination, opaqueImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.processFailed("Failed to finalize image: \(destinationURL.lastPathComponent)")
        }
    }

    private func writePNGImage(_ image: IndexedImage, to destinationURL: URL) throws {
        let data = try encodeIndexedPNG(image)
        try data.write(to: destinationURL)
    }

    private func encodeIndexedPNG(_ image: IndexedImage) throws -> Data {
        var data = Data()
        data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        data.append(pngChunk(type: "IHDR", payload: try pngIHDRPayload(width: image.width, height: image.height)))
        data.append(pngChunk(type: "PLTE", payload: Data(image.palette)))
        data.append(pngChunk(type: "IDAT", payload: try pngIDATPayload(image: image)))
        data.append(pngChunk(type: "IEND", payload: Data()))
        return data
    }

    private func pngIHDRPayload(width: Int, height: Int) throws -> Data {
        var payload = Data()
        payload.append(bigEndian(width))
        payload.append(bigEndian(height))
        payload.append(UInt8(8))
        payload.append(UInt8(3))
        payload.append(UInt8(0))
        payload.append(UInt8(0))
        payload.append(UInt8(0))
        return payload
    }

    private func pngIDATPayload(image: IndexedImage) throws -> Data {
        let rowLength = image.width + 1
        var raw = Data(count: rowLength * image.height)
        raw.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            image.indices.withUnsafeBytes { indexBuffer in
                guard let indexBase = indexBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                for y in 0..<image.height {
                    let rawRow = y * rowLength
                    base[rawRow] = 0
                    let sourceOffset = y * image.width
                    memcpy(base.advanced(by: rawRow + 1), indexBase.advanced(by: sourceOffset), image.width)
                }
            }
        }

        let compressedLength = compressBound(uLong(raw.count))
        var compressed = Data(count: Int(compressedLength))
        var destinationLength = compressedLength
        let result = compressed.withUnsafeMutableBytes { compressedBuffer -> Int32 in
            guard let compressedBase = compressedBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                return Z_MEM_ERROR
            }
            return raw.withUnsafeBytes { rawBuffer -> Int32 in
                guard let rawBase = rawBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                    return Z_MEM_ERROR
                }
                return compress2(
                    compressedBase,
                    &destinationLength,
                    rawBase,
                    uLong(raw.count),
                    Z_BEST_COMPRESSION
                )
            }
        }
        guard result == Z_OK else {
            throw CLIError.processFailed("Failed to compress PNG data")
        }
        compressed.removeSubrange(Int(destinationLength)..<compressed.count)
        return compressed
    }

    private func pngChunk(type: String, payload: Data) -> Data {
        var chunk = Data()
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { chunk.append(contentsOf: $0) }
        let typeBytes = Array(type.utf8)
        chunk.append(contentsOf: typeBytes)
        chunk.append(payload)
        var crc: uLong = crc32(0, nil, 0)
        crc = typeBytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return crc
            }
            return crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(typeBytes.count))
        }
        crc = payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return crc
            }
            return crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(payload.count))
        }
        let crcBE = UInt32(crc).bigEndian
        withUnsafeBytes(of: crcBE) { chunk.append(contentsOf: $0) }
        return chunk
    }

    private func bigEndian(_ value: Int) -> Data {
        var bigEndianValue = UInt32(value).bigEndian
        return Data(bytes: &bigEndianValue, count: 4)
    }

    private func opaqueImage(from image: CGImage) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    func optimizePassedStepAttachments(in steps: [AllureStep],
                                       outputURL: URL,
                                       parentBranchPassed: Bool = true) {
        let urls = collectPassedStepAttachmentURLs(in: steps, outputURL: outputURL, parentBranchPassed: parentBranchPassed)
        let pngURLs = Array(Set(urls))
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.path < $1.path }
        guard !pngURLs.isEmpty else {
            return
        }
        for url in pngURLs {
            do {
                try optimizePNGPaletteNatively(at: url)
            } catch {
                continue
            }
        }
    }

    private func collectPassedStepAttachmentURLs(in steps: [AllureStep],
                                                 outputURL: URL,
                                                 parentBranchPassed: Bool) -> [URL] {
        var urls: [URL] = []
        for step in steps {
            let currentBranchPassed = parentBranchPassed && step.status == "passed"
            if currentBranchPassed {
                urls.append(contentsOf: step.attachments.map { outputURL.appendingPathComponent($0.source) })
            }
            urls.append(contentsOf: collectPassedStepAttachmentURLs(
                in: step.steps,
                outputURL: outputURL,
                parentBranchPassed: currentBranchPassed
            ))
        }
        return urls
    }

    private func optimizePNGPaletteNatively(at url: URL) throws {
        guard configuration.passedStepImagePaletteColors > 0 else {
            return
        }
        guard let originalSize = fileSize(at: url),
              originalSize >= Self.paletteOptimizationMinimumSizeBytes else {
            return
        }
        if !configuration.noLibs, let pngQuantPath {
            do {
                try optimizePNGPaletteWithPNGQuant(at: url, executablePath: pngQuantPath, originalSize: originalSize)
                return
            } catch {
            }
        } else {
            logPngQuantHintIfNeeded()
        }
        guard let sourceImage = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decodedImage = CGImageSourceCreateImageAtIndex(sourceImage, 0, nil) else {
            return
        }

        guard let quantizedImage = try SwiftPaletteQuantizer.quantize(
            image: decodedImage,
            colors: configuration.passedStepImagePaletteColors
        ) else {
            return
        }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-quantized.png")
        try? FileManager.default.removeItem(at: temporaryURL)
        try writePNGImage(quantizedImage, to: temporaryURL)

        let quantizedSize = fileSize(at: temporaryURL)
        guard let quantizedSize, quantizedSize < originalSize else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private func optimizePNGPaletteWithPNGQuant(at url: URL,
                                                executablePath: String,
                                                originalSize: Int64) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-pngquant.png")
        try? FileManager.default.removeItem(at: temporaryURL)

        let colors = max(2, min(configuration.passedStepImagePaletteColors, 256))
        _ = try runCommand(
            executablePath: executablePath,
            arguments: [
                "--speed", "1",
                "--strip",
                "--force",
                "--output", temporaryURL.path,
                "--colors", "\(colors)",
                url.path
            ]
        )

        guard let quantizedSize = fileSize(at: temporaryURL),
              quantizedSize < originalSize else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }
}
