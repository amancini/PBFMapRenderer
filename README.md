# PBFMapRenderer

A **Delphi VCL** library that reads **MVT/PBF vector tiles** from **MBTiles** and renders them to a
`TCanvas` using a **Mapbox GL / MapTiler `style.json`** (paint, layout, expressions, filters, sprites,
MapLibre-style label placement).

Target: **Delphi 10.3 Rio+**, VCL, FireDAC (SQLite **statically linked** — no `sqlite3.dll`). No external
runtime dependencies.

| GDI+ | Skia |
|------|------|
| ![gdi](Docs/skia-vs-gdi/gdi.png) | ![skia](Docs/skia-vs-gdi/skia.png) |

<sub>Same renderer, two backends — Rome z14. See [`Docs/skia-vs-gdi`](Docs/skia-vs-gdi/).</sub>

## Pluggable drawing backend

Drawing goes through `TPBFDrawSurface`. The **base class is the GDI+ backend**; a subclass overrides only
the primitives it reimplements. `TPBFSkiaSurface` (in `PBFMap.Render.Surface.Skia`) is a Skia backend
(geometry + text with a real stroke halo + icons).

- Switch at runtime: `Engine.UseSkia := True`.
- The renderer has **no backend conditionals** — it talks only to the surface.
- Skia is enabled **only if you link `PBFMap.Render.Surface.Skia`** (ships `sk4d.dll`); otherwise the
  library has zero Skia dependency. Adding another backend (e.g. Direct2D) is just another subclass.

Per-primitive Skia vs GDI+ (`Test\surfbench.dpr`): fills **4.5×**, dashed lines **1.9×**, circles 2.2×,
solid lines 1.5×. End-to-end ~1.3–1.4× (text/icons and CPU decode are a large, backend-shared share).

## Quick start

```pascal
uses PBFMap.Engine;

var Engine: TPBFMapEngine;
begin
  Engine := TPBFMapEngine.Create(256);          // 256px output tiles
  try
    Engine.OpenTiles('data\roma.mbtiles');
    Engine.LoadStyle('style.json');             // also loads sprite.json/png from that folder
    // Engine.UseSkia := True;                   // optional: Skia backend
    Engine.RenderTile(14, 8760, 6088, Image1.Picture.Bitmap.Canvas);
  finally
    Engine.Free;
  end;
end;
```

`TPBFMapEngine` is **not thread-safe** — use one engine per thread. A shared parsed style/sprite can be
passed across worker engines with `SetSharedStyle` (the style holds no mutable per-render state).

### Key engine properties

| Property | Default | Effect |
|----------|---------|--------|
| `UseSkia` | False | Skia drawing backend (needs the Skia unit linked) |
| `Supersample` | 2 | SSAA factor (render N×, downscale); 1 = off |
| `Antialias` | True | GDI+ geometry anti-aliasing |
| `SyntheticCasing` | True | Grey under-stroke for light lines — set **False** for rich styles (osm-bright) |
| `MetatileSize` | 2 | Render an N×N block as one scene so edge labels stitch; slices cached (re-paint ≈ instant) |
| `TileCacheSize` | 64 | LRU of decoded tiles |
| `OnLog` | nil | `TPBFLogEvent`; when set, failures log + degrade instead of raising |

## Architecture (`Source\`)

```
MBTiles → Decompress → MVT.Parser → TMVTTile ┐
                          style.json → TMGLStyle ┼→ TMGLRenderer → TPBFDrawSurface → TCanvas
                                                 ┘                  (GDI+ | Skia)
```

| Unit | Role |
|------|------|
| `PBFMap.Decoder` / `PBFMap.Compression` | protobuf reader (zero-copy sub-ranges) / gzip-zlib-raw |
| `PBFMap.MVT.Parser` / `PBFMap.MVT.Types` | PBF → `TMVTTile`; features, geometry, typed values |
| `PBFMap.Color` / `PBFMap.Expressions` | colour parsing; Mapbox GL expression AST + filters |
| `PBFMap.Style.Model` / `PBFMap.Style.Parser` | `style.json` → paint/layout property bags |
| `PBFMap.Collision` / `PBFMap.Sprite` | symbol collision grid; sprite atlas |
| `PBFMap.Render.Surface` (+`.Skia`) | drawing backend abstraction (GDI+ base / Skia subclass) |
| `PBFMap.Renderer.GL` / `PBFMap.Engine` | style-driven paint + placement; `TPBFMapEngine` facade |
| `PBFMap.Profile` | opt-in per-function profiler (zero-cost when off) |

## Build & test

No `.dproj` for the library (just the `Source\` units). Build the test/sample projects; `dcc32` needs the
FireDAC/VCL search path (`rsvars.bat`).

```sh
# from Test\  (Test\build_test.bat wraps rsvars + dcc32 with the right namespaces)
build_test.bat PBFMapRenderer.Tests.dpr   &&  PBFMapRenderer.Tests.exe   # DUnitX suite (90 tests)
build_test.bat skiaab.dpr                 &&  skiaab.exe                  # GDI vs Skia A/B (links Skia)
build_test.bat bench.dpr                  &&  bench.exe                   # 7×7 z14 grid timings
```

Integration tests need `Sample\BasicViewer\style.json` + `Sample\BasicViewer\data\roma.mbtiles`
(found by walking up from the exe). Rome test tile = z14 `8760/6088`.

## Notes

- MBTiles is **TMS** (Y flipped) and **gzip**; the reader handles both.
- Performance is at the CPU/GDI+ floor: decode is zero-copy, property eval is memoised per-thread, filter
  keys are interned (FNV-1a). The remaining draw cost is the rasteriser → use Skia and/or a thread pool.
- Out of scope: SDF glyphs / curved per-glyph text, 3D `fill-extrusion` (drawn flat), `raster`/`heatmap`/
  `hillshade`, `feature-state`, multi-tile pan/zoom (the host does that).

## License

MIT — see [LICENSE](LICENSE). © 2025 amancini.
