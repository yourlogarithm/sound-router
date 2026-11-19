# SoundRouter

macOS menu-bar app that plays an audio input device live on your current output — the missing
equivalent of Windows' "Listen to this device" checkbox.

Built for an HDMI capture card (shows up as `HC-V9 Audio`) carrying PS5 sound, but works with any
input device.

## Features

- One toggle in the menu bar to start/stop playthrough
- Pick any input device; defaults to `HC-V9 Audio`
- Follows output changes (AirPods ↔ speakers) without touching the AirPods mic
- Remembers its state and resumes when the device or dock is plugged back in
- Launch at login
- ~20 ms buffer, adjustable

## Build

Requires macOS 15+ and the Xcode command line tools (`xcode-select --install`).

```sh
./build.sh
open SoundRouter.app
```

Move `SoundRouter.app` to `/Applications` if you want to use **Launch at login**.

On first start macOS asks for microphone access (needed to read any audio input). The app is
ad-hoc signed, so it may ask again after a rebuild.

## Latency

Default buffer is 20 ms. Lower means less delay but more risk of dropouts:

```sh
defaults write local.soundrouter latencyMs 10
```

Restart the app to apply. Bluetooth headphones add their own ~150–200 ms on top; use wired
output or built-in speakers for the tightest sync with video.

## How it works

Two `AVAudioEngine`s — one pinned to the input device (`AVAudioSinkNode`), one on the default
output (`AVAudioSourceNode`) — bridged by a lock-free ring buffer. A single engine can't do it on
macOS because its input and output share one device. The ring holds a target latency, re-buffers
after an underrun, and jumps forward when clock drift between the two devices builds a backlog.

Ring buffer self-test:

```sh
SoundRouter.app/Contents/MacOS/SoundRouter --test
```

## License

[MIT](LICENSE)
