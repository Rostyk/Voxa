import AppKit
import ApplicationServices
import Foundation

enum FaceTimeCheckStatus: String, Sendable {
    case ok
    case warning
    case fail
    case unknown
}

struct FaceTimeCheckRow: Identifiable, Sendable {
    let id: String
    let title: String
    let status: FaceTimeCheckStatus
    let detail: String
}

/// Accessibility-based FaceTime setup probe (no public FaceTime settings API on macOS).
struct SelectVoxaMicOutcome: Sendable {
    var success: Bool
    var logLines: [String]
    var selectedMicrophone: String?
}

struct FaceTimeSettingsCheckResult: Sendable {
    var launchedFaceTime: Bool
    var openedSettings: Bool
    var openedGeneralTab: Bool
    var signInRequired: Bool
    var signInPromptSample: String?
    var appleIDLabelFound: Bool
    var appleIDSample: String?
    var useIPhoneControlFound: Bool
    var useIPhoneSample: String?
    var groupTileCheckboxFound: Bool
    var groupTileCheckboxChecked: Bool?
    var faceTimeSelectedMicrophone: String?
    var voxaMicSelectedInFaceTime: Bool?
    var statusRows: [FaceTimeCheckRow]
    var logLines: [String]
    var errorMessage: String?

    /// Signed in with no sign-in prompt and an Apple ID label (email with `@`) visible in Settings.
    var isClearlySignedIn: Bool {
        !signInRequired && appleIDLabelFound
    }

    var summary: String {
        if let errorMessage { return errorMessage }
        if signInRequired {
            return "FaceTime is not signed in — sign in with your Apple Account first."
        }
        if !isClearlySignedIn {
            return "Sign in to FaceTime with your Apple Account, then run the check again."
        }
        return statusRows.map(\.detail).joined(separator: " ")
    }
}

enum FaceTimeSettingsInspector {

    static let voxaVirtualMicDisplayName = "Voxa Virtual Microphone"

    private static let faceTimeBundleID = "com.apple.FaceTime"
    private static let signInHints = [
        "sign in to facetime",
        "sign in with your apple",
        "sign in to facetime with your apple",
        "sign in to use facetime",
    ]
    private static let scanMaxDepth = 22
    private static let scanMaxNodes = 3_500
    private static let menuSearchMaxDepth = 10
    /// UI settle delays — short enough to feel snappy, long enough for FaceTime labels to appear.
    private static let afterLaunchMs = 450
    private static let afterSettingsOpenMs = 550
    private static let afterGeneralTabMs = 400
    private static let menuSettleSeconds = 0.22

    private struct SearchRoot {
        let label: String
        let element: AXUIElement
    }

    static func runCheck(accessibilityGranted: Bool) async -> FaceTimeSettingsCheckResult {
        var log: [String] = []
        var result = FaceTimeSettingsCheckResult(
            launchedFaceTime: false,
            openedSettings: false,
            openedGeneralTab: false,
            signInRequired: false,
            signInPromptSample: nil,
            appleIDLabelFound: false,
            appleIDSample: nil,
            useIPhoneControlFound: false,
            useIPhoneSample: nil,
            groupTileCheckboxFound: false,
            groupTileCheckboxChecked: nil,
            faceTimeSelectedMicrophone: nil,
            voxaMicSelectedInFaceTime: nil,
            statusRows: [],
            logLines: [],
            errorMessage: nil
        )

        func append(_ line: String) {
            print("[FaceTimeSettings] \(line)")
            log.append(line)
        }

        append("Starting FaceTime accessibility check…")
        append("AXIsProcessTrusted=\(AXIsProcessTrusted()) accessibilityGranted=\(accessibilityGranted)")

        guard accessibilityGranted, AXIsProcessTrusted() else {
            result.errorMessage =
                "Accessibility is not enabled for Voxa. Open System Settings → Privacy & Security → Accessibility, enable Voxa, then run the check again."
            append(result.errorMessage!)
            result.logLines = log
            return result
        }

        do {
            try await launchAndActivateFaceTime(log: append)
            result.launchedFaceTime = true
            try await Task.sleep(for: .milliseconds(afterLaunchMs))

            result = await runAXWork(log: append, starting: result)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            result.errorMessage = message
            append("Failed: \(message)")
        }

        result.statusRows = buildStatusRows(result)
        result.logLines = log
        return result
    }

