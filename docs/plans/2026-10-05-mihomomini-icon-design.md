# MihomoMini App Icon

Reusing the existing menu bar shield, the app icon is drawn as a dark blue rounded tile, a teal shield and a white M-shaped line connecting nodes.

The icon is drawn in native AppKit code in `scripts/generate-icon.swift`. The build script generates ten PNG representations from 16 to 1024 pixels, then packs them with `iconutil` into `Contents/Resources/AppIcon.icns`. Info.plist points to the resource through CFBundleIconFile. The menu bar keeps a monochrome icon that suits the system's light and dark modes.

Version 1.1.1, build 3. Verification covers previews at large and small sizes, the alpha channel, the ICNS format, the build, static checks and strict code signing.
