import Foundation

/// Backoff esponenziale con jitter per errori transitori.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: Double

    public init(maxAttempts: Int = 4, baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 60, jitter: Double = 0.2) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    /// Ritardo prima del tentativo `attempt` (1 = primo ritentativo).
    public func delay(forAttempt attempt: Int, retryAfter: TimeInterval? = nil, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            return min(retryAfter, maxDelay)
        }
        let exponential = baseDelay * pow(2, Double(max(0, attempt - 1)))
        let capped = min(exponential, maxDelay)
        let jitterAmount = capped * jitter * (random * 2 - 1)
        return max(0, capped + jitterAmount)
    }

    /// Esegue `operation` ritentando sugli errori `AIServiceError.isRetryable`.
    public func run<T: Sendable>(
        provider: String,
        sleeper: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        onRetry: (@Sendable (Int, AIServiceError) -> Void)? = nil,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try Task.checkCancellation()
                return try await operation()
            } catch {
                let mapped = AIServiceError.from(error, provider: provider)
                guard mapped.isRetryable, attempt < maxAttempts else { throw mapped }
                onRetry?(attempt, mapped)
                try await sleeper(delay(forAttempt: attempt, retryAfter: mapped.retryAfter))
            }
        }
    }
}
