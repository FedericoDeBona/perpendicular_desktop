
// Appended to VMConsole.swift by benchmark-console.sh. Uses an isolated mock
// server, never a user VM. Retaining the latest frame models the renderer's COW.
private final class ConsoleBenchmarkState: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var frameCount = 0
    private var latest: RFBFrame?
    private var error: String?
    func receive(_ frame: RFBFrame) {
        lock.lock(); frameCount += 1; latest = frame; lock.unlock()
    }
    func failure(_ value: String) {
        lock.lock(); error = value; lock.unlock(); finished.signal()
    }
    func result() -> (Int, Int, Int, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (frameCount, latest?.width ?? 0, latest?.height ?? 0, error)
    }
}

private func benchmarkCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
        Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private let benchmarkState = ConsoleBenchmarkState()
private let benchmarkStarted = ProcessInfo.processInfo.systemUptime
private let benchmarkCPUStarted = benchmarkCPUSeconds()
private let benchmarkClient = RFBConnection(socketPath: CommandLine.arguments[1],
    onFrame: { benchmarkState.receive($0) }, onReady: { _ in },
    onCutText: { _ in benchmarkState.finished.signal() },
    onFailure: { benchmarkState.failure($0) })
benchmarkClient.start()
precondition(benchmarkState.finished.wait(timeout: .now() + 30) == .success, "Benchmark timed out")
private let benchmarkElapsed = ProcessInfo.processInfo.systemUptime - benchmarkStarted
private let benchmarkCPU = benchmarkCPUSeconds() - benchmarkCPUStarted
private let benchmarkResult = benchmarkState.result()
precondition(benchmarkResult.3 == nil, "Benchmark connection failed")
benchmarkClient.stop()
private let benchmarkJSON: [String: Any] = [
    "frames": benchmarkResult.0, "width": benchmarkResult.1, "height": benchmarkResult.2,
    "elapsed_seconds": benchmarkElapsed, "cpu_seconds": benchmarkCPU,
    "raw_mib_per_second": Double(benchmarkResult.0 * benchmarkResult.1 * benchmarkResult.2 * 4) /
        1_048_576 / benchmarkElapsed
]
private let benchmarkData = try JSONSerialization.data(withJSONObject: benchmarkJSON, options: [.sortedKeys])
print(String(decoding: benchmarkData, as: UTF8.self))
