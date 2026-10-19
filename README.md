# Clementine

A small macOS menu-bar app for converting files with a drag wheel.

Start dragging any file in Finder or on your Desktop, then hold a key while you're still dragging. A wheel opens under your pointer. Let go on a slice and the new file appears next to the original.

| Key while dragging | Wheel | What's on it |
| --- | --- | --- |
| Shift | Convert | PNG, JPEG, HEIC, TIFF, GIF, BMP, PDF, Word, RTF, HTML, text, CSV, JSON, TSV, MP4, MOV, M4A, WAV, AIFF |
| Command or Option | Tools | Rotate, flip, half size, grayscale, compress, combine images into one PDF, merge PDFs, split PDF pages, video snapshot |
| Control | File actions | SHA-256 checksum, copy path, show in Finder, duplicate |

Let go in the middle of the wheel to cancel. Everything runs on your Mac; nothing is uploaded.

## Build and install

You need macOS 13 or later and Apple's Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/LightTheEgyptian/clementine.git
cd clementine
./build.sh
```

Or double-click **Build Clementine.command** in Finder. The script compiles the app with `swiftc`, signs it locally and installs it in Applications.

## How it works

- `DragWatcher.swift` notices a file drag anywhere on screen by watching the mouse button and the system drag pasteboard. No extra permissions are needed.
- `Wheel.swift` draws the radial menu (a frosted ring with spring-animated highlight) and accepts the drop.
- `Engine.swift` does the conversions with Apple's own frameworks: ImageIO, PDFKit, AVFoundation and AppKit's document readers.
- `HUD.swift` shows progress in a black bar that slides down from the notch.
