import AppKit

@main
enum NookApp {
    @MainActor private static let delegate = AppDelegate()

    static func isCLIInvocation(_ arguments: [String]) -> Bool {
        arguments.first.map { CLI.commands.contains($0) || !$0.hasPrefix("-") } ?? false
    }

    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if isCLIInvocation(arguments) { exit(CLI.run(arguments)) }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
