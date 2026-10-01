import AVFoundation
import Synchronization

/// Preallocated audio buffers handed between Core Audio's real-time thread,
/// the only borrower, and the writer queue, the only returner, without a lock.
///
/// The pools used a lock the real-time side could only `try()`: whenever the
/// writer happened to be returning a buffer at that instant, the callback
/// dropped audio although buffers were free. One such drop flagged a
/// 33-minute recording as interrupted on 2026-10-01.
///
/// A single-producer/single-consumer ring of buffer indices: only the
/// borrower advances `head`, only the returner advances `tail`.
final class RealtimeBufferRing: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
    private let identities: [ObjectIdentifier: Int]
    private let slots: UnsafeMutablePointer<Int>
    private let capacity: Int
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(buffers: [AVAudioPCMBuffer]) {
        self.buffers = buffers
        capacity = buffers.count + 1
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: 0, count: capacity)
        var identities: [ObjectIdentifier: Int] = [:]
        for (index, buffer) in buffers.enumerated() {
            slots[index] = index
            identities[ObjectIdentifier(buffer)] = index
        }
        self.identities = identities
        tail.store(buffers.count, ordering: .releasing)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    /// Real-time thread only. Never blocks or allocates.
    func borrow() -> AVAudioPCMBuffer? {
        let start = head.load(ordering: .relaxed)
        guard start != tail.load(ordering: .acquiring) else { return nil }
        let buffer = buffers[slots[start]]
        head.store((start + 1) % capacity, ordering: .releasing)
        return buffer
    }

    /// Writer queue only. A buffer from another ring is ignored.
    func giveBack(_ buffer: AVAudioPCMBuffer) {
        guard let index = identities[ObjectIdentifier(buffer)] else { return }
        let end = tail.load(ordering: .relaxed)
        let next = (end + 1) % capacity
        // Full only if a buffer was returned twice; never overwrite a slot.
        guard next != head.load(ordering: .acquiring) else { return }
        slots[end] = index
        tail.store(next, ordering: .releasing)
    }

    var availableCount: Int {
        let start = head.load(ordering: .acquiring)
        let end = tail.load(ordering: .acquiring)
        return (end - start + capacity) % capacity
    }
}
