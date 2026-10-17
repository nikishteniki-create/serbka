//
//  SerbkaApp.swift
//  Serbka
//
//  Created by Niki on 17.10.2026.
//

import SwiftUI
import AppKit
import ApplicationServices
import Carbon
import AVFoundation
import Combine
import Vision
import CoreGraphics
import ScreenCaptureKit
import Darwin
import NaturalLanguage
import UniformTypeIdentifiers

@main
struct SerbkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Label("Serbka", systemImage: "character.book.closed.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.stop()
    }
}

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var canCaptureScreen = CGPreflightScreenCaptureAccess()

    let popupModel = PopupModel()

    private let panelController = PopupPanelController()
    private let wordsWindowController = WordsWindowController()
    private let speaker = Speaker()
    private var hotKeyMonitor: Any?
    private var localHotKeyMonitor: Any?
    private var lastHotKeyAt: Date = .distantPast
    private var trustTimer: Timer?

    private init() {
        popupModel.speaker = speaker
        panelController.model = popupModel
        panelController.onRequestClose = { [weak self] in
            self?.hidePopup()
        }
    }

    func start() {
        requestAccessibilityOnLaunch()
        HotKeyManager.register { [weak self] action in
            self?.handleHotKey(action)
        }
        speaker.prefetchVoices()
        installEventMonitors()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                AppController.shared.isTrusted = AXIsProcessTrusted()
                AppController.shared.canCaptureScreen = CGPreflightScreenCaptureAccess()
            }
        }
    }

    func stop() {
        HotKeyManager.unregister()
        if let hotKeyMonitor { NSEvent.removeMonitor(hotKeyMonitor) }
        if let localHotKeyMonitor { NSEvent.removeMonitor(localHotKeyMonitor) }
        hidePopup()
        wordsWindowController.close()
        trustTimer?.invalidate()
    }

    func requestAccessibilityOnLaunch() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [prompt: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.Privacy_Accessibility"
        ]
        for string in urls {
            if let url = URL(string: string) {
                NSWorkspace.shared.open(url)
                break
            }
        }
        requestAccessibilityOnLaunch()
    }

    func openScreenCaptureSettings() {
        _ = ScreenOCR.requestAccess()
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.Privacy_ScreenCapture"
        ]
        for string in urls {
            if let url = URL(string: string) {
                NSWorkspace.shared.open(url)
                break
            }
        }
        canCaptureScreen = CGPreflightScreenCaptureAccess()
    }

    func handleHotKey(_ action: SerbkaHotKey) {
        let now = Date()
        guard now.timeIntervalSince(lastHotKeyAt) > 0.25 else { return }
        lastHotKeyAt = now

        switch action {
        case .word:
            let cocoaPoint = NSEvent.mouseLocation
            Task { await captureWordAndPresent(cocoaPoint: cocoaPoint) }
        case .paragraph:
            let cocoaPoint = NSEvent.mouseLocation
            Task { await captureParagraphAndPresent(cocoaPoint: cocoaPoint) }
        case .quizlet:
            saveCurrentWord()
        case .speak:
            popupModel.speakTranslation()
        }
    }

    private func captureWordAndPresent(cocoaPoint: NSPoint) async {
        isTrusted = AXIsProcessTrusted()
        canCaptureScreen = CGPreflightScreenCaptureAccess()

        let excludeWindowID = panelController.windowID
        panelController.hide()

        let word = await TextCapture.captureWord(cocoaPoint: cocoaPoint, excludeWindowID: excludeWindowID)
        let source = (word ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        popupModel.prepare(
            source: source,
            trusted: isTrusted,
            canCaptureScreen: canCaptureScreen,
            mode: .word
        )
        panelController.show(near: cocoaPoint)

        guard !source.isEmpty else { return }
        let translation = await Translator.translate(source)
        popupModel.updateTranslation(translation)
        panelController.fitToContent(near: cocoaPoint)
    }

    private func captureParagraphAndPresent(cocoaPoint: NSPoint) async {
        isTrusted = AXIsProcessTrusted()
        canCaptureScreen = CGPreflightScreenCaptureAccess()
        panelController.hide()

        let selected = await TextCapture.captureSelectedText()
        let source = (selected ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        popupModel.prepare(
            source: source,
            trusted: isTrusted,
            canCaptureScreen: canCaptureScreen,
            mode: .paragraph
        )
        panelController.show(near: cocoaPoint)

        guard !source.isEmpty else { return }
        let translation = await Translator.translate(source)
        popupModel.updateTranslation(translation)
        panelController.fitToContent(near: cocoaPoint)
    }

    func saveCurrentWord() {
        let point = NSEvent.mouseLocation
        guard let card = popupModel.lastCard else {
            popupModel.prepareNotice("Сначала переведите слово (⌘S) или текст (⌘P).")
            panelController.show(near: point)
            return
        }

        let status = WordStore.shared.upsert(source: card.source, translation: card.translation)
        let message = status == .updated ? "Обновлено в «Мои слова»" : "Сохранено в «Мои слова»"
        popupModel.showSavedBanner(message)
        if panelController.isVisible {
            panelController.fitToContent(near: point)
        } else {
            popupModel.prepareNotice(message)
            panelController.show(near: point)
        }
    }

    func openWordsWindow() {
        wordsWindowController.show()
    }

    func exportWordsToQuizletFile() {
        WordStore.shared.exportQuizletFile(presenter: wordsWindowController.window)
    }

    func hidePopup() {
        panelController.hide()
        speaker.stop()
    }

    private func installEventMonitors() {
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            Task { @MainActor in
                if let action = SerbkaHotKey.match(keyCode: keyCode, flags: flags) {
                    AppController.shared.handleHotKey(action)
                }
            }
        }

        localHotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let action = SerbkaHotKey.match(keyCode: event.keyCode, flags: event.modifierFlags) {
                AppController.shared.handleHotKey(action)
                return nil
            }
            return event
        }
    }
}

// MARK: - Carbon hotkeys

enum SerbkaHotKey: UInt32 {
    case word = 1
    case paragraph = 2
    case quizlet = 3
    case speak = 4

    var carbonKeyCode: UInt32 {
        switch self {
        case .word, .speak: return UInt32(kVK_ANSI_S)
        case .paragraph: return UInt32(kVK_ANSI_P)
        case .quizlet: return UInt32(kVK_ANSI_Q)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .speak: return UInt32(cmdKey | optionKey)
        case .word, .paragraph, .quizlet: return UInt32(cmdKey)
        }
    }

    static func match(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> SerbkaHotKey? {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        let significant = masked.intersection([.command, .option, .control, .shift])
        switch Int(keyCode) {
        case kVK_ANSI_S where significant == [.command, .option]:
            return .speak
        case kVK_ANSI_S where significant == .command:
            return .word
        case kVK_ANSI_P where significant == .command:
            return .paragraph
        case kVK_ANSI_Q where significant == .command:
            return .quizlet
        default:
            return nil
        }
    }
}

@MainActor
enum HotKeyManager {
    private static var hotKeyRefs: [EventHotKeyRef] = []
    private static var handlerRef: EventHandlerRef?
    fileprivate static var onPressed: (@MainActor (SerbkaHotKey) -> Void)?

    static func register(onPressed: @escaping @MainActor (SerbkaHotKey) -> Void) {
        self.onPressed = onPressed
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            serbkaHotKeyHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard installStatus == noErr else { return }

        for action in [SerbkaHotKey.word, .paragraph, .quizlet, .speak] {
            let hotKeyID = EventHotKeyID(signature: OSType(fourCharCode("SRBK")), id: action.rawValue)
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                action.carbonKeyCode,
                action.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            }
        }
    }

    static func unregister() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs = []
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

nonisolated private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + FourCharCode(scalar.value)
    }
    return result
}

nonisolated private let serbkaHotKeyHandler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    if let event {
        _ = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
    }
    let identifier = hotKeyID.id
    Task { @MainActor in
        if let action = SerbkaHotKey(rawValue: identifier) {
            HotKeyManager.onPressed?(action)
        }
    }
    return noErr
}

// MARK: - Text capture

