# Halfstop user guide

This guide walks through a typical session. For installation see the [README](../README.md). Inside
the app, **Help ▸ Halfstop Help (⌘?)** has a searchable list of every shortcut.

## Importing photos

Choose **File ▸ Import Photos… (⌘I)**, or drop a folder onto the window.

Halfstop works on photos **where they are**. Nothing is copied. It remembers the folder and picks up new
files added to it later. The import sheet offers:

| Option | What it does |
| --- | --- |
| Include subfolders | Also imports photos in folders inside the one you chose |
| Skip duplicates | Skips files whose content is already in your library, even under another name |
| Apply preset | Applies one of your saved presets to every imported photo |
| Rename files | Renames the original files on disk with a pattern (date-sequence, custom name-sequence, or date plus original name). Off by default. Revert it from **Last import** |
| Add to collection | Files the imported photos into a collection |

If you move an imported folder, right-click it in the sidebar and choose **Locate folder…** to point
Halfstop at the new place. Your edits come along because they are stored next to the photos.

## The library

The sidebar lists **All photos**, **Last import**, your **Folders** and your **Collections**.

- **Rate** with **1–5** (press the same number again to clear, **0** clears). **Pick** with **P**,
  **reject** with **X**, **unflag** with **U**.
- **Select** several photos with ⇧-click (range) or ⌘-click (add). Most actions, such as paste
  settings or move to Trash, apply to the whole selection.
- **Filter** by flag (All, Picks, Unflagged, Rejected) and by edited or unedited from the filter menu.
- **Collections** are manual groups of photos. Create one in the sidebar, then drag photos onto it, or
  make it the target and press **B** to add the selection. A photo can be in many collections, and
  removing it from one (Delete while viewing the collection) does not delete the file.

## Editing

Press **E** or **Return** on a photo. Use ← → to move to the next photo and **G** to return to the library.

- **Quick** tab: exposure, contrast, highlights, shadows, temperature, saturation, vignette.
- **Detailed** tab (press **D** to switch): full light and color, color grading wheels, tone curve,
  HSL and detail (sharpening, noise reduction).
- **Double-click** any slider to reset it. Hold **⌥** while dragging for fine control.
- **\\** shows the original for comparison.
- **Crop and straighten**: press **C** (or **R**). **Esc** leaves the tool.

### Auto adjustments

The row at the top of **Basic** (Quick tab) and **Light** (Detailed tab) reads **✦ Auto · Tone · WB · eyedropper**.
Each one measures the photo in the background (the chip shows a small spinner) and then applies its
result as **one history step**, so a single **⌘Z** takes it back. If you move to another photo or
change the edits while it measures, the result is dropped rather than applied on top of your change.

- **✦ Auto** sets white balance, exposure, contrast, highlights, shadows, whites, blacks and vibrance
  together, as the step "Auto". It reads the scene first: a photo that is already well exposed barely
  changes, and dark (low-key), bright (high-key) and night photos keep their mood instead of being
  pulled toward middle gray. It finds faces on your Mac, keeps skin from turning green or magenta,
  leans exposure toward the faces and holds vibrance back on skin. It never changes the crop or the
  straighten angle. Whites, blacks and vibrance are on the **Detailed** tab.
- **Tone** sets only exposure, contrast, highlights and shadows. **WB** sets a neutral white balance
  from the whole frame.
- **Eyedropper** (or **W**): click something in the photo that should be neutral gray.

Pressing an auto chip again, or undo then redo, is instant: results are remembered per photo.

### Auto straighten

