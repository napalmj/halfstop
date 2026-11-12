# Handoff: Halfstop — performance, editing speed, usability

Audit date: 2026-11-11. Audited branch `import-and-collections` with uncommitted work (trash/delete,
Help window, LibraryStore/LibraryViews/Catalog changes). It builds clean (`swift build -c release`).
**Before you start:** ask the user whether to commit that work first, or branch on top of it.
Don't mix it into your commits without asking.

## Context you need

- Native macOS SwiftUI + Core Image/Metal app, Swift package, **no full Xcode**, so use only
  command line tools. Build with `./scripts/bundle.sh`, which produces `build/Halfstop.app`.
- Checks: `build/Halfstop.app/Contents/MacOS/Halfstop --selftest /tmp/halfstop-test` (pipeline assertions in
  `Sources/Halfstop/App/SelfTest.swift`), plus `--make-samples` and `--snapshot` (see README).
  Add a selftest case for every pipeline change.
- The user built this to replace their previous photo editor. Their stated pain points are **laggy sliders, cluttered UI,
  and slow import/catalogs**. How the app feels matters more than how many features it has.
- **The user wants a clickable design mockup before any new UI gets built**, and wants to approve it.
  This applies to every item marked 🎨 below. Pure performance work needs no mockup.
- Render path: `PreviewArea` (Editor/EditorView.swift), then `PreviewImageView`/`PreviewMTKView`
  (Editor/PreviewRenderer.swift). `draw()` calls `ImageSource.developed(...)` (Rendering/ImageSource.swift)
  **on the main thread**, which builds the CI graph and runs the CPU work it needs (LUT, brush raster).
  After that it encodes to the drawable.

---

## P0: Editing performance (do these first)

