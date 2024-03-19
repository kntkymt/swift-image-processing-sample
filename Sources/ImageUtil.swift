func extendedImageHorizontal<T>(from src: [T], factor: Int) -> [T] {
    let left: [T] = .init(repeating: src.first!, count: factor)
    let right: [T] = .init(repeating: src.last!, count: factor)

    return left + src + right
}

func extendImage<T>(from src: UnsafeMutablePointer<T>, srcWidth: Int, extendTo dst: UnsafeMutableBufferPointer<T>, extendRadius: Int) {
    for i in 0..<extendRadius {
        dst.initializeElement(at: i, to: src.pointee)
        dst.initializeElement(at: extendRadius + srcWidth + i, to: src[srcWidth - 1])
    }

    for i in 0..<srcWidth {
        dst.initializeElement(at: extendRadius + i, to: src[i])
    }
}

func extendedImage<T>(from src: [[T]], horizontal: Int, vertical: Int) -> [[T]] {
    let horizontal = src.map { extendedImageHorizontal(from: $0, factor: horizontal) }

    return extendedImageHorizontal(from: horizontal, factor: vertical)
}
