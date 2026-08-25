import Foundation

/// Which model produced an embedding.
///
/// One compound string rather than separate model, version and dimension
/// columns: splitting them invites comparing incompatible vectors when only one
/// of the three is checked. The dimension is carried alongside as a cheap
/// corruption check, not as part of the comparison key.
public struct EmbeddingModelIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let dimension: Int

    public init(rawValue: String, dimension: Int) {
        self.rawValue = rawValue
        self.dimension = dimension
    }

    /// The offline diarizer's 256-dimension embedding head, as measured.
    public static let fluidAudioOffline = EmbeddingModelIdentifier(
        rawValue: "fluidaudio-offline-diarizer-0.15.6-256", dimension: 256
    )

    public var description: String { rawValue }
}

/// Cosine geometry over speaker embeddings.
///
/// Vectors are normalized explicitly before every comparison rather than
/// assumed to be unit-norm: the ones the diarizer emits are not, and a plain
/// dot product on them silently scales the score by the vector magnitudes.
public enum VoiceVector {
    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        for value in vector { sumOfSquares += value * value }
        let norm = max(sumOfSquares.squareRoot(), 1e-9)
        return vector.map { $0 / norm }
    }

    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var leftSquares: Float = 0
        var rightSquares: Float = 0
        for index in 0..<lhs.count {
            dot += lhs[index] * rhs[index]
            leftSquares += lhs[index] * lhs[index]
            rightSquares += rhs[index] * rhs[index]
        }
        let denominator = leftSquares.squareRoot() * rightSquares.squareRoot()
        guard denominator > 0 else { return 0 }
        return Double(dot / denominator)
    }

    /// Mean of the normalized inputs, renormalized.
    ///
    /// This is the only vector a profile is scored against. Taking a maximum
    /// over individual exemplars instead was measured to lift impostor scores
    /// far more than genuine ones, shrinking the margin by a quarter.
    public static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var accumulator = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            guard vector.count == accumulator.count else { continue }
            let normalized = l2Normalized(vector)
            for index in 0..<accumulator.count { accumulator[index] += normalized[index] }
        }
        return l2Normalized(accumulator)
    }

    /// Little-endian Float32, which is what the store holds. Explicit rather
    /// than relying on the host being little-endian.
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) -> [Float]? {
        guard data.count % 4 == 0 else { return nil }
        let count = data.count / 4
        var out = [Float]()
        out.reserveCapacity(count)
        var index = data.startIndex
        for _ in 0..<count {
            var bits: UInt32 = 0
            for byte in 0..<4 {
                bits |= UInt32(data[index + byte]) << (8 * UInt32(byte))
            }
            out.append(Float(bitPattern: bits))
            index += 4
        }
        return out
    }
}
