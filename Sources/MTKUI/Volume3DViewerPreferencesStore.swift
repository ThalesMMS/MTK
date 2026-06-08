import Foundation

public struct Volume3DViewerPreferences: Codable, Equatable, Sendable {
    public var isImageAnnotationsVisible: Bool

    public init(isImageAnnotationsVisible: Bool = true) {
        self.isImageAnnotationsVisible = isImageAnnotationsVisible
    }

    public static let `default` = Volume3DViewerPreferences()
}

public protocol Volume3DViewerPreferencesStoring: AnyObject {
    func loadVolume3DViewerPreferences() -> Volume3DViewerPreferences?
    func saveVolume3DViewerPreferences(_ preferences: Volume3DViewerPreferences)
}

public final class UserDefaultsVolume3DViewerPreferencesStore: Volume3DViewerPreferencesStoring {
    public static let defaultKey = "com.mtk.volume3DViewerPreferences"

    private let userDefaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(userDefaults: UserDefaults = .standard,
                key: String = UserDefaultsVolume3DViewerPreferencesStore.defaultKey) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func loadVolume3DViewerPreferences() -> Volume3DViewerPreferences? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? decoder.decode(Volume3DViewerPreferences.self, from: data)
    }

    public func saveVolume3DViewerPreferences(_ preferences: Volume3DViewerPreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        userDefaults.set(data, forKey: key)
    }
}
