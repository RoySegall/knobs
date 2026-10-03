import CoreImage
import Testing
@testable import KnobsKit

/// Every registered plugin must pass these, so a new knob is checked the moment it is dropped in.
@Suite("Plugin contract")
struct PluginContractTests {
    static let ids = PluginRegistry.all.map { $0.id }

    static func plugin(_ id: String) throws -> any KnobPlugin {
        try #require(PluginRegistry.all.first { $0.id == id })
    }

    /// Each param at its most extreme value: far end of a slider, full wheel, inverted curve, flipped flag.
    static func pushed(_ param: KnobParam) -> KnobValue {
        switch param.kind {
        case .slider(let slider):
            let low = abs(slider.range.lowerBound - slider.defaultValue)
            let high = abs(slider.range.upperBound - slider.defaultValue)
            return .number(high >= low ? slider.range.upperBound : slider.range.lowerBound)
        case .flag(let value): return .flag(!value)
        case .choice(let options, let value): return .choice(options.last { $0.id != value }?.id ?? value)
        case .curve: return .curve([CurvePoint(x: 0, y: 1), CurvePoint(x: 1, y: 0)])
        case .wheel: return .wheel(Wheel(hue: 30, amount: 1))
        }
    }

    @Suite("registry")
    struct Registry {
        @Test("should register plugins with unique ids")
        func uniqueIDs() {
            #expect(Set(PluginContractTests.ids).count == PluginContractTests.ids.count)
        }
    }

    @Suite("params")
    struct Params {
        @Test("should declare unique param ids with slider defaults inside their range", arguments: PluginContractTests.ids)
        func params(id: String) throws {
            let plugin = try PluginContractTests.plugin(id)
            let ids = plugin.params.map(\.id)
            #expect(!ids.isEmpty)
            #expect(Set(ids).count == ids.count)
            for param in plugin.params {
                if case .slider(let slider) = param.kind {
                    #expect(slider.range.contains(slider.defaultValue), "\(id).\(param.id)")
                }
            }
        }
    }

    @Suite("apply")
    struct Apply {
        @Test("should keep pixels finite at every slider extreme", arguments: PluginContractTests.ids)
        func extremes(id: String) throws {
            let plugin = try PluginContractTests.plugin(id)
            let input = TestImages.detail()
            for param in plugin.params {
                guard case .slider(let slider) = param.kind else { continue }
                for bound in [slider.range.lowerBound, slider.range.upperBound] {
                    let values = KnobValues(params: plugin.params, stored: [param.id: .number(bound)])
                    let output = plugin.apply(image: input, values: values, context: TestImages.context(for: input))
                    let finite = Pixels.read(output).allSatisfy { $0.isFinite }
                    #expect(finite, "\(id).\(param.id) = \(bound)")
                    if plugin.stage != .geometry {
                        #expect(output.extent == input.extent, "\(id).\(param.id) = \(bound)")
                    }
                }
            }
        }

        @Test("should leave the image untouched at default values", arguments: PluginContractTests.ids)
        func identity(id: String) throws {
            let plugin = try PluginContractTests.plugin(id)
            guard !plugin.runsAtDefaults else { return }
            let input = TestImages.detail()
            let values = KnobValues(params: plugin.params, stored: [:])
            let output = plugin.apply(image: input, values: values, context: TestImages.context(for: input))
            #expect(output.extent == input.extent)
            #expect(Pixels.maxDifference(between: output, and: input) < 1e-3)
        }

        @Test("should change the image when its params are pushed", arguments: PluginContractTests.ids)
        func pushed(id: String) throws {
            let plugin = try PluginContractTests.plugin(id)
            let input = TestImages.detail()
            let stored = Dictionary(uniqueKeysWithValues: plugin.params.map { ($0.id, PluginContractTests.pushed($0)) })
            let values = KnobValues(params: plugin.params, stored: stored)
            let output = plugin.apply(image: input, values: values, context: TestImages.context(for: input))
            if output.extent == input.extent {
                #expect(Pixels.maxDifference(between: output, and: input) > 1e-2)
            }
        }
    }
}
