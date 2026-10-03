import AppKit

// Apply Finder/Dock icon metadata without modifying the signed executable or plist.
guard CommandLine.arguments.count == 3,
      let icon = NSImage(contentsOfFile: CommandLine.arguments[1]),
      NSWorkspace.shared.setIcon(icon, forFile: CommandLine.arguments[2], options: []) else {
    fatalError("Usage: swift Diagnostics/SetAppIcon.swift icon.png /path/to/App.app")
}
print("Custom icon applied to \(CommandLine.arguments[2])")