    static func resultWithRefreshedStatusRows(_ result: FaceTimeSettingsCheckResult) -> FaceTimeSettingsCheckResult {
        var updated = result
        updated.statusRows = buildStatusRows(result)
        return updated
    }

    /// Opens FaceTime → Video → Microphone and selects the Voxa virtual mic.
    static func selectVoxaVirtualMicrophone(accessibilityGranted: Bool) async -> SelectVoxaMicOutcome {
        guard accessibilityGranted, AXIsProcessTrusted() else {
            return SelectVoxaMicOutcome(
                success: false,
                logLines: ["Accessibility is not enabled for Voxa."],
                selectedMicrophone: nil
            )
        }

        return await Task.detached(priority: .userInitiated) {
            var log: [String] = []
            func append(_ line: String) {
                print("[FaceTimeSettings] \(line)")
                log.append(line)
            }

            do {
                try await MainActor.run {
                    try activateFaceTimeIfRunning(log: append)
                }
                Thread.sleep(forTimeInterval: menuSettleSeconds)

                append("Selecting “\(voxaVirtualMicDisplayName)” via Video → Microphone…")
                let (menuBar, videoMenuItem) = try openVideoMenu(log: append)
                let microphoneSubmenu = try openMicrophoneSubmenu(
                    videoMenuItem: videoMenuItem,
                    menuBar: menuBar,
                    log: append
                )

                let needles = [normalize(voxaVirtualMicDisplayName), "voxa virtual"]
                guard let micItem = findMicrophoneDeviceMenuItem(
                    matching: needles,
                    microphoneSubmenu: microphoneSubmenu,
                    videoMenuItem: videoMenuItem,
                    menuBar: menuBar,
                    log: append
                ) else {
                    append("Could not find “\(voxaVirtualMicDisplayName)” under Microphone submenu")
                    dumpMenuItems(under: microphoneSubmenu, log: append, limit: 16, label: "Microphone subtree")
                    return SelectVoxaMicOutcome(success: false, logLines: log, selectedMicrophone: nil)
                }

                let micLabel = elementLabels(micItem).joined(separator: " ")
                append("Selecting menu item: “\(micLabel)”")
                guard performMenuItemSelect(micItem, log: append) else {
                    append("Could not activate microphone menu item")
                    return SelectVoxaMicOutcome(success: false, logLines: log, selectedMicrophone: nil)
                }
                Thread.sleep(forTimeInterval: menuSettleSeconds + 0.12)

                let selected = readFaceTimeMicrophoneSelection(log: append)
                let success = selected.map { SystemInputDeviceCatalog.isVoxaVirtualMicName($0) } ?? false
                if success, let selected {
                    append("Microphone set to “\(selected)”")
                } else {
                    append("Selection after press: “\(selected ?? "unknown")”")
                }
                return SelectVoxaMicOutcome(success: success, logLines: log, selectedMicrophone: selected)
            } catch {
                append("Select Voxa mic failed: \(error.localizedDescription)")
                return SelectVoxaMicOutcome(success: false, logLines: log, selectedMicrophone: nil)
            }
        }.value
    }

    /// Heavy AX tree walks and menu actions — never on the main thread.
    private static func runAXWork(
        log: @escaping (String) -> Void,
        starting: FaceTimeSettingsCheckResult
    ) async -> FaceTimeSettingsCheckResult {
        await Task.detached(priority: .userInitiated) {
            var result = starting
            do {
                var windowRoots = faceTimeWindowRoots(log: log)
                appendScanRoots(windowRoots, log: log, label: "initial")

                for root in windowRoots {
                    var nodes = 0
                    scanSignInAndLabels(element: root.element, depth: 0, nodes: &nodes, log: log, result: &result)
                }

                if result.signInRequired {
                    log("Sign-in prompt detected — skipping Settings and microphone checks")
                    return result
                }

                result.openedSettings = try openFaceTimeSettingsMenu(log: log)
                try await Task.sleep(for: .milliseconds(afterSettingsOpenMs))

                windowRoots = faceTimeWindowRoots(log: log)
                appendScanRoots(windowRoots, log: log, label: "after Settings")

                if let window = windowRoots.first?.element {
                    result.openedGeneralTab = pressGeneralTab(in: window, log: log)
                }
                try await Task.sleep(for: .milliseconds(afterGeneralTabMs))

                windowRoots = faceTimeWindowRoots(log: log)

                for root in windowRoots {
                    var nodes = 0
                    scanSettingsPane(element: root.element, depth: 0, nodes: &nodes, log: log, result: &result)
                }

                for root in windowRoots {
                    var nodes = 0
                    scanSignInAndLabels(element: root.element, depth: 0, nodes: &nodes, log: log, result: &result)
                }

                guard result.isClearlySignedIn else {
                    if result.signInRequired {
                        log("Sign-in prompt in Settings — skipping microphone check")
                    } else {
                        log("Apple ID not found — skipping microphone check")
                    }
                    return result
                }

                result.faceTimeSelectedMicrophone = readFaceTimeMicrophoneSelection(log: log)
                if let mic = result.faceTimeSelectedMicrophone {
                    result.voxaMicSelectedInFaceTime =
                        SystemInputDeviceCatalog.isVoxaVirtualMicName(mic)
                } else {
                    result.voxaMicSelectedInFaceTime = nil
                }

                log(
                    "Done signIn=\(result.signInRequired) settings=\(result.openedSettings) general=\(result.openedGeneralTab) " +
                        "appleID=\(result.appleIDLabelFound) mic=\(result.faceTimeSelectedMicrophone ?? "—")"
                )
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                result.errorMessage = message
                log("Failed: \(message)")
            }
            return result
        }.value
    }

