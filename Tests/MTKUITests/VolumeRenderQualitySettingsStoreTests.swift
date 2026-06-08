import MTKCore
@testable import MTKUI
import XCTest

final class VolumeRenderQualitySettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "VolumeRenderQualitySettingsStoreTests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testLoadMigratesLegacyHardShadowDefaultToCurrentDefault() throws {
        let legacyDefault = VolumeRenderQualitySettings(renderResolution: .high,
                                                        interactingResolution: .medium,
                                                        depthResolution: .high,
                                                        iterations: .medium,
                                                        shadowMode: .hard,
                                                        disableShadowsWhenInteracting: false,
                                                        directionalLightIntensity: 1.0,
                                                        ambientLightIntensity: 0.2)
        try save(legacyDefault)

        let store = UserDefaultsVolumeRenderQualitySettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(store.loadVolumeRenderQualitySettings(), .default)
    }

    func testLoadPreservesCustomHardShadowSettings() throws {
        let custom = VolumeRenderQualitySettings(renderResolution: .high,
                                                 interactingResolution: .medium,
                                                 depthResolution: .high,
                                                 iterations: .medium,
                                                 shadowMode: .hard,
                                                 disableShadowsWhenInteracting: false,
                                                 directionalLightIntensity: 1.2,
                                                 ambientLightIntensity: 0.2)
        try save(custom)

        let store = UserDefaultsVolumeRenderQualitySettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(store.loadVolumeRenderQualitySettings(), custom.sanitized)
    }

    private func save(_ settings: VolumeRenderQualitySettings) throws {
        let data = try JSONEncoder().encode(settings.sanitized)
        userDefaults.set(data, forKey: UserDefaultsVolumeRenderQualitySettingsStore.defaultKey)
    }
}
