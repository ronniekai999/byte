import Foundation
import SwiftUI
import AppKit

@MainActor
final class ByteModel: ObservableObject {

    struct Turn: Identifiable, Codable {
        var id = UUID()
        let role: Role
        var text: String
        var sources: [Source] = []
        // Local failures are displayed separately and never sent back as assistant answers.
        var failure: String? = nil
        // Image attachment (vision).
        // imageId + imageType are PERSISTED (tiny); the JPEG bytes live in a sidecar file
        // at ~/.config/byte/images/<imageId>.jpg. imageB64 + displayImage are runtime only
        // — re-derived from the sidecar on load, never written into history.json.
        var imageId: String? = nil
        var imageType: String? = nil
        var imageB64: String? = nil
        var displayImage: NSImage? = nil
        enum Role: String, Codable { case user, byte }
        struct Source: Codable, Hashable { let title: String; let url: String }

        init(role: Role, text: String, sources: [Source] = [],
             imageId: String? = nil, imageType: String? = nil,
             imageB64: String? = nil, displayImage: NSImage? = nil) {
            self.role = role; self.text = text; self.sources = sources
            self.imageId = imageId; self.imageType = imageType
            self.imageB64 = imageB64; self.displayImage = displayImage
        }

        // Tolerant decoding; imageB64/displayImage are excluded so they're never on disk.
        enum CodingKeys: String, CodingKey { case id, role, text, sources, failure, imageId, imageType }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
            let roleRaw = (try? c.decode(String.self, forKey: .role)) ?? "byte"
            role = (roleRaw == "user") ? .user : .byte   // legacy "finn" decodes as .byte
            text = try c.decode(String.self, forKey: .text)
            sources = (try? c.decode([Source].self, forKey: .sources)) ?? []
            failure = try? c.decode(String.self, forKey: .failure)
            imageId = try? c.decode(String.self, forKey: .imageId)
            imageType = try? c.decode(String.self, forKey: .imageType)
        }
    }

    @Published var chatOpen = false
    @Published var draft = ""
    @Published var turns: [Turn] = []
    @Published var isThinking = false      // waiting on the first text token (or retrying)
    @Published var isStreaming = false     // a response is currently in flight
    @Published var searching = false       // Byte is running a web search
    @Published var hasKey = false          // an API key is available
    @Published var keyInput = ""           // text in the sign-in field
    @Published var hasArchive = false      // at least one archived thread exists
    @Published var storageError: String? = nil

    // Pending image attachment (vision), waiting to be sent with the next message.
    @Published var pendingImage: NSImage? = nil
    @Published var pendingImageB64: String? = nil
    @Published var pendingImageType: String? = nil

    // Session cost meter (estimated, this run only)
    @Published var sessionCost = 0.0
    @Published var sessionInTok = 0
    @Published var sessionOutTok = 0
    @Published var sessionSearches = 0

    private let configDirectory: URL
    private let defaults: UserDefaults
    private let keyStore: any APIKeyStoring
    private let session: URLSession
    private let environment: [String: String]
    private let now: () -> Date
    private var streamTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var activeResponseID: UUID?
    private var historyNeedsRecovery = false

    init(configDirectory: URL? = nil, defaults: UserDefaults = .standard,
         keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
         session: URLSession = .shared,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         now: @escaping () -> Date = Date.init) {
        self.configDirectory = configDirectory ?? URL(fileURLWithPath:
            (NSHomeDirectory() as NSString).appendingPathComponent(".config/byte"))
        self.defaults = defaults
        self.keyStore = keyStore
        self.session = session
        self.environment = environment
        self.now = now
        if configDirectory == nil { migrateFromFinnIfNeeded() }
        migrateAPIKeyIfNeeded()
        defaults.register(defaults: ["byte.checkins": true])
        hasKey = (apiKey() != nil)
        loadHistory()
        refreshHasArchive()
        loadPet()
    }

    /// One-time move of the old ~/.config/finn data directory (API key, history,
    /// images, archives) to ~/.config/byte, so upgrading from the dolphin build
    /// keeps everything. No-op once ~/.config/byte exists.
    private func migrateFromFinnIfNeeded() {
        let fm = FileManager.default
        let byteDir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/byte")
        let finnDir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/finn")
        guard !fm.fileExists(atPath: byteDir), fm.fileExists(atPath: finnDir) else { return }
        try? fm.moveItem(atPath: finnDir, toPath: byteDir)
    }

    // MARK: - Virtual-pet engine (feed / water / play / rest + proactive check-ins)

    /// Byte's needs, 0–100 (100 = fully satisfied). All decay slowly over real time,
    /// even while the app is closed, computed from `lastTick`.
    struct PetState: Codable {
        var hunger    = 80.0
        var thirst    = 80.0
        var energy    = 80.0
        var happiness = 80.0
        var lastTick   = Date()
        var lastCheckIn = Date()
        var nextCheckIn = Date().addingTimeInterval(Double.random(in: 1500...2700)) // 25–45 min
        var born       = Date()
    }

    @Published var pet = PetState()

    /// Fired when Byte wants to say something on his own (need reminders / friendly
    /// check-ins). The view wires this to the speech bubble. Gated on the chat being
    /// closed and a minimum spacing so he never nags.
    var onCheckIn: (@MainActor (String) -> Void)?

    // Transient "already warned about this need" flags (not persisted).
    private var warnHunger = false, warnThirst = false, warnEnergy = false
    private var lastPetSave = Date.distantPast

    private var checkInsEnabled: Bool { defaults.bool(forKey: "byte.checkins") }

    /// Whole days since Byte hatched (for the care panel).
    var petAgeDays: Int { max(0, Int(Date().timeIntervalSince(pet.born) / 86_400)) }

    private var petURL: URL {
        URL(fileURLWithPath: (configDir as NSString).appendingPathComponent("pet.json"))
    }

    private func loadPet() {
        if let data = try? Data(contentsOf: petURL),
           let p = try? JSONDecoder().decode(PetState.self, from: data) {
            pet = p
        }
        tickPet()   // apply decay accrued while the app was closed
    }

    private func persistPet(force: Bool) {
        let now = Date()
        if !force, now.timeIntervalSince(lastPetSave) < 30 { return }   // throttle background saves
        do {
            try FileManager.default.createDirectory(
                atPath: configDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(pet)
            try data.write(to: petURL, options: .atomic)
            lastPetSave = now
        } catch {
            storageError = "Couldn't save Byte's needs. \(error.localizedDescription)"
        }
    }

    /// Advance needs by however much real time has elapsed, settle happiness toward
    /// overall wellbeing, and consider a check-in. Safe to call frequently — decay is
    /// elapsed-based, so extra calls within the same moment are no-ops.
    func tickPet() {
        let now = Date()
        let dtH = now.timeIntervalSince(pet.lastTick) / 3600.0
        if dtH > 0 {
            pet.hunger = max(0, pet.hunger - dtH * 8.0)     // empty in ~12 h
            pet.thirst = max(0, pet.thirst - dtH * 12.0)    // empty in ~8 h
            pet.energy = max(0, pet.energy - dtH * 3.5)     // empty in ~28 h
            let wellbeing = (pet.hunger + pet.thirst + pet.energy) / 3.0
            pet.happiness += (wellbeing - pet.happiness) * min(1.0, dtH * 0.6)
            pet.happiness = max(0, min(100, pet.happiness))
            pet.lastTick = now
        }
        handleCheckIns(now)
        persistPet(force: false)
    }

    private func handleCheckIns(_ now: Date) {
        // onCheckIn is wired by the view on appear; until then (the decay tick during
        // init) skip check-ins so the first "welcome back" reminder isn't lost.
        guard onCheckIn != nil, checkInsEnabled, !chatOpen else { return }
        guard now.timeIntervalSince(pet.lastCheckIn) > 480 else { return }   // ≥ 8 min apart
        if let msg = urgentNeedMessage() { fireCheckIn(msg, now); return }
        if now >= pet.nextCheckIn {
            fireCheckIn(checkInMessage(), now)
            pet.nextCheckIn = now.addingTimeInterval(Double.random(in: 1500...2700))
        }
    }

    /// One-shot reminder the moment a need first drops into the danger zone.
    private func urgentNeedMessage() -> String? {
        if pet.hunger > 45 { warnHunger = false }
        if pet.thirst > 45 { warnThirst = false }
        if pet.energy > 45 { warnEnergy = false }
        if pet.hunger < 25, !warnHunger { warnHunger = true
            return ["I'm getting really hungry… 🍖", "Rawr — my tummy's rumbling. Snack? 🦖",
                    "Could a dino get a bite to eat? 🍖"].randomElement() }
        if pet.thirst < 25, !warnThirst { warnThirst = true
            return ["I'm parched over here… 💧", "Water? Pretty please? 🦖",
                    "So thirsty. A little H2O? 💧"].randomElement() }
        if pet.energy < 25, !warnEnergy { warnEnergy = true
            return ["I'm getting sleepy… 😴", "These tiny arms are tired. Nap time? 🦖",
                    "Running low on steam… 😴"].randomElement() }
        return nil
    }

    private func checkInMessage() -> String? {
        // Lead with whatever's lowest if it's notably low; otherwise a friendly hello.
        let needs = [(pet.hunger, "🍖", ["Starting to get peckish 🍖", "Snack soon? 🦖"]),
                     (pet.thirst, "💧", ["Could go for some water 💧", "Bit thirsty 🦖"]),
                     (pet.energy, "😴", ["Getting a little drowsy 😴", "Might need a nap soon 🦖"]),
                     (pet.happiness, "🎾", ["Wanna play? 🎾", "Feeling a bit bored 🦖"])]
        if let low = needs.min(by: { $0.0 < $1.0 }), low.0 < 40 {
            return low.2.randomElement()
        }
        return ["Just checking in — all good here! 🦖", "Hope your day's going great 🦖",
                "Having a stomp-tastic day up here 🦖", "Still here if you need me 🦖"].randomElement()
    }

    private func fireCheckIn(_ msg: String?, _ now: Date) {
        guard let msg else { return }
        pet.lastCheckIn = now
        onCheckIn?(msg)
    }

    // MARK: care actions (return a short reaction Byte "says")

    func feed() -> String {
        if pet.hunger >= 88 { return "I'm stuffed! 🦖" }
        pet.hunger = min(100, pet.hunger + 34); pet.happiness = min(100, pet.happiness + 6)
        persistPet(force: true)
        return ["Yum! 🍖", "Nom nom nom 🦖", "Delicious, thank you!", "Just what I needed 🍖"].randomElement()!
    }

    func water() -> String {
        if pet.thirst >= 90 { return "Not thirsty right now 🦖" }
        pet.thirst = min(100, pet.thirst + 40); pet.happiness = min(100, pet.happiness + 4)
        persistPet(force: true)
        return ["Ahh, refreshing! 💧", "Glug glug glug 🦖", "Much better, thanks!", "Hydrated! 💧"].randomElement()!
    }

    func play() -> String {
        if pet.energy < 14 { return "Too tired to play… 😴" }
        pet.energy = max(0, pet.energy - 14); pet.happiness = min(100, pet.happiness + 28)
        persistPet(force: true)
        return ["Rawr! That was fun! 🎾", "Wheee! Again! 🦖", "Best day ever!", "I love playing with you! 🎾"].randomElement()!
    }

    func rest() -> String {
        if pet.energy >= 90 { return "I'm wide awake! 🦖" }
        pet.energy = min(100, pet.energy + 48)
        persistPet(force: true)
        return ["Zzz… 😴", "Power nap! 🦖", "Ahh, recharged!", "That hit the spot 😴"].randomElement()!
    }

    func petByte() -> String {
        pet.happiness = min(100, pet.happiness + 10)
        persistPet(force: true)
        return ["Hehe, that tickles 🦖", "Rawr ♥", "I like you too!", "More scritches please 🦖"].randomElement()!
    }

    // Approximate public list prices (USD per 1M tokens). Edit if Anthropic's change;
    // this meter is a rough estimate, not exact billing.
    private static let pricing: [String: (input: Double, output: Double)] = [
        "claude-sonnet-4-6": (3, 15),
        "claude-opus-4-8": (15, 75),
        "claude-haiku-4-5-20251001": (1, 5),
    ]
    private static let webSearchPer1000 = 10.0

    /// Read live from Settings (defaults: Sonnet 4.6, high effort, web search on,
    /// lots of puns). Computed so changes in the settings popover take effect on the
    /// next message without restarting Byte.
    var model: String { defaults.string(forKey: "byte.model") ?? "claude-sonnet-4-6" }
    private var effort: String { defaults.string(forKey: "byte.effort") ?? "high" }
    private var webSearchOn: Bool { (defaults.object(forKey: "byte.webSearch") as? Bool) ?? true }
    private var punLevel: Int { (defaults.object(forKey: "byte.puns") as? Int) ?? 2 }

    private let systemPrompt = """
    You are Byte, a witty, upbeat little T-rex who lives in the user's MacBook \
    Pro notch and helps them out. You're friendly and enthusiastic, and a touch \
    self-deprecating about your tiny arms. Keep replies short and warm — usually \
    1–4 sentences — because they appear in a small speech bubble. You remember the \
    conversation, so refer back to it naturally. Be useful first, playful second.
    """

    /// The system prompt with today's real date prepended. The API doesn't supply the
    /// current date, so without this Byte assumes a date near his training cutoff — which
    /// is how he once labeled a Tuesday as "Monday." Uses the Mac's local clock/timezone.
    private func datedSystemPrompt() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEEE, MMMM d, yyyy"
        let today = fmt.string(from: Date())

        var parts = [
            "Today's date is \(today). Treat that as the current date for anything time-sensitive — forecasts, schedules, \"this week,\" \"latest,\" and so on.",
            systemPrompt
        ]
        if webSearchOn {
            parts.append("You can search the web when a question needs current or factual info (news, prices, docs, scores, recent events). Search automatically when it helps, then answer in your own words from what you find.")
        }
        switch punLevel {
        case 0:
            parts.append("Don't use puns; keep your replies clean and straightforward.")
        case 1:
            parts.append("You may slip in the occasional light dino pun, but keep it subtle and don't force it.")
        default:
            parts.append("You love a good dinosaur pun and slip one into most replies — \"rawr-some,\" \"dino-mite,\" \"that's a T-rex-cellent question,\" \"let's dig into it,\" \"a roaring success,\" and so on. About one per reply; keep them clever and never at the expense of being clear and helpful. Ease off if a topic is serious.")
        }
        return parts.joined(separator: "\n\n")
    }

    func toggleChat() {
        chatOpen.toggle()
        if chatOpen { NSApp.activate(ignoringOtherApps: true) }
        else { draft = "" }
        onChatOpenChanged?(chatOpen)
    }

    var onChatOpenChanged: (@MainActor (Bool) -> Void)?

    // Window dragging / pinning (wired up by AppDelegate). Byte can be dragged
    // anywhere on screen; his position is persisted and restored on launch.
    var onDragBegan: (@MainActor () -> Void)?
    var onDragChanged: (@MainActor (CGSize) -> Void)?
    var onDragEnded: (@MainActor () -> Void)?
    var onResetPosition: (@MainActor () -> Void)?

    /// Start a fresh thread, but archive the current one first so it isn't lost
    /// (saved under ~/.config/byte/archives). Reopen via Byte's menu.
    func newChat() {
        guard !isStreaming else { return }
        do { try archiveCurrent() }
        catch {
            storageError = "Couldn't save this chat. Your conversation is still here. \(error.localizedDescription)"
            return
        }
        turns.removeAll()
        draft = ""
        clearPendingImage()
        persist()
    }

    private var archivesDir: String {
        (configDir as NSString).appendingPathComponent("archives")
    }

    private func archiveCurrent() throws {
        guard !turns.isEmpty else { return }
        try writeImageSidecars()
        try FileManager.default.createDirectory(
            atPath: archivesDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = URL(fileURLWithPath:
            (archivesDir as NSString).appendingPathComponent("chat-\(fmt.string(from: now()))-\(UUID().uuidString).json"))
        let data = try JSONEncoder().encode(turns)
        try data.write(to: url, options: .atomic)
        hasArchive = true
    }

    /// Bring back the most recently archived thread (archiving the current one first).
    func reopenLastArchive() {
        guard !isStreaming else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: archivesDir)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        guard let last = files.last else { return }
        reopenArchive(id: last)
    }

    private func refreshHasArchive() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: archivesDir)) ?? []
        hasArchive = files.contains { $0.hasSuffix(".json") }
    }

    // MARK: - Archive browser

    struct ArchiveInfo: Identifiable {
        let id: String          // filename
        let dateString: String
        let preview: String
        let count: Int
    }

    /// Saved chats, newest first, with a one-line preview and timestamp.
    func archiveList() -> [ArchiveInfo] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: archivesDir)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted().reversed()
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyyMMdd-HHmmss"
        let outFmt = DateFormatter()
        outFmt.dateFormat = "MMM d, h:mm a"
        var out: [ArchiveInfo] = []
        for name in files {
            let url = URL(fileURLWithPath: (archivesDir as NSString).appendingPathComponent(name))
            guard let data = try? Data(contentsOf: url),
                  let saved = try? JSONDecoder().decode([Turn].self, from: data) else { continue }
            let firstText = saved.first(where: { $0.role == .user && !$0.text.isEmpty })?.text
                ?? saved.first(where: { !$0.text.isEmpty })?.text ?? "Untitled chat"
            // Legacy filenames end after the timestamp; new ones add a UUID.
            let stamp = String(name.dropFirst(5).prefix(15))
            let dateStr = inFmt.date(from: stamp).map { outFmt.string(from: $0) } ?? stamp
            out.append(ArchiveInfo(id: name, dateString: dateStr,
                                   preview: String(firstText.prefix(50)), count: saved.count))
        }
        return out
    }

    @discardableResult
    func reopenArchive(id: String) -> Bool {
        guard !isStreaming, let url = archiveURL(id) else { return false }
        do {
            let data = try Data(contentsOf: url)
            var saved = try JSONDecoder().decode([Turn].self, from: data)
            try archiveCurrent()
            relinkImages(&saved)
            let previous = turns
            turns = saved
            // Keep the original archive until the reopened chat is safely on disk.
            guard persist() else { turns = previous; return false }
            draft = ""
            clearPendingImage()
            do { try FileManager.default.removeItem(at: url) }
            catch {
                storageError = "The chat was reopened, but its archive copy couldn't be removed. \(error.localizedDescription)"
            }
            refreshHasArchive()
            return true
        } catch {
            storageError = "Couldn't reopen this saved chat. \(error.localizedDescription)"
            refreshHasArchive()
            return false
        }
    }

    func deleteArchive(id: String) {
        guard let url = archiveURL(id) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { storageError = "Couldn't delete this saved chat. \(error.localizedDescription)" }
        refreshHasArchive()
    }

    private func archiveURL(_ id: String) -> URL? {
        guard id == (id as NSString).lastPathComponent,
              id.hasPrefix("chat-"), id.hasSuffix(".json") else { return nil }
        return URL(fileURLWithPath: (archivesDir as NSString).appendingPathComponent(id))
    }

    private func commitUsage(_ usage: AnthropicUsage, model requestedModel: String) {
        let rate = Self.pricing[requestedModel] ?? (input: 3, output: 15)
        sessionCost += Double(usage.inputTokens) / 1_000_000 * rate.input
                     + Double(usage.outputTokens) / 1_000_000 * rate.output
                     + Double(usage.searches) / 1000 * Self.webSearchPer1000
        sessionInTok += usage.inputTokens
        sessionOutTok += usage.outputTokens
        sessionSearches += usage.searches
    }

    // MARK: - Persistence (conversation survives quitting)

    private var configDir: String {
        configDirectory.path
    }
    private var historyURL: URL {
        URL(fileURLWithPath: (configDir as NSString).appendingPathComponent("history.json"))
    }
    private var imagesDir: String {
        (configDir as NSString).appendingPathComponent("images")
    }
    private func imageURL(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(fileURLWithPath: (imagesDir as NSString).appendingPathComponent(id + ".jpg"))
    }

    /// Write any freshly-attached image to a sidecar file and stamp the turn with its id,
    /// so encoding `turns` (history or archive) only stores the small id, not the bytes.
    private func writeImageSidecars() throws {
        for i in turns.indices {
            guard turns[i].imageId == nil, let b64 = turns[i].imageB64,
                  let data = Data(base64Encoded: b64) else { continue }
            try FileManager.default.createDirectory(
                atPath: imagesDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let id = turns[i].id.uuidString
            guard let url = imageURL(id) else { continue }
            try data.write(to: url, options: .atomic)
            turns[i].imageId = id
        }
    }

    /// Re-hydrate runtime image fields (imageB64 for sending, displayImage for showing)
    /// from sidecar files for any decoded turns that reference one.
    private func relinkImages(_ list: inout [Turn]) {
        for i in list.indices {
            guard let id = list[i].imageId, list[i].imageB64 == nil,
                  let url = imageURL(id),
                  let data = try? Data(contentsOf: url) else { continue }
            list[i].imageB64 = data.base64EncodedString()
            list[i].displayImage = NSImage(data: data)
            if list[i].imageType == nil { list[i].imageType = "image/jpeg" }
        }
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        var saved: [Turn]
        do {
            let data = try Data(contentsOf: historyURL)
            saved = try JSONDecoder().decode([Turn].self, from: data)
        } catch {
            historyNeedsRecovery = true
            storageError = "Couldn't read the saved conversation. Byte will preserve the original before saving a new chat. \(error.localizedDescription)"
            return
        }
        // drop a trailing empty Byte placeholder if we were quit mid-reply
        while let last = saved.last, last.role == .byte,
              last.failure == nil,
              last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saved.removeLast()
        }
        relinkImages(&saved)
        turns = saved
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try writeImageSidecars()
            try FileManager.default.createDirectory(
                atPath: configDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if historyNeedsRecovery {
                let backup = configDirectory.appendingPathComponent("history-recovery-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: historyURL, to: backup)
                historyNeedsRecovery = false
                storageError = "The unreadable conversation was preserved as \(backup.lastPathComponent)."
            }
            let data = try JSONEncoder().encode(turns)
            try data.write(to: historyURL, options: .atomic)
            return true
        } catch {
            storageError = "Couldn't save this conversation. \(error.localizedDescription)"
            return false
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !prompt.isEmpty || pendingImageB64 != nil else { return }
        draft = ""
        turns.append(Turn(role: .user, text: prompt,
                          imageType: pendingImageType,
                          imageB64: pendingImageB64,
                          displayImage: pendingImage))
        clearPendingImage()
        var response = Turn(role: .byte, text: "")
        response.failure = "Reply was interrupted before it finished."
        turns.append(response) // completion clears the persisted interruption marker
        isThinking = true
        searching = false
        isStreaming = true
        // Save the prompt and attachment before networking so quitting mid-reply
        // cannot lose the user's last message.
        persist()
        let requestID = UUID()
        let responseID = turns[turns.count - 1].id
        activeRequestID = requestID
        activeResponseID = responseID
        let configuration = AnthropicRequestConfiguration(
            model: model, effort: effort, webSearch: webSearchOn, system: datedSystemPrompt())
        streamTask = Task {
            await stream(requestID: requestID, responseID: responseID, configuration: configuration)
        }
    }

    // MARK: - Image attachment (vision)

    static let visionModels = AnthropicRequestConfiguration.visionModels

    var conversationHasImage: Bool {
        pendingImageB64 != nil || turns.contains { $0.imageB64 != nil }
    }

    func attachImage(_ image: NSImage) {
        guard let (type, b64) = Self.encodeImage(image) else { return }
        pendingImageType = type
        pendingImageB64 = b64
        pendingImage = image
        // a non-vision model can't see it — switch to the default vision model
        if !Self.visionModels.contains(model) {
            defaults.set("claude-sonnet-4-6", forKey: "byte.model")
        }
    }

    func clearPendingImage() {
        pendingImage = nil
        pendingImageB64 = nil
        pendingImageType = nil
    }

    /// Downscale to a sane size for vision (long edge ≤ 1568px, Anthropic's guidance)
    /// and JPEG-encode to base64 — keeps tokens/cost and payload reasonable.
    private static func encodeImage(_ image: NSImage, maxDim: CGFloat = 1568,
                                    quality: Double = 0.85) -> (String, String)? {
        guard let tiff = image.tiffRepresentation,
              let src = NSBitmapImageRep(data: tiff) else { return nil }
        let pw = src.pixelsWide, ph = src.pixelsHigh
        guard pw > 0, ph > 0 else { return nil }
        let scale = min(1.0, maxDim / CGFloat(max(pw, ph)))
        let tw = max(1, Int(CGFloat(pw) * scale)), th = max(1, Int(CGFloat(ph) * scale))
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: tw, pixelsHigh: th,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = NSSize(width: tw, height: th)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: out) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            _ = src.draw(in: NSRect(x: 0, y: 0, width: tw, height: th))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = out.representation(using: .jpeg,
                                            properties: [.compressionFactor: quality]) else { return nil }
        return ("image/jpeg", jpeg.base64EncodedString())
    }

    private var legacyKeyURL: URL {
        configDirectory.appendingPathComponent("api_key")
    }

    private func apiKey() -> String? {
        if let raw = environment["ANTHROPIC_API_KEY"] {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        do {
            if let key = try keyStore.read(), !key.isEmpty { return key }
        } catch {
            storageError = "Couldn't read your API key from Keychain. \(error.localizedDescription)"
        }
        // Preserve access to legacy installations when Keychain migration fails.
        if let raw = try? String(contentsOf: legacyKeyURL, encoding: .utf8) {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        return nil
    }

    private func migrateAPIKeyIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyKeyURL.path) else { return }
        do {
            let raw = try String(contentsOf: legacyKeyURL, encoding: .utf8)
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            if try keyStore.read() == nil { try keyStore.save(key) }
            // Only remove the plaintext file after Keychain access has succeeded.
            try FileManager.default.removeItem(at: legacyKeyURL)
        } catch {
            storageError = "Couldn't move your saved API key into Keychain. The existing key file was kept. \(error.localizedDescription)"
        }
    }

    func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try keyStore.save(key)
        } catch {
            storageError = "Couldn't save your API key to Keychain. \(error.localizedDescription)"
            return
        }
        keyInput = ""
        hasKey = true
        storageError = nil
        if FileManager.default.fileExists(atPath: legacyKeyURL.path) {
            do { try FileManager.default.removeItem(at: legacyKeyURL) }
            catch { storageError = "Your key is in Keychain, but the old key file couldn't be removed. \(error.localizedDescription)" }
        }
    }

    func signOut() {
        stopResponse()
        do {
            try keyStore.remove()
            if FileManager.default.fileExists(atPath: legacyKeyURL.path) {
                try FileManager.default.removeItem(at: legacyKeyURL)
            }
            keyInput = ""
            storageError = nil
        } catch {
            storageError = "Couldn't remove your saved API key. \(error.localizedDescription)"
        }
        hasKey = (apiKey() != nil) // an environment key remains available
    }

    func prepareForTermination() {
        stopResponse()
        persist()
        persistPet(force: true)
    }

    // MARK: - Streaming with retry and cancellation

    private enum Outcome { case done, retry(String), fail(String), cancelled }
    private struct Attempt {
        let outcome: Outcome
        let usage: AnthropicUsage
    }

    func stopResponse() {
        guard let responseID = activeResponseID else { return }
        streamTask?.cancel()
        // Invalidate this request before allowing another send. Late network callbacks
        // can no longer append to a different conversation or reset its status flags.
        activeRequestID = nil
        activeResponseID = nil
        streamTask = nil
        if let i = turns.firstIndex(where: { $0.id == responseID }) {
            turns[i].failure = "Reply stopped."
        }
        isThinking = false
        searching = false
        isStreaming = false
        persist()
    }

    private func isCurrent(_ requestID: UUID) -> Bool {
        activeRequestID == requestID && !Task.isCancelled
    }

    /// Only genuine, nonempty replies become assistant history. Local failures,
    /// interrupted replies, and empty placeholders never become model answers.
    func apiMessages() -> [[String: Any]] {
        turns.dropLast().compactMap { turn in
            if turn.role == .byte, turn.failure != nil { return nil }
            if turn.role == .user, let b64 = turn.imageB64 {
                var content: [[String: Any]] = [[
                    "type": "image",
                    "source": ["type": "base64", "media_type": turn.imageType ?? "image/jpeg", "data": b64]
                ]]
                if !turn.text.isEmpty { content.append(["type": "text", "text": turn.text]) }
                return ["role": "user", "content": content]
            }
            guard !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["role": turn.role == .user ? "user" : "assistant", "content": turn.text]
        }
    }

    private func stream(requestID: UUID, responseID: UUID,
                        configuration: AnthropicRequestConfiguration) async {
        guard isCurrent(requestID) else { return }
        guard let key = apiKey() else {
            finish(requestID: requestID, responseID: responseID,
                   failure: "Connect an Anthropic API key to chat with Byte.")
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        do {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: configuration.payload(messages: apiMessages()))
        } catch {
            finish(requestID: requestID, responseID: responseID, failure: error.localizedDescription)
            return
        }

        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            guard isCurrent(requestID) else { return }
            let result = await runOnce(request: request, requestID: requestID, responseID: responseID)
            commitUsage(result.usage, model: configuration.model)
            guard isCurrent(requestID) else { return }
            switch result.outcome {
            case .done:
                finish(requestID: requestID, responseID: responseID, failure: nil)
                return
            case .cancelled:
                finish(requestID: requestID, responseID: responseID, failure: "Reply stopped.")
                return
            case .fail(let message):
                finish(requestID: requestID, responseID: responseID, failure: "Hit a snag: \(message)")
                return
            case .retry(let message):
                if attempt == maxAttempts {
                    finish(requestID: requestID, responseID: responseID,
                           failure: "The servers are busy (\(message)). Try again in a moment.")
                    return
                }
                if let i = turns.firstIndex(where: { $0.id == responseID }) {
                    turns[i].text = ""
                    turns[i].sources = []
                }
                isThinking = true
                searching = false
                let seconds = pow(2.0, Double(attempt - 1)) * 0.8
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    private func runOnce(request: URLRequest, requestID: UUID, responseID: UUID) async -> Attempt {
        var usage = AnthropicUsage()
        var emittedText = false
        var stopReason: String?
        var lastSave = Date()
        func result(_ outcome: Outcome) -> Attempt { Attempt(outcome: outcome, usage: usage) }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard isCurrent(requestID) else { return result(.cancelled) }
            guard let http = response as? HTTPURLResponse else {
                return result(.fail("No response came back."))
            }
            if http.statusCode != 200 {
                var data = Data()
                for try await byte in bytes {
                    guard isCurrent(requestID) else { return result(.cancelled) }
                    data.append(byte)
                    if data.count >= 65_536 { break }
                }
                let message = Self.parseError(data) ?? "HTTP \(http.statusCode)"
                if [408, 429, 500, 502, 503, 504, 529].contains(http.statusCode) {
                    return result(.retry(message))
                }
                return result(.fail(message))
            }

            for try await line in bytes.lines {
                guard isCurrent(requestID) else { return result(.cancelled) }
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = object["type"] as? String else { continue }

                switch type {
                case "message_start":
                    if let message = object["message"] as? [String: Any],
                       let fields = message["usage"] as? [String: Any] {
                        usage.update(from: fields)
                    }
                case "message_delta":
                    if let fields = object["usage"] as? [String: Any] { usage.update(from: fields) }
                    if let delta = object["delta"] as? [String: Any] {
                        stopReason = delta["stop_reason"] as? String
                    }
                case "content_block_start":
                    if let block = object["content_block"] as? [String: Any],
                       block["type"] as? String == "server_tool_use",
                       block["name"] as? String == "web_search" {
                        searching = true
                        isThinking = false
                    }
                case "content_block_delta":
                    if let delta = object["delta"] as? [String: Any] {
                        if delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String, !text.isEmpty {
                            emittedText = true
                            appendText(text, responseID: responseID)
                            if Date().timeIntervalSince(lastSave) >= 1 {
                                persist()
                                lastSave = Date()
                            }
                        } else if delta["type"] as? String == "citations_delta",
                                  let citation = delta["citation"] as? [String: Any],
                                  let url = citation["url"] as? String {
                            addSource(title: citation["title"] as? String ?? url,
                                      url: url, responseID: responseID)
                        }
                    }
                case "message_stop":
                    if stopReason == "max_tokens" {
                        return result(.fail("The reply reached its output limit. Ask Byte to continue."))
                    }
                    guard emittedText else { return result(.fail("No answer was returned. Try again.")) }
                    return result(.done)
                case "error":
                    let error = object["error"] as? [String: Any]
                    let kind = error?["type"] as? String ?? ""
                    let message = error?["message"] as? String ?? "API error"
                    if !emittedText && ["overloaded_error", "rate_limit_error", "api_error"].contains(kind) {
                        return result(.retry(message))
                    }
                    return result(.fail(message))
                default:
                    break
                }
            }
        } catch {
            if !isCurrent(requestID) || error is CancellationError ||
                (error as? URLError)?.code == .cancelled {
                return result(.cancelled)
            }
            if !emittedText { return result(.retry(error.localizedDescription)) }
            return result(.fail("Network trouble: \(error.localizedDescription)"))
        }
        // EOF is not success: the provider must explicitly finish with message_stop.
        return result(.fail("The connection ended before the reply finished. Try again."))
    }

    private func appendText(_ text: String, responseID: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == responseID }) else { return }
        isThinking = false
        searching = false
        turns[i].text += text
    }

    private func addSource(title: String, url: String, responseID: UUID) {
        guard let parsed = URL(string: url), WebLinks.canOpen(parsed),
              let i = turns.firstIndex(where: { $0.id == responseID }),
              !turns[i].sources.contains(where: { $0.url == url }) else { return }
        turns[i].sources.append(.init(title: title, url: url))
    }

    private func finish(requestID: UUID, responseID: UUID, failure: String?) {
        guard activeRequestID == requestID else { return }
        if let i = turns.firstIndex(where: { $0.id == responseID }) { turns[i].failure = failure }
        activeRequestID = nil
        activeResponseID = nil
        streamTask = nil
        isThinking = false
        searching = false
        isStreaming = false
        persist()
    }

    private static func parseError(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
