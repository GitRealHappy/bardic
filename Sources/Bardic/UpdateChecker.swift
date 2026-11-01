import Foundation
import OSLog

/// Asks GitHub at launch and once a day whether a newer release exists. The request carries nothing about the user
/// or their dictation, and it can be switched off in Settings › General.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "GitRealHappy/bardic"
    static let pageURL = URL(string: "https://github.com/\(repo)")!
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "bardic", category: "updates")

    struct Release: Equatable {
        let version: String
        let url: URL
    }

    /// A release newer than this build, if one was found.
    @Published private(set) var available: Release?
    @Published private(set) var lastResult: String?

    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var enabled: Bool { UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true }

    /// Checks 30 s after launch, then once a day while running.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfEnabled() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateChecker.shared.checkIfEnabled() }
        }
    }

    private func checkIfEnabled() {
        if enabled { Task { await check() } } else { available = nil }
    }

    func check() async {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!,
                                 timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                lastResult = status == 404 ? "No releases published yet." : "GitHub answered \(status)."
                Self.log.notice("update check: HTTP \(status)")
                return
            }
            struct Latest: Decodable {
                let tag_name: String
                let html_url: URL
            }
            let latest = try JSONDecoder().decode(Latest.self, from: data)
            let version = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(version, than: Self.currentVersion) {
                available = Release(version: version, url: latest.html_url)
                lastResult = "Bardic \(version) is available."
            } else {
                available = nil
                lastResult = "You're up to date."
            }
            Self.log.notice("update check: latest \(version, privacy: .public), running \(Self.currentVersion, privacy: .public)")
        } catch {
            lastResult = "Couldn't reach GitHub."
            Self.log.notice("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Compares dotted version numbers component by component ("0.10.0" is newer than "0.9.1").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
