import ArgumentParser
import AppKit

struct RuntimeError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

func convertToGrayscale(cgImage: CGImage) -> CGImage? {
    let width = cgImage.width
    let height = cgImage.height
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: 0)

    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    return context?.makeImage()
}

@main
struct swift_image_processing_sample: ParsableCommand {

    @Argument(help: "The path to the input image (.png) file.", completion: .file())
    var inputImagePath: String

    @Option(name: .shortAndLong, help: "The path to the output image file.", completion: .file())
    var outputImagePath: String = "output.png"

    @Option(name: .shortAndLong, help: "The radius for BoxFilter. The radius must be equal or smaller then 7.")
    var radius: Int = 6

    mutating func run() throws {
        if radius > 7 {
            throw RuntimeError("The radius must be equal or smaller then 7.")
        }

        let filePath = URL(filePath: FileManager.default.currentDirectoryPath).appendingPathComponent(inputImagePath)
        let nsImage = NSImage(contentsOfFile: filePath.path)
        guard let originalCgImage = nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RuntimeError("Unable to read image: \(inputImagePath).")
        }

        // convert to grayscale
        let cgImage: CGImage
        if originalCgImage.colorSpace?.model == .monochrome {
            cgImage = originalCgImage
        } else if let grayScale = convertToGrayscale(cgImage: originalCgImage) {
            cgImage = grayScale
        } else {
            throw RuntimeError("Unable to convert image to grayscale.: \(inputImagePath).")
        }

        // please tell me better way to extract pixel data ([[UInt8]]) from Image file.
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let imageBuffer = rep.bitmapData else {
            throw RuntimeError("Unable to read image: \(inputImagePath).")
        }

        func saveImage(src: [[UInt8]]) throws {
            for y in 0..<src.count {
                for x in 0..<src[0].count {
                    imageBuffer[y * src[0].count  + x] = src[y][x]
                }
            }

            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                throw RuntimeError("Unable to convert image to PNG format.")
            }

            do {
                let path = outputImagePath.hasSuffix(".png") ? outputImagePath : "\(outputImagePath).png"
                try pngData.write(to: URL(fileURLWithPath: path))
                print("Image successfully saved to \(outputImagePath)")
            } catch {
                throw RuntimeError("Error saving image: \(error).")
            }
        }

        var image: [[UInt8]] = []
        for j in 0..<cgImage.height {
            var row: [UInt8] = []

            for i in 0..<cgImage.width {
                row.append(imageBuffer[j * cgImage.width + i])
            }

            image.append(row)
        }

        // benchmark

        let result = try benchmarkScalar2DBoxFilter(image: image, radius: radius)
        try saveImage(src: result)

        try benchmarkScalarSeparableBoxFilter(image: image, radius: radius)

        try benchmarkScalarSeparablePointerBoxFilter(image: image, radius: radius)

        try benckmarkSIMDSeparableBoxFilter(image: image, radius: radius)

        try benckmarkSIMDSeparablePointerBoxFilter(image: image, radius: radius)
    }
}

@discardableResult
func benchmarkScalar2DBoxFilter(image: [[UInt8]], radius: Int) throws -> [[UInt8]] {
    let image: [[UInt16]] = image.map { $0.map { UInt16($0) } }

    let height = image.count
    let width = image[0].count

    var result: [[UInt16]] = []

    let resultTime = benchmark(samples: 10, iterations: 10) {
        result = .init(repeating: .init(repeating: .zero, count: width), count: height)
        let extended = extendedImage(from: image, horizontal: radius, vertical: radius)
        let weight: UInt16 = UInt16(2 * radius + 1) * UInt16(2 * radius + 1)

        for y in 0..<height {
            for x in 0..<width {
                var sum = UInt16.zero
                for ry in -radius...radius {
                    for rx in -radius...radius {
                        sum += extended[y + ry + radius][x + rx + radius]
                    }
                }

                result[y][x] = sum / weight
            }
        }
    }

    print("scalar 2D \(Double(resultTime) / 1000_000.0) ms")

    return result.map { $0.map { UInt8($0) } }
}

