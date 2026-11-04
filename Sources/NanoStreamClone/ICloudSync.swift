import Foundation

// Dev round 10 (D-04): iCloud key-value sync for playlists and
// settings. No CloudKit container is built: NSUbiquitousKeyValueStore
// is the whole mechanism, and the entitlements file only declares
// the key-value capability. Behaviour contract:
// - No iCloud environment (no ubiquity identity token) -> every
//   call silently no-ops. The app never errors, never banners, and
//   never drops local data for lack of iCloud.
// - Conflict rule is last-write-wins by the snapshot's updatedAt
//   timestamp, enforced in AppState.applyICloudSnapshot; a stale
//   remote never overwrites newer local data.
// - Scope is playlists metadata + plain settings only. Passwords
//   live in the Keychain and are never in a snapshot (see
//   AppState.ICloudSnapshot); keys and tokens are never synced.
// - Entitlements take effect only in a signed build. This repo's CI
//   builds unsigned (CODE_SIGNING_ALLOWED=NO), so whether the
//   capability actually activates is a signed-build verification
//   item, stated here and in the round report, not claimed.

@MainActor
final class ICloudSync {
    static let shared = ICloudSync()

    private let storeKey = "nanostream.icloud.snapshot"
    private var onExternalChange: ((AppState.ICloudSnapshot) -> Void)?
    private var observing = false

    private var store: NSUbiquitousKeyValueStore { NSUbiquitousKeyValueStore.default }

    /// True only when the device reports an iCloud identity. Without
    /// one, push/pull are no-ops by design (see the header note).
    var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Starts observing external changes. Safe to call repeatedly;
    /// the observer is installed once. The handler runs on the main
    /// actor (the notification is delivered there by dispatching
    /// through the main queue below).
    func start(onExternalChange: @escaping (AppState.ICloudSnapshot) -> Void) {
        self.onExternalChange = onExternalChange
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleExternalChange()
            }
        }
    }

    /// Pushes the current snapshot. No-op without iCloud or when
    /// sync is disabled by the caller (AppState.save gates on the
    /// setting before calling).
    func push(from state: AppState) {
        guard isAvailable else { return }
        let snapshot = state.iCloudSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        store.set(data, forKey: storeKey)
        store.synchronize()
    }

    /// One-time pull at launch. A stored snapshot newer than local
    /// data flows through the same apply path as external changes.
    func pullInitial(into state: AppState) {
        guard isAvailable else { return }
        store.synchronize()
        guard let data = store.data(forKey: storeKey),
              let snapshot = try? JSONDecoder().decode(AppState.ICloudSnapshot.self, from: data) else { return }
        state.applyICloudSnapshot(snapshot)
    }

    private func handleExternalChange() {
        guard isAvailable else { return }
        store.synchronize()
        guard let data = store.data(forKey: storeKey),
              let snapshot = try? JSONDecoder().decode(AppState.ICloudSnapshot.self, from: data) else { return }
        onExternalChange?(snapshot)
    }
}