enum TextCapture {
    static func captureWord(cocoaPoint: NSPoint, excludeWindowID: CGWindowID) async -> String? {
        let axPoint = quartzPoint(from: cocoaPoint)

        if AXIsProcessTrusted() {
            if let word = wordUnderCursor(axPoint: axPoint) {
                return word
            }
            if !shouldAvoidSyntheticClicks(axPoint: axPoint),
               let word = await selectWordByDoubleClick(axPoint: axPoint) {
                return word
            }
        }

        return await ScreenOCR.word(nearCocoa: cocoaPoint, axPoint: axPoint, excludeWindowID: excludeWindowID)
    }

    /// Full selected text, then a synthetic copy, then the clipboard. No length cap.
    static func captureSelectedText() async -> String? {
        if AXIsProcessTrusted() {
            let systemWide = AXUIElementCreateSystemWide()
            if let focused = focusedElement(systemWide: systemWide),
               let selected = unlimitedSelectedText(from: focused) {
                return selected
            }
            if let copied = await copyViaCommandC(preservingParagraphs: true) {
                return copied
            }
        }

        if let clipboard = NSPasteboard.general.string(forType: .string) {
            let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count >= 40 || !isGarbageName(trimmed) {
                return trimmed.serbianNormalized
            }
        }
        return nil
    }

    /// `NSEvent.mouseLocation` is Cocoa: origin at the bottom-left of the primary display.
    /// Accessibility / Quartz uses origin at the top-left of the primary display.
    static func quartzPoint(from mouseLocation: NSPoint) -> CGPoint {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let axY = primaryScreenHeight - mouseLocation.y
        return CGPoint(x: mouseLocation.x, y: axY)
    }

    static func wordUnderCursor(axPoint: CGPoint) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        let candidates = elementsAt(axPoint: axPoint, systemWide: systemWide)

        for element in candidates {
            if let word = wordAtPosition(in: element, point: axPoint), isRealCapturedWord(word) {
                return word
            }
        }

        for element in candidates {
            if let selected = usableSelectedText(from: element) {
                return selected
            }
        }

        return usableSelectedText(from: focusedElement(systemWide: systemWide))
    }

    static func isRealCapturedWord(_ text: String) -> Bool {
        let value = cleaned(text)
        guard value.rangeOfCharacter(from: .letters) != nil else { return false }
        return !isGarbageName(value)
    }

    static func isGarbageName(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }

        var names: Set<String> = [
            "safari", "google chrome", "chrome", "firefox", "arc", "brave", "brave browser",
            "microsoft edge", "edge", "opera", "orion", "vivaldi", "serbka", "finder",
            "youtube", "webkit", "webview"
        ]
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased() {
            names.insert(app)
        }
        if let ownName = NSRunningApplication.current.localizedName?.lowercased() {
            names.insert(ownName)
        }

        if names.contains(lower) { return true }
        for name in names where lower.hasSuffix(" - \(name)") || lower.hasSuffix(" — \(name)") {
            return true
        }
        return false
    }

    private static func shouldAvoidSyntheticClicks(axPoint: CGPoint) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        let elements = elementsAt(axPoint: axPoint, systemWide: systemWide)

        for element in elements {
            let role = (stringAttribute(element, kAXRoleAttribute) ?? "").lowercased()
            let subrole = (stringAttribute(element, kAXSubroleAttribute) ?? "").lowercased()
            let description = (stringAttribute(element, kAXDescriptionAttribute) ?? "").lowercased()
            let roleDescription = (stringAttribute(element, "AXRoleDescription") ?? "").lowercased()
            let blob = [role, subrole, description, roleDescription].joined(separator: " ")

            if blob.contains("video") || blob.contains("media") || blob.contains("player") {
                return true
            }

            if role == "aximage" || role == "axunknown" || role == "axgroup" {
                if let frame = frame(of: element), frame.width > 280, frame.height > 160 {
                    let value = stringAttribute(element, kAXValueAttribute) ?? ""
                    if value.isEmpty {
                        return true
                    }
                }
            }
        }

        return false
    }

    private static func elementsAt(axPoint: CGPoint, systemWide: AXUIElement) -> [AXUIElement] {
        var seen = Set<ObjectIdentifier>()
        var result: [AXUIElement] = []

        func append(_ element: AXUIElement?) {
            guard let element else { return }
            let id = ObjectIdentifier(element)
            guard !seen.contains(id) else { return }
            seen.insert(id)
            result.append(element)
        }

        var elementRef: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &elementRef
        )
        if error == .success {
            append(elementRef)
        }

        append(parameterizedElement(systemWide, attribute: "AXHitTest", point: axPoint))
        if let root = elementRef {
            append(parameterizedElement(root, attribute: "AXHitTest", point: axPoint))
        }
        append(focusedElement(systemWide: systemWide))

        var current = elementRef
        for _ in 0..<8 {
            guard let node = current else { break }
            append(node)
            current = parent(of: node)
        }

        return result
    }

    private static func focusedElement(systemWide: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard error == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func usableSelectedText(from element: AXUIElement?) -> String? {
        guard let element else { return nil }
        guard let text = stringAttribute(element, kAXSelectedTextAttribute), !text.isEmpty else {
            return nil
        }
        let full = stringAttribute(element, kAXValueAttribute)
        if let full, text == full, text.count > 40 {
            return nil
        }
        guard text.count <= 80 else { return nil }
        let cleanedText = cleaned(text)
        guard isRealCapturedWord(cleanedText) else { return nil }
        return cleanedText
    }

    private static func unlimitedSelectedText(from element: AXUIElement?) -> String? {
        guard let element else { return nil }
        guard let text = stringAttribute(element, kAXSelectedTextAttribute) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count < 48, isGarbageName(trimmed) { return nil }
        return trimmed.serbianNormalized
    }

    private static func wordAtPosition(in element: AXUIElement, point: CGPoint) -> String? {
        let points = candidatePoints(for: element, global: point)

        for candidate in points {
            if let child = parameterizedElement(element, attribute: "AXHitTest", point: candidate),
               child != element,
               let word = extractWord(from: child, point: candidate),
               isRealCapturedWord(word) {
                return word
            }
            if let word = extractWord(from: element, point: candidate), isRealCapturedWord(word) {
                return word
            }
        }

        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let titleRoles: Set<String> = [
            "AXButton", "AXLink", "AXMenuItem", "AXStaticText",
            "AXRadioButton", "AXCheckBox", "AXTab", "AXPopUpButton"
        ]
        if titleRoles.contains(role),
           let title = stringAttribute(element, kAXTitleAttribute),
           (2...40).contains(title.count) {
            let cleanedTitle = cleaned(title)
            if isRealCapturedWord(cleanedTitle) { return cleanedTitle }
        }
        return nil
    }

    private static func extractWord(from element: AXUIElement, point: CGPoint) -> String? {
        if let index = characterIndex(in: element, point: point),
           let word = wordFromIndex(element, index: index) {
            return word
        }

        if let range = parameterizedRange(element, attribute: kAXRangeForPositionParameterizedAttribute, point: point),
           let word = wordFromIndex(element, index: range.location) {
            return word
        }

        return nil
    }

    private static func characterIndex(in element: AXUIElement, point: CGPoint) -> CFIndex? {
        if let range = parameterizedRange(element, attribute: kAXRangeForPositionParameterizedAttribute, point: point) {
            return range.location
        }

        guard let axPoint = axValue(point: point) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXCharacterForPoint" as CFString,
            axPoint,
            &value
        )
        guard error == .success, let value else { return nil }

        if let number = value as? NSNumber {
            return CFIndex(number.intValue)
        }
        if CFGetTypeID(value) == AXValueGetTypeID(), let range = axRange(from: value) {
            return range.location
        }
        if let character = value as? String,
           let full = stringAttribute(element, kAXValueAttribute) {
            let location = (full as NSString).range(of: character).location
            if location != NSNotFound {
                return CFIndex(location)
            }
        }
        return nil
    }

    private static func wordFromIndex(_ element: AXUIElement, index: CFIndex) -> String? {
        var resolvedIndex = index
        if let composed = rangeForIndex(element, index: index) {
            resolvedIndex = composed.location
            if let snippet = stringForRange(element, location: composed.location, length: max(composed.length, 1)),
               snippet.count <= 2,
               let expanded = expandAround(element, start: composed.location),
               !expanded.isEmpty {
                return cleaned(expanded)
            }
        }

        if let full = stringAttribute(element, kAXValueAttribute), !full.isEmpty {
            let word = WordExtractor.word(in: full, atUTF16: Int(resolvedIndex))
            if !word.isEmpty { return cleaned(word) }
        }

        if let expanded = expandAround(element, start: resolvedIndex), !expanded.isEmpty {
            return cleaned(expanded)
        }
        return nil
    }

    private static func expandAround(_ element: AXUIElement, start: CFIndex) -> String? {
        let window = 48
        let from = max(0, start - window)
        let length = CFIndex(window * 2)
        guard let snippet = stringForRange(element, location: from, length: length), !snippet.isEmpty else {
            return nil
        }
        let localIndex = Int(start - from)
        let word = WordExtractor.word(in: snippet, atUTF16: localIndex)
        return word.isEmpty ? nil : word
    }

    private static func candidatePoints(for element: AXUIElement, global: CGPoint) -> [CGPoint] {
        var points = [global]
        if let frame = frame(of: element), frame.width > 0, frame.height > 0 {
            let local = CGPoint(x: global.x - frame.origin.x, y: global.y - frame.origin.y)
            points.append(local)
            points.append(CGPoint(x: local.x, y: frame.height - local.y))
        }
        return points
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
              let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private static func parameterizedElement(_ element: AXUIElement, attribute: String, point: CGPoint) -> AXUIElement? {
        guard let axPoint = axValue(point: point) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            axPoint,
            &value
        )
        guard error == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func parameterizedRange(_ element: AXUIElement, attribute: String, point: CGPoint) -> CFRange? {
        guard let axPoint = axValue(point: point) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            axPoint,
            &value
        )
        guard error == .success, let value else { return nil }
        return axRange(from: value)
    }

    private static func rangeForIndex(_ element: AXUIElement, index: CFIndex) -> CFRange? {
        let number = NSNumber(value: Int(index))
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForIndexParameterizedAttribute as CFString,
            number,
            &value
        )
        guard error == .success, let value else { return nil }
        return axRange(from: value)
    }

    private static func stringForRange(_ element: AXUIElement, location: CFIndex, length: CFIndex) -> String? {
        var range = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        )
        guard error == .success else { return nil }
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private static func axValue(point: CGPoint) -> AXValue? {
        var mutablePoint = point
        return AXValueCreate(.cgPoint, &mutablePoint)
    }

    private static func axRange(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func selectWordByDoubleClick(axPoint: CGPoint) async -> String? {
        postDoubleClick(at: axPoint)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let systemWide = AXUIElementCreateSystemWide()
        if let word = readSelection(systemWide: systemWide, axPoint: axPoint), isRealCapturedWord(word) {
            return word
        }

        try? await Task.sleep(nanoseconds: 80_000_000)
        if let word = readSelection(systemWide: systemWide, axPoint: axPoint), isRealCapturedWord(word) {
            return word
        }

        if let copied = await copyViaCommandC(preservingParagraphs: false), isRealCapturedWord(copied) {
            return copied
        }
        return nil
    }

    private static func readSelection(systemWide: AXUIElement, axPoint: CGPoint) -> String? {
        if let selected = usableSelectedText(from: focusedElement(systemWide: systemWide)) {
            return selected
        }

        var elementRef: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &elementRef
        )
        if error == .success, let selected = usableSelectedText(from: elementRef) {
            return selected
        }
        return nil
    }

    private static func postDoubleClick(at quartzPoint: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0

        let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        )
        move?.flags = []
        move?.post(tap: .cghidEventTap)

        func click(state: Int64, downType: CGEventType, upType: CGEventType) {
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: downType,
                mouseCursorPosition: quartzPoint,
                mouseButton: .left
            )
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: upType,
                mouseCursorPosition: quartzPoint,
                mouseButton: .left
            )
            down?.flags = []
            up?.flags = []
            down?.setIntegerValueField(.mouseEventClickState, value: state)
            up?.setIntegerValueField(.mouseEventClickState, value: state)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }

        click(state: 1, downType: .leftMouseDown, upType: .leftMouseUp)
        click(state: 2, downType: .leftMouseDown, upType: .leftMouseUp)
    }

    private static func copyViaCommandC(preservingParagraphs: Bool) async -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let snapshot = PasteboardSnapshot.save()
        NSPasteboard.general.clearContents()

        postCommandC()
        try? await Task.sleep(nanoseconds: preservingParagraphs ? 180_000_000 : 120_000_000)

        let copied = NSPasteboard.general.string(forType: .string)
        snapshot.restore()

        guard let copied else { return nil }
        let trimmed = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if preservingParagraphs {
            if trimmed.count < 48, isGarbageName(trimmed) { return nil }
            return trimmed.serbianNormalized
        }
        return cleaned(copied)
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyC = CGKeyCode(kVK_ANSI_C)

        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func cleaned(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = collapsed.trimmingCharacters(in: WordExtractor.edgeCharacters)
        if stripped.count > 200 {
            return String(stripped.prefix(200)).trimmingCharacters(in: WordExtractor.edgeCharacters)
        }
        return stripped
    }
}