@discardableResult
func benchmarkScalarSeparableBoxFilter(image: [[UInt8]], radius: Int) throws -> [[UInt8]] {
    let image: [[UInt16]] = image.map { $0.map { UInt16($0) } }
    let height = image.count
    let width = image[0].count

    let L = 2 * radius + 1
    var result: [[UInt16]] = []

    let resultTime = benchmark(samples: 100, iterations: 100) {
        result = .init(repeating: .init(repeating: .zero, count: width), count: height)
        let weight = UInt16(L * L)

        let widthExtended = width + 2 * radius
        var extended: [[UInt16]] = .init(repeating: [], count: L)
        for k in 0..<L-1 {
            extended[k] = extendedImageHorizontal(from: image[max(0, k - radius)], factor: radius)
        }

        for y in 0..<height {
            var yresult: [UInt16] = .init(repeating: 0, count: widthExtended)
            extended[L-1] = extendedImageHorizontal(from: image[min(height - 1, y + radius)], factor: radius)

            // yフィルタ
            for x in 0..<widthExtended {
                var sum = UInt16.zero
                for r in 0..<L {
                    sum += extended[r][x]
                }

                yresult[x] = sum
            }

            // xフィルタ
            for x in 0..<width {
                var sum = UInt16.zero
                for r in 0..<L {
                    sum += yresult[x+r]
                }

                result[y][x] = sum / weight
            }

            for k in 0..<L-1 {
                extended[k] = extended[k+1]
            }
        }
    }

    print("scalar separable \(Double(resultTime) / 1000_000.0) ms")

    return result.map { $0.map { UInt8($0) } }
}

@discardableResult
func benchmarkScalarSeparablePointerBoxFilter(image: [[UInt8]], radius: Int) throws -> [[UInt8]] {
    let height = image.count
    let width = image[0].count
    let L = 2 * radius + 1

    // convert [[UInt8]] -> UnsafeMutablePointer<UInt16>
    let imagePointer: UnsafeMutablePointer<UInt16> = .allocate(capacity: width * height)
    do {
        var pointer: UnsafeMutablePointer<UInt16> = imagePointer
        for y in 0..<height {
            for x in 0..<width {
                pointer.initialize(to: UInt16(image[y][x]))
                pointer = pointer.successor()
            }
        }
    }
    defer {
        imagePointer.deinitialize(count: width * height)
        imagePointer.deallocate()
    }

    var resultPointer: UnsafeMutableBufferPointer<UInt16> = .allocate(capacity: 0)
    let resultTime = benchmark(samples: 100, iterations: 100) {
        let widthExtended = width + 2 * radius
        let weight = UInt16(L * L)

        // 毎回deallocateしないとメモリリークするが
        // 一番最後の実験結果は必要なため先頭で行う
        resultPointer.deinitialize()
        resultPointer.deallocate()

        resultPointer = .allocate(capacity: width * height)
        resultPointer.initialize(repeating: .zero)

        let extendedPointer: UnsafeMutableBufferPointer<UnsafeMutableBufferPointer<UInt16>> = .allocate(capacity: L)
        for k in 0..<L {
            extendedPointer[k] = .allocate(capacity: widthExtended)
        }
        for k in 0..<L-1 {
            extendImage(
                from: imagePointer.advanced(by: max(0, k - radius) * width),
                srcWidth: width,
                extendTo: extendedPointer[k],
                extendRadius: radius
            )
        }

        let yresultPointer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: widthExtended)
        yresultPointer.initialize(repeating: .zero)

        for y in 0..<height {
            extendImage(
                from: imagePointer.advanced(by: min(height - 1, y + radius) * width),
                srcWidth: width,
                extendTo: extendedPointer[L-1],
                extendRadius: radius
            )

            for x in 0..<widthExtended {
                var sum = UInt16.zero
                for r in 0..<L {
                    sum += extendedPointer[r][x]
                }

                yresultPointer[x] = sum
            }

            for x in 0..<width {
                var sum = UInt16.zero
                for r in 0..<L {
                    sum += yresultPointer[x+r]
                }

                sum /= weight

                resultPointer[width * y + x] = sum
            }

            // ringBuffering
            let temp = extendedPointer.moveElement(from: 0)
            for k in 0..<L-1 {
                extendedPointer[k] = extendedPointer[k+1]
            }
            extendedPointer[L-1] = temp
        }

        yresultPointer.deinitialize()
        yresultPointer.deallocate()

        for k in 0..<L {
            extendedPointer[k].deinitialize()
            extendedPointer[k].deallocate()
        }
        extendedPointer.deinitialize()
        extendedPointer.deallocate()
    }

    print("scalar separable pointer \(Double(resultTime) / 1000_000.0) ms")

    var result: [[UInt8]] = .init(repeating: .init(repeating: .zero, count: width), count: height)

    for y in 0..<height {
        for x in 0..<width {
            result[y][x] = UInt8(resultPointer[y * width + x])
        }
    }

    return result
}

