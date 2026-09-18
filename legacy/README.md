# Legacy Swift LightStar

This tree is the native Swift 6 / Xcode app (macOS menu bar + iOS remote + widgets)
that LightStar shipped before the Tauri + Next.js rewrite.

It is kept for protocol reference and as a fallback. **Do not add features here.**
The product is the Tauri app at the repository root.

Build (macOS only):

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme LightStar -configuration Debug
```
