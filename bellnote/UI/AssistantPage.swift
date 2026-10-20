import OSLog
import SwiftData
import SwiftUI

/// Assistant tab: live voice assistant over every ready lecture, session memory only.
/// Stays off while any recording is processed so the pipeline keeps the model and memory.
struct AssistantPage: View {
    private static let log = Logger(subsystem: "app.bellnote", category: "talk")

    @Query(sort: \Term.createdAt) private var terms: [Term]
    @Environment(AppSession.self) private var session
    @State private var talk = TalkSession()

    private var processingBusy: Bool { PipelineActivity.shared.isBusy }

    var body: some View {
        Group {
            if processingBusy {
                ContentUnavailableView {
                    Label("Assistant", systemImage: "waveform.and.mic")
                } description: {
                    Text("Assistant pauses while a recording is processed.")
                }
            } else {
                talkBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Self.log.info("Assistant appear busy=\(self.processingBusy) terms=\(self.terms.count) phase=\(String(describing: self.talk.phase), privacy: .public)")
            syncTalk()
        }
        .onDisappear {
            Self.log.info("Assistant disappear phase=\(String(describing: self.talk.phase), privacy: .public)")
            talk.stop()
        }
        .onChange(of: processingBusy) { _, busy in
            Self.log.info("Assistant processingBusy=\(busy)")
            syncTalk()
        }
        .onChange(of: terms.count) { _, count in
            Self.log.info("Assistant terms count=\(count)")
            syncTalk()
        }
    }

    private var talkBody: some View {
        // Orb stays centered; the turn card overlays the bottom so it does not push the orb up.
        ZStack {
            VStack(spacing: 8) {
                AssistantVoiceOrb(phase: talk.phase, hearing: hearingSpeech)
                    .frame(width: 280, height: 280)
                Text(verbatim: talk.statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .animation(.easeInOut(duration: 0.2), value: talk.statusLine)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let card = turnCardContent {
                VStack {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(card.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: card.body)
                            .font(.body)
                            .textSelection(.enabled)
                            .animation(.easeOut(duration: 0.12), value: card.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    /// True while Listening and live words are already on the You card.
    private var hearingSpeech: Bool {
        guard talk.phase == .listening else { return false }
        return !talk.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Partial speech fills the same “You” card that later holds the final line.
    private var turnCardContent: (title: String, body: String)? {
        let live = talk.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            return (String(localized: "You"), live)
        }
        guard let latest = talk.turns.last else { return nil }
        let title = latest.role == .user ? String(localized: "You") : String(localized: "Bellnote")
        return (title, latest.text)
    }

    private func syncTalk() {
        if processingBusy {
            Self.log.info("Assistant sync stop — pipeline busy")
            talk.stop()
            return
        }
        switch talk.phase {
        case .preparing, .thinking, .speaking:
            // Do not cut warm-up or a live reply for a term-list refresh.
            Self.log.info("Assistant sync skip phase=\(String(describing: self.talk.phase), privacy: .public)")
            return
        case .idle, .listening, .needsMicrophone, .needsModel, .needsVoice, .failed:
            Self.log.info("Assistant sync restart phase=\(String(describing: self.talk.phase), privacy: .public)")
            talk.stop()
            talk.start(terms: terms, session: session)
        }
    }
}

/// VoiceOrbs-style Particles Orb — rotating 3D point cloud (sphere ↔ ring). No Pill / no text.
private struct AssistantVoiceOrb: View {
    var phase: TalkPhase
    /// Listening only: live transcript is on screen. Color and a pulse; resting shape stays.
    var hearing: Bool
    /// Kept across view rebuilds so sphere↔ring easing does not reset every frame.
    @State private var dynamics = OrbDynamics()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let blend = dynamics.tick(
                to: t,
                towardRing: ringTarget,
                towardWave: waveTarget,
                towardHelix: helixTarget,
                towardHear: hearTarget
            )
            let energy = energyAmount(at: t)
            let color = dotColor(hear: blend.hear, at: t)
            Canvas { context, size in
                drawParticles(
                    context: context,
                    size: size,
                    time: t,
                    ring: blend.ring,
                    wave: blend.wave,
                    helix: blend.helix,
                    hear: blend.hear,
                    energy: energy,
                    color: color
                )
            }
            .frame(width: 280, height: 280)
        }
        .accessibilityHidden(true)
    }

    /// Listening / thinking only — values match the first Particles Orb (do not retune).
    private var ringTarget: CGFloat {
        switch phase {
        case .thinking:
            return 1
        case .listening:
            return 0.08
        case .preparing:
            return 0
        case .needsMicrophone, .needsModel, .needsVoice, .failed:
            return 0.35
        case .speaking, .idle:
            return 0
        }
    }

    /// Speaking only — frequency ribbon. Listening/thinking never use this.
    private var waveTarget: CGFloat {
        phase == .speaking ? 1 : 0
    }

    /// Preparing only — double helix. Eases out into the sphere when listening starts.
    private var helixTarget: CGFloat {
        phase == .preparing ? 1 : 0
    }

    /// Listening only, and only while words are landing. Other phases stay on their own color.
    private var hearTarget: CGFloat {
        phase == .listening && hearing ? 1 : 0
    }

    /// Resting lavender eases into violet → magenta → orange → amber while speech is live.
    private func dotColor(hear: CGFloat, at time: TimeInterval) -> Color {
        guard phase == .listening, hear > 0 else { return particleColor }
        let stops: [(r: Double, g: Double, b: Double)] = [
            (0.68, 0.30, 1.0),
            (0.98, 0.32, 0.72),
            (1.0, 0.46, 0.16),
            (1.0, 0.84, 0.25),
        ]
        let span = time * 0.55
        let pos = span - Double(stops.count) * floor(span / Double(stops.count))
        let index = Int(pos) % stops.count
        let next = stops[(index + 1) % stops.count]
        let current = stops[index]
        let fraction = pos - Double(index)
        let live = (
            r: current.r + (next.r - current.r) * fraction,
            g: current.g + (next.g - current.g) * fraction,
            b: current.b + (next.b - current.b) * fraction
        )
        let t = Double(hear)
        let rest = (r: 0.62, g: 0.55, b: 1.0)
        return Color(
            red: rest.r + (live.r - rest.r) * t,
            green: rest.g + (live.g - rest.g) * t,
            blue: rest.b + (live.b - rest.b) * t
        )
    }

    private var particleColor: Color {
        switch phase {
        case .listening:
            return Color(red: 0.62, green: 0.55, blue: 1.0)
        case .thinking:
            return Color(red: 0.78, green: 0.58, blue: 1.0)
        case .speaking:
            return Color(red: 0.72, green: 0.48, blue: 0.98)
        case .preparing:
            return Color(red: 0.55, green: 0.62, blue: 0.92)
        case .needsMicrophone, .needsModel, .needsVoice, .failed:
            return Color.secondary
        case .idle:
            return Color(red: 0.7, green: 0.62, blue: 1.0)
        }
    }

    private var spinRate: Double {
        switch phase {
        case .listening: 0.7
        case .thinking: 1.55
        case .preparing: 0.45
        // Keep the waveform facing the student — slow yaw.
        case .speaking: 0.22
        default: 0.35
        }
    }

    private func energyAmount(at time: TimeInterval) -> CGFloat {
        switch phase {
        case .listening:
            return CGFloat((sin(time * 2.6) + 1) / 2) * 0.55 + 0.25
        case .thinking:
            return CGFloat((sin(time * 4.2) + 1) / 2) * 0.45 + 0.35
        case .speaking:
            return CGFloat((sin(time * 7.5) + 1) / 2) * 0.75 + 0.4
        case .preparing:
            return CGFloat((sin(time * 1.8) + 1) / 2) * 0.3 + 0.2
        case .needsMicrophone, .needsModel, .needsVoice, .failed:
            return 0.15
        case .idle:
            return CGFloat((sin(time * 1.4) + 1) / 2) * 0.2 + 0.12
        }
    }

    private func drawParticles(
        context: GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        ring: CGFloat,
        wave: CGFloat,
        helix: CGFloat,
        hear: CGFloat,
        energy: CGFloat,
        color: Color
    ) {
        let mid = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let baseRadius = min(size.width, size.height) * 0.32
        let r = Double(ring)
        let w = Double(wave)
        let h = Double(helix)
        // Helix breathe matches the old preparing pass (listen-like pulse).
        let helixEnergy = (sin(time * 2.6) + 1) / 2 * 0.55 + 0.25
        let shownEnergy = Double(energy) * (1 - h) + helixEnergy * h
        let breathe = 1 + 0.05 * sin(time * 1.8) + 0.1 * shownEnergy
        // Same radius for listen, think, speak, and the preparing helix.
        let radius = baseRadius * breathe
        // Each shape keeps its own yaw. Blending time * rate spins the cloud
        // because time is seconds since 2001, so a small rate change is a huge angle.
        let particleYaw = time * spinRate
        let helixYaw = time * 0.55
        let pitch = (0.35 + 0.12 * sin(time * 0.55)) * Double(1 - 0.85 * wave)
        let sphereW = max(0, 1 - r - w)
        let count = Double(Self.particleCount)
        // Thinking: ~56 evenly spaced dots (constant gap). No irregular skips.
        let ringDotCount = 56
        let baseDraw = max(
            ringDotCount,
            Int((Double(Self.particleCount) * (1 - r) + Double(ringDotCount) * r).rounded())
        )
        // Speaking is one wave. Fewer dots so the gaps stay visible.
        let speakDotCount = 28
        let withWave = max(
            1,
            Int((Double(baseDraw) * (1 - w) + Double(speakDotCount) * w).rounded())
        )
        // Preparing stays a 72-dot double helix; the count eases with the shape.
        let helixDotCount = 72
        let drawCount = max(
            1,
            Int((Double(withWave) * (1 - h) + Double(helixDotCount) * h).rounded())
        )

        var projected: [(z: Double, point: CGPoint, size: CGFloat, alpha: Double)] = []
        projected.reserveCapacity(drawCount)

        let cosY = cos(particleYaw)
        let sinY = sin(particleYaw)
        let cosH = cos(helixYaw)
        let sinH = sin(helixYaw)
        let cosP = cos(pitch)
        let sinP = sin(pitch)

        for slot in 0..<drawCount {
            let index = slot * (Self.particleCount - 1) / max(drawCount - 1, 1)
            let (sx, sy, sz) = Self.unitSphere[index]
            // Same ring shape; even angle on the ring so spacing stays equal.
            let fibAngle = atan2(sz, sx)
            let evenAngle = Double(slot) / Double(drawCount) * 2 * .pi
            let angle = fibAngle * (1 - r) + evenAngle * r
            // Same circle. A small tube keeps the band from collapsing to a line.
            // Tube follows the ring weight, so listening (ring ≈ 0.08) stays put.
            // Outer edge stays on the unit circle, matching the listen sphere.
            let tube = 0.10 * r
            let major = 1 - tube
            let twist = Double(slot) * 1.15 + time * 0.85
            let radial = major + cos(twist) * tube
            let ringX = cos(angle) * radial
            let ringY = sin(angle * 3 + time * 1.2) * 0.12 * major + sin(twist) * tube
            let ringZ = sin(angle) * radial

            // Speaking only: frequency ribbon.
            let u = Double(index) / count
            // Width matches the listen sphere (±1). Peaks stay inside that box.
            let waveX = (u - 0.5) * 2
            let amp = 0.5 + 0.5 * Double(energy)
            let waveY =
                (sin(u * .pi * 5 + time * 9) * 0.38
                    + sin(u * .pi * 9 + time * 14) * 0.25
                    + sin(u * .pi * 2.5 + time * 6) * 0.27)
                * amp
            let waveZ = 0.0

            var x = sx * sphereW + ringX * r + waveX * w
            var y = sy * sphereW + ringY * r + waveY * w
            var z = sz * sphereW + ringZ * r + waveZ * w
            let j = (sin(time * (2.2 + Double(index % 7) * 0.15) + Double(index)) * 0.5 + 0.5)
            // Speaking stays on one line. Jitter here reads as a second row of dots.
            // Helix has no scatter, so this fades out with the sphere.
            let jitter = 1 + Double(energy) * 0.12 * j * (1 - r * 0.5) * (1 - w) * (1 - h)
            x *= jitter
            y *= jitter
            z *= jitter

            let hu = Double(slot) / Double(max(drawCount - 1, 1))
            let strand = slot.isMultiple(of: 2) ? 0.0 : Double.pi
            let helixAngle = hu * 3.2 * Double.pi + time * 1.15 + strand
            let arm = 0.95
            let hx = cos(helixAngle) * arm
            let hy = (hu - 0.5) * 2
            let hz = sin(helixAngle) * arm

            let x1p = x * cosY - z * sinY
            let z1p = x * sinY + z * cosY
            let y1p = y * cosP - z1p * sinP
            let z2p = y * sinP + z1p * cosP

            let hx1 = hx * cosH - hz * sinH
            let hz1 = hx * sinH + hz * cosH

            var x1 = x1p * (1 - h) + hx1 * h
            var y1 = y1p * (1 - h) + hy * h
            var z2 = z2p * (1 - h) + hz1 * h

            // Hearing only. hear is 0 the rest of the time, so the resting sphere is unchanged.
            let ripple = sin(time * 8 + sy * 4) * 0.7 + sin(time * 13 + sx * 3) * 0.3
            let pulse = (ripple + 1) / 2
            let open = 1 + Double(hear) * 0.14 * pulse
            x1 *= open
            y1 *= open
            z2 *= open

            let depth = (z2 + 1) * 0.5
            let scale = radius * (0.78 + 0.42 * depth)
            let px = mid.x + CGFloat(x1) * scale
            let py = mid.y + CGFloat(y1) * scale
            // Same dot size for listen and think (ring no longer shrinks the points).
            let dotBoost = 1 + Double(hear) * 0.75 * pulse
            let dot = CGFloat(1.4 + 2.6 * depth) * CGFloat(0.85 + 0.25 * shownEnergy) * CGFloat(dotBoost)
            let particleAlpha = (0.18 + 0.72 * depth) * (1 - 0.12 * r)
            let helixAlpha = 0.28 + 0.62 * depth
            let alpha = particleAlpha * (1 - h) + helixAlpha * h
            projected.append((z2, CGPoint(x: px, y: py), dot, alpha))
        }

        projected.sort { $0.z < $1.z }
        for item in projected {
            let rect = CGRect(
                x: item.point.x - item.size * 0.5,
                y: item.point.y - item.size * 0.5,
                width: item.size,
                height: item.size
            )
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(item.alpha)))
        }
    }

    private static let particleCount = 360
    /// Fibonacci sphere samples, unit radius.
    private static let unitSphere: [(Double, Double, Double)] = {
        let n = particleCount
        let golden = Double.pi * (3 - sqrt(5))
        var points: [(Double, Double, Double)] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let y = 1 - (Double(i) / Double(n - 1)) * 2
            let r = sqrt(max(0, 1 - y * y))
            let theta = golden * Double(i)
            points.append((cos(theta) * r, y, sin(theta) * r))
        }
        return points
    }()
}

/// Frame-to-frame easing so sphere ↔ ring ↔ wave ↔ helix does not pop.
private final class OrbDynamics {
    private var ring: CGFloat = 0
    private var wave: CGFloat = 0
    private var helix: CGFloat = 0
    private var hear: CGFloat = 0
    private var lastTime: TimeInterval?

    func tick(
        to time: TimeInterval,
        towardRing: CGFloat,
        towardWave: CGFloat,
        towardHelix: CGFloat,
        towardHear: CGFloat
    ) -> (ring: CGFloat, wave: CGFloat, helix: CGFloat, hear: CGFloat) {
        let dt: TimeInterval
        let isFirst = lastTime == nil
        if let lastTime {
            dt = min(0.05, max(1 / 120, time - lastTime))
        } else {
            dt = 1 / 30
        }
        lastTime = time
        let rate = CGFloat(1 - exp(-dt * 6))
        ring += (towardRing - ring) * rate
        wave += (towardWave - wave) * rate
        // First paint of Preparing is already the helix. Later phase changes ease.
        if isFirst {
            helix = towardHelix
        } else {
            helix += (towardHelix - helix) * rate
        }
        hear += (towardHear - hear) * rate
        return (ring, wave, helix, hear)
    }
}
