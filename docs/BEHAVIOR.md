# Detailed behavior and upgrade notes

Notchline is a local, renamed build based on the MIT-licensed source of
Tendedero v1.7.0 by Alejandro Buján. The Notchline name and icon are original
to this personal edition. The upstream license is included in `../LICENSE` and
in the built app bundle.

## Behavior

- **Appearance > Particle emergence** replaces the former Holographic field.
  A fixed upper-center light source casts two feathered stage-light beams onto
  the scan curtains, which travel from the shelf ends toward its center. Card
  pixels materialize only after a scanner passes their fixed screen position;
  the central fusion settles into persistent projection light. Closing reverses
  the same sweep. New arrivals and returned originals still condense locally,
  without rescanning the whole row. The completed cards are sharp and retain their original
  colors, with soft mint-white light behind their edges. Cards share a straight
  bottom edge seated in a recessed translucent shelf. Its front lip and contact
  shadows ground the collection; hovering and pressing keep each lower edge in
  the slot. Drag a card’s lower edge back to that slot to return it. The shelf,
  card hit targets, capture/paste flights and return band share one geometry.
  The moving beams fade into a quiet fan from the same source once the cards
  settle. There is no enclosing HUD. Closing recedes into the same
  screen area; clicking sends a local pulse, double-click pastes immediately and
  sends a continuous stream of independently timed light particles to a verified
  editor when available. A copy dissolves at its source, particles travel with
  short luminous tails and fan into a soft horizontal sheen at the destination.
  The approximately 88pt sheen grows from the input point, feathers at both ends
  and fades completely, replacing the former circular landing marker. Its extent
  is fitted to the destination display; the original returns
  while the stream is still moving. Switching themes or apps cancels the effect
  without affecting the already-dispatched paste. Detached cards follow
  the pointer with readable content. Outside the return slot, their backing light
  weakens and short corner lights signal pending removal. Returning reverses that
  cue; releasing evaporates the stationary image from its upper edge and sides
  into fine rising, receding motes over 0.60 seconds. No ring or fragments remain.
  Put back / ⌘Z, Quick Look, Markup, recording handling, scrolling and clipboard
  collection retain their behavior. Reduce Motion uses a static reveal, while
  Reduce Transparency supplies readable backing. The saved theme identifier is
  retained, so existing Holographic field selections adopt Particle emergence
  automatically. Clothesline remains available. Idle particle views have no timer.
- On macOS 26 and later, photo frames and feedback capsules use native Liquid
  Glass. Photos stay sharp above the glass frame, and text clippings keep their
  paper surface. Earlier systems retain the frosted materials.
- On a display with a camera notch, only the notch gap reported by AppKit's
  `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` reveals the line.
- On displays without a notch, the middle third of the menu bar reveals it.
- The reveal delay and every other reveal path remain at their v1.7.0 values.
- At first launch, common preferences are copied from Tendedero if Notchline
  has no value for them. Saved photos and screenshot takeover are not copied.
- The menu bar icon uses the same curved rope, two pegs and hanging photo as
  the app icon. Outlined pegs mean clipboard watching is off; filled pegs mean
  it is on.
- **Hang copied images** and **Hang copied text** are on by default. Under
  **New clipping style**, choose **Random colors** (the default) or **Classic cream**.
  New text clippings use a soft butter, mint, rose, sky, lilac or peach tint. Existing clippings
  keep their paper color, including in hover previews and after a restart.
  Hover for a larger typeset excerpt, click to copy the full text,
  or double-click to paste it into the focused editor. Hold to preview the file,
  or choose **Open** from its context menu. Clippings are saved locally under
  `~/Library/Application Support/Notchline/Text Clips`. Blank, private-marked and over-1-MiB
  text copies are skipped.
- A photo hovered for 0.42 seconds opens a passive enlargement below the line.
  Hovering another photo switches it after 0.12 seconds; leaving the photos
  closes it after 0.25 seconds. The panel is mouse-transparent and cannot
  cover the cards.
- Click anywhere on a photo to copy it. A small confirmation appears below it.
  Double-click pastes the image into an editor that accepts images. Holding opens
  Markup and force-click opens Quick Look. Double-clicking a recording opens its file.
- Double-click writes the clipping or image to the clipboard and sends ⌘V once
  to the app that was frontmost on the second press. The receiving app handles
  Paste, including chat inputs that do not expose an accessibility text field.
  Switching apps or input fields, pressing a key, or right-clicking cancels dispatch.
  The matched press and release on the clipping count as one paste gesture. Further
  left clicks must belong to the line or leave the same input field and selection verifiable. Identifiable password fields are excluded. Images need an editor
  that accepts them. A newer clipboard copy cancels
  the pending paste. Use **Double-click paste access** in the menu bar to see
  whether the running copy is authorized and open its privacy settings. If macOS
  shows an enabled entry but the menu reports missing access after an upgrade,
  remove just the Notchline entry and add the installed app again. **Show this
  app in Finder** identifies the correct bundle.
- After a text paste is sent, the clipping folds into a paper airplane and glides to the
  caret or visible editor. The original stays on the line. Choose **Clipping flight speed** in the menu bar for fast, medium
  (default), or slow. Reduce Motion or an unavailable destination uses the usual cue.
- **Open** on a clipboard clipping opens the local copy Notchline saved: a UTF-8
  text file in `Text Clips` or a PNG in `Screenshots`, both under
  `~/Library/Application Support/Notchline`. A screenshot or image collected
  from a watched folder opens the existing file at its recorded path.
- Pull a photo off its pin and it follows the pointer anywhere on the screen.
  Release to scatter it into flecks of the image. Release with any part of the
  photo touching the rope to return it to its pin. This gesture keeps the original file,
  including inbox captures. Use Put back (or ⌘Z over the line) to rehang it.

## Build

Run `bash scripts/build-app.sh release` from this directory. It makes a universal,
locally signed app in `build/Notchline.app.zip`. Keeping development builds
zipped prevents a second Notchline icon from appearing in Launchpad.
For stable signing across upgrades, set `git config --local notchline.signingIdentity`
with the name or fingerprint of the code-signing certificate used for the
previous release, or provide `NOTCHLINE_SIGNING_IDENTITY` when building.
A release requires a configured signing identity. Only debug builds may fall
back to ad hoc signing. Privacy permissions are still granted by macOS.
Run `bash scripts/package-dmg.sh` to make the versioned DMG for colleagues. Quit
the old Notchline, drag the new app into the old app’s folder, and choose Replace.
The bundle ID stays `local.notchline.personal`, so existing preferences and
hanging items are used by the replacement. The build is locally signed and
macOS may ask for manual approval on another computer's first launch.
For every upgrade, keep the app bundle named `Notchline.app`, the executable
named `Notchline`, and the bundle ID `local.notchline.personal`. Increase both
`CFBundleShortVersionString` and `CFBundleVersion` before packaging. The DMG
packager checks the identity and refuses to overwrite a DMG with the same
version. Replace the previous app in its existing installation folder, then
verify one Notchline is running and the user's preferences are still present.
The icon is drawn from original vector
paths in `scripts/make-notched-icon.swift` and packed into `Notchline.icns`.

Quit the installed Notchline before replacing its app bundle. Its bundle ID is
`local.notchline.personal`; its screenshot folder is
`~/Library/Application Support/Notchline/Screenshots`.
