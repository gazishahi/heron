import Foundation

/// Where Heron and Side keep settings: the person's own, except in a test, which gets a store
/// of its own process's, gone when it exits. Tests wrote to the owner's settings: consent for
/// temporary rule files, recent projects that were temporary folders, test agents, a usage
/// limit (2026-09-30 audit, TST-1; 2026-10-01). A UI test's app sets its own (`store`).
public enum HeronDefaults {
    public nonisolated(unsafe) static var store: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestBundlePath"] != nil || environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        else { return .standard }
        return InMemoryDefaults()
    }()

}

/// Settings that never reach the disk: what a test gets. A store made with a suite name is a
/// file in ~/Library/Preferences, and the preferences daemon writes it back after it's deleted,
/// so per-test stores had piled up there (2,443 files by 2026-10-01).
public final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init() { super.init(suiteName: nil)! }

    public override func object(forKey defaultName: String) -> Any? { lock.withLock { values[defaultName] } }
    public override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
    public override func removeObject(forKey defaultName: String) { lock.withLock { _ = values.removeValue(forKey: defaultName) } }
    public override func set(_ value: Bool, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    public override func set(_ value: Int, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    public override func set(_ value: Double, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    public override func set(_ value: Float, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    public override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
    public override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    public override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    public override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    public override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    public override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    public override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? Int(string(forKey: defaultName) ?? "") ?? 0 }
    public override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? Double(string(forKey: defaultName) ?? "") ?? 0 }
    public override func float(forKey defaultName: String) -> Float { Float(double(forKey: defaultName)) }
    public override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false }
    public override func url(forKey defaultName: String) -> URL? { object(forKey: defaultName) as? URL }
    public override func dictionaryRepresentation() -> [String: Any] { lock.withLock { values } }
    public override func removePersistentDomain(forName domainName: String) { lock.withLock { values.removeAll() } }
}