@discardableResult
func benckmarkSIMDSeparableBoxFilter(image: [[UInt8]], radius: Int) throws -> [[UInt8]] {
    let image: [[UInt16]] = image.map { $0.map { UInt16($0) } }

    let height = image.count
    let width = image[0].count
    let L = 2 * radius + 1
    var result: [[UInt16]] = []

    let resultTime = benchmark(samples: 100, iterations: 100) {
        result = .init(repeating: .init(repeating: .zero, count: width), count: height)
        let widthExtended = width + 2 * radius
        var extended: [[UInt16]] = .init(repeating: [], count: L)
        let weightSIMD = SIMD16<UInt16>(repeating: UInt16(L * L))
        for k in 0..<L-1 {
            extended[k] = extendedImageHorizontal(from: image[max(0, k - radius)], factor: radius)
        }

        var yresult: [UInt16] = .init(repeating: 0, count: widthExtended)

        for y in 0..<height {
            extended[L-1] = extendedImageHorizontal(from: image[min(height - 1, y + radius)], factor: radius)

            // yfilter
            do {
                var x = 0
                while x < widthExtended - 16 {
                    var sum = SIMD16<UInt16>.zero
                    for k in 0..<L {
                        sum &+= SIMD16<UInt16>(extended[k][x..<x+16])
                    }

                    for k in 0..<16 {
                        yresult[x+k] = sum[k]
                    }

                    x += 16
                }
            }
            // yfilter あまり処理
            do {
                let offset = widthExtended - 16

                var sum = SIMD16<UInt16>.zero
                for k in 0..<L {
                    sum &+= SIMD16<UInt16>(extended[k][offset..<offset+16])
                }

                for k in 0..<16 {
                    yresult[offset+k] = sum[k]
                }
            }

            // xfilter
            do {
                var x = 0
                while x < width - 16 {
                    var sum = SIMD16<UInt16>.zero

                    for k in 0..<L {
                        let startIndex = x + k
                        sum &+= SIMD16<UInt16>(yresult[startIndex..<startIndex+16])
                    }

                    sum /= weightSIMD

                    for k in 0..<16 {
                        result[y][x+k] = sum[k]
                    }

                    x += 16
                }
            }
            // xfilter あまり処理
            do {
                let offset = width - 16
                var sum = SIMD16<UInt16>.zero

                for k in 0..<L {
                    let startIndex = offset + k
                    sum &+= SIMD16<UInt16>(yresult[startIndex..<startIndex+16])
                }

                sum /= weightSIMD

                for k in 0..<16 {
                    result[y][offset+k] = sum[k]
                }
            }

            // ringBuffering
            for k in 0..<L-1 {
                extended[k] = extended[k+1]
            }
        }
    }

    print("SIMD16 separable \(Double(resultTime) / 1000_000.0) ms")

    return result.map { $0.map { UInt8($0) } }
}

