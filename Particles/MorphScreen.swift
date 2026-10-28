import SwiftUI
import UIKit

/// A white screen with one object on it. Tap the object and it comes apart
/// into its own motes — the same dust the signature turns into, only each
/// grain keeps the colour of the pixel it was lifted from. The motes do not
/// fade out: they fly, repaint themselves, and settle into the next object.
struct MorphScreen: View {
    private static let pictures = ["MorphAshtray", "MorphVase", "MorphCat"]
    /// How far the object presses in under a finger.
    private static let pressScale: CGFloat = 0.9

    @State private var settings = MorphSettings()
    @State private var shapes: [MorphShape] = []
    /// Bumped every time the pictures are cut up again.
    @State private var shapesToken = 0
    @State private var index = 0
    @State private var step: MorphStep?
    @State private var pictureOpacity: Double = 1
    @State private var isMorphing = false
    @State private var isPressed = false
    @State private var showsControls = false

    /// The two ends of the morph, where the real pictures and the motes trade
    /// places. Each picture moves in the gap the motes leave it: the first one
    /// only goes once they are solid over it, and the second is already back
    /// before they begin to dissolve. Nothing is ever half-faded over
    /// something else half-faded, so neither end blinks.
    private var pictureOutStart: Double {
        settings.seconds(at: MorphCanvasView.handoverIn)
    }
    private var pictureOut: Double {
        settings.seconds(at: 0.16) - pictureOutStart
    }
    /// A longer window than the dissolve: with a thin swarm there is more for
    /// the picture to fill in, and it should arrive rather than appear.
    private var pictureInStart: Double {
        settings.seconds(at: 0.72)
    }
    private var pictureIn: Double {
        settings.seconds(at: MorphCanvasView.handoverOut) - pictureInStart
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width - 56, geometry.size.height * 0.46)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let box = CGRect(
                x: centre.x - side / 2,
                y: centre.y - side / 2,
                width: side,
                height: side
            )

            ZStack {
                Color.white.ignoresSafeArea()

                ZStack {
                    Image(Self.pictures[index])
                        .resizable()
                        .scaledToFit()
                        .frame(width: side, height: side)
                        .opacity(pictureOpacity)
                        .position(centre)
                        .contentShape(Rectangle())
                        // One gesture for both halves of the tap: the press
                        // that squeezes the object, and the lift that sets it
                        // off. A plain tap gesture gives up if the finger is
                        // held, which would leave a press that goes nowhere.
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in isPressed = true }
                                .onEnded { drag in
                                    isPressed = false
                                    let travel = hypot(
                                        drag.translation.width,
                                        drag.translation.height
                                    )
                                    if travel < 24 { advance() }
                                }
                        )

                    MorphCanvas(
                        shapes: shapes,
                        shapesToken: shapesToken,
                        step: step,
                        box: box,
                        settings: settings,
                        onSettle: { isMorphing = false }
                    )
                    .allowsHitTesting(false)
                }
                .scaleEffect(isPressed ? Self.pressScale : 1)
                .animation(.spring(duration: 0.3, bounce: 0), value: isPressed)
                // Out of the panel's way while it is open.
                .offset(y: showsControls ? -186 : 0)
                .animation(.spring(duration: 0.3, bounce: 0.1), value: showsControls)

                MorphControls(
                    settings: $settings,
                    isOpen: $showsControls,
                    onResample: resample
                )
            }
        }
        .ignoresSafeArea()
        .tint(.black)
        .task { await loadShapes() }
    }

    /// Lets go of the picture on screen and gathers its motes into the next.
    private func advance() {
        guard !isMorphing, shapes.count == Self.pictures.count else { return }

        let next = (index + 1) % Self.pictures.count
        isMorphing = true
        step = MorphStep(from: index, to: next, token: (step?.token ?? 0) + 1)

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        withAnimation(.easeOut(duration: pictureOut).delay(pictureOutStart)) {
            pictureOpacity = 0
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(pictureInStart))
            // Swapped while it is invisible, so the picture underneath is
            // already the new one by the time the motes land on it.
            index = next
            withAnimation(.easeIn(duration: pictureIn)) { pictureOpacity = 1 }
        }
    }

    private func resample() {
        Task { await loadShapes(again: true) }
    }

    private func loadShapes(again: Bool = false) async {
        guard again || shapes.isEmpty else { return }

        let images = Self.pictures.compactMap { UIImage(named: $0)?.cgImage }
        guard images.count == Self.pictures.count else { return }

        let carried = images.map(CapturedImage.init)
        let lattice = Int(settings.lattice)
        let population = Int(settings.population)

        let cut = await Task.detached(priority: .userInitiated) {
            MorphSampler.shapes(
                from: carried.map(\.cgImage),
                lattice: lattice,
                population: population
            )
        }.value

        shapes = cut
        shapesToken += 1
    }
}

#Preview {
    MorphScreen()
}