    private static func appendScanRoots(_ roots: [SearchRoot], log: (String) -> Void, label: String) {
        if roots.isEmpty {
            log("\(label): FaceTime main window unavailable")
        } else {
            log("\(label): \(roots.map(\.label).joined(separator: ", "))")
        }
    }

    // MARK: - FaceTime window scope (app main window only)

    private static func faceTimeWindowRoots(log: (String) -> Void) -> [SearchRoot] {
        guard let app = faceTimeApplicationElement() else {
            log("FaceTime app element unavailable")
            return []
        }
        guard let window = mainWindow(of: app) else {
            log("FaceTime main window unavailable")
            return []
        }
        let title = stringAttribute(kAXTitleAttribute as CFString, on: window) ?? ""
        return [SearchRoot(label: "FaceTime main window “\(title)”", element: window)]
    }

    private static func mainWindow(of app: AXUIElement) -> AXUIElement? {
        if let focused = elementAttribute(kAXFocusedWindowAttribute as CFString, on: app) {
            return focused
        }
        if let main = elementAttribute(kAXMainWindowAttribute as CFString, on: app) {
            return main
        }
        return windows(of: app).first
    }

    // MARK: - Launch

    private enum InspectorError: LocalizedError {
        case faceTimeNotRunning
        case settingsMenuUnavailable
        case videoMenuUnavailable

        var errorDescription: String? {
            switch self {
            case .faceTimeNotRunning: return "FaceTime is not running."
            case .settingsMenuUnavailable: return "Could not open FaceTime → Settings (see scan log)."
            case .videoMenuUnavailable: return "Could not open FaceTime → Video menu."
            }
        }
    }

