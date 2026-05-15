import AppKit
import ApplicationServices
import Foundation

/// Low-level Accessibility tree search for in-call FaceTime UI.
/// On macOS the active call controls (Keypad, digits) live under **Notification Center**, not FaceTime.app.
enum FaceTimeAccessibilityAX {
    static let faceTimeBundleID = "com.apple.FaceTime"
    static let notificationCenterBundleID = "com.apple.notificationcenterui"
    static let keypadButtonTitle = "Keypad"

    /// FaceTime in-call keypad button labels (after opening Keypad).
    private static let digitKeypadLabels: [Character: String] = [
        "1": "1,",
        "2": "2, ABC",
        "3": "3, DEF",
        "4": "4, GHI",
        "5": "5, JKL",
        "6": "6, MNO",
        "7": "7, PQRS",
        "8": "8, TUV",
        "9": "9, WXYZ",
    ]

    private static let maxSearchDepth = 32
    private static let logSurveyMaxNodes = 250
    private static let logSurveyMaxDepth = 12

    /// Keeps the call in FaceTime; UI is driven via Notification Center’s AX tree.
    static func activateFaceTimeCallApp() throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: faceTimeBundleID).first else {
            throw FaceTimeDTMFAccessibility.Error.faceTimeNotRunning
        }
        print("[VoxaDTMF] activate FaceTime pid=\(app.processIdentifier)")
        _ = app.activate(options: [.activateIgnoringOtherApps])
    }

    /// Notification Center hosts the in-call overlay (`NotificationCenterWindow` → hosted window → Keypad).
    static func buildCallUISearchRoots() throws -> [SearchRoot] {
        var roots: [SearchRoot] = []

        if let notificationCenter = NSRunningApplication.runningApplications(
            withBundleIdentifier: notificationCenterBundleID
        ).first {
            print(
                "[VoxaDTMF] Notification Center pid=\(notificationCenter.processIdentifier) " +
                    "(in-call Keypad UI is here, not FaceTime.app)"
            )
            let ncApp = AXUIElementCreateApplication(notificationCenter.processIdentifier)
            roots.append(contentsOf: searchRoots(from: ncApp, appName: "NotificationCenter"))
        } else {
            print("[VoxaDTMF] Notification Center (com.apple.notificationcenterui) not running")
        }

        if let faceTime = NSRunningApplication.runningApplications(withBundleIdentifier: faceTimeBundleID).first {
            print("[VoxaDTMF] FaceTime pid=\(faceTime.processIdentifier) (fallback AX roots)")
            let ftApp = AXUIElementCreateApplication(faceTime.processIdentifier)
            roots.append(contentsOf: searchRoots(from: ftApp, appName: "FaceTime"))
        }

        if roots.isEmpty {
            throw FaceTimeDTMFAccessibility.Error.faceTimeNotRunning
        }
        return roots
    }

    /// Opens the in-call keypad only when digit buttons are not already on screen.
    static func ensureKeypadOpen(roots: [SearchRoot]) async throws {
        logSearchPlan(roots: roots, target: "digit keypad visible (1,)")

        if let visibleRoot = roots.first(where: { findDigitButton(digit: "1", under: $0.element) != nil }) {
            print("[VoxaDTMF] digit keypad already visible under \(visibleRoot.label) — skip Keypad")
            return
        }

        print("[VoxaDTMF] digit keypad not visible — searching for Keypad button")
        guard let match = findButton(titled: keypadButtonTitle, roots: roots, logSurveyOnFailure: true) else {
            print("[VoxaDTMF] Keypad button not found under any root (see AX survey above)")
            throw FaceTimeDTMFAccessibility.Error.keypadUnavailable
        }

        print("[VoxaDTMF] opening Keypad via root=\(match.rootLabel) \(describe(match.element))")
        try performPress(on: match.element, label: keypadButtonTitle)

        let appeared = await waitForDigitKeypad(roots: roots, timeoutSeconds: 1.5)
        if !appeared {
            print("[VoxaDTMF] digit keypad did not appear after Keypad press — post-press survey:")
            for root in roots {
                logTreeSurvey(under: root.element, rootLabel: root.label, maxDepth: logSurveyMaxDepth)
            }
            throw FaceTimeDTMFAccessibility.Error.keypadUnavailable
        }
        print("[VoxaDTMF] digit keypad appeared after Keypad press")
    }

    static func isDigitKeypadVisible(roots: [SearchRoot]) -> Bool {
        roots.contains { findDigitButton(digit: "1", under: $0.element) != nil }
    }

    static func pressDigit(_ digit: Character, roots: [SearchRoot]) throws {
        guard let match = findDigitButton(digit: digit, roots: roots) else {
            print("[VoxaDTMF] digit \(digit) not found — survey:")
            for root in roots {
                logTreeSurvey(under: root.element, rootLabel: root.label, maxDepth: logSurveyMaxDepth)
            }
            throw FaceTimeDTMFAccessibility.Error.digitUnavailable(digit)
        }
        let label = digitKeypadLabels[digit] ?? String(digit)
        print("[VoxaDTMF] press digit \(digit) root=\(match.rootLabel) \(describe(match.element))")
        try performPress(on: match.element, label: label)
    }

    // MARK: - Search roots (app → windows)

    struct SearchRoot {
        let label: String
        let element: AXUIElement
    }

    private struct ElementMatch {
        let element: AXUIElement
        let rootLabel: String
    }

    /// application → main/focused window → NotificationCenterWindow / hosted window → buttons.
    private static func searchRoots(from application: AXUIElement, appName: String) -> [SearchRoot] {
        var roots: [SearchRoot] = []
        var seen = Set<String>()

        func append(_ suffix: String, _ element: AXUIElement) {
            let key = elementKey(element)
            guard !seen.contains(key) else { return }
            seen.insert(key)
            roots.append(SearchRoot(label: "\(appName)/\(suffix)", element: element))
        }

        append("application", application)

        if let main = elementAttribute(kAXMainWindowAttribute as CFString, on: application) {
            append("mainWindow", main)
        } else {
            print("[VoxaDTMF] \(appName) kAXMainWindowAttribute: unavailable")
        }

        if let focused = elementAttribute(kAXFocusedWindowAttribute as CFString, on: application) {
            append("focusedWindow", focused)
        } else {
            print("[VoxaDTMF] \(appName) kAXFocusedWindowAttribute: unavailable")
        }

        if let windows = elementsAttribute(kAXWindowsAttribute as CFString, on: application) {
            print("[VoxaDTMF] \(appName) kAXWindowsAttribute: \(windows.count) window(s)")
            for (index, window) in windows.enumerated() {
                let title = stringAttribute(kAXTitleAttribute as CFString, on: window) ?? ""
                let subrole = stringAttribute(kAXSubroleAttribute as CFString, on: window) ?? ""
                let suffix = windowSuffix(index: index, title: title, subrole: subrole)
                append(suffix, window)
            }
        } else {
            print("[VoxaDTMF] \(appName) kAXWindowsAttribute: unavailable or empty")
        }

        return roots
    }

    private static func windowSuffix(index: Int, title: String, subrole: String) -> String {
        if title.isEmpty, subrole.isEmpty {
            return "window[\(index)]"
        }
        if subrole.isEmpty {
            return "window[\(index)] title=\"\(title)\""
        }
        if title.isEmpty {
            return "window[\(index)] subrole=\"\(subrole)\""
        }
        return "window[\(index)] title=\"\(title)\" subrole=\"\(subrole)\""
    }

    private static func logSearchPlan(roots: [SearchRoot], target: String) {
        print("[VoxaDTMF] AX search plan target=\"\(target)\" roots=\(roots.count)")
        for root in roots {
            print("[VoxaDTMF]   root \(root.label): \(describe(root.element))")
        }
    }

    // MARK: - Find buttons

    private static func findButton(
        titled title: String,
        roots: [SearchRoot],
        logSurveyOnFailure: Bool = false
    ) -> ElementMatch? {
        let normalizedTarget = normalize(title)
        print("[VoxaDTMF] findButton title=\"\(title)\" normalized=\"\(normalizedTarget)\"")

        for root in roots {
            print("[VoxaDTMF]   BFS under \(root.label) maxDepth=\(maxSearchDepth)")
            if let element = findButton(titled: normalizedTarget, under: root.element, rootLabel: root.label) {
                return ElementMatch(element: element, rootLabel: root.label)
            }
        }

        if logSurveyOnFailure {
            print("[VoxaDTMF] findButton FAILED — full AX survey (buttons + shallow tree):")
            for root in roots {
                logTreeSurvey(under: root.element, rootLabel: root.label, maxDepth: logSurveyMaxDepth)
            }
        }
        return nil
    }

    private static func findButton(titled normalizedTarget: String, under root: AXUIElement, rootLabel: String) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var nodesVisited = 0
        var buttonsLogged = 0
        let maxButtonLogs = 40

        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > maxSearchDepth { continue }
            nodesVisited += 1

            if isPressable(element) {
                let summary = describe(element)
                if buttonMatchesTitle(element, normalizedTarget: normalizedTarget)
                    || buttonMatchesKeypadHeuristic(element, normalizedTarget: normalizedTarget)
                {
                    print("[VoxaDTMF]     MATCH depth=\(depth) root=\(rootLabel) \(summary)")
                    return element
                }
                if buttonsLogged < maxButtonLogs {
                    buttonsLogged += 1
                    print("[VoxaDTMF]     button depth=\(depth) \(summary)")
                }
            }

            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }

        print("[VoxaDTMF]     end BFS root=\(rootLabel) nodes=\(nodesVisited) buttonsLogged=\(buttonsLogged)")
        return nil
    }

    private static func findDigitButton(digit: Character, roots: [SearchRoot]) -> ElementMatch? {
        for root in roots {
            if let element = findDigitButton(digit: digit, under: root.element) {
                return ElementMatch(element: element, rootLabel: root.label)
            }
        }
        return nil
    }

    private static func findDigitButton(digit: Character, under root: AXUIElement) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]

        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > maxSearchDepth { continue }

            if isPressable(element), buttonMatchesDigit(element, digit: digit) {
                return element
            }

            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    // MARK: - Matching

    private static func isButton(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute as CFString, on: element) else { return false }
        return role == (kAXButtonRole as String) || role == "AXButton"
    }

    private static func isPressable(_ element: AXUIElement) -> Bool {
        if isButton(element) { return true }
        if hasAction(element, named: kAXPressAction as String) { return true }
        guard let role = stringAttribute(kAXRoleAttribute as CFString, on: element) else { return false }
        return role == "AXPressAction" || role == "AXMenuButton"
    }

    private static func buttonMatchesTitle(_ element: AXUIElement, normalizedTarget: String) -> Bool {
        for label in elementLabels(element) {
            if normalize(label) == normalizedTarget { return true }
        }
        return false
    }

    private static func buttonMatchesKeypadHeuristic(_ element: AXUIElement, normalizedTarget: String) -> Bool {
        guard normalizedTarget == normalize(keypadButtonTitle) else { return false }
        return elementLabels(element).contains { normalize($0).contains("keypad") }
    }

    private static func buttonMatchesDigit(_ element: AXUIElement, digit: Character) -> Bool {
        for label in elementLabels(element) {
            let normalized = normalize(label)
            for candidate in digitAccessibilityTitles(digit) {
                if normalized == normalize(candidate) { return true }
            }
            if let keypadLabel = digitKeypadLabels[digit], normalized == normalize(keypadLabel) { return true }
            if digit >= "0", digit <= "9" {
                if normalized == "\(digit)," || normalized.hasPrefix("\(digit), ") { return true }
            }
        }
        return false
    }

    // MARK: - Tree logging

    private static func logTreeSurvey(under root: AXUIElement, rootLabel: String, maxDepth: Int) {
        print("[VoxaDTMF] --- AX survey root=\(rootLabel) \(describe(root)) maxDepth=\(maxDepth) ---")
        var queue: [(element: AXUIElement, depth: Int, path: String)] = [(root, 0, rootLabel)]
        var nodeCount = 0

        while !queue.isEmpty, nodeCount < logSurveyMaxNodes {
            let (element, depth, path) = queue.removeFirst()
            if depth > maxDepth { continue }
            nodeCount += 1

            let indent = String(repeating: "  ", count: depth)
            let marker = isPressable(element) ? " [pressable]" : ""
            print("[VoxaDTMF] \(indent)\(path) \(describe(element))\(marker)")

            let childElements = children(of: element)
            if depth < maxDepth {
                for (index, child) in childElements.enumerated() {
                    let childPath = depth == 0 ? "child[\(index)]" : "\(path)/[\(index)]"
                    queue.append((child, depth + 1, childPath))
                }
            } else if !childElements.isEmpty {
                print("[VoxaDTMF] \(indent)  … \(childElements.count) children (depth cap)")
            }
        }

        if nodeCount >= logSurveyMaxNodes {
            print("[VoxaDTMF] --- survey truncated at \(logSurveyMaxNodes) nodes ---")
        } else {
            print("[VoxaDTMF] --- survey end \(nodeCount) nodes ---")
        }
    }

    private static func describe(_ element: AXUIElement) -> String {
        let role = stringAttribute(kAXRoleAttribute as CFString, on: element) ?? "?"
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, on: element) ?? ""
        let title = stringAttribute(kAXTitleAttribute as CFString, on: element) ?? ""
        let description = stringAttribute(kAXDescriptionAttribute as CFString, on: element) ?? ""
        let identifier = stringAttribute(kAXIdentifierAttribute as CFString, on: element) ?? ""

        var parts = ["role=\(role)"]
        if !subrole.isEmpty { parts.append("subrole=\(subrole)") }
        if !title.isEmpty { parts.append("title=\"\(title)\"") }
        if !description.isEmpty, description != title { parts.append("desc=\"\(description)\"") }
        if !identifier.isEmpty { parts.append("id=\"\(identifier)\"") }
        if hasAction(element, named: kAXPressAction as String) { parts.append("actions=Press") }
        return parts.joined(separator: " ")
    }

    private static func elementLabels(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute]
            .compactMap { stringAttribute($0 as CFString, on: element) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Children & attributes

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = objectAttribute(kAXChildrenAttribute as CFString, on: element) else { return [] }
        if let list = raw as? [AXUIElement] { return list }
        if CFGetTypeID(raw) == CFArrayGetTypeID() {
            let array = raw as! CFArray
            let count = CFArrayGetCount(array)
            var result: [AXUIElement] = []
            result.reserveCapacity(count)
            for index in 0 ..< count {
                let value = CFArrayGetValueAtIndex(array, index)
                result.append(unsafeBitCast(value, to: AXUIElement.self))
            }
            return result
        }
        return []
    }

    private static func elementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        guard let raw = objectAttribute(attribute, on: element) else { return nil }
        if CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return (raw as! AXUIElement)
        }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func elementsAttribute(_ attribute: CFString, on element: AXUIElement) -> [AXUIElement]? {
        guard let raw = objectAttribute(attribute, on: element) else { return nil }
        if let list = raw as? [AXUIElement] { return list }
        if CFGetTypeID(raw) == CFArrayGetTypeID() {
            let array = raw as! CFArray
            let count = CFArrayGetCount(array)
            return (0 ..< count).map { index in
                let value = CFArrayGetValueAtIndex(array, index)
                return unsafeBitCast(value, to: AXUIElement.self)
            }
        }
        return nil
    }

    private static func hasAction(_ element: AXUIElement, named actionName: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return false }
        let count = CFArrayGetCount(names)
        for index in 0 ..< count {
            guard let value = CFArrayGetValueAtIndex(names, index) else { continue }
            let cfName = unsafeBitCast(value, to: CFString.self) as String
            if cfName == actionName { return true }
        }
        return false
    }

    private static func waitForDigitKeypad(roots: [SearchRoot], timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isDigitKeypadVisible(roots: roots) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return isDigitKeypadVisible(roots: roots)
    }

    // MARK: - Actions

    private static func performPress(on element: AXUIElement, label: String) throws {
        let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if pressResult == .success {
            print("[VoxaDTMF] AXPress “\(label)” OK")
            return
        }

        print("[VoxaDTMF] AXPress “\(label)” failed code=\(pressResult.rawValue) \(describe(element))")
        throw FaceTimeDTMFAccessibility.Error.keypadUnavailable
    }

    // MARK: - Digit titles

    private static func digitAccessibilityTitles(_ digit: Character) -> [String] {
        if let faceTimeLabel = digitKeypadLabels[digit] {
            return [faceTimeLabel, String(digit)]
        }
        switch digit {
        case "0": return ["0,", "0"]
        case "*": return ["*", "*,", "Star", "asterisk"]
        case "#": return ["#", "#,", "Pound", "Hash", "number sign"]
        default: return [String(digit)]
        }
    }

    // MARK: - AX attribute helpers

    private static func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return (value as! CFString) as String
        }
        return nil
    }

    private static func objectAttribute(_ attribute: CFString, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value
    }

    private static func normalize(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func elementKey(_ element: AXUIElement) -> String {
        String(format: "%p", unsafeBitCast(element, to: Int.self))
    }
}
