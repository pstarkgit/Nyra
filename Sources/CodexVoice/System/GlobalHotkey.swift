import AppKit
import CoreGraphics
import Foundation

struct RightOptionHotkeyDecision: Equatable, Sendable {
    let isDown: Bool
    let shouldToggle: Bool

    static func evaluate(
        keyCode: UInt16,
        alternateDown: Bool,
        wasDown: Bool
    ) -> RightOptionHotkeyDecision {
        guard keyCode == 61 else {
            return RightOptionHotkeyDecision(isDown: wasDown, shouldToggle: false)
        }
        let isDown = alternateDown
        return RightOptionHotkeyDecision(
            isDown: isDown,
            shouldToggle: isDown && !wasDown
        )
    }
}

private final class HotkeyTapContext: @unchecked Sendable {
    private let lock = NSLock()
    private var isDown = false
    let onToggle: @MainActor () -> Void

    init(onToggle: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
    }

    func process(event: CGEvent) -> Bool {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(
            .keyboardEventKeycode
        ))
        let alternateDown = event.flags.contains(.maskAlternate)
        lock.lock()
        let decision = RightOptionHotkeyDecision.evaluate(
            keyCode: keyCode,
            alternateDown: alternateDown,
            wasDown: isDown
        )
        isDown = decision.isDown
        lock.unlock()
        if decision.shouldToggle {
            Task { @MainActor [onToggle] in onToggle() }
        }
        return keyCode == 61
    }
}

private func globalHotkeyCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .flagsChanged, let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let context = Unmanaged<HotkeyTapContext>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return context.process(event: event) ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class GlobalHotkey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var context: HotkeyTapContext?
    var onToggle: (() -> Void)?

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        stop()
        guard Self.hasAccessibility else { return false }
        let context = HotkeyTapContext { [weak self] in self?.onToggle?() }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: globalHotkeyCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        ) else { return false }
        self.context = context
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        context = nil
    }

    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
    }
}
