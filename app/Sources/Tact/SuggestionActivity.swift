import Combine
import Foundation

/// What the menu bar says about a suggestion: one being generated, or one
/// ready for a chat that is not in front. Only the newest trigger's
/// suggestion is kept, so one state covers every chat tool.
@MainActor
final class SuggestionActivity: ObservableObject {
    enum Kind { case none, generating, ready }

    static let shared = SuggestionActivity()
    /// How long a ready suggestion waits for its chat to come back.
    static let waitLifetime: TimeInterval = 300

    @Published private(set) var kind: Kind = .none
    private var owner: String?

    func set(_ kind: Kind, for requestID: String) {
        owner = requestID
        self.kind = kind
    }

    /// Clears the state only for the request that set it, so a request that
    /// ends late cannot clear a newer one's.
    func clear(_ requestID: String) {
        guard owner == requestID else { return }
        owner = nil
        kind = .none
    }
}
