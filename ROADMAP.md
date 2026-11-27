# SwarfEngrave roadmap

SwarfEngrave is a design-and-carve editor for 2D work: lay out shapes, text in any installed font and imported
images on a grid the size of your stock, give each object its own depth and cut type, check the carve in 3D, and
send G-code to SwarfGRBL. It is a native Mac app with the Swarf Suite look: Swift 6, SwiftUI with AppKit where
SwiftUI falls short (font panel, text layout), Metal and Core Text, SwiftPM only, macOS 26.

## Design independence
SwarfEngrave offers the capabilities people expect from browser-based hobby CNC design tools (per-object depth,
text, image tracing, a live preview), but its interface, wording, icons, file format and artwork are its own and
follow the Swarf Suite, not any other product. Ground rules:
- No copying another product's layout, panel arrangement, icons, colour scheme, terminology, sample projects or
  help text. Build from SwarfPath's window structure, SwarfGRBL's theme and macOS conventions instead.
- SF Symbols and our own drawn icons only. No bundled third-party fonts or clip art unless their licence allows it.
- No reading or writing another product's own project format. SVG and DXF are open formats and are the way in.
- Don't name other products in the app, the docs or the website.

| Phase | What | Status |
|---|---|---|
| 0 | Plan and repo (this file) | ✅ |
| 1 | Shared engine package, split out of SwarfPath's `CAMCore` | ⬜ |
| 2 | Editor: canvas, shapes, system-font text, artwork import | ⬜ |
| 3 | Per-object depth and cut type | ⬜ |
| 4 | 3D carve view and checks | ⬜ |
| 5 | V-carve in depth: flat-bottom, inlays | ⬜ |
| 6 | More operations and job planning | ⬜ |
| 7 | Export and send to SwarfGRBL | ⬜ |
| 8 | Releases (signed, notarized, self-updating) | ⬜ |

## Phase 1: shared engine
SwarfPath's `CAMCore` already has most of what an engraving app needs. Move it into a package both apps use
(its own repo in Swarf-Suite, or a SwarfPath library product to begin with), without changing SwarfPath's output:
- Tools: the tool library (`Tooling.swift`, including V-bits and the Fusion 360 import), feeds and speeds
  (`FeedsCalculator.swift`).
- Machines: profiles and post-processors (`Post.swift`), so a file for the FoxAlien is the same from either app.
- Sending: `GCodeHub.swift` (`POST /api/jobs` to SwarfGRBL).
- Toolpath basics: `Toolpath`, ordering and linking moves (`Ordering.swift`), and the medial-axis V-carve in
  `VCarve.swift`, made to take vector regions as well as SwarfPath's grid.
- SwarfPath's tests must pass unchanged on the shared package before SwarfEngrave depends on it.

## Phase 2: editor
The window is arranged like SwarfPath: a `NavigationSplitView` with a sidebar, the canvas in the middle, a native
`.inspector` column on the right and a macOS toolbar.

It is styled like SwarfGRBL, the gm-guitars look. Share SwarfGRBL's `Theme.swift` (move it into a small shared
package, or copy it to begin with) rather than redrawing it:
- Dark only: obsidian (`#121212`) behind the canvas, slate panels (`#1e1e1e`/`#262626`/`#303030`), thin `line`
  dividers.
- A warm gold accent (`#c5a059`, `goldBright` for highlights, `goldDim` for selected fills); off-white text and
  steel for secondary text.
- Section headings in wide-tracked capitals (`Eyebrow`), buttons with `SGButtonStyle` (primary gold for Make
  Toolpaths and Send, outline gold, ghost), `ok`/`warn`/`danger` colours for checks.
- The app name in gold tracked capitals at the left of the toolbar, as SwarfGRBL's top bar has it.
- Monospaced figures (`Font.mono`) for coordinates, depths and times.
- **Sidebar**, a `List` in sections, as in SwarfPath:
  - *Setup*: Stock (size, thickness, species with a colour swatch), Work Zero, Machine & Bits.
  - *Design*: the object tree, grouped by cut depth (e.g. "Surface · 0.5 mm", "Pocket · 3 mm", "Through"), each
    row with its cut-type symbol, name and depth. Drag a row between groups to change its depth; drag within a group
    to reorder. Hide, lock and rename from the context menu.
  - *Sheets*: several stock pieces in one document, each its own sheet (no separate bottom strip).
- **Canvas** (Metal): the stock drawn true to size on an engineering-paper grid with mm or inch rulers along the
  top and left edges, pan with two fingers, pinch to zoom, snap to grid, to other objects and to the stock edges and
  centre, smart guides while dragging. A floating SwarfPath-style tool palette for the modes that work on the
  canvas: select, direct-select points, pen, measure, place tabs.
- **One view at a time, switched in the toolbar**: *Design* (2D), *Carve* (3D result) and *Both* (vertical split,
  design on top). Remembers the choice per document.
- **Toolbar**: Add Shape (menu), Add Text, Import Artwork, the Design/Carve/Both control, Make Toolpaths, Send to
  SwarfGRBL, Inspector. Every command is also in the menus with a shortcut (Insert, Arrange, Path, Carve menus).
- **Shapes**: rectangle, rounded rectangle, ellipse, polygon, star, line and Bézier paths. Arrange menu for align,
  distribute, group, mirror, bring forward/back; Path menu for union, subtract, intersect, exclude, offset,
  simplify, join and break.