    @MainActor
    private static func activateFaceTimeIfRunning(log: (String) -> Void) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: faceTimeBundleID).first else {
            throw InspectorError.faceTimeNotRunning
        }
        log("Activating FaceTime pid=\(app.processIdentifier)")
        _ = app.activate(options: [.activateIgnoringOtherApps])
    }

    @MainActor
    private static func launchAndActivateFaceTime(log: (String) -> Void) async throws {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: faceTimeBundleID) {
            log("Opening FaceTime…")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
        try await waitForRunningFaceTime(log: log)
    }

    @MainActor
    private static func waitForRunningFaceTime(log: (String) -> Void) async throws {
        for attempt in 0 ..< 20 {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: faceTimeBundleID).first {
                log("Activating FaceTime pid=\(app.processIdentifier)")
                _ = app.activate(options: [.activateIgnoringOtherApps])
                return
            }
            if attempt == 0 { log("Waiting for FaceTime…") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw InspectorError.faceTimeNotRunning
    }

    private static func applicationElement(bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func faceTimeApplicationElement() -> AXUIElement? {
        applicationElement(bundleID: faceTimeBundleID)
    }

    // MARK: - Menus

    private static func openFaceTimeSettingsMenu(log: (String) -> Void) throws -> Bool {
        guard let appElement = faceTimeApplicationElement() else {
            log("FaceTime not running")
            throw InspectorError.faceTimeNotRunning
        }

        guard let menuBar = elementAttribute(kAXMenuBarAttribute as CFString, on: appElement) else {
            log("FaceTime menu bar not found")
            throw InspectorError.settingsMenuUnavailable
        }

        guard let faceTimeMenuItem = findMenuBarItem(titled: "FaceTime", under: menuBar) else {
            log("FaceTime menu bar item not found")
            dumpMenuBarItems(menuBar, log: log)
            throw InspectorError.settingsMenuUnavailable
        }

        log("Opening FaceTime menu (AXShowMenu)")
        if !showMenu(faceTimeMenuItem) {
            log("AXShowMenu failed, trying AXPress on FaceTime menu")
            try performPress(faceTimeMenuItem)
        }
        Thread.sleep(forTimeInterval: menuSettleSeconds)

        let settingsTitles = ["settings", "settings…", "preferences", "preferences…"]
        if let settingsItem = findMenuItem(matching: settingsTitles, under: menuBar, maxDepth: menuSearchMaxDepth, log: log) {
            log("Pressing Settings (found under menu bar)")
            try performPress(settingsItem)
            return true
        }
        if let settingsItem = findMenuItem(matching: settingsTitles, under: faceTimeMenuItem, maxDepth: menuSearchMaxDepth, log: log) {
            log("Pressing Settings (found under FaceTime menu item)")
            try performPress(settingsItem)
            return true
        }

        log("Settings menu item not found")
        dumpMenuBarItems(menuBar, log: log)
        throw InspectorError.settingsMenuUnavailable
    }

    private static func openVideoMenu(log: (String) -> Void) throws -> (menuBar: AXUIElement, videoMenuItem: AXUIElement) {
        guard let appElement = faceTimeApplicationElement() else {
            throw InspectorError.faceTimeNotRunning
        }
        guard let menuBar = elementAttribute(kAXMenuBarAttribute as CFString, on: appElement) else {
            log("Video menu: menu bar missing")
            throw InspectorError.videoMenuUnavailable
        }
        guard let videoMenuItem = findMenuBarItem(titled: "Video", under: menuBar) else {
            log("Video menu bar item not found")
            throw InspectorError.videoMenuUnavailable
        }

        log("Opening Video menu")
        if !showMenu(videoMenuItem) {
            log("AXShowMenu failed, trying AXPress on Video menu")
            guard AXUIElementPerformAction(videoMenuItem, kAXPressAction as CFString) == .success else {
                throw InspectorError.videoMenuUnavailable
            }
        }
        Thread.sleep(forTimeInterval: menuSettleSeconds)
        return (menuBar, videoMenuItem)
    }

    private static func readFaceTimeMicrophoneSelection(log: (String) -> Void) -> String? {
        do {
            let (menuBar, videoMenuItem) = try openVideoMenu(log: log)
            _ = try? openMicrophoneSubmenu(videoMenuItem: videoMenuItem, menuBar: menuBar, log: log)
            if let selected = findCheckedMenuItem(under: videoMenuItem, header: "microphone", log: log)
                ?? findCheckedMenuItem(under: menuBar, header: "microphone", log: log)
            {
                log("Microphone selection: “\(selected)”")
                return selected
            }
            log("No checked item under Video → Microphone")
            return nil
        } catch {
            log("Video menu: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            return nil
        }
    }

    private static func openMicrophoneSubmenu(
        videoMenuItem: AXUIElement,
        menuBar: AXUIElement,
        log: (String) -> Void
    ) throws -> AXUIElement {
        let microphoneTitles = ["microphone"]
        let microphoneItem =
            findMenuItem(matching: microphoneTitles, under: videoMenuItem, maxDepth: menuSearchMaxDepth, log: log)
            ?? findMenuItem(matching: microphoneTitles, under: menuBar, maxDepth: menuSearchMaxDepth + 4, log: log)

        guard let microphoneItem else {
            log("Microphone submenu entry not found under Video")
            throw InspectorError.videoMenuUnavailable
        }

        let header = elementLabels(microphoneItem).joined(separator: " ")
        log("Opening Microphone submenu (“\(header)”)")
        if !showMenu(microphoneItem) {
            log("AXShowMenu on Microphone failed, trying AXPress")
            guard AXUIElementPerformAction(microphoneItem, kAXPressAction as CFString) == .success else {
                throw InspectorError.videoMenuUnavailable
            }
        }
        Thread.sleep(forTimeInterval: menuSettleSeconds)
        return microphoneItem
    }

    private static func findMicrophoneDeviceMenuItem(
        matching needles: [String],
        microphoneSubmenu: AXUIElement,
        videoMenuItem: AXUIElement,
        menuBar: AXUIElement,
        log: (String) -> Void
    ) -> AXUIElement? {
        let searchDepth = menuSearchMaxDepth + 8
        if let item = findAXMenuItem(matching: needles, under: microphoneSubmenu, maxDepth: searchDepth, log: log) {
            return item
        }
        for root in [videoMenuItem, menuBar] {
            if let item = findAXMenuItemAfterHeader(
                header: "microphone",
                matching: needles,
                under: root,
                maxDepth: searchDepth,
                log: log
            ) {
                return item
            }
        }
        return nil
    }

    private static func findAXMenuItem(
        matching needles: [String],
        under root: AXUIElement,
        maxDepth: Int,
        log: (String) -> Void
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > maxDepth { continue }

            if isMenuItem(element) {
                let combined = normalize(elementLabels(element).joined(separator: " "))
                if isMicrophoneSectionHeader(combined) { /* skip */ }
                else if needles.contains(where: { combined.contains($0) }), !combined.contains("use system setting") {
                    log("Found AXMenuItem: “\(elementLabels(element).joined(separator: " "))”")
                    return element
                }
            }

            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func findAXMenuItemAfterHeader(
        header: String,
        matching needles: [String],
        under root: AXUIElement,
        maxDepth: Int,
        log: (String) -> Void
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var sawHeader = false
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > maxDepth { continue }

            let combined = normalize(elementLabels(element).joined(separator: " "))
            if combined == header || combined.hasPrefix("\(header) ") || combined.contains(header) {
                sawHeader = true
            }

            if sawHeader, isMenuItem(element) {
                if isMicrophoneSectionHeader(combined) { /* skip header row */ }
                else if needles.contains(where: { combined.contains($0) }), !combined.contains("use system setting") {
                    log("Found AXMenuItem after Microphone header: “\(elementLabels(element).joined(separator: " "))”")
                    return element
                }
            }

            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func isMicrophoneSectionHeader(_ normalizedCombined: String) -> Bool {
        normalizedCombined == "microphone"
            || (normalizedCombined.hasPrefix("microphone ") && !normalizedCombined.contains("voxa"))
    }

    private static func isMenuItem(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute as CFString, on: element) ?? ""
        return role == (kAXMenuItemRole as String) || role == "AXMenuItem"
    }

    private static func performMenuItemSelect(_ element: AXUIElement, log: (String) -> Void) -> Bool {
        if AXUIElementPerformAction(element, kAXPickAction as CFString) == .success {
            log("kAXPickAction succeeded")
            return true
        }
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            log("kAXPressAction succeeded")
            return true
        }
        log("kAXPickAction and kAXPressAction failed")
        return false
    }

    private static func dumpMenuItems(
        under root: AXUIElement,
        log: (String) -> Void,
        limit: Int,
        label: String
    ) {
        var count = 0
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty, count < limit {
            let (element, depth) = queue.removeFirst()
            if depth > menuSearchMaxDepth + 6 { continue }
            if isMenuItem(element) {
                let labels = elementLabels(element)
                let role = stringAttribute(kAXRoleAttribute as CFString, on: element) ?? "?"
                log("  [\(label)] depth=\(depth) role=\(role) “\(labels.joined(separator: " | "))”")
                count += 1
            }
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
    }

    private static func pressGeneralTab(in window: AXUIElement, log: (String) -> Void) -> Bool {
        if let general = findPressable(matching: ["general"], under: window, maxDepth: scanMaxDepth) {
            log("Pressing General tab")
            do {
                try performPress(general)
                return true
            } catch {
                log("General press failed: \(error.localizedDescription)")
            }
        }
        log("General tab not found in FaceTime main window")
        return false
    }

    // MARK: - Scans

    private static func scanSignInAndLabels(
        element: AXUIElement,
        depth: Int,
        nodes: inout Int,
        log: (String) -> Void,
        result: inout FaceTimeSettingsCheckResult
    ) {
        guard depth <= scanMaxDepth, nodes < scanMaxNodes else { return }
        nodes += 1

        for label in elementLabels(element) {
            let lower = normalize(label)
            if signInHints.contains(where: { lower.contains($0) }) {
                result.signInRequired = true
                result.signInPromptSample = String(label.prefix(120))
                log("Sign-in text: “\(label)”")
                return
            }
        }

        for child in children(of: element) {
            scanSignInAndLabels(element: child, depth: depth + 1, nodes: &nodes, log: log, result: &result)
            if result.signInRequired { return }
        }
    }

    private static func scanSettingsPane(
        element: AXUIElement,
        depth: Int,
        nodes: inout Int,
        log: (String) -> Void,
        result: inout FaceTimeSettingsCheckResult
    ) {
        guard depth <= scanMaxDepth, nodes < scanMaxNodes else { return }
        if result.appleIDLabelFound && result.useIPhoneControlFound { return }
        nodes += 1

        let role = stringAttribute(kAXRoleAttribute as CFString, on: element) ?? ""
        let labels = elementLabels(element)

        if role == (kAXStaticTextRole as String) || role == "AXStaticText" {
            for label in labels {
                if label.contains("@"), !result.appleIDLabelFound {
                    result.appleIDLabelFound = true
                    result.appleIDSample = String(label.prefix(80))
                    log("Apple ID (@): “\(label)”")
                }
                let lower = normalize(label)
                if !result.useIPhoneControlFound,
                   (lower.contains("iphone") && (lower.contains("use") || lower.contains("calls")))
                    || lower.contains("use your iphone")
                {
                    result.useIPhoneControlFound = true
                    result.useIPhoneSample = String(label.prefix(100))
                    log("iPhone relay: “\(label)”")
                }
            }
        }

        if !result.useIPhoneControlFound, isPressable(element) {
            let combined = labels.joined(separator: " ").lowercased()
            if combined.contains("use") && combined.contains("iphone") {
                result.useIPhoneControlFound = true
                result.useIPhoneSample = String(labels.joined(separator: " ").prefix(100))
            }
        }

        if result.appleIDLabelFound && result.useIPhoneControlFound { return }

        for child in children(of: element) {
            scanSettingsPane(element: child, depth: depth + 1, nodes: &nodes, log: log, result: &result)
            if result.appleIDLabelFound && result.useIPhoneControlFound { return }
        }
    }

    // MARK: - Find

    private static func findMenuBarItem(titled target: String, under menuBar: AXUIElement) -> AXUIElement? {
        let normalized = normalize(target)
        for child in children(of: menuBar) {
            for label in elementLabels(child) where normalize(label) == normalized {
                return child
            }
        }
        return nil
    }

    private static func dumpMenuBarItems(_ menuBar: AXUIElement, log: (String) -> Void) {
        for child in children(of: menuBar) {
            let labels = elementLabels(child)
            let role = stringAttribute(kAXRoleAttribute as CFString, on: child) ?? "?"
            log("  menuBar child role=\(role) labels=\(labels)")
        }
    }

    private static func findMenuItem(
        matching titles: [String],
        under root: AXUIElement,
        maxDepth: Int,
        log: (String) -> Void
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > maxDepth { continue }
            if isPressable(element) {
                for label in elementLabels(element) {
                    let n = normalize(label)
                    if titles.contains(where: { n == $0 || n.hasPrefix($0) }) {
                        log("Found menu item “\(label)”")
                        return element
                    }
                }
            }
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func findCheckedMenuItem(under menuRoot: AXUIElement, header: String, log: (String) -> Void) -> String? {
        var queue: [(AXUIElement, Int)] = [(menuRoot, 0)]
        var sawHeader = false
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > menuSearchMaxDepth { continue }
            let labels = elementLabels(element)
            let combined = normalize(labels.joined(separator: " "))
            if combined == header || combined.contains(header) {
                sawHeader = true
            }
            if sawHeader, isPressable(element) {
                if menuItemIsSelected(element), let title = labels.first, !title.isEmpty {
                    return title
                }
                for label in labels where !label.isEmpty {
                    if menuItemIsSelected(element) { return label }
                }
            }
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func menuItemIsSelected(_ element: AXUIElement) -> Bool {
        if let value = stringAttribute(kAXValueAttribute as CFString, on: element) {
            let n = normalize(value)
            if n == "1" || n == "true" || n.contains("checked") || n.contains("selected") { return true }
        }
        if let mark = stringAttribute("AXMenuItemMarkChar" as CFString, on: element), !mark.isEmpty {
            return true
        }
        return false
    }

    private static func findPressable(matching needles: [String], under root: AXUIElement, maxDepth: Int) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > maxDepth { continue }
            if isPressable(element) {
                let combined = normalize(elementLabels(element).joined(separator: " "))
                if needles.contains(where: { combined.contains($0) }) {
                    return element
                }
            }
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    // MARK: - AX helpers

    private static func showMenu(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success
    }

    private static func performPress(_ element: AXUIElement) throws {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw InspectorError.settingsMenuUnavailable
        }
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        guard let raw = copyObject(kAXWindowsAttribute as CFString, on: app) else { return [] }
        if let list = raw as? [AXUIElement] { return list }
        if CFGetTypeID(raw) == CFArrayGetTypeID() {
            let array = raw as! CFArray
            return (0 ..< CFArrayGetCount(array)).map { index in
                unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: AXUIElement.self)
            }
        }
        return []
    }

    private static func isPressable(_ element: AXUIElement) -> Bool {
        if hasAction(element, kAXPressAction as String) { return true }
        let role = stringAttribute(kAXRoleAttribute as CFString, on: element) ?? ""
        return role == (kAXMenuBarItemRole as String) || role == (kAXMenuItemRole as String)
            || role == (kAXButtonRole as String) || role == (kAXRadioButtonRole as String)
            || role == "AXMenuButton"
    }

    private static func hasAction(_ element: AXUIElement, _ name: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return false }
        for index in 0 ..< CFArrayGetCount(names) {
            guard let value = CFArrayGetValueAtIndex(names, index) else { continue }
            if unsafeBitCast(value, to: CFString.self) as String == name { return true }
        }
        return false
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyObject(kAXChildrenAttribute as CFString, on: element) else { return [] }
        if let list = raw as? [AXUIElement] { return list }
        if CFGetTypeID(raw) == CFArrayGetTypeID() {
            let array = raw as! CFArray
            return (0 ..< CFArrayGetCount(array)).map { index in
                unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: AXUIElement.self)
            }
        }
        return []
    }

    private static func elementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        guard let raw = copyObject(attribute, on: element) else { return nil }
        if CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
        return nil
    }

    private static func copyObject(_ attribute: CFString, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private static func elementLabels(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute]
            .compactMap { stringAttribute($0 as CFString, on: element) }
            .filter { !$0.isEmpty }
    }

    private static func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return (value as! CFString) as String
        }
        return nil
    }

    private static func normalize(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func buildStatusRows(_ r: FaceTimeSettingsCheckResult) -> [FaceTimeCheckRow] {
        var rows: [FaceTimeCheckRow] = []

        let appleAccountStatus: FaceTimeCheckStatus
        let appleAccountDetail: String
        if r.signInRequired {
            appleAccountStatus = .fail
            appleAccountDetail = r.signInPromptSample ?? "Sign in to FaceTime with your Apple Account"
        } else if r.appleIDLabelFound, let appleID = r.appleIDSample {
            appleAccountStatus = .ok
            appleAccountDetail = "Signed in as \(appleID)"
        } else {
            appleAccountStatus = .warning
            appleAccountDetail = "Could not confirm sign-in — open FaceTime → Settings and sign in, then run the check again"
        }

        rows.append(
            FaceTimeCheckRow(
                id: "signin",
                title: "Apple Account",
                status: appleAccountStatus,
                detail: appleAccountDetail
            )
        )

        guard r.isClearlySignedIn else { return rows }

        if r.useIPhoneControlFound {
            rows.append(
                FaceTimeCheckRow(
                    id: "iphone",
                    title: "Calls from iPhone",
                    status: .ok,
                    detail: r.useIPhoneSample ?? "“Use your iPhone” control present"
                )
            )
        }

        if let mic = r.faceTimeSelectedMicrophone {
            let voxaSelected = r.voxaMicSelectedInFaceTime == true
            rows.append(
                FaceTimeCheckRow(
                    id: "mic",
                    title: "FaceTime microphone",
                    status: voxaSelected ? .ok : .warning,
                    detail: voxaSelected
                        ? "Selected: “\(mic)”"
                        : "Selected: “\(mic)”. Choose “\(voxaVirtualMicDisplayName)” under FaceTime → Video → Microphone if you want Voxa to speak on your behalf during calls."
                )
            )
        } else {
            rows.append(
                FaceTimeCheckRow(
                    id: "mic",
                    title: "FaceTime microphone",
                    status: .warning,
                    detail: "Could not read Video → Microphone menu"
                )
            )
        }

        return rows
    }
}
