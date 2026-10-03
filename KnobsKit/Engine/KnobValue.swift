import Foundation

public enum KnobValue: Sendable, Hashable {
    case number(Double)
    case flag(Bool)
    case choice(String)
    case curve([CurvePoint])
    case wheel(Wheel)
}

/// A tone-curve control point, both axes 0...1.
public struct CurvePoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
}

/// A color-wheel position: hue in degrees, amount 0...1 from the center.
public struct Wheel: Sendable, Hashable, Codable {
    public var hue: Double
    public var amount: Double

    public init(hue: Double, amount: Double) {
        self.hue = hue
        self.amount = amount
    }
}

/// One plugin's values with every param present, typed and clamped.
public struct KnobValues: Sendable, Hashable {
    public private(set) var storage: [String: KnobValue]

    public init(params: [KnobParam], stored: [String: KnobValue]) {
        storage = Dictionary(uniqueKeysWithValues: params.map { ($0.id, $0.resolve(stored[$0.id])) })
    }

    public subscript(id: String) -> KnobValue? {
        storage[id]
    }

    public func isNeutral(params: [KnobParam]) -> Bool {
        params.allSatisfy { storage[$0.id] == $0.defaultValue }
    }

    public func number(_ id: String) -> Double {
        guard case .number(let value) = storage[id] else { preconditionFailure("No number param \(id)") }
        return value
    }

    public func flag(_ id: String) -> Bool {
        guard case .flag(let value) = storage[id] else { preconditionFailure("No flag param \(id)") }
        return value
    }

    public func choice(_ id: String) -> String {
        guard case .choice(let value) = storage[id] else { preconditionFailure("No choice param \(id)") }
        return value
    }

    public func curve(_ id: String) -> [CurvePoint] {
        guard case .curve(let value) = storage[id] else { preconditionFailure("No curve param \(id)") }
        return value
    }

    public func wheel(_ id: String) -> Wheel {
        guard case .wheel(let value) = storage[id] else { preconditionFailure("No wheel param \(id)") }
        return value
    }
}

// Plain JSON in the sidecar: 0.5, true, "1:1", [[0,0],[1,1]], {"hue":30,"amount":0.2}.
extension KnobValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .flag(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .choice(value)
        } else if let value = try? container.decode([CurvePoint].self) {
            self = .curve(value)
        } else {
            self = .wheel(try container.decode(Wheel.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .flag(let value): try container.encode(value)
        case .choice(let value): try container.encode(value)
        case .curve(let value): try container.encode(value)
        case .wheel(let value): try container.encode(value)
        }
    }
}

extension CurvePoint: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}
