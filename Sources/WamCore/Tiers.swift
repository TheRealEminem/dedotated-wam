import Foundation

/// The four default triage tiers an app can be sorted into before the user has had a say.
public enum DefaultTier: String, CaseIterable, Codable, Sendable {
    /// Nothing is lost by closing it: media players, chat, stores, launchers, games.
    case closeFirst
    /// Heavy, but restores its state when reopened: browsers, mail, notes.
    case closeNext
    /// May hold unsaved work or running jobs: editors, IDEs, creative tools, terminals.
    case lastResort
    /// Must not be closed automatically: system pieces, security tools, input and window utilities.
    case never
}
