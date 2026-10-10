import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
struct ByteView: View {
    @ObservedObject var model: ByteModel

    // Idle + breach
    @State private var bob = false
    @State private var glowPulse = false
    @State private var breachOffset: CGFloat = 0
    @State private var breachScale: CGFloat = 1
    @State private var breachTilt: Double = 0
    @State private var swimX: CGFloat = 0
    @State private var isBusy = false
    @State private var lastMove = -1
    @State private var showHappy = false
    @AppStorage("byte.sounds") private var soundsOn = true
    @State private var rippleScale: CGFloat = 0.2
    @State private var rippleOpacity: Double = 0

    // Quip bubble (idle)
    @State private var quip: String? = nil
    @State private var quipID = 0

    @State private var hovering = false
    @State private var isDragging = false
    @State private var showCare = false
    // Care animations: a prop (mouse / lake / ball) animates around Byte.
    enum CareScene { case none, feed, water, play }
    @State private var careScene: CareScene = .none
    @State private var propX: CGFloat = 0
    @State private var propY: CGFloat = 0
    @State private var propScale: CGFloat = 1
    @State private var propOpacity: Double = 0
    @State private var propFlip = false
    // Hover action bar (quick feed/water/play without the big menu)
    @State private var showActions = false
    @State private var hoverBand = false
    @State private var hoverBar = false
    @State private var hideActionsTask: Task<Void, Never>? = nil
    @State private var dropTarget = false
    @FocusState private var inputFocused: Bool

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var secondsToNext = Int.random(in: 10...18)

    private let accent = Color(red: 0.80, green: 0.47, blue: 0.36)

    private var mood: ByteSprite.Mood {
        if model.isThinking || model.searching { return .thinking }
        if showHappy { return .happy }
        return model.pet.happiness >= 70 ? .happy : .neutral
    }

    /// A small thought-emoji that floats over Byte when a need is getting low.
    private var affectEmoji: String? {
        let p = model.pet
        if p.hunger < 28 { return "🍖" }
        if p.thirst < 28 { return "💧" }
        if p.energy < 25 { return "😴" }
        if p.happiness < 30 { return "🥺" }
        return nil
    }

