//
//  LiveContainerLaunchAlert.swift
//  Reynard
//

import UIKit

// Inside LiveContainer, Gecko child processes are hosted by LiveContainer's
// LiveProcess extension (see patches/ipc/glue/NSExtensionUtils.mm.patch). If
// they cannot start, for example because Reynard is not a LiveContainer shared
// app, no web page loads. The Gecko patch posts the reason, and this shows it
// once per launch. Nothing is registered outside LiveContainer.
final class LiveContainerLaunchAlert {
    static let shared = LiveContainerLaunchAlert()

    private static let launchFailedNotification = Notification.Name("Reynard.LiveContainerChildProcessLaunchFailed")
    private let presentationRetryLimit = 40

    private var isStarted = false
    private var hasPresented = false
    private var hasStartedChildProcess = false
    private var pendingMessage: String?

    private init() {}

    func start() {
        guard !isStarted, NSClassFromString("LCSharedUtils") != nil else {
            return
        }
        isStarted = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLaunchFailure(_:)),
            name: Self.launchFailedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChildProcessDidStart),
            name: .geckoRuntimeChildProcessDidStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    // A child process that started proves the LiveContainer setup works, so
    // later failures are transient and not worth an alert.
    @objc nonisolated private func handleChildProcessDidStart() {
        DispatchQueue.main.async {
            self.hasStartedChildProcess = true
            self.pendingMessage = nil
        }
    }

    // Posted from Gecko's extension completion queue, not the main thread.
    @objc nonisolated private func handleLaunchFailure(_ notification: Notification) {
        let message = notification.userInfo?[NSLocalizedDescriptionKey] as? String
        DispatchQueue.main.async {
            self.present(message: message ?? NSLocalizedString("Unknown error.", comment: ""))
        }
    }

    @objc private func handleApplicationDidBecomeActive() {
        guard let message = pendingMessage else {
            return
        }
        pendingMessage = nil
        present(message: message)
    }

    private func present(message: String, retryCount: Int = 0) {
        guard !hasPresented, !hasStartedChildProcess else {
            return
        }

        guard UIApplication.shared.applicationState == .active else {
            pendingMessage = message
            return
        }

        guard let presenter = UIApplication.shared.topViewController() else {
            guard retryCount < presentationRetryLimit else {
                pendingMessage = message
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                self.present(message: message, retryCount: retryCount + 1)
            }
            return
        }

        hasPresented = true
        let alert = UIAlertController(
            title: NSLocalizedString("Web Pages Can't Load", comment: ""),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        presenter.present(alert, animated: true)
    }
}