### 1. Preview renders at the full 3200 px source, whatever the on-screen size
`PreviewRenderer.previewPixelSize = 3200` (PreviewRenderer.swift:11). The whole filter chain runs at that
size: RAW develop, highlight/shadow (radius = longEdge/200), noise reduction, mask blurs, and sharpening.
Only at the end is it scaled down to the drawable (`encode`, ~line 186). A typical preview pane is about
1600×1000 drawable pixels, so the GPU does roughly 4× the work it needs to on every slider tick.
- **Fix:** add a `renderScale` parameter to `developed()`. Scale the source down to the drawable's
  long edge first. For RAW, either set `CIRAWFilter.scaleFactor` (this re-decodes, so keep one decoded
  instance per scale tier) or transform `raw.outputImage`. All radii already scale with `longEdge`, so
  the look stays the same. Keep full 3200 px for zoom > fit (see #8).
- Optional, more speed: a **draft tier** while dragging (0.5× drawable) and full quality ~150 ms after
  release. `AdjustSlider` already knows `dragging`, so expose it through the store
  (e.g. `store.isScrubbing`).
- **Accept when:** Exposure/Highlights drags on a 45 MP RAW hold 60 fps on Apple Silicon (check with
  Instruments' Metal System Trace, or log frame times in `draw`), and selftest still passes.

### 2. The histogram re-runs the whole develop pipeline on a second context after every frame
`onRendered` → `requestHistogram` (EditorView.swift:78, PreviewRenderer.swift:113, :178) takes the
**unrendered** CIImage graph and renders it again on `Render.background`, which has
`cacheIntermediates: false` (RenderServices.swift). For RAW that means a second RAW develop per frame,
competing with the preview for the GPU.
- **Fix:** compute the histogram from what was already rendered. Run `CIAreaHistogram` on the drawable
  texture (`CIImage(mtlTexture:)`) inside the same command buffer, or on a cached small rendition.
  Throttle it to about 8 Hz, and skip it while `isScrubbing` (refresh on release).

### 3. Brush painting re-rasterizes every stroke on the CPU, on the main thread, for every mouse move
Each drag point appends to `strokes` (EditorView.swift:312). That changes the hash in
`MaskRenderer.brush` (MaskRenderer.swift:154), so the cache misses and `rasterize` (:191) redraws
**all** strokes with CG radial-gradient dabs at up to 2048 px. The cost grows with total stroke length,
which is why lag builds up over a painting session. Refine strokes on automatic masks are worse:
`refine` (:172) also does a synchronous GPU readback (`createCGImage`) for each point.
- **Fix:** paint incrementally. Keep a per-mask `CGContext` (or an `MTLTexture`) holding the strokes
  committed so far, and stamp only the new dabs of the active stroke onto it. Rebuild from scratch only
  on undo, history jumps, or a size change. For refine, cache the base-mask readback once per gesture,
  not per point.
- Also simplify stroke points as they come in (drop points closer than ~0.25 × radius, or run RDP on
  stroke end). That keeps sidecars and history small (see #6).
- **Accept when:** a 30-second continuous brush session stays smooth. Add a selftest checking that the
  incremental raster matches the full re-raster (pixel diff < 1/255).

### 4. Rebuilding the LUT allocates on the heap per cell, on the main thread
`ColorLUT.build` (ColorLUT.swift:62) fills 48³ = 110,592 cells. When HSL is active, `bandWeights` (:108)
allocates an array per cell, and grading allocates `[ws, wm, wh]` per cell (:188). Every tick of an
HSL, color-wheel, curve, contrast, whites or blacks control rebuilds the LUT synchronously in `draw()`.
- **Quick fix:** remove the per-cell allocations (fixed-size tuples or `withUnsafeTemporaryAllocation`)
  and spread the `b` slices across `DispatchQueue.concurrentPerform`. Expect 10× or better.
- **Better fix:** replace the LUT with a Metal `CIColorKernel` that takes the tone table as a 1-D
  texture and HSL/grading as uniforms. Then there's no CPU work per tick. Keep the LUT path for
  selftest parity.

### 5. The SwiftUI observation fan-out costs O(photos × sliders) per tick
- `store.current` (LibraryStore.swift:204) does `photos.first { $0.url == currentID }`, a linear scan
  with URL equality. Every `ScopedSlider` calls it through `scopedValue` (:871), so a Detailed panel of
  about 40 controls scans the whole library about 40 times per tick. It also registers an observation
  on the whole `photos` array.
  **Fix:** keep a `[URL: Photo]` index (next to `photoByRef`) and/or cache `currentPhoto` as a stored
  property updated in `setCurrent`.
- `visiblePhotos` (:168) is computed and re-filters the library on every access. It's called several
  times per body (grid overlay ×3, filmstrip, `prepare`, `step`, `GridCell.contextTargets`).
  **Fix:** make it a stored array, recomputed when source, filters, photos, or a photo's
  rating/flag/edited state changes.
- `Photo.adjustments` is a single observed property, so every tick re-evaluates every panel section.
  Consider passing slider values down as plain values from one parent instead of letting each slider
  read the store. Measure with `Self._printChanges()` before and after.
- `PreviewToken` (EditorView.swift:25) hashes and compares the full `Adjustments` (including every brush
  point) on each body/update. Replace it with a cheap monotonically increasing `editRevision: Int` on
  `Photo`.

### 6. Sidecars grow roughly quadratically and get rewritten 0.5 s after every change
`HistoryStep` stores the **full** `Adjustments`, strokes included, for up to 100 steps (Photo.swift,
LibraryStore.swift:625). On a brush-heavy photo, every stroke is stored about 100 times. On top of that,
`writeSidecar` pretty-prints (LibraryStore.swift:484), and `scheduleSave` copies and encodes everything
each time.
- **Fix:** move history into a separate file (`.halfstop/<name>.history.json`) written on commit, not per
  tick. Store only the changed top-level fields per step, or dedupe masks by id and revision. Drop
  `.prettyPrinted`. Keep the main sidecar small: rating, flag, current adjustments, snapshots. Stay
  backward compatible with the existing `Sidecar` decoder (it already tolerates missing keys).

### 7. Smaller items
- `ThumbnailService` caches have count limits (2000 each, RenderServices.swift:34) but no **cost**
  limit. 2000 edited 640 px images is about 2 GB. Set `totalCostLimit` with cost = bytesPerRow × height.
- `PreviewRenderer` LRU keeps only 5 decoded sources (:87), which is fine. Prefetch 2 neighbors in the
  direction of travel instead of ±1.
- The sky mask (MaskRenderer.swift:100) runs a large Gaussian blur at full res every frame. Cache it
  like subject masks: keyed by url plus a hash of the base image's global adjustments, at
  1024–2048 px.
- Export (LibraryViews.swift:528) runs serially with no cancel. Run 2 jobs at a time, add Cancel, and
  reuse one CIContext.

---

## P1: Usability and faster editing

| # | Change | Why | Files |
|---|---|---|---|
| 8 🎨 | **Zoom and pan**: Z or click toggles Fit / 100% at the cursor; space-drag pans; ⌘+/⌘−; a small navigator thumbnail | There is currently **no zoom at all**, so sharpening, noise reduction and precise brush/mask work can't be judged. This is the biggest editing gap | EditorView `PreviewArea`, `PreviewMTKView.encode` (needs a viewport transform), `MaskOverlay`/`CropOverlay` coordinate mapping |
| 9 | **Faster slider input**: hover + scroll wheel adjusts; ↑/↓ nudges the hovered slider (⇧ = ×10); click the value to type a number; keep the ⌥ fine-drag | Familiar from other editors; much faster than dragging | Components/AdjustSlider.swift |
| 10 | **White-balance eyedropper** (W) and **Auto** buttons (Auto tone via `CIImage.autoAdjustmentFilters`, Auto WB) | Most common first steps on any photo | ImageSource, AdjustPanel (Color section), store |
| 11 | **Clipping overlay** (J): blue for crushed shadows, red for blown highlights | The histogram already computes clip fractions but nothing shows where | ImageSource (overlay pass like the mask overlay) |
| 12 🎨 | **Before/after modes**: hold `\` for a momentary before, plus split and side-by-side | One toggle is slow for A/B checks | EditorView, PreviewMTKView |
| 13 | **Selective paste and sync**: paste dialog with group checkboxes (Light, Color, Grading, Curve, HSL, Detail, Masks, Crop); "Paste from previous" (⌥⌘V) | Paste currently copies everything except crop (LibraryStore.swift:906) | LibraryStore, new sheet |
| 14 | **Culling speed**: optional auto-advance after a rating or flag (toggle on/off); full-screen loupe in the library (Space) | Faster culling of a shoot | LibraryStore `setRating`/`setFlag`, HalfstopApp key monitor |
| 15 | **Sort**: capture date, name, rating, edited. The grid is in filesystem enumeration order today | Basic library need | LibraryStore `visiblePhotos`, toolbar |
| 16 | **Preset hover preview**: show the preset on the preview while hovering it in the menu | Quicker preset choice | PanelFooter, PreviewArea (temporary adjustments) |
| 17 | **Panel declutter** 🎨: "solo" sections (opening one collapses the others) and a "Modified only" filter | Detailed tab is a long scroll; this fits the user's "minimal UI" goal | AdjustPanel `DetailedPanel`, `PanelSection` |
| 18 | **Export keeps metadata** (EXIF/GPS/copyright, with a "strip location" option), plus export presets and "Export again" (⌥⇧⌘E) | Exports currently drop all metadata. `Exporter` never copies source properties (RenderServices.swift) | RenderServices `Exporter`, export sheet |
| 19 🎨 | **Rating filter on the filmstrip**: a compact star row at the strip's leading edge (click ★3 = "3★ and up", click the lit star again to clear), with the count it shows, e.g. "42 of 378". See notes below the table | In Edit mode the only rating filter is in the toolbar Filter menu, so narrowing the strip to your picks while editing takes several clicks | EditorView `Filmstrip` (:391), LibraryStore `minRating`/`visiblePhotos`/`step`/`setRating` |

**Notes for #19**
- The filmstrip already shows `store.visiblePhotos`, which applies `minRating` (LibraryStore.swift:262).
  The new control is just a faster way to set that **same** `minRating`. Don't add separate filmstrip
  state; the toolbar Filter label (`filterLabel`, LibraryViews.swift:294) and the library grid then stay
  in sync.
- Ask in the mockup whether "exactly N★" is wanted as well as "N★ and up" (⌥-click, say). Today's
  picker only has "and up".
- **Fix an existing bug at the same time:** if you lower the current photo's rating below the filter,
  it drops out of `visiblePhotos` but stays current, because `setRating` doesn't re-check visibility.
  The strip then loses its highlight, and `step()` falls back to index 0, so ← / → jumps to the start
  of the strip. Keep the current photo in the strip (dimmed) until you move off it, and step from the
  position it had. Add a selftest case: filter 3★, rate the current photo 1★, step → lands on the next
  photo, not the first.
- Show an empty state in the strip ("No 5★ photos · Clear filter") instead of a blank bar.

## P2: Library and import scale

- **Persistent thumbnail cache** in `~/Library/Caches/Halfstop/thumbs/<fingerprint>-<adjHash>.heic`.
  Today every launch re-extracts every embedded preview and re-renders every edited thumbnail.
- **Incremental rescans**: `FolderWatcher` → `reload()` rescans every folder and re-reads sidecars on
  any FSEvent. Use the event paths to rescan only the affected folder(s).
- **Parallel sidecar reads** in `scanCatalog` (LibraryStore.swift:276), e.g. `concurrentPerform` per
  folder. JSON decode of history-heavy sidecars dominates (and #6 shrinks it).
- `Photo` init per scanned item happens on the main actor (:252). For 10k+ photos, build the photos
  off-main and assign once.

## Suggested order

1. Measure first: add a frame-time log in `PreviewMTKView.draw` (and a `--bench` selftest that develops
   a sample at 3200 px with HSL + brush + subject mask and prints ms). Record baseline numbers in the PR.
2. Do #5, #2, #1, #4 and #3 as separate small PRs, checking the numbers after each.
3. Do #6 (sidecar format) carefully. It needs a backward-compat test that loads an old sidecar.
4. Then the P1 items: no-mockup items (#9–11, #13–15, #18) first, mockup items (#8, #12, #16, #17, #19) after
   the user approves a sketch. The #19 current-photo bug fix needs no mockup, so it can go in early.

## Done means

- Measured before/after numbers for drags (global slider, HSL, brush) on a large RAW.
- `--selftest` passes, with new cases for each pipeline change.
- README key table and Help window (`App/HelpView.swift`) updated for any new shortcuts.