@discardableResult
func benckmarkSIMDSeparablePointerBoxFilter(image: [[UInt8]], radius: Int) throws -> [[UInt8]] {
    let L = 2 * radius + 1
    let height = image.count
    let width = image[0].count

    // convert [[UInt8]] -> UnsafeMutablePointer<UInt16>
    let imagePointer: UnsafeMutablePointer<UInt16> = .allocate(capacity: width * height)
    do {
        var pointer: UnsafeMutablePointer<UInt16> = imagePointer
        for y in 0..<height {
            for x in 0..<width {
                pointer.initialize(to: UInt16(image[y][x]))
                pointer = pointer.successor()
            }
        }
    }
    defer {
        imagePointer.deinitialize(count: width * height)
        imagePointer.deallocate()
    }

    var resultPointer: UnsafeMutableBufferPointer<UInt16> = .allocate(capacity: 0)

    let resultTime = benchmark(samples: 100, iterations: 100) {
        let weightSIMD = SIMD16<UInt16>(repeating: UInt16(L * L))
        let widthExtended = width + 2 * radius

        // 毎回deallocateしないとメモリリークするが
        // 一番最後の実験結果は必要なため先頭で行う
        resultPointer.deinitialize()
        resultPointer.deallocate()

        resultPointer = .allocate(capacity: width * height)
        resultPointer.initialize(repeating: .zero)

        let extendedPointer: UnsafeMutableBufferPointer<UnsafeMutableBufferPointer<UInt16>> = .allocate(capacity: L)
        for k in 0..<L {
            extendedPointer[k] = .allocate(capacity: widthExtended)
        }
        for k in 0..<L-1 {
            extendImage(
                from: imagePointer.advanced(by: max(0, k - radius) * width),
                srcWidth: width,
                extendTo: extendedPointer[k],
                extendRadius: radius
            )
        }

        let yresultPointer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: widthExtended)
        yresultPointer.initialize(repeating: .zero)

        for y in 0..<height {
            extendImage(
                from: imagePointer.advanced(by: min(height - 1, y + radius) * width),
                srcWidth: width,
                extendTo: extendedPointer[L-1],
                extendRadius: radius
            )

            // yfilter
            do {
                var x = 0
                while x < widthExtended - 16 {
                    var sum = SIMD16<UInt16>.zero
                    for k in 0..<L {
                        sum &+= SIMD16<UInt16>(extendedPointer[k][x..<x+16])
                    }

                    for k in 0..<16 {
                        yresultPointer[x+k] = sum[k]
                    }

                    x += 16
                }
            }
            // yfilter あまり処理
            do {
                let offset = widthExtended - 16

                var sum = SIMD16<UInt16>.zero
                for k in 0..<L {
                    sum &+= SIMD16<UInt16>(extendedPointer[k][offset..<offset+16])
                }

                // これをSIMDのstoreにしたい
                for k in 0..<16 {
                    yresultPointer[offset+k] = sum[k]
                }
            }

            // xfilter
            do {
                var x = 0
                while x < width - 16 {
                    var sum = SIMD16<UInt16>.zero

                    for k in 0..<L {
                        let startIndex = x + k
                        sum &+= SIMD16<UInt16>(yresultPointer[startIndex..<startIndex+16])
                    }

                    sum /= weightSIMD

                    for k in 0..<16 {
                        resultPointer[width * y + x + k] = sum[k]
                    }

                    x += 16
                }
            }
            // xfilter あまり処理
            do {
                let offset = width - 16
                var sum = SIMD16<UInt16>.zero

                for k in 0..<L {
                    let startIndex = offset + k
                    sum &+= SIMD16<UInt16>(yresultPointer[startIndex..<startIndex+16])
                }

                sum /= weightSIMD

                for k in 0..<16 {
                    resultPointer[width * y + offset + k] = sum[k]
                }
            }

            // ringBuffering
            let temp = extendedPointer.moveElement(from: 0)
            for k in 0..<L-1 {
                extendedPointer[k] = extendedPointer[k+1]
            }
            extendedPointer[L-1] = temp
        }

        yresultPointer.deinitialize()
        yresultPointer.deallocate()

        for k in 0..<L {
            extendedPointer[k].deinitialize()
            extendedPointer[k].deallocate()
        }
        extendedPointer.deinitialize()
        extendedPointer.deallocate()
    }

    print("SIMD16 separable pointer \(Double(resultTime) / 1000_000.0) ms")

    var result: [[UInt8]] = .init(repeating: .init(repeating: .zero, count: width), count: height)

    for y in 0..<height {
        for x in 0..<width {
            result[y][x] = UInt8(resultPointer[y * width + x])
        }
    }

    return result
}
