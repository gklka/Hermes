import Foundation

/// Imports the history of encrypted 1:1 chats from Messenger's web app (after it has been
/// restored there with your PIN). The web app shows each message with its real message ID,
/// so imported messages line up with ones the live connection delivers.
///
/// Chats wait in a queue, as they take turns with the page: the open chat first, then (after
/// a restore) the recent ones. Each chat remembers the stretch of its history that's imported
/// (its coverage, kept across launches), so opening it again only reads what's newer, and
/// scrolling to its top reads the next batch before it, again and again until the chat's start.
/// The page always loads a chat from its newest message back, so an import scrolls past the
/// imported stretch without reading it again.
///
/// For a while after a restore the web app is still downloading the history, so a chat is
/// imported again every few minutes until nothing older turns up.
///
/// The Activity window shows the queue, the running import and a log of the finished ones.
final class WebHistoryImporter {
    static let shared = WebHistoryImporter()

    /// Called on the main thread when a chat's import is queued, starts or ends.
    var onStateChange: ((_ threadID: String) -> Void)?
    /// Posted when anything the Activity window shows changes (also the running import's progress).
    static let activityDidChange = Notification.Name("WebHistoryImporterActivityDidChange")

    enum Mode: String, Codable {
        /// What's newer than the imported stretch (the first time: a batch from the newest back).
        case latest
        /// The batch before the imported stretch (and what's newer, which is read on the way).
        case earlier
    }

    private struct Job {
        let threadID: String
        var mode: Mode
        /// Asked for by opening the chat (not in the background, e.g. after a restore): only
        /// needed while the chat is shown.
        var opened = true
    }

    /// Chats whose history the web app couldn't show (not restored there with the PIN yet).
    private(set) var needsRestore: Set<String> = []
    /// Chats whose newest messages were imported since launch (opening them again doesn't).
    private var done: Set<String> = []
    /// Waiting to be imported, the next first.
    private var queue: [Job] = []
    /// Being imported now, since when.
    private var current: Job?
    private var currentStarted = Date()
    private var isRunning = false
    /// Waiting to be imported again (more history may still arrive): when, and how often each was.
    private var retryAt: [String: Date] = [:]
    private var tries: [String: Int] = [:]
    /// The oldest message collected per chat (ms), to tell when an import found nothing older.
    private var oldest: [String: Int64] = [:]
    /// Changes when the account logs out, so the work for it stops.
    private var generation = 0
    /// Where the running import is.
    private var stage: Stage = .startingWebApp

    private static let retryDelay: TimeInterval = 120
    private static let maxTries = 6
    /// How many of the most recent encrypted chats are imported after a restore.
    private static let recentChatCount = 15
    /// How many messages an import reads (new ones; the imported stretch is skipped).
    private static let batchSize = 400
    /// For this long after a restore, the web app may still be downloading the history.
    private static let restoringPeriod: TimeInterval = 30 * 60
    private static let restoredAtKey = "WebRestoredAt"

    // MARK: - Kept across launches

    /// The imported stretch of a chat's history (message times, ms).
    private struct Coverage: Codable {
        var oldest: Int64
        var newest: Int64
    }

    /// One import in the Activity window's log.
    struct Record {
        enum Result { case done, retrying, needsRestore, failed }
        let threadID: String
        let mode: Mode
        let started: Date
        let ended: Date
        let result: Result
        let summary: String
    }

    /// The imports finished since launch, the latest first (the Activity window's log).
    private var log: [Record] = []

    private struct Saved: Codable {
        var coverage: [String: Coverage] = [:]
        /// Chats whose start the web app showed: there's nothing older to read.
        var reachedStart: Set<String> = []
    }

    private static let savedKey = "WebHistoryImporterState"

    private var saved: Saved {
        didSet {
            if let data = try? JSONEncoder().encode(saved) {
                UserDefaults.standard.set(data, forKey: Self.savedKey)
            }
        }
    }