In **Crop & straighten** (**C**), **Auto straighten** under the Straighten slider looks for the horizon
and levels it, as the step "Auto straighten". It only acts when it is confident and the tilt is at
most 10°, and it changes only the angle. Otherwise the photo shows "No horizon found" (or "Horizon
already level") and nothing changes.

### Learn from my edits

With **Learn from my edits** on (**Settings**, **⌘,**; on by default), ✦ Auto adapts to how you finish
photos. Each time you edit a photo by hand, Halfstop notes a few numbers about it (brightness, color,
faces, RAW or not) and how your sliders differ from what ✦ Auto would have done. Once at least
**20** edited photos have been measured, ✦ Auto adds what you usually change on the most similar
ones, within modest limits, and its tooltip reads "Auto (adapted to your edits)".

- It learns on this Mac, from your own edits only. Nothing is uploaded, and there is no training data
  from anyone else. What it learned is kept in the library index (`catalog.json`).
- Photos count once you edit them (any history step, undo or redo). Pasting settings or applying a
  preset to many photos at once only measures the one that's open. Photos edited before this
  feature existed aren't measured until you change them again.
- Only ✦ Auto adapts; Tone and WB stay as they are. Turning the setting off stops collecting and
  using it immediately, and keeps what was learned in case you turn it back on.

### Masks

Masks apply adjustments to part of the photo, each with its own sliders.

- **Brush**: paint where the effect applies. **[** and **]** change the brush size, **⌥-drag** erases.
- **Linear** and **radial**: drag on the photo, then use the handles to move, resize or feather.
  **⇧-drag** adds another shape to the same mask, and each shape can add, subtract or intersect.
- **Subject** (Apple Vision) and **sky**: detected automatically. For subject masks, click the
  subjects on the photo to include or leave them out. Grow, shrink and soften the result as needed.
- Any mask can be **refined** with add or subtract brush strokes.
- **O** shows or hides the red overlay that displays the mask.

### History and snapshots

The panel on the left of the editor lists every edit as a named step (auto actions and changes made
through Local AI control included). Click a step to go back to it.
Your next edit removes the struck-out steps after it. **⌘Z** and **⇧⌘Z** undo and redo one step at a
time. **Snapshots ▸ Save** keeps a named version that survives trimming and clearing.

### Presets and copying settings

- **Photo ▸ Save Preset…** stores the current global look. Presets carry only the global look, never
  crop or masks.
- **⇧⌘C** copies a photo's settings and **⇧⌘V** pastes them onto the selected photos. Each photo keeps
  its own crop.
- **⇧⌘R** resets all adjustments on the photo.

Edits save automatically a moment after each change (the top bar shows Saving… and Saved). **⌘S**
saves immediately.

## Local AI control (MCP)

Halfstop can let an AI app on the same Mac, such as Claude Code, look at and edit the photo open in
the editor, so you can ask for things like "make this warmer and lift the shadows a little". It does
this by running a small [MCP](https://modelcontextprotocol.io) server that the AI app connects to.
**It is off by default.**

### Privacy and safety

- **Halfstop makes no network requests to outside services and stores no API keys.** The AI app you
  use is the one that talks to its AI service, under its own settings and terms.
- The server listens on **127.0.0.1 only**, so other computers on your network can't reach it, and
  it refuses requests from web pages. Every request must carry a **token** that Halfstop makes when
  you turn the feature on and keeps in your login keychain.
- It runs only while the setting is on, and stops the moment you turn it off.
- An AI app can only work on **the photo open in the editor**. It can read its file name (not the
  folder), size, rating, flag, slider values and a few measured numbers (brightness percentiles,
  color, faces, horizon), and ask for a small preview image (at most 512 pixels, with no camera or
  location data). Anything it reads goes to that AI app and the service behind it.
- It can change the global sliders (white balance, exposure, contrast, highlights, shadows, whites,
  blacks, vibrance, saturation, vignette, sharpening, noise reduction), run ✦ Auto and Auto
  straighten, and undo. It can't open other photos, crop (beyond Auto straighten's angle), edit
  masks, the tone curve, HSL or color grading, change ratings, export, delete, or touch any file.
  Every change is one step in the photo's history, named after what the AI app asked for (or "AI
  edit"), and the editor briefly shows "AI control: …". **⌘Z** undoes it.

### Setting it up

1. Open **Halfstop ▸ Settings** (**⌘,**) and turn on **Let AI apps on this Mac edit the open photo**
   under **Local AI control (MCP)**. The status should read "Running on 127.0.0.1:47615".
2. Add Halfstop to your AI app:
   - **Claude Code:** click **Copy command** and run it in Terminal. It looks like
     `claude mcp add --transport http halfstop http://127.0.0.1:47615/mcp --header "Authorization: Bearer <token>"`.
   - **Other MCP apps** that connect to HTTP servers: click **Copy JSON config** and paste the
     `mcpServers` entry into the app's MCP settings (for Claude Code, a project's `.mcp.json` takes
     the same entry). Apps that can only start local command-line servers need an HTTP bridge; see
     their documentation.
