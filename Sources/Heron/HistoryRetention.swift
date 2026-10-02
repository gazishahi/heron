import Foundation

/// How long Think conversations are kept on disk.
///
/// Sessions hold every tool result verbatim — file contents, command output, whatever the agent
/// read — and until now they were kept forever with no way to expire or delete them short of
/// deleting the track. `SecretRedactor` reduces what lands there; this governs how long any of
/// it lives. Applies to conversation *content* only: checkpoints stay, because they're the
/// record of what an agent actually changed and they point at real git commits.
public enum HistoryRetention: Int, CaseIterable {
    case forever = 0
    case ninetyDays = 90
    case thirtyDays = 30
    case sevenDays = 7

    private static let defaultsKey = "SideHistoryRetentionDays"

    public static var current: HistoryRetention {
        get { HistoryRetention(rawValue: HeronDefaults.store.integer(forKey: defaultsKey)) ?? .forever }
        set { HeronDefaults.store.set(newValue.rawValue, forKey: defaultsKey) }
    }

    public var displayName: String {
        switch self {
        case .forever: return "Keep forever"
        case .ninetyDays: return "Keep for 90 days"
        case .thirtyDays: return "Keep for 30 days"
        case .sevenDays: return "Keep for 7 days"
        }
    }

    /// Conversations last active before this date are expired. `nil` means nothing expires.
    public func cutoffDate(now: Date = Date()) -> Date? {
        guard self != .forever else { return nil }
        return Calendar.current.date(byAdding: .day, value: -rawValue, to: now)
    }
}
