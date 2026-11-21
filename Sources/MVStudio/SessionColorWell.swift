import AppKit

@MainActor
final class SessionColorWell: NSColorWell {
    private(set) var sessionID: UUID?
    override func activate(_ exclusive: Bool) {
        let wasActive = isActive
        super.activate(exclusive)
        if !wasActive && isActive { sessionID = UUID() }
    }
    override func deactivate() {
        super.deactivate()
        sessionID = nil
    }
}
