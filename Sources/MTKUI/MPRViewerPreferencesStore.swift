//
//  MPRViewerPreferencesStore.swift
//  MTKUI
//
//  Persistence boundary for MPR viewer menu preferences.
//

import Foundation

public struct MPRViewerPreferences: Codable, Equatable, Sendable {
    public var screenLayout: MPRScreenLayout
    public var isAnnotationsVisible: Bool
    public var isCrosshairVisible: Bool

    public init(screenLayout: MPRScreenLayout = .defaultLayout,
                isAnnotationsVisible: Bool = true,
                isCrosshairVisible: Bool = true) {
        self.screenLayout = screenLayout
        self.isAnnotationsVisible = isAnnotationsVisible
        self.isCrosshairVisible = isCrosshairVisible
    }

    public static let `default` = MPRViewerPreferences()
}

public protocol MPRViewerPreferencesStoring: AnyObject {
    func loadMPRViewerPreferences() -> MPRViewerPreferences?
    func saveMPRViewerPreferences(_ preferences: MPRViewerPreferences)
}

public final class UserDefaultsMPRViewerPreferencesStore: MPRViewerPreferencesStoring {
    public static let defaultKey = "com.mtk.mprViewerPreferences"

    private let userDefaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(userDefaults: UserDefaults = .standard,
                key: String = UserDefaultsMPRViewerPreferencesStore.defaultKey) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func loadMPRViewerPreferences() -> MPRViewerPreferences? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? decoder.decode(MPRViewerPreferences.self, from: data)
    }

    public func saveMPRViewerPreferences(_ preferences: MPRViewerPreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        userDefaults.set(data, forKey: key)
    }
}
