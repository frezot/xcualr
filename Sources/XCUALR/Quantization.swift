import Foundation
import CoreGraphics

enum ImageFormat {
    case png
    case jpeg
}

struct IndexedImage {
    let width: Int
    let height: Int
    let indices: [UInt8]
    let palette: [UInt8]

    func makeCGImage() -> CGImage? {
        guard !palette.isEmpty, palette.count.isMultiple(of: 3) else {
            return nil
        }
        let lastIndex = palette.count / 3 - 1
        guard let colorSpace = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: lastIndex, colorTable: palette) else {
            return nil
        }
        let data = Data(indices)
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

struct SwiftPaletteQuantizer {
    private static let binLevels = 32
    private static let histogramSize = binLevels * binLevels * binLevels
    private static let ditherStrength: Float = 1.0
    private static let luminanceWeights: (Float, Float, Float) = (0.2126, 0.7152, 0.0722)

    private static let srgbToLinear: [Float] = {
        (0..<256).map { value in
            let c = Float(value) / 255.0
            if c <= 0.04045 {
                return c / 12.92
            }
            return pow((c + 0.055) / 1.055, 2.4)
        }
    }()

    struct HistogramBin {
        let r: Float
        let g: Float
        let b: Float
        let weight: Int
    }

    struct LinearColor {
        var r: Float
        var g: Float
        var b: Float
    }

    private struct HistogramAccumulator {
        var weight: Int = 0
        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0
    }

    private struct ColorBox {
        let indices: [Int]

        func score(histogram: [HistogramBin]) -> Float {
            guard !indices.isEmpty else {
                return 0
            }
            let mean = meanColor(histogram: histogram)
            var varianceR: Float = 0
            var varianceG: Float = 0
            var varianceB: Float = 0
            for index in indices {
                let bin = histogram[index]
                let weight = Float(bin.weight)
                let dr = bin.r - mean.r
                let dg = bin.g - mean.g
                let db = bin.b - mean.b
                varianceR += dr * dr * weight
                varianceG += dg * dg * weight
                varianceB += db * db * weight
            }
            return max(varianceR, varianceG, varianceB)
        }

        func meanColor(histogram: [HistogramBin]) -> LinearColor {
            var sumR: Float = 0
            var sumG: Float = 0
            var sumB: Float = 0
            var totalWeight: Float = 0
            for index in indices {
                let bin = histogram[index]
                let weight = Float(bin.weight)
                sumR += bin.r * weight
                sumG += bin.g * weight
                sumB += bin.b * weight
                totalWeight += weight
            }
            guard totalWeight > 0 else {
                return LinearColor(r: 0, g: 0, b: 0)
            }
            return LinearColor(
                r: sumR / totalWeight,
                g: sumG / totalWeight,
                b: sumB / totalWeight
            )
        }

        func split(histogram: [HistogramBin]) -> (ColorBox, ColorBox)? {
            guard indices.count > 1 else {
                return nil
            }

            let axis = dominantAxis(histogram: histogram)
            let sorted = indices.sorted { lhs, rhs in
                switch axis {
                case .r:
                    return histogram[lhs].r < histogram[rhs].r
                case .g:
                    return histogram[lhs].g < histogram[rhs].g
                case .b:
                    return histogram[lhs].b < histogram[rhs].b
                }
            }
            let totalWeight = sorted.reduce(0) { $0 + histogram[$1].weight }
            guard totalWeight > 1 else {
                return nil
            }

            let halfWeight = totalWeight / 2
            var accumulated = 0
            var splitIndex = 0
            for (index, histogramIndex) in sorted.enumerated() {
                accumulated += histogram[histogramIndex].weight
                if accumulated >= halfWeight {
                    splitIndex = index + 1
                    break
                }
            }

            if splitIndex <= 0 || splitIndex >= sorted.count {
                splitIndex = sorted.count / 2
            }
            guard splitIndex > 0, splitIndex < sorted.count else {
                return nil
            }

            let left = Array(sorted[..<splitIndex])
            let right = Array(sorted[splitIndex...])
            guard !left.isEmpty, !right.isEmpty else {
                return nil
            }
            return (ColorBox(indices: left), ColorBox(indices: right))
        }

        private func dominantAxis(histogram: [HistogramBin]) -> Axis {
            let mean = meanColor(histogram: histogram)
            var varianceR: Float = 0
            var varianceG: Float = 0
            var varianceB: Float = 0
            for index in indices {
                let bin = histogram[index]
                let weight = Float(bin.weight)
                let dr = bin.r - mean.r
                let dg = bin.g - mean.g
                let db = bin.b - mean.b
                varianceR += dr * dr * weight
                varianceG += dg * dg * weight
                varianceB += db * db * weight
            }
            if varianceR >= varianceG && varianceR >= varianceB {
                return .r
            }
            if varianceG >= varianceB {
                return .g
            }
            return .b
        }

        private enum Axis {
            case r
            case g
            case b
        }
    }

