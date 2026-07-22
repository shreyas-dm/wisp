import SwiftUI
import WispKit

/// Full-screen, click-through overlay content: orb (bottom right), response
/// bubble above it, and the pointer animation layer.
struct OverlayRootView: View {
    @ObservedObject var engine: CompanionEngine
    @ObservedObject var pointerModel: PointerModel

    private let orbDiameter: CGFloat = 30
    private let orbMargin: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let orbCenter = CGPoint(
                x: geometry.size.width - orbMargin - orbDiameter / 2,
                y: geometry.size.height - orbMargin - orbDiameter / 2
            )
            ZStack(alignment: .topLeading) {
                PointerLayer(request: pointerModel.request, orbCenter: orbCenter)

                OrbView(
                    state: engine.state,
                    audioLevel: engine.audioLevel,
                    alwaysVisible: engine.orbAlwaysVisible
                )
                .frame(width: orbDiameter, height: orbDiameter)
                .position(orbCenter)

                bubble(in: geometry.size)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func bubble(in size: CGSize) -> some View {
        let showsTranscript = engine.state == .listening && !engine.partialTranscript.isEmpty
        let showsListeningHint = engine.state == .listening && engine.partialTranscript.isEmpty
        let showsReply = !engine.bubbleText.isEmpty
        if showsReply || showsTranscript || showsListeningHint {
            ResponseBubbleView(
                text: showsReply ? engine.bubbleText : (showsTranscript ? engine.partialTranscript : "Listening…"),
                isSecondary: !showsReply
            )
            .frame(maxWidth: 380, alignment: .trailing)
            .position(
                x: size.width - orbMargin - 190,
                y: size.height - orbMargin - orbDiameter - 16 - 60
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeOut(duration: 0.25), value: engine.bubbleText)
            .animation(.easeOut(duration: 0.25), value: engine.state)
        }
    }
}

// MARK: - Orb

struct OrbView: View {
    let state: EngineState
    let audioLevel: Float
    let alwaysVisible: Bool

    @State private var breathing = false
    @State private var shimmerRotation = 0.0

    private var visible: Bool { alwaysVisible || state != .idle }

    var body: some View {
        ZStack {
            // Soft outer glow.
            Circle()
                .fill(stateColor.opacity(0.35))
                .blur(radius: 10)
                .scaleEffect(1.35)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.42, green: 0.36, blue: 0.98),
                                 Color(red: 0.62, green: 0.32, blue: 0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle()
                        .stroke(stateColor.opacity(state == .listening ? 0.9 : 0.0), lineWidth: 2)
                        .scaleEffect(state == .listening ? 1.35 : 1.0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: state == .listening)
                )
                .scaleEffect(scale)
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: breathing)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state)

            if state == .thinking {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(shimmerRotation))
                    .scaleEffect(1.18)
                    .onAppear {
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                            shimmerRotation = 360
                        }
                    }
                    .onDisappear { shimmerRotation = 0 }
            }

            if state == .listening {
                WaveformView(level: audioLevel)
                    .frame(width: 18, height: 12)
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.5), value: visible)
        .onAppear { breathing = true }
    }

    private var scale: CGFloat {
        switch state {
        case .idle: return breathing ? 1.06 : 1.0
        case .listening: return 1.08
        case .thinking: return 1.0
        case .responding, .speaking: return 1.05
        }
    }

    private var stateColor: Color {
        switch state {
        case .idle: return Color(red: 0.5, green: 0.4, blue: 0.95)
        case .listening: return Color(red: 0.3, green: 0.85, blue: 0.5)
        case .thinking: return Color(red: 0.95, green: 0.75, blue: 0.3)
        case .responding, .speaking: return Color(red: 0.4, green: 0.6, blue: 0.98)
        }
    }
}

/// Five-bar microphone level indicator inside the orb while listening.
struct WaveformView: View {
    let level: Float

    private static let barMultipliers: [CGFloat] = [0.55, 0.85, 1.0, 0.75, 0.6]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.95))
                    .frame(
                        width: 2,
                        height: 3 + CGFloat(level) * 9 * Self.barMultipliers[index]
                    )
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
    }
}

// MARK: - Bubble

struct ResponseBubbleView: View {
    let text: String
    let isSecondary: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(isSecondary ? Color.white.opacity(0.6) : Color.white.opacity(0.92))
                .italic(isSecondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.72))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }
}

// MARK: - Pointer

