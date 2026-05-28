//
//  VolumeRenderQualitySettingsStore.swift
//  MTKUI
//
//  Persistence boundary for 3D volume render quality preferences.
//

import Foundation
import MTKCore

public protocol VolumeRenderQualitySettingsStoring: AnyObject {
    func loadVolumeRenderQualitySettings() -> VolumeRenderQualitySettings?
    func saveVolumeRenderQualitySettings(_ settings: VolumeRenderQualitySettings)
}

public final class UserDefaultsVolumeRenderQualitySettingsStore: VolumeRenderQualitySettingsStoring {
    public static let defaultKey = "com.mtk.volumeRenderQualitySettings"

    private let userDefaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(userDefaults: UserDefaults = .standard,
                key: String = UserDefaultsVolumeRenderQualitySettingsStore.defaultKey) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func loadVolumeRenderQualitySettings() -> VolumeRenderQualitySettings? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? decoder.decode(VolumeRenderQualitySettings.self, from: data).sanitized
    }

    public func saveVolumeRenderQualitySettings(_ settings: VolumeRenderQualitySettings) {
        guard let data = try? encoder.encode(settings.sanitized) else { return }
        userDefaults.set(data, forKey: key)
    }
}
