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

### Added
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
