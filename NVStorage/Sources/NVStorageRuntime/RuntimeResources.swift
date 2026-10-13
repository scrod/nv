import Foundation

/// Finds the package resources in a signed application's standard resource directory or SwiftPM layout.
enum RuntimeResources {
    static let bundle: Bundle = {
        if let location = Bundle.main.url(forResource: "NVStorage_NVStorageRuntime", withExtension: "bundle"),
           let embedded = Bundle(url: location) { return embedded }
        return Bundle.module
    }()
}
