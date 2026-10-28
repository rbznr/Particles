import SwiftUI

/// The knobs, parked at the bottom of the screen. Collapsed they are one small
/// button; open they are a card of sliders. Everything but the two sampling
/// knobs takes effect as the slider moves — those two re-cut the pictures when
/// the slider is let go, so dragging them stays smooth.
struct MorphControls: View {
    @Binding var settings: MorphSettings
    @Binding var isOpen: Bool
    var onResample: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if isOpen { panel } else { handle }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: isOpen)
    }

    private var handle: some View {
        HStack {
            Spacer()
            Button { isOpen = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            }
        }
        .transition(.opacity)
    }

    private var panel: some View {
        VStack(spacing: 2) {
            HStack(spacing: 14) {
                Text("Animation")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Button("Reset") {
                    settings = MorphSettings()
                    onResample()
                }
                .font(.footnote)
                Button { isOpen = false } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                }
            }
            .padding(.bottom, 2)

            knob("Break apart", $settings.scatter, 0.1...2.0, format: "%.2f s")
            knob("Come together", $settings.gather, 0.1...2.0, format: "%.2f s")
            knob("Grid", $settings.lattice, 120...360, step: 10, format: "%.0f", resamples: true)
            knob("Particles", $settings.population, 2_000...24_000, step: 500, format: "%.0f", resamples: true)
            knob("Particle size", $settings.pointSize, 0.5...3.0, format: "%.2f")
            knob("Spread", $settings.spread, 0...1.4, format: "%.2f")
            knob("Swirl", $settings.swirl, 0...1.4, format: "%.2f")
            knob("Drift", $settings.wander, 0...0.10, format: "%.3f")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 20, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func knob(
        _ title: String,
        _ value: Binding<Double>,
        _ range: ClosedRange<Double>,
        step: Double = 0,
        format: String,
        resamples: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 96, alignment: .leading)

            Slider(value: value, in: range, step: step > 0 ? step : 0.001) { editing in
                if resamples, !editing { onResample() }
            }

            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .font(.caption)
    }
}
