import SwiftUI

/// Builds a view model once and keeps it for the life of the view.
///
/// A sheet's or a destination's content closure is not run once: SwiftUI
/// re-evaluates it whenever the presenting view updates — a badge count, a
/// toast, a timer. A screen handed `SomeViewModel(...)` straight from such a
/// closure therefore got a *new* model on every update: the load it was in
/// the middle of was cancelled and reported as a network problem, the draft
/// somebody was typing vanished, a room reconnected. Everything the model
/// had was thrown away for no reason anybody could see.
///
/// `@State` is SwiftUI's own answer: the first value wins for as long as the
/// view keeps its identity. Give the host an `.id` when a different payload
/// — another room, another thread — should mean a different model.
public struct Owned<Model, Content: View>: View {

    @State private var model: Model
    private let content: (Model) -> Content

    /// - Parameters:
    ///   - make: Called on every evaluation, used **once** per identity.
    ///   - content: The screen, given the model it may keep.
    public init(_ make: () -> Model, @ViewBuilder content: @escaping (Model) -> Content) {
        self._model = State(initialValue: make())
        self.content = content
    }

    public var body: some View {
        content(model)
    }
}