3. Open a photo in Halfstop's editor and ask your AI app to work on it.

The copied command and JSON contain the token: keep them private. **Regenerate** makes a new token
(apps set up with the old one stop working until you give them the new one). To use another port,
type it in **Port**; the server restarts there and you need to update the AI app's settings.

If you build Halfstop from source, macOS may ask once after a rebuild whether Halfstop may use its
token in your keychain. Choose **Always Allow**. If you denied it, click **Regenerate** to make a new
token (and give it to your AI app).

## Exporting

Press **⇧⌘E** (**File ▸ Export…**) to write edited copies of the selected photos as **JPEG**, **HEIC**
or **16-bit TIFF**. JPEG and HEIC have a quality slider. Your originals are never changed.

## Deleting

**⌘⌫** (or **Delete** in the library grid, outside a collection) and **Photo ▸ Delete Rejected
Photos…** move photos and their edits to the macOS Trash after asking. Halfstop never erases files
itself. To restore a photo, use Finder's **Put Back**, and put back the matching `.json` file from
the `.halfstop` folder too if you want to keep its edits.

## Where Halfstop keeps things

- Edits, ratings and flags: `<photo folder>/.halfstop/<filename>.json`; edit history: `<filename>.history.json` next to it
- Library index (folders, collections, what ✦ Auto learned from your edits): `~/Library/Application Support/Halfstop/catalog.json`
- Presets: `~/Library/Application Support/Halfstop/presets.json`
- Local AI control token: your login keychain, as "Halfstop local AI control token"

To back up your work, include the hidden `.halfstop` folders with your photos, and the `Halfstop` folder in
Application Support. To move your library to another Mac, copy the photo folders (with `.halfstop`) and
the `Halfstop` support folder, and use **Locate folder…** in the sidebar if the folders end up in different places.

## Troubleshooting

**The app won't open on another Mac.** The build is ad-hoc signed and not notarized. Right-click the
app, choose **Open**, then confirm. Builds made on the same Mac open normally.

**A RAW file won't open or looks wrong.** Halfstop decodes RAW through macOS, so a camera must be supported
by your version of macOS. Update macOS, or check that Preview can open the file.

**Sliders feel slow on large files.** Use a release build (`./scripts/bundle.sh`, not `debug`). Preview
speed also depends on the size of the photo and the GPU.

**My library list is empty after an update.** If Halfstop cannot read `catalog.json` it copies the file to
`catalog.unreadable-<timestamp>.json` in the same folder instead of overwriting it. If only some entries
can't be read, it keeps the rest and copies the original to `catalog.partial-<code>.json` first (sidecars
and `presets.json` get the same treatment). Your photos and
their `.halfstop` sidecars are untouched, so you can re-import the folders, or attach that file to a bug report.

**Local AI control says the port is in use.** Another app is using that port. Type a different port
in **Settings ▸ Local AI control** and update your AI app's settings with the new address.

**My AI app can't connect to Halfstop.** Check that the setting is on and the status says Running,
that a photo is open in the editor, and that the app has the current token (copy the command or
JSON again after **Regenerate**).

**Reporting a problem.** Please open an issue with your macOS version, Mac model, the photo's file
type, and the steps to reproduce. See [CONTRIBUTING.md](../CONTRIBUTING.md).