    static func quantize(image: CGImage, colors requestedColors: Int) throws -> IndexedImage? {
        let targetColors = min(max(requestedColors, 2), 256)
        let (pixels, width, height) = try decodeImage(image)
        let histogram = buildHistogram(from: pixels)
        guard histogram.count > targetColors else {
            return nil
        }

        let boxes = splitBoxes(histogram: histogram, targetColors: targetColors)
        guard !boxes.isEmpty else {
            return nil
        }

        var palette = boxes.map { $0.meanColor(histogram: histogram) }
        palette = refinePalette(histogram: histogram, palette: palette, passes: 2)
        let lookup = buildLookupTable(palette: palette)
        let output = try remap(
            pixels: pixels,
            width: width,
            height: height,
            palette: palette,
            lookup: lookup
        )
        return IndexedImage(
            width: width,
            height: height,
            indices: output,
            palette: palette.flatMap { color in
                [linearToSrgb(color.r), linearToSrgb(color.g), linearToSrgb(color.b)]
            }
        )
    }

    private static func decodeImage(_ image: CGImage) throws -> ([UInt8], Int, Int) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else {
                return false
            }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard success else {
            throw CLIError.processFailed("Failed to decode image for quantization")
        }
        return (pixels, width, height)
    }

    private static func buildHistogram(from pixels: [UInt8]) -> [HistogramBin] {
        var accumulators = Array(repeating: HistogramAccumulator(), count: histogramSize)

        pixels.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            let pixelCount = pixels.count / 4
            for index in 0..<pixelCount {
                let offset = index * 4
                var r = Int(pointer[offset])
                var g = Int(pointer[offset + 1])
                var b = Int(pointer[offset + 2])
                let a = Int(pointer[offset + 3])
                if a == 0 {
                    r = 255
                    g = 255
                    b = 255
                } else if a < 255 {
                    r = min(255, r + 255 - a)
                    g = min(255, g + 255 - a)
                    b = min(255, b + 255 - a)
                }

                let binIndex = histogramIndex(red: r, green: g, blue: b)
                let linearR = srgbToLinear[r]
                let linearG = srgbToLinear[g]
                let linearB = srgbToLinear[b]

                accumulators[binIndex].weight += 1
                accumulators[binIndex].sumR += linearR
                accumulators[binIndex].sumG += linearG
                accumulators[binIndex].sumB += linearB
            }
        }

