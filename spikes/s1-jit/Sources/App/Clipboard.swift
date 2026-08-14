#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Der Bericht muss sich auch dann abholen lassen, wenn der Lauf ohne
/// angehängten Debugger stattfand — dann gibt es keine Konsole.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
