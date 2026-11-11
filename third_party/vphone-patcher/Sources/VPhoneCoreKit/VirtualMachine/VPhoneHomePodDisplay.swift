import Foundation

// MARK: - HomePod LED Geometry

/// LED order and normalized positions supplied by the guest's device tree.
/// The fixed-point hardware coordinates already describe the diffuser surface.
public struct VPhoneHomePodDisplayGeometry: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let ring: UInt32
    }

    public let points: [Point]
    public let bitDepth: Int
    public let hardwareVersion: UInt32

    public enum ValidationError: Error, Equatable {
        case missingProperty(String)
        case invalidCoordinates
        case invalidBitDepth
        case invalidFrame
    }

    public init(xCoordinates: [Double], yCoordinates: [Double], rings: [UInt32], bitDepth: Int, hardwareVersion: UInt32) throws {
        guard !xCoordinates.isEmpty, xCoordinates.count <= 1024,
              xCoordinates.count == yCoordinates.count, xCoordinates.count == rings.count,
              xCoordinates.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }),
              yCoordinates.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) })
        else { throw ValidationError.invalidCoordinates }
        guard (1 ... 32).contains(bitDepth) else { throw ValidationError.invalidBitDepth }
        self.points = zip(zip(xCoordinates, yCoordinates), rings).map { Point(x: $0.0.0, y: $0.0.1, ring: $0.1) }
        self.bitDepth = bitDepth
        self.hardwareVersion = hardwareVersion
    }

    /// Decode the unmodified DT property payloads, not a serialized kernel tree.
    /// MDX/YCoords are little-endian unsigned 16.16 fixed-point values.
    public init(deviceTreeProperties properties: [String: Data]) throws {
        func words(_ name: String) throws -> [UInt32] {
            guard let data = properties[name] else { throw ValidationError.missingProperty(name) }
            guard !data.isEmpty, data.count % 4 == 0, data.count <= 4096 else { throw ValidationError.invalidCoordinates }
            return stride(from: 0, to: data.count, by: 4).map { offset in
                UInt32(data[data.startIndex + offset]) |
                    UInt32(data[data.startIndex + offset + 1]) << 8 |
                    UInt32(data[data.startIndex + offset + 2]) << 16 |
                    UInt32(data[data.startIndex + offset + 3]) << 24
            }
        }
        let x = try words("MDXCoords").map { Double($0) / 65536 }
        let y = try words("MDYCoords").map { Double($0) / 65536 }
        let rings = try words("MDRingCoords")
        let depth = try words("MDBitDepth")
        let version = try words("MDHWVersion")
        guard depth.count == 1, version.count == 1 else { throw ValidationError.invalidCoordinates }
        try self.init(xCoordinates: x, yCoordinates: y, rings: rings, bitDepth: Int(depth[0]), hardwareVersion: version[0])
    }

    /// The hardware coordinates already use the full cap's unit square.
    /// Do not stretch their bounds: the unpopulated border is physical margin.
    public var normalizedPoints: [Point] { points }
}

// MARK: - Guest LED Frame

/// A snapshot of guest-controlled LED output. RGB is normalized linear light;
/// presentation applies the guest brightness without inventing animation.
public struct VPhoneHomePodDisplayFrame: Equatable, Sendable {
    public let pixels: [[Double]]
    public let brightness: Double
    public let plusBrightness: Double
    public let minusBrightness: Double
    public let generation: UInt64

    public init(pixels: [[Double]], brightness: Double = 1, plusBrightness: Double = 0, minusBrightness: Double = 0, generation: UInt64 = 0) throws {
        func valid(_ value: Double) -> Bool { value.isFinite && (0 ... 1).contains(value) }
        guard !pixels.isEmpty, pixels.count <= 1024,
              pixels.allSatisfy({ $0.count == 3 && $0.allSatisfy(valid) }),
              [brightness, plusBrightness, minusBrightness].allSatisfy(valid)
        else { throw VPhoneHomePodDisplayGeometry.ValidationError.invalidFrame }
        self.pixels = pixels
        self.brightness = brightness
        self.plusBrightness = plusBrightness
        self.minusBrightness = minusBrightness
        self.generation = generation
    }

    /// The event/RPC envelope owns geometry; a frame must match that geometry
    /// before replacing the currently displayed snapshot.
    public func matches(_ geometry: VPhoneHomePodDisplayGeometry) -> Bool {
        pixels.count == geometry.points.count
    }

    /// MiniDisplay HW3 carries separate Siri/transient and always-on banks for
    /// the same emitters. Their light contributes to the same diffuser. HPDS
    /// has already applied its brightness/LUT to each bank before submission;
    /// MDDisplayBrightness is a driver feature flag, not a master light level.
    public init(banks: [[[Double]]], plusBrightness: Double = 0, minusBrightness: Double = 0, generation: UInt64 = 0) throws {
        guard !banks.isEmpty, banks.count <= 2 else { throw VPhoneHomePodDisplayGeometry.ValidationError.invalidFrame }
        let frames = try banks.map { try Self(pixels: $0) }
        guard let first = frames.first, frames.allSatisfy({ $0.pixels.count == first.pixels.count })
        else { throw VPhoneHomePodDisplayGeometry.ValidationError.invalidFrame }
        let pixels = first.pixels.indices.map { index in
            (0 ..< 3).map { channel in min(1, frames.reduce(0) { $0 + $1.pixels[index][channel] }) }
        }
        try self.init(pixels: pixels, plusBrightness: plusBrightness, minusBrightness: minusBrightness, generation: generation)
    }
}

