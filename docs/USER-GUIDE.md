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
- **Detailed** tab (press **D** to switch): full light and color, color grading wheels, tone curves,
  HSL and hue curves, detail (sharpening, noise reduction), effects, lens corrections and spot removal.
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

### Presence: texture, clarity and dehaze

At the bottom of **Light**. Each also works inside a mask.

- **Texture** brings out (or, below 0, smooths) fine detail such as fabric, foliage or skin.
- **Clarity** adds punch to midtones by raising contrast between neighbouring areas. It holds back
  right along hard edges, so a skyline doesn't get a dark outline. Below 0 it softens.
- **Dehaze** removes haze and fog and brings back the color they wash out. Below 0 it adds a soft haze.

### Tone curves

**Tone curve** has two modes:

- **Parametric**: four sliders (Highlights, Lights, Darks, Shadows) each bend their part of the
  tonal range. Drag the three markers under the graph to move where the regions meet.
- **Point**: drag on the curve to add and move points; drag a point off the graph to remove it.
  **RGB** changes brightness; **Red**, **Green** and **Blue** change one channel, for color casts and
  film-style looks. The other channels' curves show faintly behind. **Medium contrast**, **Matte**
  and **Flat** set the curve in one click.

Both modes apply together (the region sliders first).

### HSL and hue curves

**HSL** switches between **Sliders** (eight colors) and **Curves**. The curves run over the color
wheel, with the middle line meaning no change:

- **Hue**: up moves a color toward the next hue to the right, down toward the left.
- **Saturation**: up makes a color more saturated, down takes it toward gray.
- **Luminance**: up brightens a color, down darkens it.

Drag on the graph to bend one color: Halfstop adds a point there with neutral points on each side, so
neighbouring colors change gently and the rest not at all. **Target adjust** (**T**) lets you drag up
or down on the photo itself, on the color you want to change. Gray areas don't respond.

### Effects and lens

- **Grain** adds film-like grain, with **Grain size** and **Roughness**. It's sized relative to the
  photo, so the preview matches the export, and the same photo always gets the same grain.
- **Lens**: **Use lens profile** corrects distortion and vignetting with the profile the camera
  recorded (RAW files that have one; on by default). **Remove color fringing** takes the color out of
  purple and green fringes along high-contrast edges. **Distortion** straightens lines that bow
  outward (positive) or inward (negative), and **Lens vignetting** brightens dark corners.

### Removing spots

Press **Q** (or **Remove spots** at the bottom of the Detailed tab) and click a dust spot or blemish.
Halfstop picks a clean patch nearby, copies it over the spot and matches its color and brightness to
the surroundings. The selected spot shows its source as a dashed circle: drag either circle to move
it. **[** and **]** change the size, **⌥-click** or **Delete** removes a spot, **Esc** finishes.

Spots belong to one photo, so pasting settings and presets leave them out (choose **Removed spots**
in **Paste Selected Settings…** to copy them anyway). Many spots slow the preview a little while you
drag exposure or white balance; other sliders aren't affected.

### Masks

Masks apply adjustments to part of the photo, each with its own sliders.

- **Brush**: paint where the effect applies. **[** and **]** change the brush size, **⌥-drag** erases.
- **Linear** and **radial**: drag on the photo, then use the handles to move, resize or feather.
  **⇧-drag** adds another shape to the same mask, and each shape can add, subtract or intersect.
- **Subject** (Apple Vision) and **sky**: detected automatically. For subject masks, click the
  subjects on the photo to include or leave them out. Grow, shrink and soften the result as needed.
- Any mask can be **refined** with add or subtract brush strokes.
- **Limit to** narrows any mask to a **Brightness** range (Low, High, Smoothness) or a **Color**:
  click the photo to pick it, then set the **Tolerance**. Turn on the overlay to see what's kept.
- **O** shows or hides the red overlay that displays the mask.

### History and snapshots

The panel on the left of the editor lists every edit as a named step (auto actions and changes made
with the `halfstop` command included). Click a step to go back to it.
Your next edit removes the struck-out steps after it. **⌘Z** and **⇧⌘Z** undo and redo one step at a
time. **Snapshots ▸ Save** keeps a named version that survives trimming and clearing.

### Presets and copying settings

- **Photo ▸ Save Preset…** stores the current global look. Presets carry only the global look, never
  crop, masks or removed spots.
- **⇧⌘C** copies a photo's settings and **⇧⌘V** pastes them onto the selected photos. Each photo keeps
  its own crop.
- **⇧⌘R** resets all adjustments on the photo.

Edits save automatically a moment after each change (the top bar shows Saving… and Saved). **⌘S**
saves immediately.

## Editing from the command line / with an AI agent

Halfstop is also a command-line tool, `halfstop`. You can use it yourself in Terminal, or let an AI
agent that can run commands, such as Claude Code, edit photos with you: "make these warmer and lift
the shadows a little".

### Installing it

The tool is the app itself, so there's nothing extra to download. Put it on your `PATH` with a link
(no administrator rights needed). **Settings ▸ Command-line tool** shows the exact line for where
your copy of Halfstop is, with a **Copy** button; for an app in Applications it is:

