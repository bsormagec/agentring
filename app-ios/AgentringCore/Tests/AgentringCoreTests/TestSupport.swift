import Foundation
import XCTest
@testable import AgentringCore

enum Fixtures {
    /// `protocol/` at the repo root, found from this file (or `AGENTRING_PROTOCOL_DIR`).
    static var protocolDir: URL {
        if let dir = ProcessInfo.processInfo.environment["AGENTRING_PROTOCOL_DIR"] {
            return URL(fileURLWithPath: dir)
        }
        // app-ios/AgentringCore/Tests/AgentringCoreTests/TestSupport.swift → repo root
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AgentringCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AgentringCore
            .deletingLastPathComponent() // app-ios
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("protocol")
    }

    static func url(_ relative: String) -> URL { protocolDir.appendingPathComponent(relative) }

    static func data(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }

    static func string(_ relative: String) throws -> String { String(decoding: try data(relative), as: UTF8.self) }

    static func json(_ relative: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try data(relative)) as? [String: Any], relative)
    }

    /// The `.json` files in `protocol/examples/<dir>`, sorted.
    static func files(in dir: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url("examples/\(dir)"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Thread-safe recorder for callbacks in tests.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// A mutable value shared with `@Sendable` closures in tests.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T

    init(_ v: T) { self.v = v }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Asserts that `body` throws an error of type `E` and returns it.
@discardableResult
func assertThrowsAsync<E: Error, T>(
    _ type: E.Type, _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> T
) async -> E? {
    do {
        _ = try await body()
        XCTFail("expected \(E.self) \(message)", file: file, line: line)
    } catch let e as E {
        return e
    } catch {
        XCTFail("expected \(E.self), got \(error) \(message)", file: file, line: line)
    }
    return nil
}

/// Same JSON value (objects compared as dictionaries, numbers by value).
func jsonEqual(_ a: Any, _ b: Any) -> Bool {
    switch (a, b) {
    case let (x as [String: Any], y as [String: Any]):
        return x.count == y.count && x.allSatisfy { k, v in y[k].map { jsonEqual(v, $0) } ?? false }
    case let (x as [Any], y as [Any]):
        return x.count == y.count && zip(x, y).allSatisfy { jsonEqual($0, $1) }
    case let (x as String, y as String):
        return x == y
    case let (x as NSNumber, y as NSNumber):
        return x == y
    case (is NSNull, is NSNull):
        return true
    default:
        return false
    }
}
