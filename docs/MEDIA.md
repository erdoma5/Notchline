# Demo media provenance

The README media are selected from the Notchline product showcase and app-generated previews. They contain demonstration content, not the user's desktop, saved clippings, or private files.

| File | Purpose | Source |
| --- | --- | --- |
| `assets/notchline-showcase.mp4` | 72-second, 1920×1080, 30 fps H.264/AAC showcase | Programmatic scenes using native Notchline visual assets |
| `assets/overview.png` | Collection overview | Showcase keyframe |
| `assets/video-cover.png` | Video cover | Showcase keyframe |
| `assets/paper-plane.png` | Paste feedback | Showcase poster |
| `assets/color-clippings.png` | Paper-color examples | Application-rendered demonstration |

## How the showcase was made

- The Notchline icon comes from the original vector artwork in `scripts/make-notched-icon.swift`.
- Paper clippings, clothes pegs, and paper-plane poses are rendered from the app's Swift drawing code, using demonstration text.
- The landscape sample, desktop background, and editor are drawn demonstration scenery, not desktop recordings or third-party photographs.
- Music and sound effects are synthesized in code. No external music track or font file is redistributed.
- Some motion is slowed to explain the interaction. The click comparison is slowed by 1.7×. Offline glass rendering and added presentation outlines may differ from a live desktop.
- The video illustrates the Clothesline appearance. It does not claim to demonstrate every feature or the current Particle emergence theme.

The native assets derive in part from Tendedero, so the attribution and license in [../LICENSE](../LICENSE) and [../ACKNOWLEDGEMENTS.md](../ACKNOWLEDGEMENTS.md) apply. The internal movie-making workspace and third-party production tooling are not included in this repository.

Video SHA-256: `1cd9ccd9d2a49d2afaf5c82d4a7990a551fdb85e4738ffdbfbf4927baffc9c1f`.
