import Carbon.HIToolbox

/// Global ⌃⌥⌘ shortcuts. Carbon hot keys work from any app and don't need Accessibility permission.
final class HotKeys {
    private var actions: [UInt32: () -> Void] = [:]
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Each key is a virtual key code (kVK_ANSI_R and so on), pressed together with ⌃⌥⌘.
    init(_ bindings: [(key: Int, action: () -> Void)]) {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue().actions[id.id]?()
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)

        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            actions[id] = binding.action
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(binding.key), UInt32(controlKey | optionKey | cmdKey),
                                             EventHotKeyID(signature: OSType(0x54414B45), id: id),   // 'TAKE'
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { hotKeys.append(ref) } else { NSLog("Take: shortcut \(binding.key) is taken (\(status))") }
        }
    }

    deinit {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
