import Network

/// 网络可达性:用于"联网优先,断网降级本地"。
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "com.bevis.voicekey.net"))
    }
}
