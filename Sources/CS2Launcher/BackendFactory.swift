import Foundation

/// `CS2L_PREVIEW=1` runs the UI against the fake backend.
func makeBackend() -> LauncherBackend {
    ProcessInfo.processInfo.environment["CS2L_PREVIEW"] == "1" ? PreviewBackend() : LiveBackend()
}
