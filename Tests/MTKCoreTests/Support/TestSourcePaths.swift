import Foundation

func packageRootURL(filePath: StaticString = #filePath) -> URL {
    let fileManager = FileManager.default
    var currentURL = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()

    while true {
        let packageMarker = currentURL.appendingPathComponent("Package.swift").path
        let gitMarker = currentURL.appendingPathComponent(".git").path
        if fileManager.fileExists(atPath: packageMarker) || fileManager.fileExists(atPath: gitMarker) {
            return currentURL
        }

        let parentURL = currentURL.deletingLastPathComponent()
        if parentURL.path == currentURL.path {
            return currentURL
        }
        currentURL = parentURL
    }
}

func sourceFilePath(_ relativePath: String, filePath: StaticString = #filePath) -> String {
    packageRootURL(filePath: filePath).appendingPathComponent(relativePath).path
}
