#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/Check.swift" <<'SWIFT'
import AppKit
import Carbon

@MainActor
enum MenuBarRuntime {
    static var opens = 0
    static func openMainApplication() { opens += 1 }
}

@main
enum Check {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let shortcut = GlobalShortcut()
        try shortcut.setEnabled(true)
        try shortcut.setEnabled(true)
        let other = GlobalShortcut()
        do {
            try other.setEnabled(true)
            fatalError("Duplicate registration should fail")
        } catch {}

        var event: EventRef?
        assert(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                           0, 0, &event) == noErr)
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: 0x4753594E, id: 1)
        assert(SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                 EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr)
        assert(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        assert(MenuBarRuntime.opens == 1)
        try shortcut.setEnabled(false)
        _ = SendEventToEventTarget(event, GetApplicationEventTarget())
        assert(MenuBarRuntime.opens == 1)
        try other.setEnabled(true)
        try other.setEnabled(false)
        try shortcut.setEnabled(true)
        try shortcut.setEnabled(false)
        print("Global shortcut registration, dispatch, disable, and re-enable passed")
    }
}
SWIFT
swiftc -parse-as-library "$repo/Sources/PortalMenuBar/GlobalShortcut.swift" "$scratch/Check.swift" -o "$scratch/check"
"$scratch/check"