enum WordExtractor {
    struct Token {
        let text: String
        let nsRange: NSRange
        let range: Range<String.Index>
    }

    static let edgeCharacters: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.formUnion(.symbols)
        set.formUnion(.whitespacesAndNewlines)
        set.insert(charactersIn: "_")
        return set
    }()

    /// Letters, digits, in-word punctuation, and explicit Serbian Latin/Cyrillic letters.
    /// Combining marks are included so decomposed ć/č/š/ћ stay a single word character.
    static let wordCharacters: CharacterSet = {
        var set = CharacterSet.letters
        set.formUnion(.decimalDigits)
        set.formUnion(.nonBaseCharacters)
        set.insert(charactersIn: "’'`'-–—")
        set.insert(charactersIn: "čćšžđČĆŠŽĐчћшжђЋЧШЖЂљњџЉЊЏыэъёЫЭЪЁ")
        return set
    }()

    static func isWordCharacter(_ fragment: String) -> Bool {
        guard !fragment.isEmpty else { return false }
        let scalars = fragment.unicodeScalars
        if scalars.allSatisfy({ wordCharacters.contains($0) }) {
            return true
        }
        if scalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            return true
        }
        guard let first = scalars.first else { return false }
        let firstIsWord = wordCharacters.contains(first) || CharacterSet.letters.contains(first)
        guard firstIsWord else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            wordCharacters.contains(scalar)
                || CharacterSet.letters.contains(scalar)
                || scalar.properties.canonicalCombiningClass != .notReordered
        }
    }

    static func word(in text: String, atUTF16 index: Int) -> String {
        let nsText = text as NSString
        guard nsText.length > 0 else { return "" }

        let clamped = max(0, min(index, nsText.length - 1))
        let composed = nsText.rangeOfComposedCharacterSequence(at: clamped)
        let letterAtIndex = nsText.substring(with: composed)
        let walked = walkComposedWord(in: nsText, at: composed.location)

        var byWordsHit = ""
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: .byWords
        ) { substring, range, _, stop in
            if NSLocationInRange(clamped, range) || NSLocationInRange(composed.location, range) {
                byWordsHit = substring ?? nsText.substring(with: range)
                stop.pointee = true
            }
        }

        let chosen: String
        if !byWordsHit.isEmpty, byWordsPreservesLetter(byWordsHit, letterAtIndex: letterAtIndex) {
            if !walked.isEmpty,
               walked.contains(letterAtIndex),
               walked.count > byWordsHit.count {
                chosen = walked
            } else {
                chosen = byWordsHit
            }
        } else {
            chosen = walked
        }

        return chosen.trimmingCharacters(in: edgeCharacters)
    }

    /// Tokenize with composed-character sequences so ћ/ć/č never split.
    static func wordTokens(in text: String) -> [Token] {
        let nsText = text as NSString
        var tokens: [Token] = []
        var utf16 = 0

        while utf16 < nsText.length {
            let composed = nsText.rangeOfComposedCharacterSequence(at: utf16)
            if isWordCharacter(nsText.substring(with: composed)) {
                let start = composed.location
                var end = composed.location + composed.length
                while end < nsText.length {
                    let next = nsText.rangeOfComposedCharacterSequence(at: end)
                    if isWordCharacter(nsText.substring(with: next)) {
                        end = next.location + next.length
                    } else {
                        break
                    }
                }
                let nsRange = NSRange(location: start, length: end - start)
                if let range = Range(nsRange, in: text) {
                    let raw = nsText.substring(with: nsRange)
                    let trimmed = raw.trimmingCharacters(in: edgeCharacters)
                    tokens.append(Token(text: trimmed.isEmpty ? raw : trimmed, nsRange: nsRange, range: range))
                }
                utf16 = end
            } else {
                utf16 = composed.location + composed.length
            }
        }

        return tokens
    }

    private static func byWordsPreservesLetter(_ byWords: String, letterAtIndex: String) -> Bool {
        guard isWordCharacter(letterAtIndex) else { return true }
        return byWords.contains(letterAtIndex)
    }

    private static func walkComposedWord(in nsText: NSString, at utf16Index: Int) -> String {
        guard nsText.length > 0 else { return "" }
        let clamped = max(0, min(utf16Index, nsText.length - 1))
        let origin = nsText.rangeOfComposedCharacterSequence(at: clamped)
        guard isWordCharacter(nsText.substring(with: origin)) else { return "" }

        var start = origin.location
        var end = origin.location + origin.length

        while start > 0 {
            let previous = nsText.rangeOfComposedCharacterSequence(at: start - 1)
            if isWordCharacter(nsText.substring(with: previous)) {
                start = previous.location
            } else {
                break
            }
        }
        while end < nsText.length {
            let next = nsText.rangeOfComposedCharacterSequence(at: end)
            if isWordCharacter(nsText.substring(with: next)) {
                end = next.location + next.length
            } else {
                break
            }
        }

        return nsText.substring(with: NSRange(location: start, length: end - start))
    }
}

