import Foundation

public enum RotationDecision {
    public static func isDue(automatic: Bool, busy: Bool, nextChange: Date?, now: Date = Date()) -> Bool {
        automatic && !busy && nextChange.map { $0 <= now } == true
    }
}

@MainActor
public final class RotationTicker {
    private var task: Task<Void, Never>?
    public init(intervalNanoseconds: UInt64 = 10_000_000_000, action: @escaping @MainActor () -> Void) {
        task = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: intervalNanoseconds) }
                catch { break }
                guard !Task.isCancelled else { break }
                action()
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
