# Knobs

A Lightroom-style photo editor for macOS (iPhone later). Every knob is a plugin: the engine decodes the
photo, runs the plugins in stage order and renders. It knows nothing about exposure or dehaze.

## Build

```bash
scripts/generate.sh                    # plugin registry + Xcode project (both gitignored). Run after cloning.
scripts/test.sh [derived-data-dir]     # unit tests (Debug)
scripts/install.sh                     # Release build → ~/Applications/Knobs.app, the one copy to run
scripts/render.sh in.ARW out.jpg --size 1200 --side-by-side dehaze.amount=60
```

- Toolchain: Xcode 27 (Swift 6.4, Swift 6 language mode), XcodeGen, and the Metal toolchain
  (`xcodebuild -downloadComponent MetalToolchain`) because every `.metal` file is a Core Image kernel.
- Build products live under `build/DerivedData.noindex`. The `.noindex` suffix keeps Spotlight and the
  App Library from listing every build as another Knobs app. Parallel checkouts pass their own derived-data dir.
- Restart the app from `~/Applications/Knobs.app` after `scripts/install.sh`; don't launch build products.

## Layout

```
KnobsKit/            the engine, a platform-neutral framework
  Engine/            plugin protocol, params/values, sidecar, render engine, preview session, analysis, export
  Engine/Metal/      shared kernel helpers (KnobsKernels.h), display roll-off, auto-tone measuring
  Plugins/<Name>/    one folder per plugin: <Name>Plugin.swift + optional .metal kernels
  Plugins/Shared/    guided filter and presence helpers shared by several plugins
  Generated/         PluginRegistry.generated.swift (gitignored, written by scripts/generate-registry.sh)
Knobs/               the macOS app (SwiftUI, default MainActor isolation)
  Models/            EditorModel, LibraryModel, ExportModel, thumbnails
  Views/             ContentView, MetalCanvas, CanvasView, InspectorView, FilmstripView, ExportSheet
  Controls/          ParamControl (kind → control), KnobSlider, CurveEditor, WheelControl, ParamGroupControl
  Tools/             canvas tools: crop, graduated filter (overlay + editor glue)
  Debug/PerfProbe    -knobsProbe launch argument; see Tooling
KnobsResources/      asset catalog (app icon); outside Knobs/ because synced folders get no resources phase
KnobsRender/         knobs-render, a CLI that runs the same pipeline (render, compare, bench, auto)
KnobsKitTests/       Swift Testing; PluginContractTests runs against every registered plugin
design/              the icon's 1024 px source
project.yml          XcodeGen spec; sources are synced folders, so new files need no regeneration
```

## Architecture

### Pipeline

`Photo.load(url:)` reads the file once. A RAW (UTType conforms to `.rawImage`) is kept as `Data` so each
render can build a decoder; a bitmap becomes an oriented `CIImage`. Loading also measures a
`PhotoAnalysis` from a 512 px decode: the sensor clip level and the camera-look fit (see Profile).

`RenderEngine` sorts plugins by `(stage, order)` and runs the active ones: those with any non-default
value, plus plugins with `runsAtDefaults` (Profile, Reconstruct Highlights). Stages, in order:

| Stage | Plugins |
|---|---|
| `raw` | white_balance (5), exposure (10), highlight_reconstruction (90) |
| `scene` | lens_corrections (10), dehaze (30) |
| `tone` | brightness (5), contrast (10), tone (30: highlights/shadows/whites/blacks), tone_curve (50) |
| `presence` | texture (10), clarity (20) |
| `color` | vibrance, saturation, color_mixer, color_grading |
| `detail` | noise_reduction (10), sharpening (20) |
| `geometry` | crop (10) |
| `effects` | graduated_filter (5), vignette (10), grain (20) |
| `output` | profile |

- **RAW:** plugins that can, set the `CIRAWFilter` in `configure(raw:)` and return true (white balance,
  exposure, noise reduction); everything else runs through `apply` on the decoded image. The decoder runs
  with `extendedDynamicRangeAmount = 1`, so highlights above 1 survive (2+ stops on a Sony A6600).