enum ScreenOCR {
    /// Wide enough to keep the first and last letters of a subtitle word inside the crop.
    private static let cropSize = CGSize(width: 1120, height: 280)
    private static let preferredLanguages = ["sr-Cyrl", "ru-RU", "sr-Latn", "en-US"]

    static func requestAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func word(nearCocoa cocoaPoint: NSPoint, axPoint: CGPoint, excludeWindowID: CGWindowID) async -> String? {
        guard requestAccess() else { return nil }

        let captureRect = rect(around: axPoint)
        guard let image = await screenshot(rect: captureRect, excludeWindowID: excludeWindowID) else {
            return nil
        }

        let cursor = visionPoint(axPoint: axPoint, in: captureRect)
        let languages = preferredLanguages
        return await recognizeWord(in: image, nearestTo: cursor, preferredLanguages: languages)
    }

    private static func rect(around axPoint: CGPoint) -> CGRect {
        var rect = CGRect(
            x: axPoint.x - cropSize.width / 2,
            y: axPoint.y - cropSize.height / 2,
            width: cropSize.width,
            height: cropSize.height
        )

        if let screen = NSScreen.screens.first(where: {
            let cocoa = NSPoint(x: axPoint.x, y: (NSScreen.screens.first?.frame.height ?? 0) - axPoint.y)
            return NSMouseInRect(cocoa, $0.frame, false)
        }) ?? NSScreen.screens.first {
            let quartzScreen = CGRect(
                x: screen.frame.origin.x,
                y: (NSScreen.screens.first?.frame.height ?? 0) - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            rect = rect.intersection(quartzScreen)
            if rect.isNull || rect.isEmpty {
                rect = quartzScreen
            }
        }
        return rect.integral
    }

    private static func screenshot(rect: CGRect, excludeWindowID: CGWindowID) async -> CGImage? {
        if let image = windowListImage(rect: rect, excludeWindowID: excludeWindowID),
           image.width > 8, image.height > 8 {
            return image
        }
        return await screenCaptureKitImage(rect: rect, excludeWindowID: excludeWindowID)
    }

    /// `CGWindowListCreateImage` is marked obsolete in the SDK, so it is loaded at runtime.
    private static func windowListImage(rect: CGRect, excludeWindowID: CGWindowID) -> CGImage? {
        typealias CreateImage = @convention(c) (
            CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
        ) -> Unmanaged<CGImage>?

        struct Loader {
            static let createImage: CreateImage? = {
                let paths = [
                    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
                ]
                for path in paths {
                    guard let handle = dlopen(path, RTLD_LAZY) else { continue }
                    if let symbol = dlsym(handle, "CGWindowListCreateImage") {
                        return unsafeBitCast(symbol, to: CreateImage.self)
                    }
                }
                return nil
            }()
        }

        guard let createImage = Loader.createImage else { return nil }

        let imageOption: CGWindowImageOption = [.bestResolution, .boundsIgnoreFraming]
        if excludeWindowID != kCGNullWindowID,
           let image = createImage(
            rect,
            .optionOnScreenBelowWindow,
            excludeWindowID,
            imageOption
           )?.takeRetainedValue(),
           image.width > 8, image.height > 8 {
            return image
        }

        return createImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            imageOption
        )?.takeRetainedValue()
    }

