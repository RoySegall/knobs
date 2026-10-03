# Knobs

A Lightroom-style photo editor for macOS (iPhone later). Every knob is a plugin: the engine decodes
the photo, runs the plugins in stage order and renders. It knows nothing about exposure or dehaze.

## Build

```bash
scripts/generate.sh                       # plugin registry + Xcode project (gitignored). Run after cloning.
scripts/test.sh [derived-data-dir]        # unit tests
scripts/render.sh [--derived dir] in.heic out.jpg --size 1200 --side-by-side dehaze.amount=60
```

`knobs-render --list` prints every param; `scripts/render.sh --bench in.heic plugin.param=value` times a preview frame.
Parallel checkouts pass their own derived-data dir.

## Layout

- `KnobsKit/Engine/` — plugin protocol, params, values, sidecar document, render engine, kernel loader.
- `KnobsKit/Plugins/<Name>/` — one folder per plugin: `<Name>Plugin.swift` plus optional `.metal` kernels.
- `Knobs/` — the Mac app. `Controls/ParamControl.swift` maps a param kind to its control.
- `KnobsKitTests/` — Swift Testing. `PluginContractTests` runs against every registered plugin.

## Writing a plugin

- A `struct XPlugin: KnobPlugin` anywhere under `KnobsKit/Plugins/` is registered on the next build.
- `id` and param ids are sidecar keys. Never rename them once photos have been edited.
- `apply` must return the input unchanged at default values, keep pixels finite at every extreme,
  and keep the extent (geometry stage excepted). The contract tests enforce all three.
- Pixels are linear extended sRGB and may exceed 1. Use `KnobsKernels.h` helpers for perceptual math.
- Radii are full-resolution pixels times `context.scale`, so the preview matches the export.
- Kernel names are global across the metallib: prefix them with the plugin id (`dehaze_transmission`).
- Load kernels with `KernelLibrary.color/general/warp(name)`; they are cached.
- RAW-capable knobs set the decoder in `configure(raw:)` and return true; `apply` covers JPEG/HEIC.
  A decoder property not yet in `RAWBaseline` must be added there, or the live preview keeps stale values.
- Geometry plugins honour `context.framing`: `.uncropped` is the crop tool showing the whole frame.

## Code style

- Calls with more than one argument use labels (Swift's default; don't add `_` to multi-arg functions).
- Model lifecycle state with an enum, never parallel `is...` booleans.
- Comments: at most three lines, end with a period, say why rather than what.
- Tests: Swift Testing, nested `@Suite`s, `@Test("should ...")`, bad flows before happy flows.
- Package manager for any JS tooling: `pnpm`.
