import Foundation

@discardableResult
func benchmark(samples: UInt64, iterations: UInt64, operation: () -> Void) -> UInt64 {
    var best = UInt64.max
    for _ in 0..<samples {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            operation()
        }
        let end = DispatchTime.now().uptimeNanoseconds

        best = min(best, (end - start) / iterations)
    }

    return best
}
