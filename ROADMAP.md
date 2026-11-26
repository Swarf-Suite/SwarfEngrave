# SwarfEngrave roadmap

SwarfEngrave turns 2D artwork into V-carve, engraving and profile G-code. Same stack as the rest of the Swarf
Suite: Swift 6, SwiftUI and Metal, SwiftPM only, macOS 26.

| Phase | What | Status |
|---|---|---|
| 0 | Plan and repo (this file) | ✅ |
| 1 | Shared engine package, split out of SwarfPath's `CAMCore` | ⬜ |
| 2 | Document and 2D canvas: shapes, text, import | ⬜ |
| 3 | V-carve toolpaths from vectors | ⬜ |
| 4 | More operations: engrave, inlay, pocket, profile | ⬜ |
| 5 | Preview and simulation | ⬜ |
| 6 | Export and send to SwarfGRBL | ⬜ |
| 7 | Releases (signed, notarized, self-updating) | ⬜ |

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

## Phase 2: document and canvas
- A `.swarfengrave` document: stock size and thickness, work origin, artwork layers, operations, tools.
- 2D canvas (Metal or Core Graphics) with pan, zoom, snapping, a grid and the stock outline.
- Shapes: rectangle, rounded rectangle, ellipse, polygon, star, line, Bézier path; move, scale, rotate, mirror,
  align, distribute; boolean union, subtract and intersect; offset.
- Text: any installed font, on a line or along a curve, letter spacing; converted to paths for toolpaths.
- Import SVG and DXF (paths, units, open and closed curves) and bitmaps traced to vectors.

## Phase 3: V-carve
- True V-carve from closed vector regions: the bit follows the medial axis with depth from the distance to the edge
  and the bit angle, so corners come out sharp.
- Flat-bottom V-carve: a depth limit, with a flat end mill clearing the floor and the V-bit doing the walls.
- Several V-bit angles in one job; start depth for carving into a surface that isn't Z 0.
- Open curves engraved along the line at a set depth.

## Phase 4: more operations
- Inlays (male and female V-carve pairs with a glue gap and start depth), the guitar use: headstock logos and
  fret markers.
- Pocket and profile (inside, outside, on the line) with tabs, ramps and lead-ins, reusing SwarfPath's ideas.
- Drilling for holes and circles.
- Fewest bit changes, one file per bit, as SwarfPath's Auto Plan does.

## Phase 5: preview and simulation
- 3D preview of the carved stock (heightmap simulation, like SwarfPath's) in the material's colour.
- Time estimate per operation and for the job, from the machine profile's feeds and accelerations.
- Warnings: a region too narrow for the bit, a depth past the stock, a V-bit deeper than its cutting length.

## Phase 6: export and send
- Save G-code per bit, or send the group straight to SwarfGRBL (`X-Source: SwarfEngrave`), with the Z-zero line in
  the header that SwarfGRBL reads.
- SwarfGRBL: show SwarfEngrave as a source like SwarfPath (it already takes any `X-Source`); nothing else needed.

## Phase 7: releases
- Developer ID signing, notarization and Sparkle updates from GitHub Releases, the same way SwarfGRBL ships.
- A page on gm-guitars.net beside SwarfGRBL and SwarfPath.

## Ideas
- Templates for common jobs: house signs, guitar truss rod covers, coasters.
- Photo engraving (depth from brightness) with a ball or V-bit.
- Wrapping text and artwork around a cylinder for rotary-axis machines.
