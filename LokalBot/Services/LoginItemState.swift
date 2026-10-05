import Combine
import Foundation
import ServiceManagement

/// Main-thread mirror of the login-item state.
///
/// `SMAppService` performs synchronous system work. Keep that work behind this
/// small feature-owned object so Settings rendering only reads cached values.
@MainActor
final class LoginItemState: ObservableObject {
    static let shared = LoginItemState()

    @Published private(set) var isEnabled = false
    @Published private(set) var isLoaded = false
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?

    private let read: @Sendable () -> Bool
    private let write: @Sendable (Bool) throws -> Void

    init(read: @escaping @Sendable () -> Bool = { SMAppService.mainApp.status == .enabled },
         write: @escaping @Sendable (Bool) throws -> Void = { enabled in
             if enabled {
                 try SMAppService.mainApp.register()
             } else {
                 try SMAppService.mainApp.unregister()
             }
         }) {
        self.read = read
        self.write = write
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        let read = read
        isEnabled = await Task.detached(priority: .utility) { read() }.value
        isLoaded = true
        isBusy = false
    }

    func setEnabled(_ enabled: Bool) async {
        guard isLoaded, !isBusy else { return }
        isBusy = true
        error = nil
        let read = read
        let write = write
        let result = await Task.detached(priority: .utility) { () -> (Bool, String?) in
            do {
                try write(enabled)
                return (read(), nil)
            } catch {
                return (read(), error.localizedDescription)
            }
        }.value
        isEnabled = result.0
        error = result.1
        isBusy = false
    }
}
