# Knobs

Lightroom-style photo editing on the Mac, with every control a plugin.

```bash
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain
scripts/generate.sh
open Knobs.xcodeproj
```

Edits are stored next to each photo as `<file>.knobs` JSON. Originals are never written.