        var histogram: [HistogramBin] = []
        histogram.reserveCapacity(4096)
        for accumulator in accumulators where accumulator.weight > 0 {
            let weight = Float(accumulator.weight)
            histogram.append(HistogramBin(
                r: accumulator.sumR / weight,
                g: accumulator.sumG / weight,
                b: accumulator.sumB / weight,
                weight: accumulator.weight
            ))
        }
        return histogram
    }

    private static func splitBoxes(histogram: [HistogramBin], targetColors: Int) -> [ColorBox] {
        var boxes = [ColorBox(indices: Array(histogram.indices))]
        while boxes.count < targetColors {
            var bestIndex: Int?
            var bestScore: Float = 0
            for (index, box) in boxes.enumerated() {
                let score = box.score(histogram: histogram)
                if score > bestScore, box.indices.count > 1 {
                    bestScore = score
                    bestIndex = index
                }
            }

            guard let index = bestIndex, let split = boxes[index].split(histogram: histogram) else {
                break
            }

            boxes[index] = split.0
            boxes.append(split.1)
        }
        return boxes
    }

    private static func refinePalette(histogram: [HistogramBin], palette: [LinearColor], passes: Int) -> [LinearColor] {
        guard !palette.isEmpty else {
            return palette
        }

        var currentPalette = palette
        for _ in 0..<max(passes, 0) {
            var sums = Array(repeating: (r: Float(0), g: Float(0), b: Float(0), weight: Int(0)), count: currentPalette.count)
            for bin in histogram {
                let index = nearestPaletteIndex(for: bin, palette: currentPalette)
                let weight = bin.weight
                sums[index].r += bin.r * Float(weight)
                sums[index].g += bin.g * Float(weight)
                sums[index].b += bin.b * Float(weight)
                sums[index].weight += weight
            }

            for index in sums.indices where sums[index].weight > 0 {
                let weight = Float(sums[index].weight)
                currentPalette[index] = LinearColor(
                    r: sums[index].r / weight,
                    g: sums[index].g / weight,
                    b: sums[index].b / weight
                )
            }
        }
        return currentPalette
    }

    private static func buildLookupTable(palette: [LinearColor]) -> [Int] {
        var lookup = [Int](repeating: 0, count: histogramSize)
        for red in 0..<binLevels {
            for green in 0..<binLevels {
                for blue in 0..<binLevels {
                    let bin = histogramIndex(red: red * 8 + 4, green: green * 8 + 4, blue: blue * 8 + 4)
                    let sample = LinearColor(
                        r: srgbToLinear[min(red * 8 + 4, 255)],
                        g: srgbToLinear[min(green * 8 + 4, 255)],
                        b: srgbToLinear[min(blue * 8 + 4, 255)]
                    )
                    lookup[bin] = nearestPaletteIndex(for: sample, palette: palette)
                }
            }
        }
        return lookup
    }

    private static func remap(
        pixels: [UInt8],
        width: Int,
        height: Int,
        palette: [LinearColor],
        lookup: [Int]
    ) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height)
        var currentErrorR = [Float](repeating: 0, count: width + 2)
        var currentErrorG = [Float](repeating: 0, count: width + 2)
        var currentErrorB = [Float](repeating: 0, count: width + 2)
        var nextErrorR = [Float](repeating: 0, count: width + 2)
        var nextErrorG = [Float](repeating: 0, count: width + 2)
        var nextErrorB = [Float](repeating: 0, count: width + 2)

        pixels.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                swap(&currentErrorR, &nextErrorR)
                swap(&currentErrorG, &nextErrorG)
                swap(&currentErrorB, &nextErrorB)
                nextErrorR = [Float](repeating: 0, count: width + 2)
                nextErrorG = [Float](repeating: 0, count: width + 2)
                nextErrorB = [Float](repeating: 0, count: width + 2)

                let rowOffset = y * width * 4
                for x in 0..<width {
                    let pixelOffset = rowOffset + x * 4
                    var red = Int(pointer[pixelOffset])
                    var green = Int(pointer[pixelOffset + 1])
                    var blue = Int(pointer[pixelOffset + 2])
                    let alpha = Int(pointer[pixelOffset + 3])
                    if alpha == 0 {
                        red = 255
                        green = 255
                        blue = 255
                    } else if alpha < 255 {
                        red = min(255, red + 255 - alpha)
                        green = min(255, green + 255 - alpha)
                        blue = min(255, blue + 255 - alpha)
                    }

                    var linearR = srgbToLinear[red] + currentErrorR[x + 1] * ditherStrength
                    var linearG = srgbToLinear[green] + currentErrorG[x + 1] * ditherStrength
                    var linearB = srgbToLinear[blue] + currentErrorB[x + 1] * ditherStrength
                    linearR = clamp(linearR)
                    linearG = clamp(linearG)
                    linearB = clamp(linearB)

                    let sr = Int(linearToSrgb(linearR))
                    let sg = Int(linearToSrgb(linearG))
                    let sb = Int(linearToSrgb(linearB))
                    let paletteIndex = lookup[histogramIndex(red: sr, green: sg, blue: sb)]
                    output[y * width + x] = UInt8(paletteIndex)

                    let errorR = linearR - palette[paletteIndex].r
                    let errorG = linearG - palette[paletteIndex].g
                    let errorB = linearB - palette[paletteIndex].b

                    currentErrorR[x + 2] += errorR * 7.0 / 16.0
                    currentErrorG[x + 2] += errorG * 7.0 / 16.0
                    currentErrorB[x + 2] += errorB * 7.0 / 16.0

                    nextErrorR[x] += errorR * 3.0 / 16.0
                    nextErrorG[x] += errorG * 3.0 / 16.0
                    nextErrorB[x] += errorB * 3.0 / 16.0

                    nextErrorR[x + 1] += errorR * 5.0 / 16.0
                    nextErrorG[x + 1] += errorG * 5.0 / 16.0
                    nextErrorB[x + 1] += errorB * 5.0 / 16.0

                    nextErrorR[x + 2] += errorR * 1.0 / 16.0
                    nextErrorG[x + 2] += errorG * 1.0 / 16.0
                    nextErrorB[x + 2] += errorB * 1.0 / 16.0
                }
            }
        }

        return output
    }

    private static func nearestPaletteIndex(for color: HistogramBin, palette: [LinearColor]) -> Int {
        nearestPaletteIndex(
            for: LinearColor(r: color.r, g: color.g, b: color.b),
            palette: palette
        )
    }

    private static func nearestPaletteIndex(for color: LinearColor, palette: [LinearColor]) -> Int {
        var bestIndex = 0
        var bestDistance = Float.greatestFiniteMagnitude
        let (wr, wg, wb) = luminanceWeights
        for (index, candidate) in palette.enumerated() {
            let dr = color.r - candidate.r
            let dg = color.g - candidate.g
            let db = color.b - candidate.b
            let distance = dr * dr * wr + dg * dg * wg + db * db * wb
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func histogramIndex(red: Int, green: Int, blue: Int) -> Int {
        let r = clampComponent(red) >> 3
        let g = clampComponent(green) >> 3
        let b = clampComponent(blue) >> 3
        return (r << 10) | (g << 5) | b
    }

    private static func clampComponent(_ value: Int) -> Int {
        min(max(value, 0), 255)
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func linearToSrgb(_ value: Float) -> UInt8 {
        let clamped = clamp(value)
        let srgb: Float
        if clamped <= 0.0031308 {
            srgb = clamped * 12.92
        } else {
            srgb = 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        }
        return UInt8(max(0, min(255, Int((srgb * 255.0).rounded()))))
    }
}
