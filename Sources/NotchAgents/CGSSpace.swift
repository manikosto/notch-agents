import AppKit

typealias CGSConnectionID = UInt
typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> CGSConnectionID
@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: Int, _ options: NSDictionary?) -> CGSSpaceID
@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)
@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

/// Отдельный CGS-space для окна нотча: окно живёт вне пользовательских Spaces
/// и не участвует в анимации их переключения — не «отстаёт» от железной чёлки.
/// Приватный API WindowServer; приём проверен в boring.notch и Pock.
final class CGSSpace {
    private let id: CGSSpaceID
    private let connection = _CGSDefaultConnection()

    init(level: Int = Int(Int32.max)) {
        id = CGSSpaceCreate(connection, 0x1, nil)
        CGSSpaceSetAbsoluteLevel(connection, id, level)
        CGSShowSpaces(connection, [id] as NSArray)
    }

    func add(_ window: NSWindow) {
        CGSAddWindowsToSpaces(connection, [window.windowNumber] as NSArray, [id] as NSArray)
    }

    deinit {
        CGSHideSpaces(connection, [id] as NSArray)
        CGSSpaceDestroy(connection, id)
    }
}
