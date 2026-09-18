import GreminderShare
import SwiftUI
#if os(macOS)
    import AppKit

    typealias SharePlatformController = NSViewController
#else
    import UIKit

    typealias SharePlatformController = UIViewController
#endif

@objc(ShareViewController)
final class ShareViewController: SharePlatformController {
    override func loadView() {
        #if os(macOS)
            view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 580))
        #else
            view = UIView()
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let content = ShareComposerView(
            loadItems: { [weak self] in
                try await ShareItemLoader.drafts(from: self?.extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            },
            complete: { [weak self] in self?.extensionContext?.completeRequest(returningItems: []) },
            cancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSUserCancelledError,
                ))
            },
        )
        #if os(macOS)
            let host = NSHostingController(rootView: content)
            preferredContentSize = NSSize(width: 460, height: 580)
        #else
            let host = UIHostingController(rootView: content)
            preferredContentSize = CGSize(width: 460, height: 580)
            isModalInPresentation = true
        #endif
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #if os(iOS)
            host.didMove(toParent: self)
        #endif
    }
}