```bash
mkdir -p ~/.local/bin && ln -sf /Applications/Halfstop.app/Contents/MacOS/Halfstop ~/.local/bin/halfstop
```

Then run `halfstop --help`. If Terminal says "command not found", add
`export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and open a new Terminal window. If you move
Halfstop.app, run the line again. To remove the tool, delete `~/.local/bin/halfstop`.

### Commands

| Command | What it does |
| --- | --- |
| `halfstop info <photo>…` | Size, RAW or not, rating, slider values, history, and an analysis: brightness percentiles, mean color, scene type, faces, horizon, and the angle Auto straighten would set |
| `halfstop get <photo>…` | The current slider values and where the photo is in its history |
| `halfstop set <photo>… name=value…` | Changes sliders: `exposure=0.5` sets a value, `exposure+=0.3` and `contrast-=10` change it. Optional `--label "Warmer"` names the step |
| `halfstop auto <photo>…` | ✦ Auto, exactly as in the app (including Learn from my edits, if it's on) |
| `halfstop straighten <photo>…` | Auto straighten. Prints "No horizon found" and changes nothing if there's no clear horizon |
| `halfstop undo <photo>…`, `halfstop redo <photo>…` | One step back or forward in the photo's history |
| `halfstop render <photo> -o <file.jpg>` | Writes a JPEG of the current edit (1024 pixels on the long edge, `--size` up to 4096), with no camera or location data, so you or an agent can look at the result |
| `halfstop help <command>` | Details and examples |

The sliders are `temperature`, `tint`, `exposure` (in EV, -5 to 5), `contrast`, `highlights`,
`shadows`, `whites`, `blacks`, `vibrance`, `saturation`, `vignette` (each -100 to 100),
`sharpening` and `noise_reduction` (0 to 100). Values outside the range are clamped, and the tool
says so. Masks, crop, tone curves, HSL and hue curves, color grading, removed spots and the lens
profile and fringing switches can't be changed from the command line.

Several photos at once work, shell patterns too (`halfstop auto trip/*.jpg`). If one photo can't be
done (not found, not a photo), the tool says why and carries on with the rest. Add `--json` for
output a program can read. The exit status is 0 when everything worked, 1 when a photo failed, and 2
for a mistake in the command (then nothing is changed).

Examples:

```bash
halfstop info IMG_0042.jpg
halfstop set IMG_0042.jpg exposure+=0.3 shadows=25 --label "Brighter"
halfstop auto *.jpg
halfstop render IMG_0042.jpg -o ~/Desktop/preview.jpg
halfstop undo IMG_0042.jpg
```

### Using it with Claude Code

1. Install the tool as above, and check `halfstop --help` works in Terminal.
2. Start Claude Code in (or give it) the folder with your photos, and tell it something like:
   "Run `halfstop --help` first, then use the halfstop command to make IMG_0042.jpg warmer and lift
   the shadows. Render a preview to /tmp and look at it before you finish."
3. The agent runs `halfstop info`, `set` or `auto`, then `halfstop render … -o /tmp/preview.jpg` and
   opens the JPEG to check its work.
4. Look at the result in Halfstop. If Halfstop is open, the changes show up within a second, as steps
   in the history panel. **⌘Z** undoes them.

Other agents that can run shell commands work the same way: point them at `halfstop --help`.

### Privacy and safety

- The tool only reads and writes local files: your photos are only read, and edits go to Halfstop's
  own files in the photo's `.halfstop` folder, the same ones the app uses. It never changes, renames
  or moves a photo file, and it never connects to a network. `render` writes only the JPEG you ask
  for, never over a photo (one with Halfstop edits or camera data) or Halfstop's files, and replaces
  another existing file, such as an earlier preview, only with `--force`.
- Every change is one step in the photo's history, so you can always undo it, here or in the app.
  Steps made from the command line don't count as your own edits for Learn from my edits.
- An AI agent sees what the tool prints and any preview it renders, and sends that to its AI
  service under its own settings and terms. Halfstop itself sends nothing anywhere.

### When Halfstop is open

Halfstop notices edits made from the command line straight away: the editor, thumbnail and
histogram update, and the editor briefly shows "Updated from the command line". If you were changing
the same photo in the app at that moment, nothing is lost: Halfstop keeps the command line's version
and puts your changes on top of it as one more step (where both changed the same slider, yours
wins), and shows "Merged with changes made outside Halfstop". One **⌘Z** brings back exactly the
command line's version.

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

**`halfstop: command not found`.** The link isn't on your `PATH`: see [Installing it](#installing-it).
If you moved Halfstop.app, make the link again.

**A command-line edit doesn't show in the app.** Check that the photo is in one of the app's
imported folders (the tool also works on photos that aren't, but the app only shows its own
library). Changes appear within a second; reopening the photo always shows what's saved.

**Reporting a problem.** Please open an issue with your macOS version, Mac model, the photo's file
type, and the steps to reproduce. See [CONTRIBUTING.md](../CONTRIBUTING.md).
