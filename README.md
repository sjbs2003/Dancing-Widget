# MastiKhor

A tiny macOS menu-bar app that shows a transparent, floating dancer on your screen whenever **Apple Music** is playing. Music stops, the dancer disappears.

## How it works

- Listens for Apple Music's play/pause notifications (no polling, almost no CPU).
- Loads your clips from `Resources/` (a `.gif` and an `.mp4`), strips the checkerboard/light background, and plays them in a loop in a click-through window pinned to the bottom-right corner.
- Playlist: the `aman` video plays once, then the `shinchan` gif plays 3 times, then repeats.
- Lives in the menu bar (music note icon) where you can switch the dancer on/off or quit.

## Setup

The media files are **not** included in this repo. Add your own:

1. Put your files in `Resources/`, named `shinchan.gif` and `aman.mp4`
   (or edit the names in the `playlist` in `Sources/main.swift`).
2. Adjust the `crop` values in the playlist so they frame your dancer, and tweak the background-removal colour check if your background isn't light/checkerboard.
3. Build and run:

```sh
./build.sh
open build/MastiKhor.app
```

Requires macOS with the Xcode Command Line Tools (`xcode-select --install`). No Xcode needed.

The first time you switch it on, macOS asks for permission to talk to Music. Allow it.