- **Inspector** (a `Form` with collapsible sections, not tabs): *Geometry* (position with a 9-point origin picker,
  size, lock aspect, rotation), *Text* (for text objects), *Cut* (Phase 3). Fields take arithmetic, so `120/2-3`
  works anywhere a number goes.
- **Text, using system fonts**:
  - Every font macOS can use: system fonts, fonts the user has installed in Font Book, and variable fonts with
    their axes (weight, width, slant). Picked with the standard macOS font panel (`NSFontPanel`) plus a font menu in
    the inspector with a live preview of the text.
  - Size in mm or inches (cap height or em, user's choice), tracking, line spacing, alignment, multi-line.
  - Text on a straight baseline, in a circle (top or bottom arc), or along any path.
  - Laid out with Core Text, outlines taken from `CTFontCreatePathForGlyph`, so kerning and ligatures match what
    macOS draws. Text stays editable; outlines are made only when toolpaths are generated, with overlaps between
    glyphs merged so script fonts carve cleanly.
  - If a document uses a font the Mac doesn't have, warn and keep the last generated outlines so the carve doesn't
    change.
- **Import artwork**: SVG and DXF straight to vectors (units, open and closed curves, layers to groups); PDF and EPS
  vector art through Quartz; PNG, JPEG, HEIC and TIFF traced to vectors in a sheet with a side-by-side before/after
  preview, threshold, smoothing, minimum detail size, and invert. Drag and drop onto the canvas, or paste from
  other apps.
- Undo/redo for everything (the document's `UndoManager`), copy/paste between documents, autosave and versions
  through `DocumentGroup`.

## Phase 3: per-object depth and cut type
Every object carries its own cut, set in the inspector's *Cut* section, so a sign can have a 0.5 mm engraved border,
3 mm pocketed letters and a cut-out edge in one design.
- **Depth**: a stepper field, a slider from the stock top to the stock bottom, and quick buttons for common depths
  (0.5, 1, 2, 3 mm and "Through"). Through cuts go to the thickness plus a small overcut set in Machine & Bits.
- **Cut type**, as a segmented control with SF Symbols:
  - *Engrave*: the bit runs on the line.
  - *Profile*: inside or outside the line, with tabs.
  - *Pocket*: clears the whole area to depth.
  - *V-carve*: depth from the bit angle and the shape's width (Phase 5).
- **Tabs** for through profiles: on/off, length, height, count; drag them along the edge on the canvas in tab mode.
- **Depth colours on the canvas**: objects are filled in gold, pale for shallow and rich for deep,
  with a small depth key in the canvas corner; through cuts are drawn as a dashed outline, and engraved lines as a
  stroke the width of the bit.
- **Overlaps**: the deeper cut wins where pockets overlap; a shallower object inside a deeper pocket stays as a
  raised island; a warning when an object would be cut away completely.
- **Bits**: the job's bits are picked in Machine & Bits from the shared tool library; an optional larger clearing bit
  for big pockets, with the smaller bit finishing the edges.

## Phase 4: 3D carve view
- The *Carve* view (and the lower half of *Both*) shows the carved stock as a heightmap simulation like SwarfPath's,
  in the stock's species colour and grain, and updates a moment after each edit. Orbit, zoom, top/front/iso
  buttons, and a toggle to draw toolpaths over it.
- Play back the cut, with a scrubber.
- Estimated time for the whole job and per bit, from the machine profile's feeds and accelerations, in the window
  subtitle as SwarfPath shows stock size.
- Problems in a list under the sidebar and as badges on the canvas: details narrower than the bit, depth past the
  stock, a V-bit deeper than its cutting length, objects off the stock.

## Phase 5: V-carve in depth
- True V-carve from closed regions: the bit follows the medial axis with depth from the distance to the edge and
  the bit angle, so corners come out sharp.
- Flat-bottom V-carve: a depth limit, with a flat end mill clearing the floor and the V-bit doing the walls.
- Several V-bit angles in one job; start depth for carving into a surface that isn't Z 0.
- Open curves engraved along the line at a set depth.
- Inlays: male and female V-carve pairs with a glue gap and start depth, for headstock logos and fret markers.

## Phase 6: more operations and job planning
- Ramps and lead-ins for outlines and fills, reusing SwarfPath's ideas.
- Drilling for holes and small circles.
- Fewest bit changes, one file per bit, as SwarfPath's Auto Plan does.

## Phase 7: export and send
- Save G-code per bit, or send the group straight to SwarfGRBL (`X-Source: SwarfEngrave`), with the Z-zero line in
  the header that SwarfGRBL reads.
- SwarfGRBL: show SwarfEngrave as a source like SwarfPath (it already takes any `X-Source`); nothing else needed.

## Phase 8: releases
- Developer ID signing, notarization and Sparkle updates from GitHub Releases, the same way SwarfGRBL ships.
- A page on gm-guitars.net beside SwarfGRBL and SwarfPath.

## Ideas
- Templates for common jobs: house signs, guitar truss rod covers, coasters, fret markers.
- A library of our own simple shapes and symbols (stars, hearts, arrows, guitar outlines), drawn for SwarfEngrave.
- Photo engraving (depth from brightness) with a ball or V-bit.
- Named values (e.g. `thickness`) that fields can refer to, so a design adapts when the stock changes.
- Wrapping text and artwork around a cylinder for rotary-axis machines.
- Bring old designs across from other tools through their SVG export.
