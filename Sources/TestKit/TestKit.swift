import Foundation
import Synchronization

/// A single assertion failure, with the source location that produced it.
public struct TestFailure: Sendable {
    public let message: String
    public let file: String
    public let line: UInt

    public init(message: String, file: String, line: UInt) {
        self.message = message
        self.file = file
        self.line = line
    }
}

/// Thrown by a test that cannot run in the current environment. Skipped tests are
/// reported separately from failures so an absent credential never reads as a pass.
public struct TestSkip: Error, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// Collects assertion results for one test. Handed to the test body rather than
/// held in global state, so tests stay independent.
public final class Expect: Sendable {
    private let failures = Mutex<[TestFailure]>([])

    public init() {}

    public var recorded: [TestFailure] { failures.withLock { $0 } }

    public func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        failures.withLock { $0.append(TestFailure(message: message, file: "\(file)", line: line)) }
    }

    public func isTrue(
        _ condition: Bool,
        _ message: @autoclosure () -> String = "expected true",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !condition { fail(message(), file: file, line: line) }
    }

    public func isFalse(
        _ condition: Bool,
        _ message: @autoclosure () -> String = "expected false",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if condition { fail(message(), file: file, line: line) }
    }

    public func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if actual != expected {
            let suffix = message().isEmpty ? "" : " — \(message())"
            fail("expected \(expected), got \(actual)\(suffix)", file: file, line: line)
        }
    }

    public func notEqual<T: Equatable>(
        _ actual: T,
        _ unexpected: T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if actual == unexpected {
            let suffix = message().isEmpty ? "" : " — \(message())"
            fail("expected value other than \(unexpected)\(suffix)", file: file, line: line)
        }
    }

    public func isNil(
        _ value: Any?,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let value {
            let suffix = message().isEmpty ? "" : " — \(message())"
            fail("expected nil, got \(value)\(suffix)", file: file, line: line)
        }
    }

    @discardableResult
    public func unwrap<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "unexpected nil",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        guard let value else {
            fail(message(), file: file, line: line)
            throw UnwrapFailure()
        }
        return value
    }

    public func close(
        _ actual: Double,
        _ expected: Double,
        tolerance: Double,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !(abs(actual - expected) <= tolerance) {
            let suffix = message().isEmpty ? "" : " — \(message())"
            fail("expected \(expected) ± \(tolerance), got \(actual)\(suffix)", file: file, line: line)
        }
    }

    public func throwsError(
        _ body: () throws -> Void,
        _ message: @autoclosure () -> String = "expected an error",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try body()
            fail(message(), file: file, line: line)
        } catch {
            // expected
        }
    }

    /// Asserts the specific error, not merely that one was thrown. A typed
    /// domain error is part of the contract, and a test that accepts any error
    /// passes when the code throws the wrong one.
    public func throwsError<E: Error & Equatable>(
        _ expected: E,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try body()
            fail("expected \(expected)", file: file, line: line)
        } catch let error as E {
            if error != expected {
                fail("expected \(expected), got \(error)", file: file, line: line)
            }
        } catch {
            fail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    public func throwsError(
        _ body: () async throws -> Void,
        _ message: @autoclosure () -> String = "expected an error",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            fail(message(), file: file, line: line)
        } catch {
            // expected
        }
    }

    public struct UnwrapFailure: Error {}
}

public struct Test: Sendable {
    public let name: String
    public let body: @Sendable (Expect) async throws -> Void

    public init(_ name: String, _ body: @escaping @Sendable (Expect) async throws -> Void) {
        self.name = name
        self.body = body
    }
}

public struct Suite: Sendable {
    public let name: String
    public let tests: [Test]

    public init(_ name: String, _ tests: [Test]) {
        self.name = name
        self.tests = tests
    }
}

public func test(_ name: String, _ body: @escaping @Sendable (Expect) async throws -> Void) -> Test {
    Test(name, body)
}

public struct TestReport: Sendable {
    public var passed = 0
    public var failed = 0
    public var skipped = 0
    public var duration: TimeInterval = 0
    public var isSuccess: Bool { failed == 0 }
}

public enum TestRunner {
    /// Runs the given suites and returns a process exit code.
    public static func run(_ suites: [Suite], arguments: [String]) async -> Int32 {
        var filter: String?
        var listOnly = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--filter":
                index += 1
                if index < arguments.count { filter = arguments[index] }
            case "--list":
                listOnly = true
            default:
                break
            }
            index += 1
        }

        if listOnly {
            for suite in suites {
                for test in suite.tests { print("\(suite.name)/\(test.name)") }
            }
            return 0
        }

        var report = TestReport()
        let started = Date()
        var failureLines: [String] = []

        for suite in suites {
            let selected = suite.tests.filter { test in
                guard let filter else { return true }
                return "\(suite.name)/\(test.name)".localizedCaseInsensitiveContains(filter)
            }
            guard !selected.isEmpty else { continue }
            print("\n\(suite.name)")
            for test in selected {
                let expect = Expect()
                var skipReason: String?
                var thrown: Error?
                let testStarted = Date()
                do {
                    try await test.body(expect)
                } catch let skip as TestSkip {
                    skipReason = skip.reason
                } catch let unwrap as Expect.UnwrapFailure {
                    _ = unwrap  // the failure is already recorded
                } catch {
                    thrown = error
                }
                let elapsed = Date().timeIntervalSince(testStarted)
                let failures = expect.recorded
                if let skipReason {
                    report.skipped += 1
                    print("  ~ \(test.name) — skipped: \(skipReason)")
                } else if failures.isEmpty && thrown == nil {
                    report.passed += 1
                    print(String(format: "  ✓ %@ (%.0f ms)", test.name, elapsed * 1000))
                } else {
                    report.failed += 1
                    print("  ✗ \(test.name)")
                    for failure in failures {
                        let location = "\(shortPath(failure.file)):\(failure.line)"
                        print("      \(location) \(failure.message)")
                        failureLines.append("\(suite.name)/\(test.name) — \(location) \(failure.message)")
                    }
                    if let thrown {
                        print("      threw: \(thrown)")
                        failureLines.append("\(suite.name)/\(test.name) — threw: \(thrown)")
                    }
                }
            }
        }

        report.duration = Date().timeIntervalSince(started)
        print("\n" + String(repeating: "─", count: 60))
        if !failureLines.isEmpty {
            print("Failures:")
            for line in failureLines { print("  \(line)") }
        }
        print(String(
            format: "%d passed, %d failed, %d skipped in %.2fs",
            report.passed, report.failed, report.skipped, report.duration
        ))
        return report.isSuccess ? 0 : 1
    }

    private static func shortPath(_ path: String) -> String {
        guard let range = path.range(of: "Tests/") ?? path.range(of: "Sources/") else {
            return (path as NSString).lastPathComponent
        }
        return String(path[range.lowerBound...])
    }
}
