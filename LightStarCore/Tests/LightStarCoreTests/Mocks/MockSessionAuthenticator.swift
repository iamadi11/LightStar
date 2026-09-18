import Foundation
@testable import LightStarCore

/// Mock session authenticator for testing authentication flows.
/// Implements proper authentication logic that real implementation should use.
public final class MockSessionAuthenticator: SessionAuthenticator, @unchecked Sendable {
    
    // MARK: - Configuration
    
    /// Current valid pairing code (nil if no code generated).
    public private(set) var currentPairingCode: String?
    
    /// Expiry time for current pairing code.
    public private(set) var codeExpiry: Date?
    
    /// Code validity duration in seconds.
    public var codeValidityDuration: TimeInterval = 120
    
    /// Maximum failed attempts before rate limiting.
    public var maxFailedAttempts: Int = 3
    
    /// Rate limit duration in seconds.
    public var rateLimitDuration: TimeInterval = 60
    
    // MARK: - State
    
    private var validSessions: [String: SessionInfo] = [:]
    private var failedAttempts: [String: FailedAttemptRecord] = [:]
    private let lock = NSLock()
    
    private struct SessionInfo {
        let token: String
        let createdAt: Date
        var lastUsedAt: Date
    }
    
    private struct FailedAttemptRecord {
        var count: Int
        var lockoutUntil: Date?
    }
    
    // MARK: - Test Tracking
    
    public private(set) var generateCodeCallCount = 0
    public private(set) var validateCodeCallCount = 0
    public private(set) var validateTokenCallCount = 0
    public private(set) var invalidateCallCount = 0
    
    public init() {}
    
    // MARK: - SessionAuthenticator
    
    public func generatePairingCode() -> String {
        lock.lock()
        defer { lock.unlock() }
        
        generateCodeCallCount += 1
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        currentPairingCode = code
        codeExpiry = Date().addingTimeInterval(codeValidityDuration)
        return code
    }
    
    public func validatePairingCode(_ code: String, clientID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        validateCodeCallCount += 1
        
        // Check rate limiting
        if let record = failedAttempts[clientID],
           let lockout = record.lockoutUntil,
           Date() < lockout {
            return nil
        }
        
        // Check code validity
        guard let expectedCode = currentPairingCode,
              let expiry = codeExpiry,
              Date() < expiry,
              code == expectedCode else {
            // Record failed attempt
            var record = failedAttempts[clientID] ?? FailedAttemptRecord(count: 0, lockoutUntil: nil)
            record.count += 1
            if record.count >= maxFailedAttempts {
                record.lockoutUntil = Date().addingTimeInterval(rateLimitDuration)
            }
            failedAttempts[clientID] = record
            return nil
        }
        
        // Success - clear code and create session
        currentPairingCode = nil
        codeExpiry = nil
        failedAttempts[clientID] = nil
        
        let token = UUID().uuidString
        validSessions[token] = SessionInfo(
            token: token,
            createdAt: Date(),
            lastUsedAt: Date()
        )
        
        return token
    }
    
    public func validateSessionToken(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        validateTokenCallCount += 1
        
        guard var session = validSessions[token] else {
            return false
        }
        
        session.lastUsedAt = Date()
        validSessions[token] = session
        return true
    }
    
    public func invalidateSession(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        
        invalidateCallCount += 1
        validSessions.removeValue(forKey: token)
    }
    
    public func isRateLimited(clientID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let record = failedAttempts[clientID],
              let lockout = record.lockoutUntil else {
            return false
        }
        return Date() < lockout
    }
    
    // MARK: - Test Helpers
    
    /// Reset all state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        currentPairingCode = nil
        codeExpiry = nil
        validSessions.removeAll()
        failedAttempts.removeAll()
        generateCodeCallCount = 0
        validateCodeCallCount = 0
        validateTokenCallCount = 0
        invalidateCallCount = 0
    }
    
    /// Get number of active sessions.
    public var activeSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return validSessions.count
    }
    
    /// Force expire the current pairing code.
    public func expireCurrentCode() {
        lock.lock()
        defer { lock.unlock() }
        codeExpiry = Date().addingTimeInterval(-1)
    }
    
    /// Create a valid session directly (for testing).
    public func createTestSession() -> String {
        lock.lock()
        defer { lock.unlock() }
        
        let token = UUID().uuidString
        validSessions[token] = SessionInfo(
            token: token,
            createdAt: Date(),
            lastUsedAt: Date()
        )
        return token
    }
    
    /// Get failed attempt count for a client.
    public func failedAttemptCount(for clientID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return failedAttempts[clientID]?.count ?? 0
    }
}