struct PointerLayer: View {
    let request: PointRequest?
    let orbCenter: CGPoint

    var body: some View {
        ZStack {
            if let request {
                PointerAnimationView(request: request, orbCenter: orbCenter)
                    .id(request.id)
            }
        }
        .allowsHitTesting(false)
    }
}

/// One pointing gesture: a glowing beacon flies from the orb to the target
/// along a curved path, then a highlight ring pulses around the element.
struct PointerAnimationView: View {
    let request: PointRequest
    let orbCenter: CGPoint

    @State private var flightProgress: CGFloat = 0
    @State private var beaconOpacity: Double = 1
    @State private var ringOpacity: Double = 0
    @State private var ringScale: CGFloat = 0.85

    private var targetCenter: CGPoint {
        CGPoint(x: request.targetRectInView.midX, y: request.targetRectInView.midY)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Beacon in flight.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.55, green: 0.5, blue: 1.0),
                                 Color(red: 0.45, green: 0.38, blue: 0.98).opacity(0.0)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 14
                    )
                )
                .frame(width: 26, height: 26)
                .overlay(Circle().fill(Color.white.opacity(0.9)).frame(width: 7, height: 7))
                .opacity(beaconOpacity)
                .modifier(
                    QuadraticBezierPosition(
                        progress: flightProgress,
                        start: orbCenter,
                        end: targetCenter
                    )
                )

            // Highlight ring around the target element.
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(red: 0.5, green: 0.44, blue: 1.0), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(red: 0.5, green: 0.44, blue: 1.0).opacity(0.10))
                )
                .frame(
                    width: request.targetRectInView.width + 8,
                    height: request.targetRectInView.height + 8
                )
                .position(x: targetCenter.x, y: targetCenter.y)
                .opacity(ringOpacity)
                .scaleEffect(ringScale, anchor: .center)
        }
        .onAppear(perform: animate)
    }

    private func animate() {
        withAnimation(.easeInOut(duration: 0.55)) {
            flightProgress = 1
        }
        withAnimation(.easeOut(duration: 0.2).delay(0.5)) {
            beaconOpacity = 0
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.5)) {
            ringOpacity = 1
            ringScale = 1.0
        }
        withAnimation(.easeInOut(duration: 0.35).delay(0.85).repeatCount(2, autoreverses: true)) {
            ringScale = 1.05
        }
        withAnimation(.easeOut(duration: 0.5).delay(2.0)) {
            ringOpacity = 0
        }
    }
}

/// Positions a view along a quadratic bezier from `start` to `end`, bowed
/// perpendicular to the travel direction. `progress` is animatable so
/// SwiftUI interpolates the flight.
struct QuadraticBezierPosition: GeometryEffect {
    var progress: CGFloat
    let start: CGPoint
    let end: CGPoint

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = progress
        let control = Self.controlPoint(start: start, end: end)
        let oneMinusT = 1 - t
        let x = oneMinusT * oneMinusT * start.x + 2 * oneMinusT * t * control.x + t * t * end.x
        let y = oneMinusT * oneMinusT * start.y + 2 * oneMinusT * t * control.y + t * t * end.y
        // The view is laid out at the top-left corner; translate its center
        // to the bezier point.
        return ProjectionTransform(
            CGAffineTransform(translationX: x - size.width / 2, y: y - size.height / 2)
        )
    }

    static func controlPoint(start: CGPoint, end: CGPoint) -> CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = max(1, sqrt(dx * dx + dy * dy))
        // Perpendicular unit vector; bow height scales with distance but is
        // capped so short hops still arc gently and long ones don't balloon.
        let bow = min(120, distance * 0.25)
        return CGPoint(x: mid.x - dy / distance * bow, y: mid.y + dx / distance * bow)
    }
}

/// Ring-only pulse used on displays other than the orb's.
struct RingFlashView: View {
    let targetRect: CGRect

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.85

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(red: 0.5, green: 0.44, blue: 1.0), lineWidth: 2)
                .frame(width: targetRect.width + 8, height: targetRect.height + 8)
                .position(x: targetRect.midX, y: targetRect.midY)
                .opacity(opacity)
                .scaleEffect(scale)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                opacity = 1
                scale = 1.0
            }
            withAnimation(.easeInOut(duration: 0.35).delay(0.35).repeatCount(2, autoreverses: true)) {
                scale = 1.05
            }
            withAnimation(.easeOut(duration: 0.5).delay(1.8)) {
                opacity = 0
            }
        }
    }
}