    private static func screenCaptureKitImage(rect: CGRect, excludeWindowID: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) })
                    ?? content.displays.first else {
                return nil
            }

            let bounds = CGDisplayBounds(display.displayID)
            var source = rect.intersection(bounds)
            guard !source.isNull, !source.isEmpty else { return nil }
            source.origin.x -= bounds.origin.x
            source.origin.y -= bounds.origin.y

            let bundleID = Bundle.main.bundleIdentifier
            let excluded = content.windows.filter { window in
                window.owningApplication?.bundleIdentifier == bundleID
                    || window.windowID == excludeWindowID
            }

            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = source
            configuration.showsCursor = false
            let scale = backingScale(for: display.displayID)
            configuration.width = max(1, Int((source.width * scale).rounded()))
            configuration.height = max(1, Int((source.height * scale).rounded()))
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            return nil
        }
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        return screen?.backingScaleFactor ?? 2
    }

    private static func visionPoint(axPoint: CGPoint, in captureRect: CGRect) -> CGPoint {
        let x = (axPoint.x - captureRect.minX) / max(captureRect.width, 1)
        let yFromTop = (axPoint.y - captureRect.minY) / max(captureRect.height, 1)
        return CGPoint(
            x: min(max(x, 0), 1),
            y: min(max(1 - yFromTop, 0), 1)
        )
    }

    private static func recognizeWord(
        in image: CGImage,
        nearestTo cursor: CGPoint,
        preferredLanguages: [String]
    ) async -> String? {
        let raw = await Task.detached(priority: .userInitiated) { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.012

            let supported = (try? request.supportedRecognitionLanguages()) ?? []
            let languages = preferredLanguages.filter { language in
                supported.contains {
                    $0.caseInsensitiveCompare(language) == .orderedSame
                        || $0.lowercased().hasPrefix(String(language.prefix(2)).lowercased())
                }
            }
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }

            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }

            return wordUnderCursor(cursor: cursor, observations: request.results ?? [])
        }.value

        guard let raw else { return nil }
        let cleaned = TextCapture.cleaned(raw)
        return TextCapture.isRealCapturedWord(cleaned) ? cleaned : nil
    }

    private static func wordUnderCursor(
        cursor: CGPoint,
        observations: [VNRecognizedTextObservation]
    ) -> String? {
        func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
            if rect.contains(point) { return 0 }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return hypot(dx, dy)
        }

        struct Candidate {
            let text: String
            let box: CGRect
            let distance: CGFloat
            let containsCursor: Bool
        }

        func padded(_ rect: CGRect) -> CGRect {
            rect.insetBy(dx: -0.014, dy: -0.05)
        }

        /// `location` / `length` / `total` are UTF-16 units, matching NSString / Vision ranges.
        func interpolatedBox(lineBox: CGRect, location: Int, length: Int, total: Int) -> CGRect {
            let safeTotal = max(total, 1)
            let startFrac = CGFloat(location) / CGFloat(safeTotal)
            let endFrac = CGFloat(location + max(length, 1)) / CGFloat(safeTotal)
            return CGRect(
                x: lineBox.minX + lineBox.width * startFrac,
                y: lineBox.minY,
                width: max(lineBox.width * max(endFrac - startFrac, 0.0001), 0.0001),
                height: lineBox.height
            )
        }

        func addWordHit(
            from recognized: VNRecognizedText,
            line: String,
            lineBox: CGRect,
            token: WordExtractor.Token,
            into hits: inout [Candidate]
        ) {
            guard token.text.rangeOfCharacter(from: .letters) != nil else { return }
            let rawBox = (try? recognized.boundingBox(for: token.range)?.boundingBox)
                ?? interpolatedBox(
                    lineBox: lineBox,
                    location: token.nsRange.location,
                    length: token.nsRange.length,
                    total: (line as NSString).length
                )
            let box = padded(rawBox)
            hits.append(
                Candidate(
                    text: token.text,
                    box: box,
                    distance: distance(from: cursor, to: box),
                    containsCursor: box.contains(cursor)
                )
            )
        }

        /// Map cursor → nearest composed character, then expand to the full word token.
        /// Walks UTF-16 composed sequences; never `line.index(after:)` / Character offsets.
        func expandFullWord(in recognized: VNRecognizedText, lineBox: CGRect) -> WordExtractor.Token? {
            let line = recognized.string
            let nsLine = line as NSString
            guard nsLine.length > 0 else { return nil }

            var bestUTF16 = 0
            var bestScore = CGFloat.greatestFiniteMagnitude
            var foundCharacterBox = false
            var utf16 = 0

            while utf16 < nsLine.length {
                let composed = nsLine.rangeOfComposedCharacterSequence(at: utf16)
                if let swiftRange = Range(composed, in: line),
                   let characterBox = try? recognized.boundingBox(for: swiftRange)?.boundingBox {
                    foundCharacterBox = true
                    let box = padded(characterBox)
                    let score = box.contains(cursor) ? 0 : distance(from: cursor, to: characterBox)
                    if score < bestScore {
                        bestScore = score
                        bestUTF16 = composed.location
                    }
                }
                utf16 = composed.location + composed.length
            }

            if !foundCharacterBox {
                let t = min(max((cursor.x - lineBox.minX) / max(lineBox.width, 0.0001), 0), 0.999)
                let rawIndex = min(max(Int((t * CGFloat(nsLine.length)).rounded(.down)), 0), nsLine.length - 1)
                bestUTF16 = nsLine.rangeOfComposedCharacterSequence(at: rawIndex).location
            }

            let tokens = WordExtractor.wordTokens(in: line)
            if let token = tokens.first(where: { NSLocationInRange(bestUTF16, $0.nsRange) }) {
                return token
            }

            let walked = WordExtractor.word(in: line, atUTF16: bestUTF16)
            guard !walked.isEmpty else { return nil }
            return tokens.first(where: { $0.text == walked })
        }

        var hits: [Candidate] = []

        for observation in observations {
            guard let recognized = observation.topCandidates(1).first else { continue }
            let line = recognized.string
            let lineBox = observation.boundingBox
            let nsLine = line as NSString

            for token in WordExtractor.wordTokens(in: line) {
                addWordHit(from: recognized, line: line, lineBox: lineBox, token: token, into: &hits)
            }

            nsLine.enumerateSubstrings(
                in: NSRange(location: 0, length: nsLine.length),
                options: .byWords
            ) { substring, range, _, _ in
                guard let substring, substring.rangeOfCharacter(from: .letters) != nil else { return }
                guard let swiftRange = Range(range, in: line) else { return }
                let letterAtRange = nsLine.substring(with: nsLine.rangeOfComposedCharacterSequence(at: range.location))
                if WordExtractor.isWordCharacter(letterAtRange), !substring.contains(letterAtRange) {
                    return
                }
                addWordHit(
                    from: recognized,
                    line: line,
                    lineBox: lineBox,
                    token: WordExtractor.Token(text: substring, nsRange: range, range: swiftRange),
                    into: &hits
                )
            }

            if let expanded = expandFullWord(in: recognized, lineBox: lineBox) {
                addWordHit(from: recognized, line: line, lineBox: lineBox, token: expanded, into: &hits)
            }
        }

        hits.sort { lhs, rhs in
            if lhs.containsCursor != rhs.containsCursor {
                return lhs.containsCursor && !rhs.containsCursor
            }
            if lhs.containsCursor, lhs.text.count != rhs.text.count {
                return lhs.text.count > rhs.text.count
            }
            if abs(lhs.distance - rhs.distance) > 0.0005 {
                return lhs.distance < rhs.distance
            }
            return lhs.text.count > rhs.text.count
        }

        if let best = hits.first(where: { $0.containsCursor }) {
            return best.text
        }
        if let best = hits.first, best.distance < 0.08 {
            return best.text
        }
        return nil
    }
}

struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func save() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var dictionary: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dictionary[type] = data
                }
            }
            items.append(dictionary)
        }
        return PasteboardSnapshot(items: items)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { dictionary in
            let item = NSPasteboardItem()
            for (type, data) in dictionary {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

// MARK: - Language

enum TranslationDirection {
    case serbianToRussian
    case russianToSerbian
    case unknown
}

struct TranslationResult {
    let direction: TranslationDirection
    let russian: String
    let serbianCyrillic: String
    let serbianLatin: String
    let message: String
    let isFailure: Bool

    static func serbianToRussian(_ russian: String) -> TranslationResult {
        TranslationResult(
            direction: .serbianToRussian,
            russian: russian.serbianNormalized,
            serbianCyrillic: "",
            serbianLatin: "",
            message: russian.serbianNormalized,
            isFailure: false
        )
    }

    static func russianToSerbian(cyrillic: String, latin: String) -> TranslationResult {
        let cyr = cyrillic.serbianNormalized
        let lat = latin.serbianNormalized
        return TranslationResult(
            direction: .russianToSerbian,
            russian: "",
            serbianCyrillic: cyr,
            serbianLatin: lat,
            message: [cyr, lat].filter { !$0.isEmpty }.joined(separator: "\n"),
            isFailure: false
        )
    }

    static func failure(_ message: String) -> TranslationResult {
        TranslationResult(
            direction: .unknown,
            russian: "",
            serbianCyrillic: "",
            serbianLatin: "",
            message: message,
            isFailure: true
        )
    }
}

enum LanguageHint {
    case serbian
    case russian
    case ambiguous
}

enum LanguageDetector {
    private static let serbianOnly = CharacterSet(charactersIn: "ћђљњџјЋЂЉЊЏЈčćšžđČĆŠŽĐ")
    private static let russianOnly = CharacterSet(charactersIn: "ыэъёЫЭЪЁ")
    private static let cyrillicBlock = CharacterSet(charactersIn: UnicodeScalar(0x0400)!...UnicodeScalar(0x04FF)!)

    static func hint(for text: String) -> LanguageHint {
        let scalars = text.unicodeScalars
        let hasSerbian = scalars.contains { serbianOnly.contains($0) }
        let hasRussian = scalars.contains { russianOnly.contains($0) }
        let hasCyrillic = scalars.contains { cyrillicBlock.contains($0) }
        let hasLatinLetter = scalars.contains { scalar in
            CharacterSet.letters.contains(scalar) && !cyrillicBlock.contains(scalar)
        }

        if hasRussian && !hasSerbian { return .russian }
        if hasSerbian { return .serbian }
        if hasLatinLetter && !hasCyrillic { return .serbian }
        if !hasCyrillic { return .serbian }

        let recognizer = NLLanguageRecognizer()
        let serbian = NLLanguage("sr")
        recognizer.languageConstraints = [.russian, serbian, .croatian, .bulgarian, .ukrainian]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let russianScore = hypotheses[.russian] ?? 0
        let serbianScore = (hypotheses[serbian] ?? 0) + (hypotheses[.croatian] ?? 0)

        if russianScore > serbianScore + 0.12 { return .russian }
        if serbianScore > russianScore + 0.12 { return .serbian }
        return .ambiguous
    }

    static func isRussianCode(_ code: String?) -> Bool {
        guard let code else { return false }
        return code.lowercased().hasPrefix("ru")
    }

    static func isSerbianCode(_ code: String?) -> Bool {
        guard let code else { return false }
        let lower = code.lowercased()
        return lower.hasPrefix("sr") || lower.hasPrefix("hr") || lower.hasPrefix("bs")
    }
}

enum SerbianScript {
    private static let cyrillicToLatin: [(String, String)] = [
        ("Љ", "Lj"), ("љ", "lj"),
        ("Њ", "Nj"), ("њ", "nj"),
        ("Џ", "Dž"), ("џ", "dž"),
        ("Ђ", "Đ"), ("ђ", "đ"),
        ("Ћ", "Ć"), ("ћ", "ć"),
        ("Ж", "Ž"), ("ж", "ž"),
        ("Ч", "Č"), ("ч", "č"),
        ("Ш", "Š"), ("ш", "š"),
        ("А", "A"), ("а", "a"),
        ("Б", "B"), ("б", "b"),
        ("В", "V"), ("в", "v"),
        ("Г", "G"), ("г", "g"),
        ("Д", "D"), ("д", "d"),
        ("Е", "E"), ("е", "e"),
        ("З", "Z"), ("з", "z"),
        ("И", "I"), ("и", "i"),
        ("Ј", "J"), ("ј", "j"),
        ("К", "K"), ("к", "k"),
        ("Л", "L"), ("л", "l"),
        ("М", "M"), ("м", "m"),
        ("Н", "N"), ("н", "n"),
        ("О", "O"), ("о", "o"),
        ("П", "P"), ("п", "p"),
        ("Р", "R"), ("р", "r"),
        ("С", "S"), ("с", "s"),
        ("Т", "T"), ("т", "t"),
        ("У", "U"), ("у", "u"),
        ("Ф", "F"), ("ф", "f"),
        ("Х", "H"), ("х", "h"),
        ("Ц", "C"), ("ц", "c")
    ]

    private static let latinToCyrillic: [(String, String)] = [
        ("Dž", "Џ"), ("dž", "џ"), ("DŽ", "Џ"),
        ("Dj", "Ђ"), ("dj", "ђ"), ("DJ", "Ђ"),
        ("Lj", "Љ"), ("lj", "љ"), ("LJ", "Љ"),
        ("Nj", "Њ"), ("nj", "њ"), ("NJ", "Њ"),
        ("Đ", "Ђ"), ("đ", "ђ"),
        ("Ć", "Ћ"), ("ć", "ћ"),
        ("Č", "Ч"), ("č", "ч"),
        ("Š", "Ш"), ("š", "ш"),
        ("Ž", "Ж"), ("ž", "ж"),
        ("A", "А"), ("a", "а"),
        ("B", "Б"), ("b", "б"),
        ("V", "В"), ("v", "в"),
        ("G", "Г"), ("g", "г"),
        ("D", "Д"), ("d", "д"),
        ("E", "Е"), ("e", "е"),
        ("Z", "З"), ("z", "з"),
        ("I", "И"), ("i", "и"),
        ("J", "Ј"), ("j", "ј"),
        ("K", "К"), ("k", "к"),
        ("L", "Л"), ("l", "л"),
        ("M", "М"), ("m", "м"),
        ("N", "Н"), ("n", "н"),
        ("O", "О"), ("o", "о"),
        ("P", "П"), ("p", "п"),
        ("R", "Р"), ("r", "р"),
        ("S", "С"), ("s", "с"),
        ("T", "Т"), ("t", "т"),
        ("U", "У"), ("u", "у"),
        ("F", "Ф"), ("f", "ф"),
        ("H", "Х"), ("h", "х"),
        ("C", "Ц"), ("c", "ц")
    ]

    static func toLatin(_ text: String) -> String {
        replace(text, using: cyrillicToLatin).serbianNormalized
    }

    static func toCyrillic(_ text: String) -> String {
        replace(text, using: latinToCyrillic).serbianNormalized
    }

    static func pair(from raw: String) -> (cyrillic: String, latin: String) {
        let normalized = raw.serbianNormalized
        if looksLatin(normalized) {
            return (toCyrillic(normalized), normalized)
        }
        return (normalized, toLatin(normalized))
    }

    private static func looksLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.letters.contains($0) && ($0.value < 0x0400 || $0.value > 0x04FF)
        }
    }

    private static func replace(_ text: String, using table: [(String, String)]) -> String {
        var result = text
        for (from, to) in table {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }
}

private extension String {
    var serbianNormalized: String {
        precomposedStringWithCanonicalMapping
    }
}

// MARK: - Translation

enum Translator {
    private enum CallResult {
        case success(text: String, detected: String?)
        case failure(String)
    }

    private static let chunkLimit = 3800

    static func translate(_ text: String) async -> TranslationResult {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .failure("Нет слова для перевода.")
        }

        let chunks = chunk(query)
        guard let first = chunks.first else {
            return .failure("Нет слова для перевода.")
        }

        let hint: LanguageHint
        switch LanguageDetector.hint(for: String(query.prefix(500))) {
        case .russian:
            hint = .russian
        case .serbian:
            hint = .serbian
        case .ambiguous:
            switch await request(first, sourceLanguage: "auto", targetLanguage: "ru") {
            case .success(let translated, let detected):
                if LanguageDetector.isRussianCode(detected) || isIdentity(translated, first) {
                    hint = .russian
                } else {
                    hint = .serbian
                }
            case .failure:
                hint = .serbian
            }
        }

        if chunks.count == 1 {
            return hint == .russian
                ? await translateRussian(query)
                : await translateSerbian(query)
        }

        var russianParts: [String] = []
        var cyrillicParts: [String] = []
        var latinParts: [String] = []

        for piece in chunks {
            let result = hint == .russian
                ? await translateRussian(piece)
                : await translateSerbian(piece)
            if result.isFailure {
                return result
            }
            if hint == .russian {
                cyrillicParts.append(result.serbianCyrillic)
                latinParts.append(result.serbianLatin)
            } else {
                russianParts.append(result.russian.isEmpty ? result.message : result.russian)
            }
        }

        if hint == .russian {
            return .russianToSerbian(
                cyrillic: cyrillicParts.joined(separator: "\n\n"),
                latin: latinParts.joined(separator: "\n\n")
            )
        }
        return .serbianToRussian(russianParts.joined(separator: "\n\n"))
    }

    private static func chunk(_ text: String) -> [String] {
        guard text.count > chunkLimit else { return [text] }

        var chunks: [String] = []
        var current = ""
        let paragraphs = text.components(separatedBy: "\n")
        for (index, paragraph) in paragraphs.enumerated() {
            let piece = index == paragraphs.count - 1 ? paragraph : paragraph + "\n"
            if current.count + piece.count <= chunkLimit {
                current += piece
                continue
            }
            if !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if piece.count <= chunkLimit {
                current = piece
            } else {
                chunks.append(contentsOf: hardSplit(piece, limit: chunkLimit))
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [text] : chunks
    }

    private static func hardSplit(_ text: String, limit: Int) -> [String] {
        var parts: [String] = []
        var remaining = text
        while remaining.count > limit {
            let end = remaining.index(remaining.startIndex, offsetBy: limit)
            parts.append(String(remaining[..<end]))
            remaining = String(remaining[end...])
        }
        if !remaining.isEmpty {
            parts.append(remaining)
        }
        return parts
    }

    private static func translateSerbian(_ text: String) async -> TranslationResult {
        switch await request(text, sourceLanguage: "sr", targetLanguage: "ru") {
        case .success(let text, _):
            return .serbianToRussian(text)
        case .failure(let message):
            return .failure(message)
        }
    }

    private static func translateRussian(_ text: String) async -> TranslationResult {
        async let latinCall = request(text, sourceLanguage: "ru", targetLanguage: "sr")
        async let cyrillicCall = request(text, sourceLanguage: "ru", targetLanguage: "sr-Cyrl")

        let latinPayload = await latinCall
        let cyrillicPayload = await cyrillicCall

        var latin = ""
        var cyrillic = ""
        if case .success(let text, _) = latinPayload {
            let pair = SerbianScript.pair(from: text)
            latin = pair.latin
            cyrillic = pair.cyrillic
        }
        if case .success(let text, _) = cyrillicPayload {
            let pair = SerbianScript.pair(from: text)
            cyrillic = pair.cyrillic
            if latin.isEmpty {
                latin = pair.latin
            }
        }

        if cyrillic.isEmpty && latin.isEmpty {
            if case .failure(let message) = latinPayload {
                return .failure(message)
            }
            if case .failure(let message) = cyrillicPayload {
                return .failure(message)
            }
            return .failure("Не удалось получить сербский перевод.")
        }

        if cyrillic.isEmpty { cyrillic = SerbianScript.toCyrillic(latin) }
        if latin.isEmpty { latin = SerbianScript.toLatin(cyrillic) }
        return .russianToSerbian(cyrillic: cyrillic, latin: latin)
    }

    private static func translateAmbiguous(_ text: String) async -> TranslationResult {
        switch await request(text, sourceLanguage: "auto", targetLanguage: "ru") {
        case .success(let translated, let detected):
            if LanguageDetector.isRussianCode(detected) || isIdentity(translated, text) {
                return await translateRussian(text)
            }
            return .serbianToRussian(translated)
        case .failure:
            return await translateSerbian(text)
        }
    }

    private static func isIdentity(_ translated: String, _ source: String) -> Bool {
        translated.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
            == source.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    private static func request(
        _ text: String,
        sourceLanguage: String,
        targetLanguage: String
    ) async -> CallResult {
        guard let url = URL(string: "https://translate.googleapis.com/translate_a/single") else {
            return .failure("Не удалось собрать запрос перевода.")
        }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }

        let body = [
            "client=\(encode("gtx"))",
            "sl=\(encode(sourceLanguage))",
            "tl=\(encode(targetLanguage))",
            "dt=\(encode("t"))",
            "q=\(encode(text))"
        ].joined(separator: "&")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failure("Сервис перевода ответил ошибкой (\(http.statusCode)).")
            }
            guard let parsed = parse(data) else {
                return .failure("Не удалось разобрать перевод.")
            }
            return .success(text: parsed.text, detected: parsed.detected)
        } catch {
            return .failure("Нет соединения с сервисом перевода.")
        }
    }

    private static func parse(_ data: Data) -> (text: String, detected: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let root = json as? [Any], let sentences = root.first as? [Any] else { return nil }

        var pieces: [String] = []
        for sentence in sentences {
            guard let parts = sentence as? [Any], let translated = parts.first as? String else { continue }
            pieces.append(translated)
        }
        let result = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }

        let detected = root.dropFirst().compactMap { $0 as? String }.first
        return (result, detected)
    }
}

