import AVFoundation
import Cocoa
import FlutterMacOS
import Speech

@main
class AppDelegate: FlutterAppDelegate {
  /// `flutter run` starts the binary as a child of the editor. macOS then
  /// charges speech and microphone prompts to the editor and aborts this
  /// process. A second launch with this argument asks as Maia itself.
  static let speechPromptArgument = "--maia-speech-prompt"

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let args = ProcessInfo.processInfo.arguments
    if args.contains(Self.speechPromptArgument) {
      NSApp.setActivationPolicy(.regular)
      // The prompt does not present during didFinishLaunching. Ask on the
      // next turn, once AppKit is up.
      DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        SFSpeechRecognizer.requestAuthorization { status in
          AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog(
              "maia-speech-prompt speech=%ld mic=%d",
              status.rawValue,
              granted ? 1 : 0
            )
            DispatchQueue.main.async {
              NSApp.terminate(nil)
            }
          }
        }
      }
      return
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
