import Foundation
import Testing
@testable import GrsaiCanvasApp

@Suite("应用数据凭据存储")
struct ApplicationDataSecretStoreTests {
    @Test("保存后可由新实例读取并覆盖")
    func persistsAcrossInstancesAndUpdates() async throws {
        let suiteName = "ApplicationDataSecretStoreTests.\(UUID().uuidString)"
        let firstDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let firstStore = ApplicationDataSecretStore(defaults: firstDefaults)
        try await firstStore.save("  first-token  ")

        let secondDefaults = try #require(UserDefaults(suiteName: suiteName))
        let secondStore = ApplicationDataSecretStore(defaults: secondDefaults)
        #expect(await secondStore.read() == "first-token")

        try await secondStore.save("second-token")
        #expect(await firstStore.read() == "second-token")
    }

    @Test("主动清除后新实例无法读取")
    func deletesPersistedCredential() async throws {
        let suiteName = "ApplicationDataSecretStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = ApplicationDataSecretStore(defaults: defaults)
        try await store.save("test-token")
        await store.delete()

        let reloadedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let reloadedStore = ApplicationDataSecretStore(defaults: reloadedDefaults)
        #expect(await reloadedStore.read() == nil)
    }

    @Test("拒绝只包含空白的凭据")
    func rejectsBlankCredential() async {
        let suiteName = "ApplicationDataSecretStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建隔离的 UserDefaults")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = ApplicationDataSecretStore(defaults: defaults)

        await #expect(throws: GrsaiClientError.self) {
            try await store.save("   \n")
        }
        #expect(await store.read() == nil)
    }
}