// MARK: - Speech

enum SpeechLanguage {
    case serbian
    case russian
}

enum SpeechTarget: Equatable {
    case source
    case translation
}

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var sessionID = UUID()
    private var currentText = ""

    var onSpeakingChange: ((Bool, SpeechTarget?) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prefetchVoices() {
        Task.detached(priority: .utility) {
            _ = VoiceCatalog.bestVoice(for: .serbian)
            _ = VoiceCatalog.bestVoice(for: .russian)
        }
    }

    func speak(_ text: String, language: SpeechLanguage, target: SpeechTarget) {
        let spoken = text.serbianNormalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }

        if synthesizer.isSpeaking, currentText == spoken {
            stop()
            return
        }

        let session = UUID()
        sessionID = session
        currentText = spoken

        Task.detached(priority: .userInitiated) {
            let voice = VoiceCatalog.bestVoice(for: language)
            let cadence = VoiceCatalog.cadence(for: voice)
            await MainActor.run { [weak self] in
                guard let self, self.sessionID == session else { return }

                if self.synthesizer.isSpeaking {
                    self.synthesizer.stopSpeaking(at: .immediate)
                }

                let utterance = AVSpeechUtterance(string: spoken)
                utterance.voice = voice
                utterance.rate = cadence.rate
                utterance.pitchMultiplier = cadence.pitch
                utterance.volume = 1.0
                utterance.preUtteranceDelay = 0.05
                utterance.postUtteranceDelay = 0.08
                self.onSpeakingChange?(true, target)
                self.synthesizer.speak(utterance)
            }
        }
    }

    func stop() {
        sessionID = UUID()
        currentText = ""
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        onSpeakingChange?(false, nil)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.currentText = ""
            self.onSpeakingChange?(false, nil)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.currentText.isEmpty {
                self.onSpeakingChange?(false, nil)
            }
        }
    }
}

private enum VoiceCatalog {
    static func bestVoice(for language: SpeechLanguage) -> AVSpeechSynthesisVoice? {
        switch language {
        case .serbian:
            return namedVoice("Lana", languages: ["hr", "sr", "bs"])
                ?? languageVoice(["sr-RS", "sr-Latn-RS", "sr-Cyrl-RS", "sr", "hr-HR", "bs-BA"])
                ?? rankedVoice(for: language)
        case .russian:
            return namedVoice("Milena", languages: ["ru"])
                ?? languageVoice(["ru-RU", "ru"])
                ?? rankedVoice(for: language)
        }
    }

    static func cadence(for voice: AVSpeechSynthesisVoice?) -> (rate: Float, pitch: Float) {
        let base = AVSpeechUtteranceDefaultSpeechRate
        switch voice?.quality {
        case .premium:
            return (base * 0.94, 0.97)
        case .enhanced:
            return (base * 0.90, 0.98)
        default:
            return (base * 0.84, 0.99)
        }
    }

    private static func namedVoice(_ name: String, languages: [String]) -> AVSpeechSynthesisVoice? {
        let matches = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            guard voice.name.localizedCaseInsensitiveContains(name) else { return false }
            return languages.contains { prefix in
                voice.language.lowercased().replacingOccurrences(of: "_", with: "-").hasPrefix(prefix)
            } && !isNovelty(voice)
        }
        return matches.max(by: { qualityScore($0) < qualityScore($1) })
    }

    private static func languageVoice(_ codes: [String]) -> AVSpeechSynthesisVoice? {
        for code in codes {
            if let voice = AVSpeechSynthesisVoice(language: code), !isNovelty(voice) {
                return voice
            }
        }
        return nil
    }

    private static func rankedVoice(for language: SpeechLanguage) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .compactMap { voice -> (AVSpeechSynthesisVoice, Int)? in
                let languageScore = matchScore(voice.language, for: language)
                guard languageScore > 0, !isNovelty(voice) else { return nil }
                return (voice, languageScore + qualityScore(voice))
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    private static func matchScore(_ languageCode: String, for language: SpeechLanguage) -> Int {
        let code = languageCode.lowercased().replacingOccurrences(of: "_", with: "-")
        switch language {
        case .serbian:
            if code.hasPrefix("sr") { return 400 }
            if code.hasPrefix("hr") { return 300 }
            if code.hasPrefix("bs") { return 120 }
            return 0
        case .russian:
            return code.hasPrefix("ru") ? 400 : 0
        }
    }

    private static func qualityScore(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0
        switch voice.quality {
        case .premium: score += 320
        case .enhanced: score += 200
        default: score += 50
        }

        let blob = voice.identifier.lowercased()
        if blob.contains("siri") || blob.contains("neural") || blob.contains("premium") { score += 80 }
        if blob.contains("enhanced") { score += 30 }
        if blob.contains("super-compact") { score -= 80 }
        else if blob.contains("compact") { score -= 15 }
        return score
    }

    private static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if #available(macOS 14.0, *) {
            return voice.voiceTraits.contains(.isNoveltyVoice)
        }
        return false
    }
}

// MARK: - Saved words

struct SavedWord: Identifiable, Codable, Equatable {
    var id: UUID
    var source: String
    var translation: String
    var createdAt: Date

    init(id: UUID = UUID(), source: String, translation: String, createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.translation = translation
        self.createdAt = createdAt
    }
}

enum WordSaveStatus {
    case inserted
    case updated
}

@MainActor
final class WordStore: ObservableObject {
    static let shared = WordStore()

    @Published private(set) var words: [SavedWord] = []

    private init() {
        load()
    }

    @discardableResult
    func upsert(source: String, translation: String) -> WordSaveStatus {
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translationText = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty, !translationText.isEmpty else { return .updated }

        if let index = words.firstIndex(where: {
            $0.source.localizedCaseInsensitiveCompare(sourceText) == .orderedSame
        }) {
            words[index].translation = translationText
            words[index].createdAt = Date()
            let updated = words.remove(at: index)
            words.insert(updated, at: 0)
            persist()
            return .updated
        }

        words.insert(SavedWord(source: sourceText, translation: translationText), at: 0)
        persist()
        return .inserted
    }

    func delete(_ word: SavedWord) {
        words.removeAll { $0.id == word.id }
        persist()
    }

    func quizletText() -> String {
        words.map { "\(flatten($0.source))\t\(flatten($0.translation))" }
            .joined(separator: "\n")
            + (words.isEmpty ? "" : "\n")
    }

    func exportQuizletFile(presenter: NSWindow?) {
        guard !words.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Экспорт для Quizlet"
        panel.nameFieldStringValue = "Serbka_Quizlet_Export.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let text = quizletText()
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }

