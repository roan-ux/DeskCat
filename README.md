# DeskCat

A small macOS companion: a black cat peeking out of a yellow box with your cat's name on it.
It floats on your desktop, its eyes follow the pointer, and now and then it jumps out to explore.

Written in pure Swift + AppKit. There are no dependencies and no image assets; the cat is drawn in code.

## Run it

You need macOS 13+ and Xcode or the Command Line Tools (`xcode-select --install`).

```sh
cd desk-cat
swift run                    # quickest way to try it
./scripts/make-app.sh        # builds build/DeskCat.app (menu-bar only, ad-hoc signed)
```

On first launch it asks for a name. You can rename it any time from the 🐈‍⬛ menu-bar icon or by right-clicking the box.

## How the animation works

The cat is drawn entirely in code, but it isn't a set of fixed pictures. It's a small procedural rig:

- **Springs for everything.** Every moving part (body pose, head, ears, eyes, paw, the box popping in) eases toward a target through a damped spring (`Spring.swift`). That gives natural ease-in/out, overshoot and settle, instead of linear jumps.
- **A skeleton, not sprites.** Hips, chest and head are blended between pose keyframes (stand, sit, crouch, loaf, play-bow, leap, held), so it morphs smoothly between them. Legs use two-bone IK. While walking, the feet stay planted on the ground and step in a real four-beat gait.
- **Animation principles.** It crouches before a jump (anticipation), stretches in the air and squashes on landing (squash and stretch), and arcs on real gravity. The tail lags behind the body and settles last (follow-through). The head turns before the body (overlapping action).
- **One cat, one size.** The same rig is used in and out of the box. While it's home, its body is clipped at the box rim and its paws hook over the edge.
- **Behaviour.** It has activities instead of always chasing the pointer: sit, look around, groom, yawn, stretch, loaf, sleep, wander. It notices the pointer only when it moves nearby, and even then only sometimes (it has a "playful" mood that runs down). When interested, it watches with a curious head tilt, creeps closer, stalks and wiggles before pouncing, or bats at the pointer with a paw. It purrs when petted and startles at fast swipes.

`playground.html` runs the same code in a browser, which is the quickest way to tune it.

## What it does

| You do | The cat does |
|---|---|
| Wiggle the pointer near the box | Rises up, paws on the rim; bats at you if you get close |
| Hover gently over its head | Petting: happy eyes, purring, hearts |
| Swipe fast past the box | Ducks into the box |
| Click the cat | Crouches and jumps out; the box tucks away |
| Move slowly along the floor near it | Sometimes stalks, wiggles and pounces; sometimes just watches |
| Hold the pointer just in front of it | May swat at it |
| Swipe fast right next to it | Startles and hops away |
| Drag the cat | Picks it up by the scruff; the box reappears so you can drop it in |
| Leave it alone | Grooms, yawns, stretches, loafs, falls asleep; eventually goes home |
| Menu bar → Call back | Walks to the box and hops in |

"Wander on its own" (on by default) lets it leave the box every few minutes.

## Settings

Menu bar cat → **Settings…** (⌘,). Everything applies live and is remembered:

- **Name** on the box
- **Coat** and **Eyes** colour: presets, or any colour from the colour well
- **Size**: small, medium, large
- **Personality**: calm (plays less, stays in the box longer), normal, playful
- **Box colour**: presets or any colour; the cardboard shading follows it
- **Wander out of the box on its own**, **Open at login** (the login option needs the bundled `DeskCat.app`)

To add another option: add a field to `Look` in `Look.swift` (with its save/load key), derive any colours in `Palette`, add a control to `SettingsWindow.swift`, and read it where it's drawn or simulated.

## Code map

| File | Role |
|---|---|
| `CatSim.swift` | Skeleton, physics and behaviour (port of the playground's logic) |
| `CatDrawing.swift` | Draws the cat with Core Graphics |
| `Spring.swift` | Damped spring and small math helpers |
| `CatController.swift` | Windows, display-synced frame loop, dragging |
| `BoxView.swift` / `CatView.swift` | The box window and the cat window |
| `AppDelegate.swift` | Menu-bar icon, menu, rename dialog |
| `PetWindow.swift` | Transparent, always-on-top, non-activating panel |
| `Look.swift` | Customisable look and personality, and the colours derived from it |
| `SettingsWindow.swift` | The Settings window |
| `Settings.swift` | Name, box position, roaming toggle |

## Lightweight

- One frame loop synced to the display (`CADisplayLink` on macOS 14+, a 60 Hz timer on 13). It drops to 20 fps while the cat dozes.
- No dependencies, no image assets, no SpriteKit or WebView. Two small transparent windows, drawn with Core Graphics.
- No permissions needed. Clicks on transparent pixels fall through to the apps underneath.