    var body: some View {
        VStack(spacing: 4) {
            band
            bubbleArea
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTarget) { providers in
            handleDrop(providers)
        }
        .onAppear {
            startIdle()
            model.onCheckIn = { msg in checkIn(msg) }
        }
        .onReceive(tick) { _ in
            model.tickPet()                       // decay needs + maybe a check-in (continues during chat)
            guard !model.chatOpen else { return }
            secondsToNext -= 1
            if secondsToNext <= 0 {
                secondsToNext = Int.random(in: 9...17)
                randomMove()
            }
        }
        .onChange(of: model.chatOpen) { _, open in
            guard open else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                inputFocused = true
            }
        }
    }

    private var band: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.62, green: 0.82, blue: 0.50).opacity(glowPulse ? 0.30 : 0.15), .clear],
                                     center: .center, startRadius: 2, endRadius: 48))
                .frame(width: 130, height: 130)
                .offset(y: breachOffset)
                .blur(radius: 7)
                .allowsHitTesting(false)

            surface.offset(y: 32)

            Circle()
                .stroke(accent.opacity(rippleOpacity), lineWidth: 2)
                .frame(width: 54, height: 54)
                .scaleEffect(x: rippleScale, y: rippleScale * 0.4)
                .offset(y: 18)
                .allowsHitTesting(false)

            ByteSprite(scale: 0.72, mood: mood)
                .scaleEffect(breachScale)
                .rotationEffect(.degrees(breachTilt))
                .offset(x: swimX, y: (bob ? 2 : 0) + breachOffset)
                .shadow(color: .black.opacity(0.30), radius: 5, y: 2)
                .shadow(color: .white.opacity(0.12), radius: 3)
                .scaleEffect(hovering ? 1.06 : 1.0)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !isDragging { isDragging = true; model.onDragBegan?() }
                            model.onDragChanged?(v.translation)
                        }
                        .onEnded { v in
                            isDragging = false
                            let moved = (v.translation.width * v.translation.width
                                       + v.translation.height * v.translation.height).squareRoot()
                            if moved < 6 { poke() } else { model.onDragEnded?() }
                        }
                )
                .onHover { h in
                    withAnimation(.easeOut(duration: 0.2)) { hovering = h }
                }
                .contextMenu {
                    Button(model.chatOpen ? "Close chat" : "Ask Byte…") { model.toggleChat() }
                    Button("Do a trick ✨") { randomMove() }
                    Button("Care for Byte…") { NSApp.activate(ignoringOtherApps: true); showCare = true }
                    if model.hasArchive {
                        Divider()
                        Button("Reopen last chat") {
                            model.reopenLastArchive()
                            if !model.chatOpen { model.toggleChat() }
                        }
                    }
                    if model.hasConnection || (model.provider == .chatGPT && model.chatGPT.isSignedIn) {
                        Divider()
                        Button("Sign out") { model.signOut() }
                    }
                    Divider()
                    Button("Reset position to notch") { model.onResetPosition?() }
                    Button("Quit Byte") { NSApp.terminate(nil) }
                }
                .help("Hover for actions · click to chat · drag to move")
                .accessibilityLabel("Byte")
                .accessibilityHint("Opens or closes chat")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.toggleChat() }

            if careScene != .none {
                PropSprite(prop: careScene == .feed ? .mouse : (careScene == .water ? .water : .ball),
                           pixel: 2.0, flip: propFlip)
                    .scaleEffect(propScale)
                    .opacity(propOpacity)
                    .offset(x: propX, y: propY)
                    .allowsHitTesting(false)
            }

            if !model.chatOpen, let e = affectEmoji {
                Text(e)
                    .font(.system(size: 16))
                    .offset(y: -40 + breachOffset)
                    .opacity(glowPulse ? 1.0 : 0.5)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(height: 92)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hoverBand = $0; updateActions() }
        .overlay(alignment: .bottom) { actionBar }
        .popover(isPresented: $showCare, arrowEdge: .bottom) {
            CareView(model: model, accent: accent)
        }
    }

    // MARK: - Hover action bar

    private var actionBar: some View {
        HStack(spacing: 6) {
            actionButton(.mouse, "Feed") { doFeed() }
            actionButton(.water, "Give water") { doWater() }
            actionButton(.ball, "Play") { doPlay() }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(accent.opacity(0.30), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .opacity(showActions && !model.chatOpen && careScene == .none ? 1 : 0)
        .scaleEffect(showActions ? 1 : 0.85, anchor: .bottom)
        .allowsHitTesting(showActions && careScene == .none && !model.chatOpen)
        .onHover { hoverBar = $0; updateActions() }
        .offset(y: 8)
    }

    private func actionButton(_ prop: Prop, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PropSprite(prop: prop, pixel: 1.5)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Show the bar while the band or the bar is hovered; hide shortly after both clear.
    /// The hide task re-checks at fire time so crossing from band to bar never dismisses it.
    private func updateActions() {
        if model.chatOpen { hoverBand = false; hoverBar = false }
        if hoverBand || hoverBar {
            hideActionsTask?.cancel(); hideActionsTask = nil
            if !showActions { withAnimation(.easeOut(duration: 0.15)) { showActions = true } }
        } else {
            hideActionsTask?.cancel()
            hideActionsTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !hoverBand && !hoverBar {
                    withAnimation(.easeOut(duration: 0.2)) { showActions = false }
                }
            }
        }
    }

    @ViewBuilder private var bubbleArea: some View {
        if model.chatOpen {
            ChatPanel(model: model, focused: $inputFocused, accent: accent)
                .frame(width: 320)
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
        } else if let q = quip {
            SpeechBubble(text: q, accent: accent)
                .frame(width: 200)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.scale(scale: 0.7, anchor: .top).combined(with: .opacity))
                .id(quipID)
        }
    }

    private var surface: some View {
        Ellipse()
            .fill(RadialGradient(colors: [Color.black.opacity(0.26), Color.black.opacity(0.10), .clear],
                                 center: .center, startRadius: 1, endRadius: 46))
            .frame(width: 104, height: 22)
            .allowsHitTesting(false)
    }

    // MARK: behaviour

    private func startIdle() {
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bob = true }
        withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { glowPulse = true }
    }

    private func poke() {
        breach()
        model.toggleChat()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage else { return }
                Task { @MainActor in attach(img) }
            }
            return true
        }
        if p.canLoadObject(ofClass: NSURL.self) {
            _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                guard let nsurl = obj as? NSURL, let img = NSImage(contentsOf: nsurl as URL) else { return }
                Task { @MainActor in attach(img) }
            }
            return true
        }
        return false
    }

    private func attach(_ img: NSImage) {
        model.attachImage(img)
        if !model.chatOpen { model.toggleChat() }
    }

    // MARK: tricks

    /// Pick a random behaviour (skipping whatever ran last so it feels organic).
    private func randomMove() {
        guard !isBusy else { return }
        let moves: [() -> Void] = [breach, swim, spin, wiggle, nod, dive, greet]
        var i = Int.random(in: 0..<moves.count)
        if i == lastMove { i = (i + 1) % moves.count }
        lastMove = i
        moves[i]()
    }

    private func breach() {
        guard !isBusy else { return }
        isBusy = true
        withAnimation(.easeOut(duration: 0.36)) {
            breachOffset = -40; breachScale = 1.12; breachTilt = -8
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            withAnimation(.easeIn(duration: 0.5)) {
                breachOffset = 0; breachScale = 1.0; breachTilt = 0
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            puff()
            if soundsOn { SoundPlayer.shared.playStomp() }
            isBusy = false
        }
    }

    /// A quick dart to the side and back.
    private func swim() {
        guard !isBusy else { return }
        isBusy = true
        withAnimation(.easeInOut(duration: 0.34)) { swimX = -30; breachTilt = -5; breachOffset = -4 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 360_000_000)
            withAnimation(.easeInOut(duration: 0.3)) { swimX = 16; breachTilt = 3 }
            try? await Task.sleep(nanoseconds: 320_000_000)
            withAnimation(.easeOut(duration: 0.42)) { swimX = 0; breachTilt = 0; breachOffset = 0 }
            try? await Task.sleep(nanoseconds: 440_000_000)
            isBusy = false
        }
    }

    /// A playful barrel roll.
    private func spin() {
        guard !isBusy else { return }
        isBusy = true
        withAnimation(.easeInOut(duration: 0.7)) { breachTilt = 360; breachScale = 1.08 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            breachTilt = 0                                   // 360° == 0°, so this is seamless
            withAnimation(.easeOut(duration: 0.25)) { breachScale = 1.0 }
            try? await Task.sleep(nanoseconds: 260_000_000)
            isBusy = false
        }
    }

    /// A happy side-to-side wiggle.
    private func wiggle() {
        guard !isBusy else { return }
        isBusy = true
        showHappy = true
        let seq: [(Double, UInt64)] = [(9, 120), (-9, 120), (6, 120), (-4, 100), (0, 130)]
        Task { @MainActor in
            for (t, d) in seq {
                withAnimation(.easeInOut(duration: Double(d) / 1000)) { breachTilt = t }
                try? await Task.sleep(nanoseconds: d * 1_000_000)
            }
            showHappy = false
            isBusy = false
        }
    }

    /// A small, friendly nod.
    private func nod() {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.18)) { breachOffset = 7; breachTilt = 4 }
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeInOut(duration: 0.18)) { breachOffset = -2; breachTilt = -1 }
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeOut(duration: 0.2)) { breachOffset = 0; breachTilt = 0 }
            try? await Task.sleep(nanoseconds: 220_000_000)
            isBusy = false
        }
    }

    /// Crouch down and pop back up.
    private func dive() {
        guard !isBusy else { return }
        isBusy = true
        withAnimation(.easeIn(duration: 0.34)) { breachOffset = 26; breachScale = 0.9; breachTilt = 6 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 360_000_000)
            puff()
            if soundsOn { SoundPlayer.shared.playStomp() }
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(.easeOut(duration: 0.5)) { breachOffset = 0; breachScale = 1.0; breachTilt = 0 }
            try? await Task.sleep(nanoseconds: 520_000_000)
            isBusy = false
        }
    }

    /// A cheerful greeting: a happy quip with a little nod.
    private func greet() {
        guard !isBusy else { return }
        isBusy = true
        showHappy = true
        if !model.chatOpen { say(Quips.random()) }
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.18)) { breachOffset = 7; breachTilt = 4 }
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.easeInOut(duration: 0.2)) { breachOffset = 0; breachTilt = 0 }
            try? await Task.sleep(nanoseconds: 280_000_000)
            showHappy = false
            isBusy = false
        }
    }

    private func puff() {
        rippleScale = 0.2; rippleOpacity = 0.85
        withAnimation(.easeOut(duration: 0.6)) { rippleScale = 1.6; rippleOpacity = 0.0 }
    }

    // MARK: - Animated care actions
    // Each summons a pixel-art prop, animates Byte interacting with it, then applies
    // the stat change at the payoff. Guarded by isBusy so they don't overlap tricks.

    private func doFeed() {
        guard !isBusy, !model.chatOpen else { return }
        if model.pet.hunger >= 88 { say(model.feed()); return }   // already stuffed — no mouse
        isBusy = true; careScene = .feed
        let fromLeft = Bool.random()
        propFlip = !fromLeft                       // mouse art faces right; flip if entering from the right
        propY = 24; propScale = 1; propOpacity = 1
        propX = fromLeft ? -112 : 112
        let mouthX: CGFloat = -24                   // just in front of Byte's snout
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.85)) { propX = mouthX }   // scurry in
            try? await Task.sleep(nanoseconds: 850_000_000)
            withAnimation(.easeIn(duration: 0.14)) { breachOffset = 12; breachTilt = -10; breachScale = 1.05 }  // chomp
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(.easeOut(duration: 0.12)) { propOpacity = 0; propScale = 0.4 }   // gulp
            let reaction = model.feed()
            withAnimation(.easeOut(duration: 0.32)) { breachOffset = 0; breachTilt = 0; breachScale = 1 }
            withAnimation { showHappy = true }
            say(reaction)
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation { showHappy = false }
            careScene = .none; isBusy = false
        }
    }

    private func doWater() {
        guard !isBusy, !model.chatOpen else { return }
        if model.pet.thirst >= 90 { say(model.water()); return }
        isBusy = true; careScene = .water
        propFlip = false; propX = -6; propY = 30
        propScale = 0.3; propOpacity = 0
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.30)) { propScale = 1; propOpacity = 1 }   // lake rises
            try? await Task.sleep(nanoseconds: 320_000_000)
            for _ in 0..<3 {                                                              // sip a few times
                withAnimation(.easeInOut(duration: 0.20)) { breachOffset = 12; breachTilt = -6 }
                try? await Task.sleep(nanoseconds: 220_000_000)
                withAnimation(.easeInOut(duration: 0.18)) { breachOffset = 2; breachTilt = -1 }
                try? await Task.sleep(nanoseconds: 190_000_000)
            }
            withAnimation(.easeOut(duration: 0.25)) { breachOffset = 0; breachTilt = 0 }
            let reaction = model.water()
            withAnimation(.easeIn(duration: 0.45)) { propOpacity = 0; propScale = 0.85 }   // lake recedes
            withAnimation { showHappy = true }
            say(reaction)
            try? await Task.sleep(nanoseconds: 650_000_000)
            withAnimation { showHappy = false }
            careScene = .none; isBusy = false
        }
    }

    private func doPlay() {
        guard !isBusy, !model.chatOpen else { return }
        if model.pet.energy < 14 { say(model.play()); return }
        isBusy = true; careScene = .play
        propFlip = false; propOpacity = 1; propScale = 1
        propX = -55; propY = -8
        Task { @MainActor in
            for i in 0..<3 {                                       // ball bounces; Byte hops to meet it
                let up = (i % 2 == 0)
                withAnimation(.easeOut(duration: 0.24)) {
                    propX = up ? -32 : -48
                    propY = up ? -30 : 22
                }
                if up {
                    withAnimation(.easeOut(duration: 0.18)) { breachOffset = -20; breachScale = 1.05 }
                } else {
                    withAnimation(.easeIn(duration: 0.18)) { breachOffset = 0; breachScale = 1 }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            withAnimation(.easeOut(duration: 0.30)) { breachOffset = 0; breachScale = 1 }
            withAnimation(.easeIn(duration: 0.40)) { propX = -120; propY = 28; propOpacity = 0 }  // rolls off
            let reaction = model.play()
            withAnimation { showHappy = true }
            say(reaction)
            try? await Task.sleep(nanoseconds: 550_000_000)
            withAnimation { showHappy = false }
            careScene = .none; isBusy = false
        }
    }

    /// Byte speaking up on his own (need reminders / friendly hellos).
    private func checkIn(_ text: String) {
        guard !model.chatOpen else { return }
        if !isBusy { greet() }
        say(text)
    }

    private func say(_ text: String) {
        guard !model.chatOpen else { return }
        quipID += 1
        let id = quipID
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { quip = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if quipID == id {
                withAnimation(.easeIn(duration: 0.3)) { quip = nil }
            }
        }
    }
}

@MainActor
struct ChatPanel: View {
    @ObservedObject var model: ByteModel
    var focused: FocusState<Bool>.Binding
    let accent: Color

    @State private var dots = ""
    @State private var showSettings = false
    @State private var showArchives = false
    private let dotTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let error = model.storageError {
                HStack(alignment: .top, spacing: 6) {
                    Text(error)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { model.storageError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss save error")
                }
            }
            if let error = model.connectionError ?? (model.provider == .chatGPT ? model.chatGPT.error : nil) {
                Text(error)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasConnection {
                transcript
                if model.pendingImage != nil { pendingImageChip }
                inputBar
                if model.provider == .chatGPT {
                    HStack {
                        Text(model.chatGPTUsageBlocked ? "ChatGPT usage limit reached" :
                             model.isLoadingModels ? "Loading your models…" : "Using ChatGPT plan")
                        Spacer()
                        Link("Manage usage", destination: ChatGPTAuth.usageURL)
                        if model.chatGPTUsageBlocked {
                            Button("Try again") { model.retryChatGPTPlanUsage() }
                                .buttonStyle(.plain)
                        }
                    }
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                }
                if model.sessionInTok + model.sessionOutTok > 0 { costFooter }
            } else {
                signIn
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(accent.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .environment(\.openURL, OpenURLAction { url in
            WebLinks.canOpen(url) ? .systemAction : .discarded
        })
        .onPasteCommand(of: [.image]) { providers in
            guard let p = providers.first, p.canLoadObject(ofClass: NSImage.self) else { return }
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage else { return }
                Task { @MainActor in model.attachImage(img) }
            }
        }
        .onReceive(dotTimer) { _ in
            guard model.isThinking || model.searching else { if !dots.isEmpty { dots = "" }; return }
            dots = dots.count >= 3 ? "" : dots + "."
        }
        .alert("You're using your ChatGPT plan", isPresented: Binding(
            get: { model.chatGPT.showPlanWelcome }, set: { model.chatGPT.showPlanWelcome = $0 })) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Eligible AI requests in Byte use your ChatGPT plan or available credits. Review usage and set Byte's limits in ChatGPT settings.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Byte 🦖").font(.system(size: 11, weight: .semibold, design: .rounded))
            Spacer()
            Text(model.model).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Settings")
                .accessibilityLabel("Settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsView(byte: model)
                }
            if model.hasArchive {
                Button { showArchives.toggle() } label: { Image(systemName: "tray.full") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Saved chats")
                    .accessibilityLabel("Saved chats")
                    .popover(isPresented: $showArchives, arrowEdge: .bottom) {
                        ArchivesView(model: model, accent: accent) { showArchives = false }
                    }
            }
            if !model.turns.isEmpty {
                Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("New chat (current one is saved)")
                    .accessibilityLabel("New chat")
                    .disabled(model.isStreaming)
            }
            Button { model.toggleChat() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Close chat")
        }
    }

    private var signIn: some View {
        ConnectionView(model: model)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.turns.isEmpty {
                        Text("Ask me anything — I'll keep it short, and I'll remember the thread 🦖")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.turns) { turn in
                        bubble(for: turn).id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 240)
            .onChange(of: model.turns.last?.text) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.turns.count) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func bubble(for turn: ByteModel.Turn) -> some View {
        let isUser = turn.role == .user
        let isLast = turn.id == model.turns.last?.id
        let showThinking = !isUser && turn.text.isEmpty && (model.isThinking || model.searching)
        let statusLabel = model.searching ? "🔍 digging…" : "thinking"
        let showCursor = !isUser && model.isStreaming && isLast && !turn.text.isEmpty
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 28) }
            Group {
                if isUser {
                    VStack(alignment: .trailing, spacing: 5) {
                        if let img = turn.displayImage {
                            Image(nsImage: img)
                                .resizable().scaledToFit()
                                .frame(maxWidth: 180, maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        if !turn.text.isEmpty {
                            Text(turn.text)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                        }
                    }
                } else if showThinking {
                    Text("\(statusLabel)\(dots)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        MarkdownText(text: turn.text + (showCursor ? " ▌" : ""))
                        if !turn.sources.isEmpty {
                            SourcesView(sources: turn.sources, accent: accent)
                        }
                        if let failure = turn.failure, !model.isStreaming || !isLast {
                            Text(failure)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isUser ? accent : Color.primary.opacity(0.08))
            )
            .frame(maxWidth: 236, alignment: isUser ? .trailing : .leading)
            .contextMenu { if !turn.text.isEmpty { Button("Copy") { copyText(turn.text) } } }
            if !isUser { Spacer(minLength: 28) }
        }
    }

    private func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            Button { pasteImage() } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Paste an image from the clipboard")
            .accessibilityLabel("Paste image")
            .disabled(model.isStreaming)
            TextField("Ask Byte…", text: $model.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .focused(focused)
                .onSubmit { model.send() }
                .disabled(model.isStreaming)
            if model.isStreaming {
                Button { model.stopResponse() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .help("Stop reply")
                .accessibilityLabel("Stop reply")
            } else {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? accent : Color.secondary)
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    private func pasteImage() {
        if let img = NSImage(pasteboard: .general) { model.attachImage(img) }
    }

    private var canSend: Bool {
        model.canSend && !model.isStreaming &&
        (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pendingImageB64 != nil)
    }

    private var pendingImageChip: some View {
        HStack(spacing: 8) {
            if let img = model.pendingImage {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text("Image attached — ask away")
                .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            Spacer()
            Button { model.clearPendingImage() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Remove attached image")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private var costFooter: some View {
        let toks = model.sessionInTok + model.sessionOutTok
        return HStack(spacing: 4) {
            if model.provider == .anthropic {
                Text("≈ \(costString(model.sessionCost))")
                Text("·").foregroundStyle(.tertiary)
            }
            Text("\(tokString(toks)) tokens")
            if model.sessionSearches > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(model.sessionSearches) search\(model.sessionSearches == 1 ? "" : "es")")
            }
            Spacer()
            Text("this session").foregroundStyle(.tertiary)
        }
        .font(.system(size: 9, design: .rounded))
        .foregroundStyle(.secondary)
        .help(model.provider == .chatGPT ? "Token usage reported this session. Review plan and credit usage in ChatGPT settings."
              : "Estimated from token usage at approximate list prices — not exact billing.")
        .padding(.horizontal, 2)
    }

    private func costString(_ c: Double) -> String {
        c < 0.1 ? String(format: "$%.4f", c) : String(format: "$%.2f", c)
    }
    private func tokString(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

struct SpeechBubble: View {
    let text: String
    let accent: Color

    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(.ultraThinMaterial)
                .frame(width: 14, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(accent.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Lightweight markdown rendering

private enum MDBlock {
    case paragraph(String)
    case heading(Int, String)
    case bullets([String])
    case ordered([String])
    case code(String?, String)
}

/// Renders a useful subset of markdown — paragraphs (with **bold**, *italic*,
/// `inline code`, links), headings, bullet/numbered lists, and fenced code blocks
/// (monospaced, scrollable, with a copy button). Enough for Claude's replies in a
/// small bubble without pulling in a dependency.
@MainActor
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks().enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MDBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inline(s))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let s):
            Text(inline(s))
                .font(.system(size: level <= 1 ? 15 : (level == 2 ? 13 : 12),
                              weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                        Text(inline(items[i]))
                            .font(.system(size: 12, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1).").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                        Text(inline(items[i]))
                            .font(.system(size: 12, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .code(let lang, let code):
            CodeBlock(lang: lang, code: code)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        guard var a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(s)
        }
        let codeRanges = a.runs.compactMap {
            ($0.inlinePresentationIntent?.contains(.code) == true) ? $0.range : nil
        }
        for r in codeRanges { a[r].font = .system(size: 12, design: .monospaced) }
        return a
    }

    private func blocks() -> [MDBlock] {
        var out: [MDBlock] = []
        let lines = text.components(separatedBy: "\n")
        var para: [String] = [], bullets: [String] = [], ordered: [String] = []
        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushBullets() { if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] } }
        func flushOrdered() { if !ordered.isEmpty { out.append(.ordered(ordered)); ordered = [] } }
        func flushAll() { flushPara(); flushBullets(); flushOrdered() }

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushAll()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1
                out.append(.code(lang.isEmpty ? nil : lang, code.joined(separator: "\n")))
                continue
            }
            if line.isEmpty { flushAll(); i += 1; continue }
            if line.hasPrefix("#") {
                flushAll()
                var lvl = 0
                var idx = line.startIndex
                while idx < line.endIndex, line[idx] == "#", lvl < 6 {
                    lvl += 1; idx = line.index(after: idx)
                }
                out.append(.heading(lvl, String(line[idx...]).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushPara(); flushOrdered()
                bullets.append(String(line.dropFirst(2)))
                i += 1; continue
            }
            if let r = line.range(of: "^[0-9]+\\.\\s", options: .regularExpression) {
                flushPara(); flushBullets()
                ordered.append(String(line[r.upperBound...]))
                i += 1; continue
            }
            flushBullets(); flushOrdered()
            para.append(line)
            i += 1
        }
        flushAll()
        return out
    }
}

@MainActor
struct CodeBlock: View {
    let lang: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang ?? "code")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .help("Copy code")
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.30)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Care panel (Byte's needs + feed/water/play/rest)

@MainActor
struct CareView: View {
    @ObservedObject var model: ByteModel
    let accent: Color
    @State private var reaction: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Byte's needs")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text(model.petAgeDays == 0 ? "newly hatched" : "\(model.petAgeDays)d old")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            NeedBar(label: "Hunger",    emoji: "🍖", value: model.pet.hunger)
            NeedBar(label: "Thirst",    emoji: "💧", value: model.pet.thirst)
            NeedBar(label: "Energy",    emoji: "😴", value: model.pet.energy)
            NeedBar(label: "Happiness", emoji: "❤️", value: model.pet.happiness)

            HStack(spacing: 7) {
                careButton("Feed",  "🍖") { model.feed() }
                careButton("Water", "💧") { model.water() }
                careButton("Play",  "🎾") { model.play() }
                careButton("Rest",  "😴") { model.rest() }
            }

            Text(reaction ?? " ")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(.easeInOut(duration: 0.2), value: reaction)
        }
        .padding(14)
        .frame(width: 252)
    }

    private func careButton(_ label: String, _ emoji: String,
                            _ action: @escaping () -> String) -> some View {
        Button {
            withAnimation { reaction = action() }
        } label: {
            VStack(spacing: 3) {
                Text(emoji).font(.system(size: 19))
                Text(label).font(.system(size: 9, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(accent.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct NeedBar: View {
    let label: String
    let emoji: String
    let value: Double

    private var color: Color {
        value > 55 ? Color(red: 0.32, green: 0.72, blue: 0.42)
        : (value > 28 ? Color(red: 0.90, green: 0.62, blue: 0.22)
                      : Color(red: 0.86, green: 0.34, blue: 0.34))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(emoji) \(label)").font(.system(size: 10))
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * CGFloat(value) / 100))
                        .animation(.easeOut(duration: 0.25), value: value)
                }
            }
            .frame(height: 7)
        }
    }
}

// MARK: - Settings (popover from the chat header)

@MainActor
struct ConnectionView: View {
    @ObservedObject var model: ByteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("AI connection", selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })) {
                ForEach(ByteModel.AIProvider.allCases, id: \.self) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .disabled(model.isStreaming || model.isConnecting)
            if model.provider == .chatGPT {
                Text("Use your ChatGPT plan")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("Eligible Plus and Pro users can use their plan or credits in Byte. Sign in securely in your browser; credentials stay in your Mac's Keychain.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.chatGPT.accounts.isEmpty {
                    Picker("Account", selection: Binding(
                        get: { model.chatGPT.activeClientID ?? "" },
                        set: { model.selectChatGPTAccount($0) })) {
                        ForEach(model.chatGPT.accounts) { account in
                            Text(account.label).tag(account.clientID)
                        }
                    }
                    .disabled(model.isStreaming || model.isConnecting || model.chatGPT.needsCredentialSave)
                }
                if model.chatGPT.needsCredentialSave {
                    Button("Retry Keychain save") { model.retryChatGPTCredentialSave() }
                        .disabled(model.isStreaming || model.isConnecting)
                }
                if model.isConnecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                        if model.chatGPT.isSigningIn { Button("Cancel") { model.cancelChatGPTSignIn() } }
                    }
                } else {
                    Button("Continue with ChatGPT") { model.signInChatGPT() }
                        .disabled(model.isStreaming || model.chatGPT.needsCredentialSave)
                    if !model.chatGPT.accounts.isEmpty {
                        Button("Add ChatGPT account") { model.signInChatGPT(addAccount: true) }
                            .disabled(model.isStreaming || model.chatGPT.needsCredentialSave)
                    }
                }
                HStack {
                    Link("Manage usage", destination: ChatGPTAuth.usageURL)
                    Spacer()
                    if model.chatGPT.isSignedIn {
                        Button("Sign out") { model.signOut() }
                            .disabled(model.isConnecting)
                    }
                }
            } else {
                Text(model.hasKey ? "Claude API key connected" : "Connect your Anthropic API key")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("Claude API usage uses your Anthropic account's API billing or eligible credits. Claude subscription sign-in for Byte requires Anthropic approval.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("sk-ant-…", text: $model.keyInput)
                    .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                    .padding(7).background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
                    .onSubmit { model.saveKey() }
                HStack {
                    Link("Get a key ↗", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    Spacer()
                    Button("Save") { model.saveKey() }
                        .disabled(model.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.hasKey { Button("Remove key") { model.signOut() } }
                }
                .disabled(model.isStreaming)
            }
        }
        .font(.system(size: 11, design: .rounded))
        .controlSize(.small)
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var byte: ByteModel
    @AppStorage("byte.webSearch") private var webSearch = true
    @AppStorage("byte.sounds") private var sounds = true
    @AppStorage("byte.checkins") private var checkins = true
    @AppStorage("byte.puns") private var puns = 2
    @AppStorage("byte.model") private var model = "claude-sonnet-4-6"
    @AppStorage("byte.effort") private var effort = "high"
    @State private var launchAtLogin = SettingsView.loginIsOn

    private static var loginIsOn: Bool {
        let s = SMAppService.mainApp.status
        return s == .enabled || s == .requiresApproval
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Byte settings")
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            ConnectionView(model: byte)
            Divider()

            Toggle("Web search", isOn: $webSearch)
            Toggle("Sound effects", isOn: $sounds)
            Toggle("Random check-ins", isOn: $checkins)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, want in
                    do {
                        if want {
                            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                        } else {
                            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                        }
                    } catch {
                        launchAtLogin = SettingsView.loginIsOn   // revert to truth
                    }
                }

            Picker("Puns", selection: $puns) {
                Text("Off").tag(0)
                Text("Light").tag(1)
                Text("Lots").tag(2)
            }
            if byte.provider == .chatGPT {
                Picker("Model", selection: Binding(get: { byte.model }, set: { byte.selectChatGPTModel($0) })) {
                    if byte.chatGPTModels.isEmpty { Text("Loading models…").tag(byte.model) }
                    ForEach(byte.chatGPTModels) { choice in Text(choice.display_name).tag(choice.slug) }
                }
                .disabled(byte.isStreaming || byte.isLoadingModels || byte.chatGPTModels.isEmpty)
                Button("Refresh models") { byte.reloadChatGPTModels() }
                    .disabled(byte.isStreaming || byte.isLoadingModels || !byte.chatGPT.canUsePlan)
            } else {
                Picker("Model", selection: $model) {
                    Text("Sonnet 4.6").tag("claude-sonnet-4-6")
                    Text("Opus 4.8").tag("claude-opus-4-8")
                    Text("Haiku 4.5").tag("claude-haiku-4-5-20251001")
                }
            }
            Picker("Effort", selection: $effort) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
            .disabled(byte.provider == .chatGPT || !AnthropicRequestConfiguration.supportsAdaptiveThinking(model))

            Text(byte.provider == .chatGPT ? "Your account determines available models and capabilities. Changes apply to the next message."
                 : AnthropicRequestConfiguration.supportsAdaptiveThinking(model)
                 ? "Changes apply to your next message."
                 : "Haiku uses standard generation. Effort applies to Sonnet and Opus.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, design: .rounded))
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Source links under web-search answers

@MainActor
struct SourcesView: View {
    let sources: [ByteModel.Turn.Source]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sources")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(Array(sources.prefix(6).enumerated()), id: \.offset) { i, s in
                Button {
                    if let u = URL(string: s.url), WebLinks.canOpen(u) {
                        NSWorkspace.shared.open(u)
                    }
                } label: {
                    Text("\(i + 1). \(label(for: s))")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(s.url)
            }
        }
        .padding(.top, 2)
    }

    private func label(for s: ByteModel.Turn.Source) -> String {
        if !s.title.isEmpty, s.title != s.url { return s.title }
        return URL(string: s.url)?.host ?? s.url
    }
}

// MARK: - Saved-chats browser (popover from the chat header)

@MainActor
struct ArchivesView: View {
    @ObservedObject var model: ByteModel
    let accent: Color
    var onPick: () -> Void
    @State private var items: [ByteModel.ArchiveInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved chats")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            if items.isEmpty {
                Text("No saved chats yet. Starting a new chat saves the current one here.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(items) { it in
                            HStack(spacing: 6) {
                                Button {
                                    if model.reopenArchive(id: it.id) { onPick() }
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(it.preview)
                                            .font(.system(size: 11, design: .rounded))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(it.dateString) · \(it.count) msg")
                                            .font(.system(size: 9, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    model.deleteArchive(id: it.id)
                                    items = model.archiveList()
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Delete this saved chat")
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { items = model.archiveList() }
    }
}
