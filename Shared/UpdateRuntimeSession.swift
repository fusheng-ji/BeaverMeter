import Foundation

@MainActor
protocol UpdateRuntimeSession: AnyObject {
    var updateInstallationBlockReason: String? { get }
    func suspendForUpdate()
    func resumeAfterUpdate()
}
