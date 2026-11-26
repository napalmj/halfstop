# Changelog

All notable changes to Halfstop are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Renamed the app from Pixon to Halfstop. On first launch, the library, presets, settings and
  thumbnail cache move to the new name, and each photo folder's hidden `.pixon` sidecar folder is
  renamed to `.halfstop` the first time Halfstop reads it.
- Auto tone, Auto WB and the white balance picker measure in the background, so the editor stays
  responsive; the chip shows a spinner meanwhile. They are much faster (auto white balance went
  from about 640 ms to under 10 ms on a 24 MP JPEG), and repeating one, or undo then redo, is instant.
- The auto row reads `[✦ Auto] [Tone] [WB] [eyedropper]`; "Auto tone" and "Auto WB" are now "Tone" and
  "WB" (full names in their tooltips). Auto tone leaves a well-exposed photo nearly alone and no longer
  drags low-key, high-key or night photos toward middle gray.

### Added
- Tone curve modes: Parametric (Highlights, Lights, Darks and Shadows sliders with movable region
  splits) and Point, with separate Red, Green and Blue curves, a histogram of the channel behind each,
  and Medium contrast, Matte and Flat shortcuts.
- Hue curves in HSL (hue, saturation and luminance over the color wheel) and Target adjust (T): drag
  up or down on a color in the photo to change it.
- Texture, Clarity and Dehaze, globally and in masks. Clarity holds back along hard edges and Dehaze
  never pushes dark edges next to bright sky to black, so neither draws halos.
- Grain (amount, size, roughness) in Effects.
- Lens section: lens profile switch (RAW), remove color fringing, manual distortion and lens vignetting.
- Spot removal (Q): click a spot and a nearby clean patch is copied over it and color-matched to its
  surroundings; drag the spot or its source, resize with [ ], remove with ⌥-click or Delete.
- Mask ranges: limit any mask to a brightness band or a picked color.
- The `halfstop` command sets texture, clarity, dehaze, grain, grain_size, grain_roughness,
  lens_distortion and lens_vignetting, and `info` reports hue curves, removed spots and lens switches.
- ✦ Auto at the top of the Basic panel (and of Light in Detailed): white balance (balanced on the photo's grayest pixels),
  exposure, contrast, highlights, shadows, whites, blacks and vibrance in one undoable step. It
  reads the scene, so a well-exposed photo barely changes and low-key, high-key and night photos
  keep their mood; vibrance holds back on skin tones.
- ✦ Auto finds faces on the device: it keeps skin from turning green or magenta, leans exposure
  toward the faces, and holds vibrance back. It also takes Core Image's own auto-enhance suggestions
  as a second opinion that nudges its values a little, never replacing them.
- Auto straighten in Crop & straighten: levels a tilted horizon (up to 10°) as one undoable step
  "Auto straighten", or shows "No horizon found". ✦ Auto never changes the crop or angle.
- Learn from my edits (Settings, on by default): once 20 photos you edited have been measured
  (each is measured in the background after you edit it), ✦ Auto adds what you usually change on
  similar photos, from your own edits only and entirely on this Mac. Its tooltip then reads "Auto
  (adapted to your edits)".
- The `halfstop` command-line tool (the app's own executable, linked onto your `PATH`; Settings ▸
  Command-line tool shows how): `info`, `get`, `set` (absolute and relative slider values, clamped
  to their ranges), `auto`, `straighten`, `undo`, `redo` and `render` (a small JPEG of the current
  edit, without metadata), for many photos at once, with `--json` output. An AI agent with a shell,
  such as Claude Code, can use it to edit photos with you. Edits go only to Halfstop's sidecar files,
  one undoable history step per photo per command; photo files are never changed. It reads and
  writes only local files.
- The open app picks up edits made outside it (the `halfstop` command) within a second: editor,
  thumbnail and histogram update, and the change is an undoable step. If the app had unsaved changes
  to the same photo, both are kept: the outside version, then the app's changes on top as one step.
  Saves never overwrite a newer version on disk.
- A Settings window (⌘,).
- README with install and usage instructions, a user guide and an architecture overview.
- MIT license, contributing guide, code of conduct, security policy and GitHub issue and pull
  request templates.
- Move to Trash and Delete Rejected Photos, rating controls in the editor, and a searchable Help window.
- `--bench` command line mode to time live-preview frames and the auto adjustments.

## [0.1.0]

Initial public development version.

### Added
- Import in place with duplicate skipping, presets, optional renaming and collections; watched folders.
- Library with folders, manual collections, ratings, pick/reject flags, filters and multi-select.
- Quick and Detailed editing, tone curve, HSL, color grading and detail controls.
- Brush, linear, radial, subject and sky masks with refinement.
- Crop and straighten, edit history with snapshots, presets, copy/paste settings, undo/redo.
- Export to JPEG, HEIC and 16-bit TIFF; RAW support through Core Image.
- App icon and `scripts/bundle.sh` to build `Halfstop.app`.
