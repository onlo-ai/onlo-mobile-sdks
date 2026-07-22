import Foundation

/// Pure recovery decision state, kept separate from Apple frameworks so its
/// transition rules are deterministic and available to package tests.
struct NetworkRecoveryGate: Sendable {
    private var observedPath = false
    private var wasAvailable = false

    mutating func pathChanged(isAvailable: Bool) -> Bool {
        defer {
            observedPath = true
            wasAvailable = isAvailable
        }
        return observedPath && !wasAvailable && isAvailable
    }
}

/// An SDK-owned observer that never retains a presenter or host controller.
/// It is deliberately inert on non-iOS builds so Swift Package source builds
/// remain portable to macOS.
final class OnloNativeLifecycleBinding: @unchecked Sendable {
    private weak var sdk: OnloSDK?
    private let lock = NSLock()
    private var installed = false
    private var recoveryGate = NetworkRecoveryGate()

    #if canImport(UIKit)
    private var foregroundObserver: NSObjectProtocol?
    #endif
    #if canImport(UIKit) && canImport(Network)
    private var pathMonitor: AnyObject?
    #endif

    init(sdk: OnloSDK) {
        self.sdk = sdk
    }

    deinit { stop() }

    func install() {
        lock.lock()
        guard !installed else {
            lock.unlock()
            return
        }
        installed = true
        lock.unlock()

        #if canImport(UIKit)
        importUIKitObserver()
        #endif
        #if canImport(UIKit) && canImport(Network)
        importNetworkObserver()
        #endif
    }

    func stop() {
        lock.lock()
        guard installed else {
            lock.unlock()
            return
        }
        installed = false
        #if canImport(UIKit)
        let observer = foregroundObserver
        foregroundObserver = nil
        #endif
        #if canImport(UIKit) && canImport(Network)
        let monitor = pathMonitor
        pathMonitor = nil
        #endif
        lock.unlock()

        #if canImport(UIKit)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        #endif
        #if canImport(UIKit) && canImport(Network)
        (monitor as? NWPathMonitor)?.cancel()
        #endif
    }

    private func foregrounded() {
        guard isInstalled(), let sdk else { return }
        Task { [weak sdk] in
            guard let sdk else { return }
            try? await sdk.refreshConfigurationForForeground()
        }
    }

    private func networkPathChanged(isAvailable: Bool) {
        lock.lock()
        let shouldRecover = installed && recoveryGate.pathChanged(isAvailable: isAvailable)
        lock.unlock()
        guard shouldRecover, let sdk else { return }
        Task { [weak sdk] in
            guard let sdk else { return }
            try? await sdk.refreshConfigurationForForeground()
        }
    }

    private func isInstalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }
}

#if canImport(UIKit)
import UIKit

private extension OnloNativeLifecycleBinding {
    func importUIKitObserver() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.foregrounded()
        }
    }
}
#endif

#if canImport(UIKit) && canImport(Network)
import Network

private extension OnloNativeLifecycleBinding {
    func importNetworkObserver() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.networkPathChanged(isAvailable: path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "ai.onlo.sdk.network-recovery"))
        lock.lock()
        let shouldCancel = !installed
        if !shouldCancel { pathMonitor = monitor }
        lock.unlock()
        if shouldCancel { monitor.cancel() }
    }
}
#endif
