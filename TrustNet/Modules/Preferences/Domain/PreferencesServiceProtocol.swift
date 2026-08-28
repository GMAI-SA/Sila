import Foundation

/// Everything the Preferences module can ask the backend to do (contract v4).
///
/// The seam ``PreferencesScreen`` depends on; ``PreferencesService`` and
/// ``PreferencesServiceMock`` are interchangeable behind it, which is what
/// makes the view-model tests honest without a network.
public protocol PreferencesServiceProtocol: Sendable {

    /// The fixed topic taxonomy, `GET /topics`.
    ///
    /// Ids are the wire contract and are stable; the labels this app renders
    /// are derived from them locally, because the contract explicitly does not
    /// promise stable labels.
    func fetchTopics() async throws -> [TopicOption]

    /// This account's stored preferences, `GET /me/preferences` — everything
    /// the International feed's filter actually runs on.
    func fetchPreferences() async throws -> FeedPreferences

    /// Writes a partial update, `PUT /me/preferences`.
    ///
    /// - Parameter update: Only the fields set are sent. When
    ///   ``PreferencesUpdate/topics`` is present it **replaces** the whole
    ///   stance set — a topic left out of the array has no stance afterwards.
    /// - Returns: The server's authoritative state after the write, which is
    ///   what the screen then shows. Never the locally-guessed value.
    /// - Throws: ``APIError`` with ``APIErrorCode/unknownTopic`` or
    ///   ``APIErrorCode/invalidCountry`` (both HTTP 400).
    func updatePreferences(_ update: PreferencesUpdate) async throws -> FeedPreferences
}