- **Working space:** linear extended sRGB, half-float (`RGBAh`). Values above 1 are normal mid-pipeline.
- **Display:** the last step maps to display range. By default it is a hue-preserving shoulder
  (`display_rolloff`: RAW knee 0.9, white 4; bitmaps untouched below 1). A plugin that returns true from
  `rendersDisplay` (Profile's camera look) takes over that job. The same kernel clears everything outside
  the image's extent (see Core Image pitfalls).
- **Output:** Display P3. Export writes through ImageIO with the original's EXIF, GPS, IPTC and camera
  TIFF fields (`ExportMetadata`), orientation 1 and the new pixel size.

### Live preview

- `PreviewSession` is per photo, sized to the canvas. A bitmap base is downscaled once and materialized
  into a GPU texture. A RAW keeps **one reused `CIRAWFilter`**: Core Image caches its demosaic, so an
  exposure tick costs ~2 ms instead of a ~200 ms re-decode. Because the filter is reused, every frame first
  restores the as-shot settings (`RAWBaseline`); a plugin that sets a decoder property not listed there
  leaves stale values in the preview.
- `EditorModel.refresh()` builds the `CIImage` graph on the main thread (cheap) and publishes it.
- `MetalCanvas` renders that graph into a `CAMetalLayer` on its own serial queue, latest-wins: it waits
  for a drawable *first*, then takes the newest job, so a fast drag never draws a stale edit. Core Image's
  per-frame setup for a RAW (5–12 ms) never blocks the main thread.
- `InspectorView` reads the document once and hands each panel a snapshot of its plugins' values;
  `PanelSection` is `Equatable` on those snapshots, so an edit redraws only the section it touched.
  Leaf controls must not read `editor.document` (that would make every control redraw on every edit).
- Measured on a 24 MP ARW: 60 fps, main thread ~4–5 ms per edit, edit → GPU done ~10–12 ms.

### App

- `EditorModel` owns the open photo: `LoadState` (empty/loading/ready/failed), `CompareMode`, `Tool`
  (none / crop / gradient, each keeping its plugin's values for Cancel). Every edit goes through
  `edit(key:)`, which records undo in a per-photo `EditHistory` (changes to the same knob within 0.6 s are
  one step) and debounces the sidecar save (400 ms).
- `LibraryModel`: the open folder, the selection, photos with a sidecar (`edited`, the filmstrip dot),
  photos removed from Knobs per folder (UserDefaults `removedPhotos`), and Move to Trash (photo + sidecar).
- `ExportModel`: the export sheet's persisted settings, single or edited-photos batches on a background
  task, progress and Stop in the toolbar.
- Tools draw SwiftUI overlays over the canvas and map points through `CanvasLayout` (a pure, tested
  image ↔ view mapping shared with the renderer). Crop shows the whole straightened frame while open
  (`context.framing == .uncropped`).
- Inspector layout is generic: `ParamControl` maps a param kind (slider, flag, choice, curve, wheel) to a
  control; params sharing a `group` render together (curves → one editor with a channel picker); runs of
  wheels share a grid; a panel can carry an action (Light's Auto). Hidden params (crop rect, gradient
  ends) are driven by canvas tools.

### Sidecar

`<photo file>.knobs`, JSON, only values that differ from the default:

```json
{ "plugins": { "exposure": { "exposure": -0.6 }, "tone": { "highlights": -80 } }, "version": 1 }
```

Plugin ids and param ids are the keys: **never rename one** once photos have been edited with it.
A corrupt sidecar is moved aside to `.knobs.corrupt`, never overwritten.

## Writing a plugin

- A `struct XPlugin: KnobPlugin` anywhere under `KnobsKit/Plugins/` is registered on the next build.
- `apply` must return the input unchanged at default values, keep pixels finite at every extreme, and keep
  the extent (geometry stage excepted). `PluginContractTests` enforces all three for every plugin.
  A plugin with `runsAtDefaults` (its default is itself a look) is exempt from identity and gets its own tests.
- Pixels are linear extended sRGB and may exceed 1. Use `KnobsKernels.h` and `Saturation/ColorOKLab.h`
  for perceptual math; do hue and saturation work in OKLab/OKLCh.
- Radii are full-resolution pixels × `context.scale`, so the preview matches the export.
- Kernel names are global across the metallib: prefix them with the plugin id (`dehaze_transmission`).
  Load kernels with `KernelLibrary.color/general/warp(name)`; they are cached.
- Budget per 4 MP frame: ≤3 ms GPU for a simple knob, ≤8 ms for multi-pass ones. No CPU work that scales
  with the image in `apply`; per-photo analysis belongs in `PhotoAnalysis`.
- Neighbour-sampling kernels return clear outside their bounds (see Core Image pitfalls).
- Geometry plugins honour `context.framing`.
- Check the look with `knobs-render --side-by-side`, the speed with `--bench`, then add behaviour tests in
  `KnobsKitTests/Plugins/<Name>Tests.swift` that test what the knob does, not just that something changed.

## Core Image pitfalls (each cost us a bug)

- Core Image may evaluate a neighbour-sampling kernel **outside its declared extent** once a later step
  moves the image (a transform, a crop, compositing), smearing edge pixels. `cropped(to:)` doesn't help:
  CI drops crops it thinks are no-ops. Kernels check their bounds and return clear outside them; the final
  display kernel clears outside the extent as a backstop.
- `CIBoxBlur`'s radius is the box *width*, rounded down to odd; radius 2 does nothing.
- Two Gaussian blurs taken from the same clamped image came back wrong at the borders; chain them instead.
- Intermediates are half floats, which breaks variance as E[x²]−E[x]²; shift values before squaring.
- Two `CIRAWFilter` decoders in one render graph: one of them renders black. Render each on its own.
- `CIRAWFilter` (the Swift API) exposes no `inputKeys`, so KVC snapshots don't work; `RAWBaseline` uses
  typed key paths.
- With extended range, Apple's decoder writes fully clipped pixels as one exact plateau value, and pixels
  with one clipped channel as exactly neutral. The plateau moves non-linearly with decoder exposure (3.21 at
  0 EV, 2.03 at −1 EV on an A6600), so highlight reconstruction measures it per frame on the GPU.

## Tooling

- `knobs-render <in> <out> [--size N] [--side-by-side] [--sidecar file.knobs] [--auto] [plugin.param=value …]`
  renders through the same engine; `--list` prints every param; `--bench <in> [values]` times a 4 MP
  preview frame on the GPU; `--auto` runs Auto tone first and prints its values.
- `Knobs -knobsProbe <log> [exposure|gradient|undo|export|library]` drives the real app and writes a
  report: frame rate, main-thread time, edit → GPU latency; undo round-trip; a 1080 px batch export into
  `<log>.export/`; library remove/restore/trash on throwaway files. The probe edits the open photo and
  restores it. Launching the app to probe quits whatever session is running, so don't probe while someone
  is using the app. In the last session the probe stopped starting at all (arguments arrived, no report);
  unexplained.
- Lightroom's sample DNGs, when Lightroom is installed:
  `/Applications/Adobe Lightroom CC/Adobe Lightroom.app/Contents/PlugIns/organize.lrmodule/Contents/Resources/Sample*.dng`.

## Known issues

Tuning
- Knob strengths were tuned by eye against memory of Lightroom, on one Sony A6600 RAW, Lightroom's samples
  and bitmaps. Expect some knobs to feel too strong or weak; calibrate against real Lightroom output.
- Badly overexposed RAWs still can't be saved where the sensor clipped (true for any editor).

Engine and plugins
- **Profile (camera look):** fitted per photo to the JPEG embedded in the RAW (tone curve + 3×3 color matrix).
  The no-preview fallback curve was hand-tuned on one camera; Adobe RGB previews are read as sRGB; grain
  and vignette run before the profile curve, so their strength follows its slope. RAWs edited before the
  profile landed now open in the camera look (their sidecars predate it).
- **Highlight reconstruction:** depends on Apple's decoder writing an exact clip plateau; fills fully clipped
  areas with a guessed color from their surroundings; costs ~1.7 ms per frame even when nothing is clipped
  (no CPU early-out yet).
- **Auto:** ~200 ms on a RAW, mostly a fresh decoder (cache the 512 px session per photo); contrast is
  judged from the interquartile spread, so flat scenes often get +20; Blacks can go large for little effect.
- **Color mixer:** Red/Orange hue shifts are smaller than Lightroom's; rotating a saturated primary blue
  turns it steel-dark; 24 sliders in one list (no Hue/Saturation/Luminance tabs).
- **Tone curve:** region sliders aren't drawn on the curve; split points are fixed; no histogram.
- **Detail:** `color_detail` has no RAW decoder equivalent; sharpening looks weaker than export at very
  small preview scales; grain doesn't soften the image the way Lightroom's does.
- **Lens corrections:** defringe only; no lateral CA removal. `CIRAWFilter` lens correction is unsupported
  for Sony + Sigma ARWs.
- **Crop:** the photo shrinks while rotating; flipping doesn't mirror an existing crop; the overlay assumes
  crop is the only geometry plugin.
- **Graduated filter:** one per photo; it runs after the crop, so it follows the frame, not the content.
- The edge-leak guard in the display kernel is defensive; the leak was never reproduced in a unit test.

App
- Filmstrip thumbnails are the camera's embedded previews, not the edited photo.
- RAW + JPEG pairs aren't grouped; export overwrites same-named files in the destination folder.
- The app icon is a legacy asset catalog; macOS 26 may frame it in a rounded square.
- No histogram, no local masks beyond the graduated filter, no presets/copy-paste of settings, no CI.

## Code style

- Calls with more than one argument use labels (Swift's default; don't add `_` to multi-arg functions).
- Model lifecycle state with an enum, never parallel `is...` booleans.
- Comments: at most three lines, end with a period, say why rather than what.
- Tests: Swift Testing, nested `@Suite`s, `@Test("should ...")`, bad flows before happy flows.
- Package manager for any JS tooling: `pnpm`.
