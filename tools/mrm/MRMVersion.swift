import Foundation

/// mrm version comes from the Info.plist that the build embeds into the binary
/// (CREATE_INFOPLIST_SECTION_IN_BINARY), so it always matches the app's
/// MARKETING_VERSION / CURRENT_PROJECT_VERSION in Configuration/Base.xcconfig.
enum MRMVersion {
    static let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    static let string = "\(marketing) (\(build))"
}
