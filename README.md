# SwarfEngrave

**V-carve design and G-code for hobby CNC, native on the Mac.** SwarfEngrave is for signs, plaques, inlays,
headstock logos and lettering: draw or import 2D artwork (text, SVG, DXF), choose V-bits and depths, see the
carve in 3D, and get G-code that SwarfGRBL sends to the machine.

> **Status: planned.** There's no code yet. This repo holds the plan; see [ROADMAP.md](ROADMAP.md).

SwarfEngrave is part of the **[Swarf Suite](https://github.com/Swarf-Suite)**:

| App | Does |
|---|---|
| [SwarfPath](https://github.com/Swarf-Suite/SwarfPath) | 3D CAM: STL models to roughing, finishing, pockets, drilling and cutouts |
| **SwarfEngrave** | 2D artwork to V-carves, inlays, engraving and profile cuts |
| [SwarfGRBL](https://github.com/Swarf-Suite/SwarfGRBL) | Sends the G-code to a GRBL machine, from either Mac |

## How it fits together

```
 SwarfEngrave ──┐
                ├── POST /api/jobs ──▶ SwarfGRBL hub ──▶ machine
 SwarfPath ─────┘
       └── shared engine: tools, feeds, post-processors, V-carve toolpaths
```

- **G-code goes to SwarfGRBL** the way SwarfPath sends it: `POST /api/jobs` on the hub (default
  `http://localhost:8080`), with `X-Source: SwarfEngrave` and, for a multi-bit job, one file per bit as a group
  (`X-Group`, `X-Group-Index`) so SwarfGRBL runs them in order and stops between them to change the bit and
  re-probe Z. The file header states Z zero in words (`Z0 = TOP of stock …`), which SwarfGRBL shows before it starts.
- **The engine is shared with SwarfPath**: the tool library and feeds calculator, the machine post-processors and
  the V-carve toolpath code SwarfPath already has (`CAMCore/VCarve.swift`), moved into a package both apps use.

## Licence

MIT, like the rest of the Swarf Suite. SwarfEngrave is an independent open source project, not affiliated with or
endorsed by any machine maker.
