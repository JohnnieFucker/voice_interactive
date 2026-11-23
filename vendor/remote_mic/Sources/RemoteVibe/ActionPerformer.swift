import AppKit

final class ActionPerformer {
    static let iTermID = "com.googlecode.iterm2"
    // NSAppleScript 的访问串行化，避免阻塞主线程的蓝牙和按键回调。
    // https://developer.apple.com/forums/thread/759287
    private let queue = DispatchQueue(label: "dev.remotevibe.iterm")
    private var busy = false

    func activate(_ action: ButtonAction = .focus, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !busy else { completion(.failure(AudioFailure("上一个切换操作尚未完成"))); return }
        busy = true
        let source = Self.navigationScript(for: action)
        queue.async {
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            let result = script?.executeAndReturnError(&error)
            let failure = error?[NSAppleScript.errorMessage] as? String ?? (result == nil ? "无法执行 iTerm2 控制脚本" : nil)
            DispatchQueue.main.async {
                if let failure { self.busy = false; completion(.failure(AudioFailure(failure))) }
                else { self.awaitFocus(attempts: 20, completion: completion) }
            }
        }
    }

    static func navigationScript(for action: ButtonAction) -> String {
        let direction = action == .previousWindow ? -1 : 1
        let cycle = action == .previousWindow || action == .nextWindow
        let cycleScript = cycle ? """
            set ids to id of every window
            set currentID to id of current window
            set chosenID to currentID
            set extremeID to currentID
            set foundTarget to false
            repeat with itemID in ids
                set candidateID to itemID as integer
                if \(direction > 0 ? "candidateID < extremeID" : "candidateID > extremeID") then set extremeID to candidateID
                if \(direction > 0 ? "candidateID > currentID" : "candidateID < currentID") then
                    if not foundTarget or \(direction > 0 ? "candidateID < chosenID" : "candidateID > chosenID") then
                        set chosenID to candidateID
                        set foundTarget to true
                    end if
                end if
            end repeat
            if not foundTarget then set chosenID to extremeID
            select window id chosenID
        """ : ""
        let paneDirection = action == .previousPane ? -1 : 1
        let paneScript = action == .previousPane || action == .nextPane ? """
            tell current tab of current window
                set paneList to sessions
                set paneCount to count of paneList
                if paneCount < 2 then error "当前标签页没有其他分屏。"
                set activeID to unique id of current session
                set activeIndex to 0
                repeat with paneIndex from 1 to paneCount
                    if unique id of item paneIndex of paneList is activeID then
                        set activeIndex to paneIndex
                        exit repeat
                    end if
                end repeat
                if activeIndex = 0 then error "当前分屏已变化，请重试。"
                set targetIndex to activeIndex + \(paneDirection)
                if targetIndex < 1 then set targetIndex to paneCount
                if targetIndex > paneCount then set targetIndex to 1
                set targetPane to item targetIndex of paneList
                tell targetPane to select
            end tell
        """ : ""
        return """
        tell application id "com.googlecode.iterm2"
            if (count of windows) = 0 then error "iTerm2 没有打开的窗口，请先创建终端会话。"
            \(cycleScript)
            \(paneScript)
            activate
        end tell
        """
    }

    private func awaitFocus(attempts: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        if Self.hasFocus { busy = false; completion(.success(())); return }
        guard attempts > 0 else { busy = false; completion(.failure(AudioFailure("iTerm2 未获得焦点，操作已取消"))); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.awaitFocus(attempts: attempts - 1, completion: completion) }
    }

    static var hasFocus: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == iTermID }

    @discardableResult
    static func post(code: CGKeyCode, flags: CGEventFlags = [], down: Bool) -> Bool {
        guard AXIsProcessTrusted(), let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return false }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardEventSuppressor.syntheticMarker)
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    static func postShortcut(_ shortcut: Shortcut, down: Bool) -> Bool {
        guard shortcut.isValid, AXIsProcessTrusted() else { return false }
        guard shortcut.modifierOnly == true else { return post(code: CGKeyCode(shortcut.code), flags: shortcut.flags, down: down) }
        let keys: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand), (63, .maskSecondaryFn)]
        let selected = keys.filter { shortcut.flags.contains($0.1) }
        var flags: CGEventFlags = down ? [] : shortcut.flags
        for (code, flag) in down ? selected : Array(selected.reversed()) {
            if down { flags.insert(flag) } else { flags.remove(flag) }
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return false }
            event.type = .flagsChanged
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardEventSuppressor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    @discardableResult
    static func tap(_ shortcut: Shortcut) -> Bool {
        guard postShortcut(shortcut, down: true) else { return false }
        return postShortcut(shortcut, down: false)
    }
}
