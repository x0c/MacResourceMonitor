import Foundation

/// Short-lived table-footer notice. A later present or clear invalidates the pending dismiss.
@MainActor
final class TransientStatusMessage {
    static let displayDuration: Duration = .seconds(3)

    private var generation = 0
    private var dismissTask: Task<Void, Never>?
    private var assign: ((String?) -> Void)?

    func present(
        _ message: String,
        duration: Duration = displayDuration,
        set: @escaping (String?) -> Void
    ) {
        generation += 1
        let mine = generation
        dismissTask?.cancel()
        assign = set
        set(message)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.dismissIfCurrent(mine)
        }
    }

    func cancel() {
        generation += 1
        dismissTask?.cancel()
        dismissTask = nil
        assign?(nil)
        assign = nil
    }

    private func dismissIfCurrent(_ mine: Int) {
        guard generation == mine else { return }
        assign?(nil)
    }
}
