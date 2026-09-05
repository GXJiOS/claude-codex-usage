import AppKit

// `QuotaBar --once`: fetch every provider once, print the result, exit. Used for
// verification from a terminal; the normal launch has no stdout.
if CommandLine.arguments.contains("--once") {
    if CommandLine.arguments.contains("--raw") {
        let group = DispatchGroup()
        group.enter()
        Task {
            defer { group.leave() }
            do { print("=== Claude\n" + (try await ClaudeProvider().fetchRawJSON())) } catch { print("Claude ERROR: \(error.localizedDescription)") }
            do { print("\n=== Codex\n" + (try await CodexProvider().fetchRawJSON())) } catch { print("Codex ERROR: \(error.localizedDescription)") }
        }
        group.wait()
        exit(0)
    }
    let providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider()]
    let group = DispatchGroup()
    for provider in providers {
        group.enter()
        Task {
            defer { group.leave() }
            do {
                let snapshot = try await provider.fetch()
                let mode = DisplayMode.load()
                print("\(provider.kind.displayName) [\(snapshot.planLabel ?? "?")] — \(mode.rawValue) %")
                print("  session : \(Format.windowLine(snapshot.session, mode: mode))")
                print("  weekly  : \(Format.windowLine(snapshot.weekly, mode: mode))")
                for extra in snapshot.extras { print("  \(extra.label): \(Format.windowLine(extra.window, mode: mode))") }
                if let tokens = snapshot.tokensToday { print("  today   : \(Format.tokens(tokens)) tokens (\(tokens))") }
                if let note = snapshot.sourceNote { print("  note    : \(note)") }
            } catch {
                print("\(provider.kind.displayName) ERROR: \(error.localizedDescription)")
            }
        }
    }
    group.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only: no Dock icon, no app menu. Info.plist also sets LSUIElement.
app.setActivationPolicy(.accessory)
app.run()
