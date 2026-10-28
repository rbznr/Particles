import Foundation

/// Everything about the morph that is worth a knob. The canvas reads most of
/// these every frame, so they take effect as the slider moves; the two that
/// decide how the pictures are cut up re-sample the swarm when the slider is
/// let go.
struct MorphSettings: Equatable {
    /// How long the object takes to come apart, in seconds.
    var scatter: Double = 0.60
    /// How long the motes then take to gather into the next one, in seconds.
    var gather: Double = 0.59
    /// Cells across the picture when it is sampled. Finer cells, finer grain.
    var lattice: Double = 280
    /// How many motes every picture is brought to.
    var population: Double = 15_000
    /// Mote size, in lattice cells.
    var pointSize: Double = 1.00
    /// How far off the straight line between its two homes a mote is thrown.
    var spread: Double = 0.21
    /// How far the whole cloud turns while it is apart, in radians.
    var swirl: Double = 0.10
    /// How wide each mote swims on its own while it is apart, as a share of
    /// the picture's box.
    var wander: Double = 0.060

    /// Neither half is allowed to collapse to nothing.
    private var out: Double { max(scatter, 0.05) }
    private var back: Double { max(gather, 0.05) }

    /// The whole trip, start to finish.
    var duration: Double { out + back }

    /// Where the morph is, 0…1, after `elapsed` seconds. The waist of the
    /// flight — where the swarm is at its loosest and the two eases meet —
    /// always lands on 0.5, so each half can take as long as it likes.
    func progress(after elapsed: Double) -> Double {
        if elapsed <= out { return min(0.5 * elapsed / out, 0.5) }
        return min(0.5 + 0.5 * (elapsed - out) / back, 1)
    }

    /// The same mapping the other way round: when the morph reaches
    /// `progress`. The picture's own fades are scheduled off this, so they
    /// stay in the gaps the motes leave however the two halves are set.
    func seconds(at progress: Double) -> Double {
        if progress <= 0.5 { return out * progress / 0.5 }
        return out + back * (progress - 0.5) / 0.5
    }
}
