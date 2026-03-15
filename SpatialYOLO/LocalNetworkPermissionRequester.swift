//
//  LocalNetworkPermissionRequester.swift
//  SpatialYOLO
//
//  首次启动主动触发局域网权限提示
//

import Foundation
import Network

@MainActor
final class LocalNetworkPermissionRequester {

    enum Result: String {
        case granted
        case denied
        case unavailable
    }

    private enum Constants {
        static let hasRequestedKey = "hasRequestedLocalNetworkPermission"
        static let serviceType = "_spylolo-perm._tcp"
        static let timeout: TimeInterval = 8
    }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var timeoutTask: Task<Void, Never>?
    private var completion: ((Result) -> Void)?
    private var didFinish = false

    func requestIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Constants.hasRequestedKey) else {
            return
        }

        UserDefaults.standard.set(true, forKey: Constants.hasRequestedKey)
        requestPermission { _ in }
    }

    func requestPermission(completion: @escaping (Result) -> Void) {
        guard listener == nil, browser == nil else {
            return
        }

        self.completion = completion
        didFinish = false

        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: "SpatialYOLO", type: Constants.serviceType)
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }

            let browser = NWBrowser(for: .bonjour(type: Constants.serviceType, domain: nil), using: parameters)
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleBrowserState(state)
                }
            }
            browser.browseResultsChangedHandler = { [weak self] _, _ in
                Task { @MainActor in
                    self?.finish(.granted)
                }
            }

            self.listener = listener
            self.browser = browser

            let queue = DispatchQueue(label: "com.darkstring.SpatialYOLO.local-network")
            listener.start(queue: queue)
            browser.start(queue: queue)

            print("[LocalNetwork] requesting permission via Bonjour probe")

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Constants.timeout * 1_000_000_000))
                await MainActor.run {
                    self?.finish(.unavailable)
                }
            }
        } catch {
            print("[LocalNetwork] failed to create permission probe: \(error)")
            finish(.unavailable)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            print("[LocalNetwork] listener failed: \(error)")
            finish(isPermissionDenied(error) ? .denied : .unavailable)
        default:
            break
        }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            print("[LocalNetwork] browser ready")
            finish(.granted)
        case .failed(let error):
            print("[LocalNetwork] browser failed: \(error)")
            finish(isPermissionDenied(error) ? .denied : .unavailable)
        case .waiting(let error):
            print("[LocalNetwork] browser waiting: \(error)")
            if isPermissionDenied(error) {
                finish(.denied)
            }
        default:
            break
        }
    }

    private func isPermissionDenied(_ error: NWError) -> Bool {
        switch error {
        case .dns(let dnsError):
            return dnsError == kDNSServiceErr_PolicyDenied
        default:
            return false
        }
    }

    private func finish(_ result: Result) {
        guard !didFinish else { return }
        didFinish = true

        timeoutTask?.cancel()
        timeoutTask = nil

        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil

        print("[LocalNetwork] permission probe finished: \(result.rawValue)")
        completion?(result)
        completion = nil
    }
}
