import Foundation

/// `halfstop --help` and `halfstop help <command>`, written so an AI agent can use the tool
/// correctly after reading it once.
enum CommandLineHelp {
    static var sliders: String {
        EditFields.fields.map { f in
            let range = f.step < 1
                ? String(format: "%.0f to %.0f, steps of %.2f", f.range.lowerBound, f.range.upperBound, f.step)
                : String(format: "%.0f to %.0f", f.range.lowerBound, f.range.upperBound)
            return "  " + f.name.padding(toLength: 16, withPad: " ", startingAt: 0) + "\(range): \(f.about)"
        }.joined(separator: "\n")
    }

    static var overview: String {
        """
        halfstop: read and edit photos with Halfstop from the command line.

        Usage: halfstop <command> <photo>... [options]

        Commands:
          info <photo>...                  size, rating, slider values, history, and an analysis:
                                           luminance percentiles, mean color, scene, faces, horizon
          get <photo>...                   current slider values and history position
          set <photo>... name=value...     change sliders (absolute: exposure=0.5, relative:
                                           exposure+=0.3, contrast-=10) as one undoable step
          auto <photo>...                  ✦ Auto (white balance, tone, whites/blacks, vibrance)
          straighten <photo>...            level a tilted horizon; does nothing if none is found
          undo <photo>... / redo <photo>...  step back or forward in the photo's edit history
          render <photo> -o <out.jpg>      write a JPEG of the current edit (to look at the result)
          help <command>                   details and examples for one command

        Options: --json (machine-readable output on stdout), -- (everything after it is a photo).

        Sliders (set takes these names; values are clamped to the range and rounded):
        \(sliders)

        How it works:
          - Edits are saved where the Halfstop app keeps them: <folder>/.halfstop/<photo>.json and
            .history.json. Photo files are never changed, renamed or moved.
          - Every change is one step in the photo's history, so it can be undone here (halfstop undo)
            or in the app (⌘Z). The app shows changes made from the command line straight away.
          - Masks, crop, tone curve, HSL and color grading can't be changed from the command line.
          - Many photos per command, and shell patterns (*.jpg) work. A photo that fails is
            reported and the others are still done.
          - Exit status: 0 all done, 1 at least one photo failed, 2 bad usage (nothing done).
          - It reads and writes only local files and never connects to a network.

        For an AI agent: start with `halfstop info <photo>`, make changes with `halfstop set` or
        `halfstop auto`, then `halfstop render <photo> -o /tmp/preview.jpg` and look at the JPEG.
        Use --json to parse results. Undo with `halfstop undo <photo>`.
        """
    }

    static func text(for command: CommandLineTool.Command) -> String {
        switch command {
        case .info:
            return """
            halfstop info <photo>... [--json]

            Describes each photo: pixel size, RAW or not, rating (0-5) and flag, the current slider
            values, other edits (crop, straighten, masks...), the history position, and an analysis
            of the photo as cropped: luminance percentiles p5-p95 (0 black, 1 white, sRGB, measured
            after automatic white balance at exposure 0), mean linear RGB, mean chroma (about 0.02 is
            muted, 0.1 colorful), skin share, the scene (normal, wellExposed, lowKey, highKey, night),
            faces (boxes 0-1, top-left origin), any horizon, and the angle `straighten` would set.
            Read-only. The analysis decodes a small copy of each photo (about 1024 pixels).

            Example:
              halfstop info IMG_0042.jpg --json
            """
        case .get:
            return """
            halfstop get <photo>... [--json]

            Prints the current slider values, other edits and history position. Read-only and fast
            (it doesn't decode the photo).

            Example:
              halfstop get *.jpg --json
            """
        case .set:
            return """
            halfstop set <photo>... name=value... [--label TEXT] [--json]

            Changes sliders of each photo as ONE undoable history step. name=value sets a value,
            name+=value and name-=value change it by that amount. Values are clamped to the slider's
            range (reported) and rounded (exposure to 0.01 EV, the others to whole numbers). Each
            slider at most once per command. Numbers are plain decimals (0.5, -20, 1e-1).
            --label names the history step (one line, at most 60 characters; default
            "\(EditFields.defaultLabel)").

            Sliders:
            \(sliders)

            Examples:
              halfstop set IMG_0042.jpg exposure+=0.3 shadows=25 --label "Brighter"
              halfstop set trip/*.jpg temperature-=10 vibrance=15
            """
        case .auto:
            return """
            halfstop auto <photo>... [--json]

            Runs Halfstop's ✦ Auto on each photo as one undoable step "Auto": white balance,
            exposure, contrast, highlights, shadows, whites, blacks and vibrance, chosen for the
            scene (well-exposed photos barely change; low-key, high-key and night photos keep their
            mood; faces are considered). If "Learn from my edits" is on in the app's Settings and
            enough photos were edited by hand, it adapts to those edits, as in the app. It replaces
            those sliders' values and never changes the crop. A good first step before fine-tuning
            with set.

            Example:
              halfstop auto *.jpg && halfstop render IMG_0042.jpg -o /tmp/preview.jpg
            """
        case .straighten:
            return """
            halfstop straighten <photo>... [--json]

            Levels a tilted horizon by setting the straighten angle (at most 10 degrees), as one
            undoable step "Auto straighten". When no horizon is found it prints "No horizon found"
            and changes nothing; when it's already level, nothing changes either.

            Example:
              halfstop straighten beach.jpg
            """
        case .undo, .redo:
            return """
            halfstop undo <photo>... [--json]
            halfstop redo <photo>... [--json]

            Steps each photo back (undo) or forward (redo) one step in its edit history, whoever made
            the step: the command line or someone in the app. Same as ⌘Z and ⇧⌘Z in the app. Undone
            steps can be redone until the next edit.

            Example:
              halfstop undo IMG_0042.jpg
            """
        case .render:
            return """
            halfstop render <photo> -o <out.jpg> [--size N] [--force] [--json]

            Writes a JPEG of the photo with its current edits and crop, at most N pixels on the long
            edge (default \(CommandLineTool.defaultRenderSize), \(CommandLineTool.renderSizes.lowerBound) to \(CommandLineTool.renderSizes.upperBound)), sRGB, with no metadata (no camera
            data, no location). Use it to look at the result of an edit. It never writes over the
            photo itself, Halfstop's edit files, a link or folder, a photo that has Halfstop edits,
            or a file with camera data; another existing file is replaced only with --force. Nothing
            is saved to the photo's edits.

            Example:
              halfstop render IMG_0042.jpg -o /tmp/IMG_0042-preview.jpg --size 1024
            """
        case .help:
            return overview
        }
    }
}
