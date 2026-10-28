import CoreGraphics
import Foundation
import simd

/// One mote of a picture. The layout mirrors `MorphPoint` in
/// `MorphShaders.metal`: two `float4`s, 32 bytes.
nonisolated struct MorphPoint {
    /// `xy` = where it rests inside the unit box, y pointing down.
    /// `z` = its cue in the flight, 0…1. `w` = its own seed.
    var place: SIMD4<Float>
    /// The colour of the pixel it stands for, straight rather than
    /// premultiplied, so a soft edge stays soft.
    var color: SIMD4<Float>
}

/// A picture sampled into motes, laid out in a unit box the picture is
/// aspect-fitted into. The renderer decides how many points that box is worth,
/// so the sampling survives any layout.
nonisolated struct MorphShape: @unchecked Sendable {
    var points: [MorphPoint]
    /// Distance between neighbouring lattice cells, in unit-box units.
    var pitch: Float
}

/// A `CGImage` handed between the main actor and the sampling task.
nonisolated struct CapturedImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Turns pictures into interchangeable swarms.
///
/// Every picture is sampled on the same lattice and filed in the same order,
/// then cut or padded to one shared population. Mote *n* of one picture is
/// therefore mote *n* of the next, and a morph is nothing more than two
/// endpoints for each mote.
nonisolated enum MorphSampler {
    /// Below this the pixel counts as background.
    private static let coverage: Float = 0.35
    /// Wedges the swarm is filed into around the middle. Within a wedge motes
    /// run from the centre outwards, so a mote near the rim of one picture
    /// lands near the rim of the next at about the same bearing — the swarm
    /// turns into the new picture rather than reshuffling itself.
    private static let wedges = 512

    /// `lattice` is how many cells the picture is cut into across the unit
    /// box, `population` how many motes every picture is brought to. Both are
    /// knobs on the screen, so they arrive from the caller.
    static func shapes(from images: [CGImage], lattice: Int, population: Int) -> [MorphShape] {
        let pitch = 1 / Float(lattice)
        return images.map { image in
            MorphShape(
                points: cue(
                    equalise(
                        sample(image, lattice: lattice),
                        population: population,
                        pitch: pitch
                    )
                ),
                pitch: pitch
            )
        }
    }

    /// Lays a lattice over the picture, aspect-fitted into the unit box, and
    /// keeps a mote wherever the picture is not see-through.
    private static func sample(_ image: CGImage, lattice: Int) -> [MorphPoint] {
        let side = lattice
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        context.interpolationQuality = .high
        let fit = min(
            Double(side) / Double(image.width),
            Double(side) / Double(image.height)
        )
        let drawn = CGSize(width: Double(image.width) * fit, height: Double(image.height) * fit)
        context.draw(image, in: CGRect(
            x: (Double(side) - drawn.width) / 2,
            y: (Double(side) - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }

        var kept: [MorphPoint] = []
        kept.reserveCapacity(side * side / 3)

        for row in 0..<side {
            for column in 0..<side {
                let offset = (row * side + column) * 4
                let alpha = Float(pixels[offset + 3]) / 255
                guard alpha > coverage else { continue }

                // The context is premultiplied; the motes carry straight
                // colour so the renderer can fade them without them darkening.
                let unpremultiply = 1 / (alpha * 255)
                kept.append(MorphPoint(
                    place: SIMD4(
                        (Float(column) + 0.5) / Float(side),
                        (Float(row) + 0.5) / Float(side),
                        0,
                        0
                    ),
                    color: SIMD4(
                        Float(pixels[offset]) * unpremultiply,
                        Float(pixels[offset + 1]) * unpremultiply,
                        Float(pixels[offset + 2]) * unpremultiply,
                        alpha
                    )
                ))
            }
        }
        return kept
    }

    /// Brings a picture to the shared population: too many motes and the
    /// extras are dropped at random, too few and some are doubled a hair off
    /// their twin so the padding does not pile up in one place.
    private static func equalise(
        _ points: [MorphPoint],
        population: Int,
        pitch: Float
    ) -> [MorphPoint] {
        guard !points.isEmpty else { return [] }

        var out = points.shuffled()
        if out.count > population {
            out.removeLast(out.count - population)
            return out
        }

        let originals = out.count
        var index = 0
        while out.count < population {
            var copy = out[index % originals]
            copy.place.x += .random(in: -pitch...pitch) * 0.5
            copy.place.y += .random(in: -pitch...pitch) * 0.5
            out.append(copy)
            index += 1
        }
        return out
    }

    /// Gives every mote its seed and its cue, then files the whole picture by
    /// bearing and depth.
    private static func cue(_ points: [MorphPoint]) -> [MorphPoint] {
        var keyed = points.map { point -> (wedge: Int, reach: Float, point: MorphPoint) in
            let dx = point.place.x - 0.5
            let dy = point.place.y - 0.5
            var bearing = atan2(dy, dx) / (2 * .pi)
            if bearing < 0 { bearing += 1 }
            return (
                min(Int(bearing * Float(wedges)), wedges - 1),
                hypot(dx, dy),
                point
            )
        }
        keyed.sort { ($0.wedge, $0.reach) < ($1.wedge, $1.reach) }

        return keyed.map { entry in
            var point = entry.point
            // The rim lets go first and the middle last, with enough slop left
            // over that the edge of the burst stays ragged.
            let reach = min(entry.reach * 2, 1)
            point.place.z = (1 - reach) * 0.55 + .random(in: 0...0.45)
            point.place.w = .random(in: 0...1)
            return point
        }
    }
}