        if let presenter {
            panel.beginSheetModal(for: presenter, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([SavedWord].self, from: data) else {
            words = []
            return
        }
        words = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        guard let data = try? encoder.encode(words) else { return }
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private var folderURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Serbka", isDirectory: true)
    }

    private var fileURL: URL {
        folderURL.appendingPathComponent("words.json")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func flatten(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class WordsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: WordsListView())
            hosting.sizingOptions = [.minSize]

            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 580),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Мои слова"
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.isMovableByWindowBackground = true
            newWindow.appearance = NSAppearance(named: .darkAqua)
            newWindow.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
            newWindow.contentView = hosting
            newWindow.delegate = self
            newWindow.minSize = NSSize(width: 420, height: 360)
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            window = newWindow
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        restoreAccessoryPolicy()
    }

    func windowWillClose(_ notification: Notification) {
        restoreAccessoryPolicy()
    }

    private func restoreAccessoryPolicy() {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Popup window

enum PresentationMode {
    case word
    case paragraph
    case notice
}

@MainActor
final class PopupModel: ObservableObject {
    @Published var source = ""
    @Published var translation = ""
    @Published var serbianCyrillic = ""
    @Published var serbianLatin = ""
    @Published var direction: TranslationDirection = .unknown
    @Published var mode: PresentationMode = .word
    @Published var isLoading = false
    @Published var isSpeaking = false
    @Published var speakingTarget: SpeechTarget?
    @Published var isTrusted = true
    @Published var saveBanner: String?

    private(set) var lastCard: (source: String, translation: String)?
    private var bannerTask: Task<Void, Never>?

    var speaker: Speaker?

    func prepare(
        source: String,
        trusted: Bool,
        canCaptureScreen: Bool = true,
        mode: PresentationMode = .word
    ) {
        self.mode = mode
        self.source = source.serbianNormalized
        self.isTrusted = trusted
        self.isSpeaking = false
        self.speakingTarget = nil
        self.saveBanner = nil
        speaker?.stop()
        self.direction = LanguageDetector.hint(for: source) == .russian
            ? .russianToSerbian
            : (source.isEmpty ? .unknown : .serbianToRussian)
        self.serbianCyrillic = ""
        self.serbianLatin = ""
        if source.isEmpty {
            if !trusted {
                translation = "Нужен доступ Универсального доступа, чтобы читать текст."
            } else if mode == .paragraph {
                translation = "Выделите текст или скопируйте его, затем нажмите ⌘P."
            } else if !canCaptureScreen {
                translation = "Для субтитров на видео разрешите запись экрана в настройках системы."
            } else {
                translation = "Наведите курсор на сербское или русское слово и нажмите ⌘S."
            }
            isLoading = false
        } else {
            translation = ""
            isLoading = true
        }
        speaker?.onSpeakingChange = { [weak self] speaking, target in
            self?.isSpeaking = speaking
            self?.speakingTarget = speaking ? target : nil
        }
    }

    func prepareNotice(_ message: String) {
        mode = .notice
        source = ""
        serbianCyrillic = ""
        serbianLatin = ""
        direction = .unknown
        isLoading = false
        isSpeaking = false
        speakingTarget = nil
        translation = message
        saveBanner = (message.contains("Сохранено") || message.contains("Обновлено")) ? message : nil
    }

    func updateTranslation(_ result: TranslationResult) {
        direction = result.direction
        translation = result.message
        serbianCyrillic = result.serbianCyrillic
        serbianLatin = result.serbianLatin
        if !result.russian.isEmpty, result.direction == .serbianToRussian {
            translation = result.russian
        }
        isLoading = false
        if !result.isFailure, !source.isEmpty {
            lastCard = (source, exportableTranslation)
        }
    }

    var exportableTranslation: String {
        switch direction {
        case .russianToSerbian:
            let parts = [serbianCyrillic, serbianLatin].filter { !$0.isEmpty }
            return parts.isEmpty ? translation : parts.joined(separator: " / ")
        case .serbianToRussian, .unknown:
            return translation
        }
    }

    func showSavedBanner(_ text: String) {
        saveBanner = text
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if saveBanner == text {
                saveBanner = nil
            }
        }
    }

    func speakSource() {
        guard canSpeakSource else { return }
        speaker?.speak(source, language: sourceSpeechLanguage, target: .source)
    }

    func speakTranslation() {
        guard canSpeakTranslation else { return }
        speaker?.speak(spokenTranslation, language: translationSpeechLanguage, target: .translation)
    }

    var canSpeakSource: Bool {
        !source.isEmpty && direction != .unknown
    }

    var canSpeakTranslation: Bool {
        !isLoading && direction != .unknown && !spokenTranslation.isEmpty
    }

    private var spokenTranslation: String {
        switch direction {
        case .russianToSerbian:
            if !serbianLatin.isEmpty { return serbianLatin }
            return serbianCyrillic.isEmpty ? translation : serbianCyrillic
        case .serbianToRussian:
            return translation
        case .unknown:
            return ""
        }
    }

    private var sourceSpeechLanguage: SpeechLanguage {
        direction == .russianToSerbian ? .russian : .serbian
    }

    private var translationSpeechLanguage: SpeechLanguage {
        direction == .russianToSerbian ? .serbian : .russian
    }
}

@MainActor
final class PopupPanelController {
    var model: PopupModel?
    var onRequestClose: (() -> Void)?

    private var panel: NSPanel?
    private var hostingView: NSHostingView<PopupView>?
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var mouseDownMonitor: Any?
    private var localMouseMonitor: Any?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var windowID: CGWindowID {
        guard let panel, panel.windowNumber > 0 else { return kCGNullWindowID }
        return CGWindowID(panel.windowNumber)
    }

    func show(near point: NSPoint) {
        let model = self.model ?? PopupModel()
        self.model = model

        if panel == nil {
            let newPanel = PopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 130),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isFloatingPanel = true
            newPanel.level = .statusBar
            newPanel.hidesOnDeactivate = false
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            newPanel.isMovableByWindowBackground = true
            newPanel.becomesKeyOnlyIfNeeded = true
            newPanel.animationBehavior = .utilityWindow
            newPanel.isReleasedWhenClosed = false
            newPanel.appearance = NSAppearance(named: .darkAqua)
            panel = newPanel
        }

        let view = PopupView(model: model)
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = [.preferredContentSize]
            hosting.autoresizingMask = [.width, .height]
            panel?.contentView = hosting
            hostingView = hosting
        }

        fitToContent(near: point)
        panel?.orderFrontRegardless()
        installWindowMonitors()
    }

    func fitToContent(near point: NSPoint) {
        guard let panel else { return }
        hostingView?.invalidateIntrinsicContentSize()

        let mode = model?.mode ?? .word
        var size: NSSize
        switch mode {
        case .paragraph:
            size = NSSize(width: 540, height: 460)
            if let visible = screen(for: point)?.visibleFrame {
                size.width = min(max(440, size.width), visible.width - 36)
                size.height = min(max(320, size.height), visible.height - 72)
            }
        case .notice:
            size = NSSize(width: 320, height: 92)
        case .word:
            size = hostingView?.fittingSize ?? NSSize(width: 320, height: 140)
            size.width = max(280, min(size.width, 420))
            size.height = max(110, min(size.height, 360))
        }

        var origin = NSPoint(x: point.x + 14, y: point.y - size.height - 16)
        if let screen = screen(for: point) {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX {
                origin.x = point.x - size.width - 14
            }
            if origin.y < visible.minY {
                origin.y = point.y + 18
            }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func hide() {
        panel?.orderOut(nil)
        removeWindowMonitors()
    }

    func contains(_ point: NSPoint) -> Bool {
        panel?.frame.contains(point) == true
    }

    private func installWindowMonitors() {
        removeWindowMonitors()

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                if self.isVisible, !self.contains(location) {
                    self.onRequestClose?()
                }
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.isVisible, !self.contains(NSEvent.mouseLocation), event.window !== self.panel {
                self.onRequestClose?()
            }
            return event
        }

        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.onRequestClose?()
                return nil
            }
            return event
        }

        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                Task { @MainActor in
                    self?.onRequestClose?()
                }
            }
        }
    }

    private func removeWindowMonitors() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        mouseDownMonitor = nil
        localMouseMonitor = nil
        localEscapeMonitor = nil
        globalEscapeMonitor = nil
    }

    private func screen(for point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