    private init() {
        saved = UserDefaults.standard.data(forKey: Self.savedKey)
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    /// When the encrypted chats were restored here last (kept across launches).
    private var restoredAt: Date? {
        get { UserDefaults.standard.object(forKey: Self.restoredAtKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.restoredAtKey) }
    }

    private var isRestoring: Bool {
        restoredAt.map { Date().timeIntervalSince($0) < Self.restoringPeriod } ?? false
    }

    /// Queued, being imported, or waiting to be imported again: the chat shows it's loading.
    func isPending(_ threadID: String) -> Bool {
        current?.threadID == threadID || queue.contains { $0.threadID == threadID } || retryAt[threadID] != nil
    }

    /// Whether the web app has messages older than the imported ones (scrolling to the top of
    /// the chat reads them: loadEarlier).
    func hasEarlier(_ threadID: String) -> Bool {
        saved.coverage[threadID] != nil && !saved.reachedStart.contains(threadID)
    }

    /// The web app is still reading the chat's history (or has more of it): the server's
    /// history, only the chat's unencrypted past, waits until it's read back to the start, so
    /// the chat shows its latest messages first and goes back in order. (Never read, e.g.
    /// without the PIN restore, the server's history is all there is.)
    func holdsServerHistory(_ threadID: String) -> Bool {
        isPending(threadID) || hasEarlier(threadID)
    }

    // What the collect script returns (decoded off the main actor).
    nonisolated private struct Result: Decodable {
        let messages: [Message]
        let error: String?
        /// The page showed the chat's first message.
        let reachedStart: Bool?
        /// It scrolled back into the imported stretch (so everything newer is read).
        let overlap: Bool?
        /// Messages imported before that show reactions.
        let reacted: [Reacted]?
    }

    /// The reactions on a message imported before.
    nonisolated struct Reacted: Codable {
        let domID: String
        let fromMe: Bool
        let reactions: [Reaction]
    }

    nonisolated struct Message: Codable {
        let domID: String
        let fromMe: Bool
        let text: String
        let images: [Image]
        /// Shared links' cards (their pictures aren't in `images`).
        let links: [Link]
        let reactions: [Reaction]
    }

    /// A reaction pill: its emoji and how many people reacted (the page doesn't say who).
    nonisolated struct Reaction: Codable {
        let emojis: [String]
        let count: Int
    }

    nonisolated struct Link: Codable {
        let url: String
        let title: String
        let description: String
        let image: Image?
    }

    nonisolated struct Image: Codable {
        let data: String
        let mimeType: String
        let width: Int
        let height: Int
    }

    /// Forgets everything (the account logged out). An import still reading the page may never
    /// finish (the page is closed), so it doesn't block the next account's.
    func reset() {
        generation += 1
        needsRestore = []
        done = []
        queue = []
        current = nil
        isRunning = false
        retryAt = [:]
        tries = [:]
        oldest = [:]
        saved = Saved()
        log = []
        restoredAt = nil
        NotificationCenter.default.post(name: Self.activityDidChange, object: self)
    }

    private func stateChanged(_ threadID: String) {
        onStateChange?(threadID)
        NotificationCenter.default.post(name: Self.activityDidChange, object: self)
    }

    /// The chat was opened: what's new in it is imported next.
    func importHistory(threadID: String) {
        guard !done.contains(threadID), current?.threadID != threadID else { return }
        enqueueFirst(Job(threadID: threadID, mode: .latest))
    }

    /// The chat's stored messages were thrown away (Refresh): its history is read again from the
    /// newest message back.
    func reimport(threadID: String) {
        saved.coverage[threadID] = nil
        saved.reachedStart.remove(threadID)
        done.remove(threadID)
        oldest[threadID] = nil
        // Also while it's being read: it's read again after that.
        enqueueFirst(Job(threadID: threadID, mode: .latest))
    }

    /// Scrolled to the top of the chat: the batch before the imported messages is read next.
    func loadEarlier(threadID: String) {
        guard hasEarlier(threadID), !isPending(threadID) else { return }
        enqueueFirst(Job(threadID: threadID, mode: .earlier))
    }

    /// The chat isn't shown anymore (another one was opened, or its window closed): what opening
    /// it asked for is dropped, and stopped if it's being read (it's read again next time).
    /// Background imports go on.
    func chatLeft(_ threadID: String) {
        guard WebSyncController.shared.isChatShown?(threadID) != true else { return }
        let before = queue.count
        queue.removeAll { $0.threadID == threadID && $0.opened }
        if let current, current.threadID == threadID, current.opened, !currentStopped {
            currentStopped = true
            CoreBridge.shared.log("WebHistoryImporter: \(threadID) closed, stopping its import")
            // The collect script checks this flag and returns early.
            Task { _ = try? await WebSyncController.shared.evaluate("window.__mmImportStop = true; return JSON.stringify(true)", as: Bool.self) }
        } else if queue.count == before {
            return
        }
        stateChanged(threadID)
    }

    /// The running import was stopped (its chat was closed): its result is thrown away.
    private var currentStopped = false
    /// The running import is the chat's first read (nothing imported yet: opened for the first
    /// time, or after Refresh).
    private var currentIsFirstRead = false

    /// How far a chat's first read is (0…1; nil when none is going on), for the chat's progress
    /// bar. Queued, it's at the start.
    func firstReadProgress(_ threadID: String) -> Double? {
        if let current, current.threadID == threadID {
            return currentIsFirstRead ? stage.overall : nil
        }
        let queued = queue.contains { $0.threadID == threadID && $0.mode == .latest }
        return queued && saved.coverage[threadID] == nil ? 0 : nil
    }

    private func enqueueFirst(_ job: Job) {
        var job = job
        // Reading earlier messages also reads the new ones on the way.
        if let queued = queue.first(where: { $0.threadID == job.threadID }), queued.mode == .earlier {
            job.mode = .earlier
        }
        queue.removeAll { $0.threadID == job.threadID }
        queue.insert(job, at: 0)
        retryAt[job.threadID] = nil
        stateChanged(job.threadID)
        runQueue()
    }

    /// The encrypted chats were just restored with the PIN: everything is worth importing again,
    /// and the recent chats are imported in the background.
    func restoreFinished() {
        CoreBridge.shared.log("WebHistoryImporter: restore finished")
        restoredAt = Date()
        needsRestore = []
        done = []
        tries = [:]
        oldest = [:]
        // The restore can bring older messages.
        saved.reachedStart = []
        importRecentChats()
    }

    /// The chats are loaded (at launch): soon after a restore, the recent chats' import goes on.
    func chatsLoaded() {
        if isRestoring { importRecentChats() }
    }

    private func importRecentChats() {
        let generation = self.generation
        Task {
            // The chat list maps the chats to the web app's.
            await WebChatImporter.shared.runOnce()
            guard generation == self.generation else { return }
            let recent = ChatStore.shared.conversations.filter { $0.isEncrypted && !$0.isGroup }.prefix(Self.recentChatCount)
            for conversation in recent where !isPending(conversation.id) {
                queue.append(Job(threadID: conversation.id, mode: .latest, opened: false))
                stateChanged(conversation.id)
            }
            runQueue()
        }
    }

    /// Imports the queued chats one after the other.
    private func runQueue() {
        guard !isRunning else { return }
        isRunning = true
        let generation = self.generation
        Task {
            while generation == self.generation, !queue.isEmpty {
                let job = queue.removeFirst()
                current = job
                currentStarted = Date()
                currentStopped = false
                currentIsFirstRead = job.mode == .latest && saved.coverage[job.threadID] == nil
                stage = .startingWebApp
                stateChanged(job.threadID)
                let (outcome, summary) = await importOnce(job)
                guard generation == self.generation else { return }
                current = nil
                if currentStopped {
                    // Nothing changes: the chat is read again when it's opened.
                    CoreBridge.shared.log("WebHistoryImporter: \(job.threadID) import stopped")
                } else {
                    finish(job, outcome, summary: summary)
                }
                stateChanged(job.threadID)
            }
            if generation == self.generation { isRunning = false }
        }
    }

    private enum Outcome {
        /// Everything asked for is imported.
        case complete
        /// The web app may still be downloading older messages: import it again later.
        case moreMayCome
        /// The web app doesn't show the chat's history (it isn't restored with the PIN).
        case needsRestore
        /// Something went wrong; it's tried again when the chat is opened.
        case failed
    }

    private func finish(_ job: Job, _ outcome: Outcome, summary: String) {
        let threadID = job.threadID
        let result: Record.Result
        switch outcome {
        case .complete:
            needsRestore.remove(threadID)
            done.insert(threadID)
            result = .done
        case .needsRestore:
            needsRestore.insert(threadID)
            result = .needsRestore
        case .moreMayCome:
            needsRestore.remove(threadID)
            let tried = tries[threadID, default: 0] + 1
            tries[threadID] = tried
            if tried < Self.maxTries {
                retryLater(threadID)
                result = .retrying
            } else {
                done.insert(threadID)
                result = .done
            }
        case .failed:
            result = .failed
        }
        let record = Record(threadID: threadID, mode: job.mode, started: currentStarted, ended: Date(), result: result, summary: summary)
        log.insert(record, at: 0)
    }

    private func retryLater(_ threadID: String) {
        retryAt[threadID] = Date().addingTimeInterval(Self.retryDelay)
        let generation = self.generation
        Task {
            try? await Task.sleep(for: .seconds(Self.retryDelay))
            // Opened meanwhile (imported then), or logged out.
            guard generation == self.generation, retryAt.removeValue(forKey: threadID) != nil else { return }
            if !queue.contains(where: { $0.threadID == threadID }) {
                queue.append(Job(threadID: threadID, mode: .latest, opened: false))
            }
            stateChanged(threadID)
            runQueue()
        }
    }

    private func setStage(_ stage: Stage) {
        self.stage = stage
        NotificationCenter.default.post(name: Self.activityDidChange, object: self)
    }

    /// Reads the chat from the web app and stores what's new; also says what it found.
    private func importOnce(_ job: Job) async -> (Outcome, String) {
        let threadID = job.threadID
        let account = ChatStore.shared.account?.id
        do {
            struct WebIDResult: Decodable { let webID: String }
            struct Params: Encodable { let threadID: String }
            struct PathResult: Decodable { let path: String }
            let webID = try await CoreBridge.shared.call("web.threadWebID", Params(threadID: threadID), as: WebIDResult.self).webID
            let path = try await CoreBridge.shared.call("web.threadPath", Params(threadID: threadID), as: PathResult.self).path
            guard !webID.isEmpty, !path.isEmpty else {
                CoreBridge.shared.log("WebHistoryImporter: no web chat known for \(threadID)")
                return (.needsRestore, "The chat isn't on Messenger web's chat list yet.")
            }
            let web = WebSyncController.shared
            setStage(.startingWebApp)
            guard await web.start(showWindow: false) else {
                return (.failed, "Messenger web couldn't be started.")
            }
            let coverage = saved.coverage[threadID]
            CoreBridge.shared.log("WebHistoryImporter: \(threadID) → web chat \(webID), reading \(job.mode.rawValue)")
            setStage(.waitingForPage)
            let script = Self.collectScript(userID: threadID, mode: job.mode, batch: Self.batchSize, coverage: coverage)
            let result = try await web.withExclusiveAccess {
                // Closed while it waited for the page.
                guard !currentStopped else { throw CancellationError() }
                setStage(.openingChat)
                await web.navigate(toPath: path, fresh: true)
                setStage(.finding)
                // The collect script reports where it is in window.__mmImport.
                var lastProgress: Progress?
                var lastChange = Date()
                let poll = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let progress = try? await web.evaluate("return JSON.stringify(window.__mmImport || {})", as: Progress.self),
                              !Task.isCancelled else { continue }
                        if progress != lastProgress {
                            lastProgress = progress
                            lastChange = Date()
                        }
                        apply(progress, mode: job.mode, hasCoverage: coverage != nil)
                    }
                }
                defer { poll.cancel() }
                do {
                    // No progress for a while: the script is stuck (or its page was replaced).
                    return try await web.evaluate(script, as: Result.self) {
                        Date().timeIntervalSince(lastChange) > Self.stallTimeout
                    }
                } catch {
                    CoreBridge.shared.log("WebHistoryImporter: \(threadID): \(error.localizedDescription); reloading the page")
                    await web.reloadPage()
                    throw error
                }
            }
            if let error = result.error {
                CoreBridge.shared.log("WebHistoryImporter: \(threadID): \(error)")
            }
            // Logged out (or in as someone else) while the page was read.
            guard ChatStore.shared.account?.id == account else {
                return (.failed, "Logged out while the chat was read.")
            }
            // Stopped part way: what was read is incomplete, so none of it is kept.
            guard !currentStopped else { return (.failed, "Stopped: the chat was closed.") }
            setStage(.saving(result.messages.count))
            struct ImportParams: Encodable { let threadID: String; let messages: [Message] }
            struct ImportResult: Decodable { let imported: Int; let unrestored: Int }
            let imported = try await CoreBridge.shared.call(
                "web.importMessages", ImportParams(threadID: threadID, messages: result.messages), as: ImportResult.self
            )
            CoreBridge.shared.log("WebHistoryImporter: \(threadID): collected \(result.messages.count), imported \(imported.imported), not restored \(imported.unrestored)")
            if let reacted = result.reacted, !reacted.isEmpty {
                struct ReactedParams: Encodable { let threadID: String; let reacted: [Reacted] }
                try await CoreBridge.shared.call("web.importReactions", ReactedParams(threadID: threadID, reacted: reacted))
            }
            // The core emits each stored message as an event, so open chats update by themselves.

            if result.error != nil {
                return (isRestoring ? .moreMayCome : .needsRestore, "Messenger web shows no messages in this chat.")
            }
            if imported.unrestored > 0 {
                let summary = "\(imported.unrestored) message\(imported.unrestored == 1 ? " isn't" : "s aren't") restored on Messenger web yet."
                return (isRestoring ? .moreMayCome : .needsRestore, summary)
            }
            // Loading older messages can stall on the page and look like the chat's start; it
            // isn't if an older encrypted message is stored (the page shows all of those). Stored
            // times are whole seconds and the page's come from message IDs, so the same message
            // can differ by up to a few seconds.
            var reachedStart = result.reachedStart == true
            if reachedStart {
                struct Oldest: Decodable { let timestamp: Int64 }
                let oldestStored = try await CoreBridge.shared.call("web.oldestEncrypted", Params(threadID: threadID), as: Oldest.self).timestamp
                let oldestRead = result.messages.compactMap { Self.timestamp(ofDOMID: $0.domID) }.min() ?? coverage?.oldest ?? .max
                if oldestStored > 0, oldestStored < min(oldestRead, coverage?.oldest ?? .max) - 5000 {
                    CoreBridge.shared.log("WebHistoryImporter: \(threadID): loading stalled, not the chat's start")
                    reachedStart = false
                }
            }
            updateCoverage(threadID, job: job, result: result, reachedStart: reachedStart)
            let summary = Self.summary(job: job, result: result, reachedStart: reachedStart, imported: imported.imported, hadCoverage: coverage != nil)
            guard job.mode == .latest, isRestoring else { return (.complete, summary) }
            // Nothing older than last time: that's all there is.
            let oldestNow = result.messages.compactMap { Self.timestamp(ofDOMID: $0.domID) }.min()
            defer { oldest[threadID] = oldestNow }
            if let oldestNow, oldestNow == oldest[threadID] { return (.complete, summary) }
            return (.moreMayCome, summary)
        } catch {
            CoreBridge.shared.log("WebHistoryImporter: \(threadID): \(error)")
            return (.failed, error.localizedDescription)
        }
    }

    /// Adds what was read to the chat's imported stretch.
    private func updateCoverage(_ threadID: String, job: Job, result: Result, reachedStart: Bool) {
        let stamps = result.messages.compactMap { Self.timestamp(ofDOMID: $0.domID) }
        if let low = stamps.min(), let high = stamps.max() {
            if var coverage = saved.coverage[threadID], job.mode == .earlier || result.overlap == true {
                coverage.oldest = min(coverage.oldest, low)
                coverage.newest = max(coverage.newest, high)
                saved.coverage[threadID] = coverage
            } else {
                // The first import, or a batch of new messages that didn't reach the imported
                // stretch: a gap, so the stretch starts over from here.
                saved.coverage[threadID] = Coverage(oldest: low, newest: high)
                saved.reachedStart.remove(threadID)
            }
        }
        if reachedStart {
            saved.reachedStart.insert(threadID)
        }
    }

    private static func summary(job: Job, result: Result, reachedStart: Bool, imported: Int, hadCoverage: Bool) -> String {
        let read = result.messages.count
        let plural = { (n: Int, word: String) in "\(n) \(word)\(n == 1 ? "" : "s")" }
        var text: String
        if read == 0 {
            text = job.mode == .earlier ? "No older messages." : "Up to date, nothing new."
        } else if job.mode == .earlier {
            text = "Read \(plural(read, "message")) (\(imported) new)."
        } else if hadCoverage, result.overlap == true {
            text = "Up to date: read \(plural(read, "newer message")) (\(imported) new)."
        } else {
            text = "Read \(plural(read, "message")) (\(imported) new)."
        }
        let readable = result.messages.contains { !$0.text.isEmpty || !$0.images.isEmpty || !$0.links.isEmpty }
        if read > 0, !readable {
            text = "Only Messenger's “end-to-end encrypted” notice, no messages to import."
        }
        if reachedStart {
            text += " Reached the start of the chat."
        } else if result.reachedStart == true {
            text += " Messenger web stopped loading older messages; scroll to the top to try again."
        }
        return text
    }

    /// The collect script's progress report.
    /// Seconds without progress after which reading a chat is given up.
    private static let stallTimeout: TimeInterval = 120

    nonisolated private struct Progress: Decodable, Equatable {
        let phase: String?
        /// Messages read (not imported before).
        let fresh: Int?
        /// Of those, the ones older than the imported stretch.
        let older: Int?
        /// Imported before, scrolled past.
        let skipped: Int?
        let fraction: Double?
        let done: Int?
        let total: Int?
    }

    private func apply(_ progress: Progress, mode: Mode, hasCoverage: Bool) {
        switch progress.phase {
        case "back":
            setStage(.scrollingBack(mode: mode, hasCoverage: hasCoverage, fresh: progress.fresh ?? 0,
                                    older: progress.older ?? 0, skipped: progress.skipped ?? 0))
        case "forward": setStage(.rendering(fraction: progress.fraction ?? 0, read: progress.fresh ?? 0))
        case "pictures": setStage(.pictures(done: progress.done ?? 0, total: progress.total ?? 0))
        default: break
        }
    }

    // MARK: - Activity

    /// Where the running import is.
    private enum Stage {
        case startingWebApp
        /// Another reader (the chat list, a chat's theme) is using the page.
        case waitingForPage
        case openingChat
        /// Waiting for the chat's messages to show on the page.
        case finding
        case scrollingBack(mode: Mode, hasCoverage: Bool, fresh: Int, older: Int, skipped: Int)
        /// Going through the chat again so every message renders fully.
        case rendering(fraction: Double, read: Int)
        case pictures(done: Int, total: Int)
        case saving(Int)

        var text: String {
            switch self {
            case .startingWebApp: return "Starting Messenger web…"
            case .waitingForPage: return WebChatImporter.shared.isReading
                ? "Waiting for the chat list to be read…"
                : "Waiting for Messenger web to finish another task…"
            case .openingChat: return "Opening the chat on Messenger web…"
            case .finding: return "Waiting for the messages to appear…"
            case .scrollingBack(let mode, let hasCoverage, let fresh, let older, let skipped):
                switch mode {
                case .earlier where older == 0:
                    return "Scrolling past the \(skipped) messages imported before…"
                case .earlier:
                    return "Reading older messages: \(older) of \(WebHistoryImporter.batchSize)"
                case .latest where hasCoverage:
                    return "Scrolling back to the messages imported before: \(fresh) new so far"
                case .latest:
                    return "Scrolling back: \(fresh) of up to \(WebHistoryImporter.batchSize) messages read"
                }
            case .rendering(_, let read): return "Reading \(read) messages in full (pictures, links, reactions)"
            case .pictures(let done, let total): return "Copying pictures: message \(done) of \(total)"
            case .saving(let count): return "Saving \(count) messages…"
            }
        }

        /// How far the whole import is (0…1), roughly: opening the chat, scrolling back (most of
        /// it), reading in full, copying pictures, saving.
        var overall: Double {
            switch self {
            case .startingWebApp, .waitingForPage: return 0.02
            case .openingChat: return 0.05
            case .finding: return 0.08
            case .scrollingBack: return 0.1 + 0.55 * (progress ?? 0)
            case .rendering(let fraction, _): return 0.65 + 0.2 * min(1, fraction)
            case .pictures: return 0.85 + 0.12 * (progress ?? 0)
            case .saving: return 0.98
            }
        }

        /// Nil while it can't be measured.
        var progress: Double? {
            switch self {
            case .scrollingBack(let mode, let hasCoverage, let fresh, let older, _):
                switch mode {
                case .earlier: return older > 0 ? min(1, Double(older) / Double(WebHistoryImporter.batchSize)) : nil
                case .latest: return hasCoverage ? nil : min(1, Double(fresh) / Double(WebHistoryImporter.batchSize))
                }
            case .rendering(let fraction, _): return min(1, fraction)
            case .pictures(let done, let total): return total > 0 ? Double(done) / Double(total) : nil
            default: return nil
            }
        }
    }

    /// A row in the Activity window.
    struct ActivityItem {
        enum Section { case upNext, now, done }
        enum Kind { case running, queued, waiting, done, retrying, needsRestore, failed }
        /// The chat read; nil for work on the whole chat list (see `name`).
        let threadID: String?
        let section: Section
        let kind: Kind
        /// What the import reads ("Newest messages", "Older messages").
        let title: String
        let status: String
        /// For a running import: how far it is (nil: indeterminate).
        let progress: Double?
        /// When it started (running) or ended (done).
        let date: Date?
        /// How long a finished import took.
        let duration: TimeInterval?
        /// The row's name when it isn't about one chat.
        var name: String? = nil
    }

    private static func title(_ mode: Mode) -> String {
        mode == .earlier ? "Older messages" : "Newest messages"
    }

    /// Up next (the queue in order, then the chats waiting to be imported again), the running
    /// import, then the log of finished ones, the latest first.
    var activityItems: [ActivityItem] {
        var items: [ActivityItem] = []
        for (index, job) in queue.enumerated() {
            let ahead = index + (current == nil ? 0 : 1)
            let status = ahead == 0 ? "Next" : "Waiting, \(ahead) before it"
            items.append(ActivityItem(threadID: job.threadID, section: .upNext, kind: .queued, title: Self.title(job.mode),
                                      status: status, progress: nil, date: nil, duration: nil))
        }
        for (threadID, date) in retryAt.sorted(by: { $0.value < $1.value }) {
            let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
            let status = "Checking again in \(seconds / 60):\(String(format: "%02d", seconds % 60)) (try \(tries[threadID, default: 0] + 1) of \(Self.maxTries)): Messenger web may still be downloading its history."
            items.append(ActivityItem(threadID: threadID, section: .upNext, kind: .waiting, title: Self.title(.latest),
                                      status: status, progress: nil, date: nil, duration: nil))
        }
        if let current {
            items.append(ActivityItem(threadID: current.threadID, section: .now, kind: .running, title: Self.title(current.mode),
                                      status: stage.text, progress: stage.progress, date: currentStarted, duration: nil))
        }
        for record in log {
            let kind: ActivityItem.Kind
            var status = record.summary
            switch record.result {
            case .done: kind = .done
            case .retrying: kind = .retrying
            case .needsRestore:
                kind = .needsRestore
                status += " Restore your encrypted chats with your PIN (File › Restore Encrypted Chats…)."
            case .failed:
                kind = .failed
                status += " It's tried again when you open the chat."
            }
            items.append(ActivityItem(threadID: record.threadID, section: .done, kind: kind, title: Self.title(record.mode),
                                      status: status, progress: nil, date: record.ended,
                                      duration: record.ended.timeIntervalSince(record.started)))
        }
        return items
    }

    /// The time of a message from its web ID ("<user>@msgr.<message ID>"): Messenger message IDs
    /// are milliseconds << 22 | random (as in the core's webMessageID).
    /// Nil for elements whose ID isn't a message ID (the time would be decades off).
    private static func timestamp(ofDOMID domID: String) -> Int64? {
        guard let dot = domID.lastIndex(of: "."), let id = UInt64(domID[domID.index(after: dot)...]) else { return nil }
        let timestamp = Int64(id >> 22)
        return timestamp > minTimestamp ? timestamp : nil
    }

    /// 2010 (ms): message times before it come from IDs that aren't message IDs.
    private static let minTimestamp: Int64 = 1_262_304_000_000

    // MARK: - Reading the page

    /// Scrolls the open chat back and returns the messages that aren't imported yet: their ID,
    /// direction, text and inline images (as base64; the page already shows them decrypted).
    /// `latest` stops on reaching the imported stretch (or after a batch), `earlier` scrolls
    /// past it and stops after a batch of older messages. Both stop at the chat's start.
    private static func collectScript(userID: String, mode: Mode, batch: Int, coverage: Coverage?) -> String {
        """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const MODE = '\(mode.rawValue)', BATCH = \(batch);
        // The imported stretch (message times): messages in it are skipped.
        const COV_FROM = \(coverage?.oldest ?? 0), COV_TO = \(coverage?.newest ?? -1);
        // Message IDs are milliseconds << 22 | random; 0 for IDs that aren't (before 2010).
        const tsOf = domID => {
          try {
            const ts = Number(BigInt(domID.slice(domID.lastIndexOf('.') + 1)) >> 22n);
            return ts > \(minTimestamp) ? ts : 0;
          } catch (e) { return 0; }
        };
        const covered = ts => ts >= COV_FROM && ts <= COV_TO;
        // Read by the app while this runs (the Activity window).
        const progress = p => { window.__mmImport = p; };
        // Set by the app when the chat is closed (WebHistoryImporter.chatLeft): stop early.
        window.__mmImportStop = false;
        const STOPPED = JSON.stringify({ messages: [], stopped: true });
        const stopped = () => window.__mmImportStop === true;
        progress({ phase: 'finding' });
        let log = null;
        for (let i = 0; i < 40; i++) {
          if (stopped()) return STOPPED;
          log = document.querySelector('[role="main"] [role="log"]');
          if (log && log.querySelector('[data-message-id^="\(userID)@"]')) break;
          await sleep(500);
        }
        if (!log || !log.querySelector('[data-message-id^="\(userID)@"]')) return JSON.stringify({ messages: [], error: 'no messages shown for this chat' });
        await sleep(1000);
        const scroller = (() => {
          for (let el = log; el; el = el.parentElement)
            if (el.scrollHeight > el.clientHeight + 20 && /(auto|scroll)/.test(getComputedStyle(el).overflowY)) return el;
          let best = null;
          for (const el of log.querySelectorAll('*'))
            if (el.scrollHeight > el.clientHeight + 20 && /(auto|scroll)/.test(getComputedStyle(el).overflowY) && (!best || el.scrollHeight > best.scrollHeight)) best = el;
          return best;
        })();
        // Pictures are read as soon as they're seen: blob: URLs can be revoked once a message
        // scrolls out of the (virtualized) list.
        const toBase64 = async src => {
          // data: URLs already hold the picture (and Facebook's content security policy blocks
          // fetching them).
          const comma = src.indexOf(',');
          if (src.startsWith('data:') && comma > 0 && src.slice(0, comma).endsWith(';base64')) {
            const data = src.slice(comma + 1);
            return { data, size: Math.floor(data.length * 3 / 4) };
          }
          const bytes = new Uint8Array(await (await fetch(src)).arrayBuffer());
          let bin = '';
          for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          return { data: btoa(bin), size: bytes.length };
        };
        const encode = async img => {
          try {
            const { data, size } = await toBase64(img.src);
            const mimeType = img.src.startsWith('data:') ? img.src.slice(5, img.src.indexOf(';')) : 'image/jpeg';
            return size < 15 * 1024 * 1024 ? { data, mimeType, width: img.width, height: img.height } : null;
          } catch (e) { return null; }
        };
        // Text with emoji, which the page draws as <img alt="😆">.
        const textOf = node => {
          let s = '';
          for (const n of node.childNodes) {
            if (n.nodeType === Node.TEXT_NODE) s += n.nodeValue;
            else if (n.nodeName === 'IMG') s += n.getAttribute('alt') || '';
            else if (n.nodeName === 'BR') s += '\\n';
            else s += textOf(n);
          }
          return s;
        };
        const isPicture = i => {
          const r = i.getBoundingClientRect();
          return r.width >= 60 && r.height >= 60 && !i.closest('[role="toolbar"]');
        };

        // Reactions: a button labelled "<count> <emoji> …" with the emoji as images.
        const reactionsOf = el => {
          const reactions = [];
          for (const button of el.querySelectorAll('[role="button"][aria-label]')) {
            const count = parseInt(button.getAttribute('aria-label'), 10);
            if (!(count > 0) || button.closest('[role="toolbar"]')) continue;
            const emojis = Array.from(button.querySelectorAll('img[alt]')).map(i => i.getAttribute('alt')).filter(Boolean);
            if (emojis.length) reactions.push({ emojis, count });
          }
          return reactions;
        };
        // Which side the message hugs: all its bubbles and pictures together, since an album
        // staggers its photos left and right (one photo's center can be on the wrong side).
        const isFromMe = (el, logRect) => {
          let left = Infinity, right = -Infinity;
          for (const part of [...el.querySelectorAll('div[dir="auto"]'), ...el.querySelectorAll('img')]) {
            const r = part.getBoundingClientRect();
            if (r.width < 20 || part.closest('[role="toolbar"]')) continue;
            left = Math.min(left, r.left);
            right = Math.max(right, r.right);
          }
          return left === Infinity
            ? (r => r.width > 0 && (r.left + r.width / 2) > logRect.left + logRect.width / 2)(el.getBoundingClientRect())
            : (logRect.right - right) < (left - logRect.left);
        };

        const seen = new Map();
        const skipped = new Set();
        // Messages imported before that show reactions: they may have come while the app was
        // offline (the live connection doesn't deliver those later).
        const reacted = new Map();
        let oldestTs = Infinity;
        const richness = m => m.text.length + 1000 * (m.images.length + m.links.length) + 10 * m.reactions.length;
        const collect = () => {
          const logRect = log.getBoundingClientRect();
          for (const el of log.querySelectorAll('[data-message-id^="\(userID)@"]')) {
            const domID = el.getAttribute('data-message-id');
            const ts = tsOf(domID);
            if (ts > 0) oldestTs = Math.min(oldestTs, ts);
            if (covered(ts)) {
              skipped.add(domID);
              const reactions = reactionsOf(el);
              if (reactions.length && !reacted.has(domID)) reacted.set(domID, { domID, fromMe: isFromMe(el, logRect), reactions });
              continue;
            }
            // Shared links' cards: <a href> with a title (and description, picture) inside. Links
            // in the message text sit in its div[dir=auto]; links around a bare photo are photos.
            const cards = Array.from(el.querySelectorAll('a[href^="http"]')).filter(a =>
              !a.closest('[role="toolbar"]') && !a.closest('div[dir="auto"]') && a.querySelector('span[dir="auto"]'));
            // A shared location is a map picture wrapped in a link to Maps, with no caption — so
            // it isn't a card. Keep the link (its coordinates) rather than scraping a bare photo.
            const isMapHref = u => /maps\\.app\\.goo\\.gl|maps\\.google|google\\.[a-z.]+\\/maps|\\/maps\\/|[?&](?:q|ll|center|query|daddr|destination)=[-\\d]/i.test(u || '');
            const mapAnchors = Array.from(el.querySelectorAll('a[href^="http"]')).filter(a =>
              !a.closest('[role="toolbar"]') && !a.closest('div[dir="auto"]') && isMapHref(a.href) &&
              Array.from(a.querySelectorAll('img')).some(isPicture));
            // A pinned location has no link: it's a button wrapping a map picture and an address.
            // Open it in Maps by that address (there are no coordinates in the page).
            const placeButtons = Array.from(el.querySelectorAll('[role="button"]')).filter(b =>
              !b.closest('[role="toolbar"]') && Array.from(b.querySelectorAll('img')).some(isPicture) &&
              b.querySelector('span[dir="auto"], div[dir="auto"]'));
            const inCard = node => cards.some(a => a.contains(node)) || mapAnchors.some(a => a.contains(node)) ||
              placeButtons.some(b => b.contains(node));
            // The text (big single emoji included): each outermost div[dir=auto].
            const texts = Array.from(el.querySelectorAll('div[dir="auto"]'))
              .filter(t => !t.closest('[role="toolbar"]') && !inCard(t) && !t.parentElement.closest('div[dir="auto"]'))
              .map(t => textOf(t).trim()).filter(Boolean);
            const links = cards.map(a => {
              const spans = Array.from(a.querySelectorAll('span[dir="auto"]')).map(s => s.innerText.trim()).filter(Boolean);
              const img = Array.from(a.querySelectorAll('img')).find(isPicture);
              return { url: a.href, title: spans[0] || '', description: spans[1] || '',
                       image: img ? { src: img.src, width: img.naturalWidth, height: img.naturalHeight } : null };
            }).concat(mapAnchors.map(a => {
              const img = Array.from(a.querySelectorAll('img')).find(isPicture);
              return { url: a.href, title: (a.getAttribute('aria-label') || '').trim(), description: '',
                       image: img ? { src: img.src, width: img.naturalWidth, height: img.naturalHeight } : null };
            })).concat(placeButtons.map(b => {
              // The address is the longest of the card's text lines (the other is a label).
              const lines = Array.from(b.querySelectorAll('span[dir="auto"], div[dir="auto"]'))
                .map(t => t.innerText.trim()).filter(Boolean).sort((x, y) => y.length - x.length);
              const address = lines[0] || '';
              const img = Array.from(b.querySelectorAll('img')).find(isPicture);
              return address ? { url: 'http://maps.apple.com/?q=' + encodeURIComponent(address), title: address,
                       description: '', image: img ? { src: img.src, width: img.naturalWidth, height: img.naturalHeight } : null } : null;
            }).filter(Boolean));
            const images = Array.from(el.querySelectorAll('img')).filter(i => isPicture(i) && !inCard(i))
              .map(i => ({ src: i.src, width: i.naturalWidth, height: i.naturalHeight }));
            const entry = { domID, ts, text: texts.join('\\n'), images, links, reactions: reactionsOf(el) };
            const old = seen.get(domID);
            // Keep the fullest version: pictures decrypt and cards render after the message appears.
            if (old && richness(old) >= richness(entry)) continue;
            entry.fromMe = old ? old.fromMe : isFromMe(el, logRect);
            entry.imagesReady = Promise.all(images.slice(0, 6).map(encode));
            entry.linksReady = Promise.all(links.slice(0, 3).map(async l => ({ ...l, image: l.image ? await encode(l.image) : null })));
            seen.set(domID, entry);
          }
        };
        // Older than the imported stretch.
        const older = () => { let n = 0; for (const m of seen.values()) if (m.ts < COV_FROM) n++; return n; };
        const enough = () => MODE === 'earlier' ? older() >= BATCH : seen.size >= BATCH;
        // Scrolled back into the imported stretch: everything newer has been seen.
        const overlap = () => MODE === 'latest' && COV_TO >= 0 && oldestTs <= COV_TO;
        const report = () => progress({ phase: 'back', fresh: seen.size, older: older(), skipped: skipped.size });
        collect();
        report();
        // Older messages can take a moment to load (longer while the web app is still restoring);
        // scrolling back faster than this makes the page stop loading them.
        let stable = 0;
        let reachedStart = !scroller;
        for (let i = 0; i < 3000 && scroller && !enough() && !overlap(); i++) {
          if (stopped()) return STOPPED;
          const before = seen.size + skipped.size;
          scroller.scrollTop = 0;
          await sleep(2000);
          collect();
          report();
          stable = seen.size + skipped.size === before ? stable + 1 : 0;
          if (stable >= 5) { reachedStart = true; break; }
        }
        // The first message on screen, to stop the second pass once it's in the imported stretch.
        const firstVisibleTs = () => {
          const top = scroller.getBoundingClientRect().top;
          for (const el of log.querySelectorAll('[data-message-id^="\(userID)@"]'))
            if (el.getBoundingClientRect().bottom > top) return tsOf(el.getAttribute('data-message-id'));
          return Infinity;
        };
        // Second pass, forward through what was read, so every message gets time to render fully.
        if (scroller) {
          scroller.scrollTop = 0;
          await sleep(1000);
          for (let i = 0; i < 400 && scroller.scrollTop + scroller.clientHeight < scroller.scrollHeight - 5; i++) {
            if (stopped()) return STOPPED;
            if (MODE === 'earlier' && COV_TO >= 0 && covered(firstVisibleTs())) break;
            scroller.scrollTop += scroller.clientHeight * 0.7;
            await sleep(700);
            collect();
            progress({ phase: 'forward', fresh: seen.size, fraction: (scroller.scrollTop + scroller.clientHeight) / scroller.scrollHeight });
          }
          await sleep(1000);
          collect();
        }
        const messages = [];
        for (const m of seen.values()) {
          if (stopped()) return STOPPED;
          progress({ phase: 'pictures', done: messages.length + 1, total: seen.size });
          const images = (await m.imagesReady).filter(Boolean);
          const links = await m.linksReady;
          messages.push({ domID: m.domID, fromMe: m.fromMe, text: m.text, images, links, reactions: m.reactions });
        }
        return JSON.stringify({ messages, reachedStart, overlap: overlap(), reacted: Array.from(reacted.values()) });
        """
    }
}
