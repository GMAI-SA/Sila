import SwiftUI
import UIKit

/// Puts "Verify your identity to do this" — and, from it, the verification
/// flow — over whatever is on top of the app, sheets included (contract v24
/// §4, §9).
///
/// A `403 self_verification_required` can come back from anywhere a vouched
/// account reaches for something that waits for verification: a room's chat,
/// questions or polls, a share, a group, a vote. Most of those live in a
/// sheet. A SwiftUI `.sheet` on the tab view cannot rise while another sheet
/// is up, so the offer either never came or came later, out of context, once
/// that sheet had closed — leaving an error toast inside the sheet and no way
/// to verify. UIKit presents over the top-most controller instead, so the
/// offer is always where the refusal happened.
///
/// Never the wall: the account keeps the app behind both.
@MainActor
final class SelfVerificationPresenter {

    private weak var prompt: UIViewController?
    private weak var flow: UIViewController?

    /// Whether the offer is on screen.
    var isShowingPrompt: Bool { prompt != nil }

    /// Whether the verification flow is on screen.
    var isShowingFlow: Bool { flow != nil }

    /// Shows the offer as a half-height sheet over whatever is on top.
    ///
    /// - Parameters:
    ///   - content: The offer.
    ///   - onGone: Called once, however it leaves — a button, a swipe, or the
    ///     screen under it closing — so the gate can take the next refusal.
    func showPrompt<Content: View>(_ content: Content, onGone: @escaping @MainActor () -> Void) {
        // One question at a time, and never over the flow it leads to.
        guard prompt == nil, flow == nil, let top = Self.topViewController() else {
            onGone()
            return
        }
        let host = PresentedHost(rootView: content)
        host.onGone = onGone
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        prompt = host
        top.present(host, animated: true)
    }

    /// Takes the offer down, then does `next` once it has gone — a second
    /// presentation cannot start while the first is still leaving.
    func dismissPrompt(then next: (@MainActor () -> Void)? = nil) {
        guard let prompt, prompt.presentingViewController != nil else {
            next?()
            return
        }
        prompt.dismiss(animated: true) { next?() }
    }

    /// Shows the verification flow full screen over whatever is on top.
    func showFlow<Content: View>(_ content: Content) {
        guard flow == nil, let top = Self.topViewController() else { return }
        let host = PresentedHost(rootView: content)
        host.modalPresentationStyle = .fullScreen
        flow = host
        top.present(host, animated: true)
    }

    /// Closes the verification flow, whatever it has presented itself.
    func dismissFlow() {
        guard let flow, let presenter = flow.presentingViewController else { return }
        presenter.dismiss(animated: true)
    }

    /// Takes down every offer and flow this presents, wherever they are —
    /// for when the tabs they were raised over are gone (a session that
    /// ended, an account sent back to the wall). SwiftUI closes its own
    /// sheets with the screen that owned them; these are UIKit's to close.
    static func dismissAll() {
        for host in PresentedHosts.live.allObjects where host.presentingViewController != nil && !host.isBeingDismissed {
            host.presentingViewController?.dismiss(animated: false)
        }
    }

    /// The controller everything else is presented from: the key window's
    /// root, followed up through whatever it presents, skipping anything on
    /// its way out.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        let window = windows.first { $0.isKeyWindow } ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Every screen ``SelfVerificationPresenter`` has up, held weakly.
@MainActor
private enum PresentedHosts {
    static let live = NSHashTable<UIViewController>.weakObjects()
}

/// A SwiftUI screen presented by UIKit, in the app's dark look, that says
/// when it has left.
private final class PresentedHost<Content: View>: UIHostingController<Content> {

    var onGone: (@MainActor () -> Void)?

    override init(rootView: Content) {
        super.init(rootView: rootView)
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(SLColor.background)
        PresentedHosts.live.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The offer presents nothing over itself, so leaving the screen means
        // it has gone, by whichever way.
        guard let gone = onGone else { return }
        onGone = nil
        gone()
    }
}
