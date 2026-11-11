@preconcurrency import CoreAudio
import Foundation

/// One Core Audio property on one object that a live source listens to.
struct AudioWatchKey: Hashable, Sendable {
    var object: AudioObjectID
    var selector: AudioObjectPropertySelector
    var scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
}

/// A set of property listeners that follows a desired set of keys: `sync` adds the listeners that are new and removes the
/// ones that are gone (the meeting app's processes and the devices they play to come and go during a call). Every block
/// runs on `queue` and only calls `onChange`; nothing in a block takes this object's lock, so removing a listener (which can
/// wait for a block in flight) never deadlocks.
final class AudioPropertyWatch: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onChange: @Sendable (AudioWatchKey) -> Void
    /// Held across the add/remove calls so two syncs never interleave.
    private let lock = NSLock()
    private var blocks: [AudioWatchKey: AudioObjectPropertyListenerBlock] = [:]

    init(queue: DispatchQueue, onChange: @escaping @Sendable (AudioWatchKey) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    /// What a sync from `current` to `desired` adds and removes.
    static func diff(current: Set<AudioWatchKey>, desired: Set<AudioWatchKey>) -> (add: Set<AudioWatchKey>, remove: Set<AudioWatchKey>) {
        (desired.subtracting(current), current.subtracting(desired))
    }

    func sync(_ desired: Set<AudioWatchKey>) {
        lock.lock()
        defer { lock.unlock() }
        let d = Self.diff(current: Set(blocks.keys), desired: desired)
        for k in d.remove {
            guard let block = blocks.removeValue(forKey: k) else { continue }
            var a = AudioObjectPropertyAddress(mSelector: k.selector, mScope: k.scope, mElement: kAudioObjectPropertyElementMain)
            // A process or device that is already gone answers with an error; its listener went with it.
            _ = AudioObjectRemovePropertyListenerBlock(k.object, &a, queue, block)
        }
        for k in d.add {
            let onChange = self.onChange
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange(k) }
            var a = AudioObjectPropertyAddress(mSelector: k.selector, mScope: k.scope, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(k.object, &a, queue, block) == noErr { blocks[k] = block }
        }
    }

    func removeAll() { sync([]) }
}
