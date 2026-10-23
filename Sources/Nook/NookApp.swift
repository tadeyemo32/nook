import AppKit

@main
enum NookApp {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let command = arguments.first, CLI.commands.contains(command) { exit(CLI.run(arguments)) }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
