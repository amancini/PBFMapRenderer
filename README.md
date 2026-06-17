# PBFMapRenderer

A **Delphi VCL** library that reads and renders **MVT / PBF vector tiles** from **MBTiles**
databases, driven by **Mapbox GL / MapTiler `style.json`**. It decodes the tiles, parses the
style (paint, layout, expressions, filters) and paints each tile to a `TCanvas` — anti-aliased
via GDI+, with a MapLibre-style symbol-placement engine.

Target: **Delphi 10.3 Rio+**, VCL, FireDAC (SQLite linked statically — no `sqlite3.dll`).

---

## Features

- **MBTiles reader** (SQLite via FireDAC, statically linked), TMS Y-flip, metadata.
- **Decompression**: gzip / zlib / raw, auto-detected.
- **MVT parser**: `vector_tile.proto` → layers / features / typed values; geometry commands
  (delta + zigzag), multi-part lines, multi-ring polygons with holes, ring classification by signed area.
- **Mapbox GL / MapTiler `style.json`**: full paint + layout model.
- **Expression engine**: `get/has/zoom/geometry-type/line-progress`, comparisons, `all/any/!`,
  `in`, `case/match/step/interpolate` (incl. `interpolate-hcl/lab`), `coalesce/concat`, math,
  `to-*`, `rgb/rgba`, `length`; legacy **function-stops** and legacy **filter arrays**.
- **Renderer** (`TCanvas`, GDI+ anti-aliased, supersampled):
  - **background** (color, opacity, pattern), **fill** (color, opacity, outline, pattern, translate,
    sort-key, holes, real alpha), **fill-extrusion** (flat footprint),
  - **line** (color, opacity, width incl. function-stops, cap, join, dasharray, gap-width, offset,
    translate, blur, gradient, sort-key, pattern best-effort, synthetic casing toggle),
  - **circle** (radius, color, opacity, stroke, blur, translate, sort-key),
  - **symbol**: `icon-image` / `icon-size` / `icon-rotate` / `icon-offset` / `icon-anchor` /
    `icon-opacity` / `icon-color` (SDF tint), text (`text-field`, `text-font`, `text-size`,
    `text-max-width` wrapping, `text-anchor`, `text-offset`, `text-justify`, `text-line-height`,
    `text-letter-spacing`, `text-transform`, halo), text-along-line.
  - **Symbol placement engine** (MapLibre-style): collect → sort by `(layer, symbol-sort-key)` →
    spatial-grid collision with padding → cross-feature dedup within `symbol-spacing` →
    variable-anchor → `text/icon-optional` / `allow-overlap` / `ignore-placement`. Place labels
    win collision over POIs (later style layers prioritised; paint order preserved).
- **Polymorphic drawing backend**: all primitives go through an abstract `TPBFDrawSurface`
  (GDI+ implementation in the base unit). An optional `TPBFSkiaSurface` child draws the same
  primitives on **Skia**. The renderer contains **no `{$IFDEF}`** — the backend is chosen at
  runtime via `Engine.UseSkia`, and Skia is enabled simply by linking
  `PBFMap.Render.Surface.Skia` into the host. Text always renders through GDI+ for parity.
- **Sprites**: loads `sprite.json` + `sprite.png` (32-bit premultiplied atlas); icons via AlphaBlend
  or GDI+ (rotation / opacity / SDF tint).
- **Metatile rendering**: render an N×N block as one scene (shared placement) so boundary labels
  stitch across tiles; output slices cached.
- **Caching**: LRU of decoded tiles + metatile output slices.
- **Logging**: optional `OnLog: TPBFLogEvent` (self-contained, no external dependency). Speaking
  severity levels `TPBFLogLevel` (`tplivException`=1 … `tplivTiming`=5). When wired, failures log
  and degrade gracefully; when not, they raise.

---

## Architecture (`Source\`)

| Unit | Role |
|------|------|
| `PBFMap.Types` | Shared types, exceptions, constants (`PBF_TILE_EXTENT=4096`) |
| `PBFMap.Decoder` | Low-level protobuf reader (varint, zigzag, fixed, packed) |
| `PBFMap.Compression` | gzip / zlib / raw → plain PBF bytes |
| `PBFMap.MBTiles` | SQLite/FireDAC reader, `GetTileData(z,x,y)`, TMS flip, metadata |
| `PBFMap.MVT.Types` | `TMVTValue`, multi-part/multi-ring geometry, `TMVTFeature/Layer/Tile` |
| `PBFMap.MVT.Parser` | PBF bytes → `TMVTTile` |
| `PBFMap.Color` | `#hex` / `rgb()` / `hsl()` / named color parsing → `TMGLColor` |
| `PBFMap.Expressions` | Mapbox GL expression AST + parser; filter / function-stop compilers |
| `PBFMap.Style.Model` | `TMGLStyle` / `TMGLLayer` / paint+layout property bags |
| `PBFMap.Style.Parser` | `style.json` → style model (incl. `class` filter index hints) |
| `PBFMap.Collision` | `TGridIndex` spatial hash for symbol collision |
| `PBFMap.Sprite` | `TMGLSprite` atlas: lookup + blit / rotate / tint icons |
| `PBFMap.Render.Surface` | Abstract `TPBFDrawSurface` drawing backend + its **GDI+** implementation |
| `PBFMap.Render.Surface.Skia` | Optional `TPBFSkiaSurface` child — same primitives on **Skia** (link to enable) |
| `PBFMap.Renderer.GL` | `TMGLRenderer`: style-driven `TCanvas` paint loop + placement (backend-agnostic) |
| `PBFMap.Engine` | `TPBFMapEngine` facade: open + style + render + caches + metatile |

**Pipeline:** `MBTiles → DecompressTile → TMVTTileParser → TMVTTile` + `style.json → TMGLStyle`
→ `TMGLRenderer` → `TCanvas`.

---

## Requirements

- Delphi 10.3 Rio or later, VCL (`Vcl.Graphics`, GDI+ via `Winapi.GDIPOBJ`).
- FireDAC (bundled with Delphi). SQLite is **statically linked**
  (`FireDAC.Phys.SQLiteWrapper.Stat` + `FireDAC.Phys.SQLiteDef`) — no `sqlite3.dll` at runtime.
- **No external dependencies.** Logging is self-contained (`TPBFLogEvent` / `TPBFLogLevel` in
  `PBFMap.Types`). The level ordinals are the numeric severities (Exception=1 … Timing=5), so a
  host with its own 0-based logger can map with `Ord(aLevel) - 1` in its `OnLog` handler.

---

## Build & Test

There is no `.dproj` for the library itself (only the units in `Source\`). The two buildable
targets are the test and sample projects.

```sh
# Unit tests (DUnitX console) — from Test\
dcc32 -B -U"..\Source" -NS"System;System.Win;Winapi;Vcl;Data;FireDAC" PBFMapRenderer.Tests.dpr
PBFMapRenderer.Tests.exe        # runs the full suite (90 tests, all pass); exit code <> 0 on failure

# Performance / profiling benchmark — from Test\
dcc32 -B ... bench.dpr
bench.exe                       # 7x7 z14 grid timings + per-layer / per-function breakdown

# Sample viewer (VCL) — has a .dproj; open in RAD Studio or build BasicViewer.dpr
```

`dcc32` needs FireDAC/VCL on the search path (set up via RAD Studio's `rsvars.bat`).
Integration tests require `Sample\BasicViewer\style.json` and `Sample\BasicViewer\data\roma.mbtiles`
(they walk up from the exe to find them). Rome test tile = z14 `8760/6088`.

---

## Quick Start

```pascal
uses PBFMap.Engine;

var
  Engine: TPBFMapEngine;
begin
  Engine := TPBFMapEngine.Create(256);     // 256px output tiles
  try
    Engine.OpenTiles('data\roma.mbtiles');
    Engine.LoadStyle('style.json');         // loads sprite.json/png from the same folder
    Engine.RenderTile(14, 8760, 6088, Image1.Picture.Bitmap.Canvas);
  finally
    Engine.Free;
  end;
end;
```

### Configuration (`TPBFMapEngine`)

| Property | Default | Effect |
|----------|---------|--------|
| `Supersample` | 2 | SSAA factor: render N× then downscale (1 = off, ~−10%) |
| `Antialias` | True | GDI+ geometry AA (off ≈ −6%, jaggier) |
| `SyntheticCasing` | True | Grey under-stroke for light lines — **set False for rich styles** (osm-bright) |
| `MetatileSize` | 2 | Render an N×N block as one scene so edge labels stitch; slices cached (re-paint ≈ instant). 1 = off |
| `TileCacheSize` | 64 | LRU of decoded tiles (warm re-render skips decode) |
| `UseSkia` | False | Switch the geometry backend to `TPBFSkiaSurface` at runtime (requires linking `PBFMap.Render.Surface.Skia`); text stays GDI+ |
| `OnLog` | nil | `TPBFLogEvent`; when set, failures log + degrade instead of raising |

The engine is **not thread-safe** — for parallel rendering use **one engine instance per thread**.

---

## Style support / coverage

For an **OpenMapTiles vector style** the common-property coverage is high. Verified against 5 real
no-key styles rendered on the same MBTiles: **osm-bright, Carto Positron / Voyager / Dark-Matter,
OSM Liberty**.

| Metric | Coverage |
|--------|----------|
| Properties handled / spec (5 vector layer types) | ~80% |
| Properties **weighted by real-world style usage** | ~99% |
| Properties present in the 5 tested styles | 100% |
| Cartographic layer types (background/fill/line/circle/symbol) | 5/5 |
| Expression operators used by the styles | 100% (+ legacy function-stops & filters) |

**Not implemented** (out of scope / structural): SDF glyph atlases (text uses GDI fonts),
per-glyph curved text, 3D `fill-extrusion` (drawn as flat footprint), `raster` / `heatmap` /
`hillshade` / `sky` layers, multi-tile pan/zoom (the host does that), and advanced expressions
(`feature-state`, `within`, `distance`, rich `format`/`number-format`, `collator`). `text-halo-blur`
is approximated (solid halo); `*-rotation-alignment` / `*-pitch-*` are read but no-ops on flat
north-up tiles.

---

## Performance

Measured single-thread on `roma.mbtiles`, osm-bright, a **7×7 = 49 tile** z14 block at 256px
(`Test\bench.dpr`). "WARM" = re-paint with caches warm.

| Config | first paint | per tile | re-paint |
|--------|-------------|----------|----------|
| metatile ON(2), SS2, AA (default) | ~6.1 s | ~124 ms | **~1 ms** (slices cached) |
| metatile OFF, SS2, AA | ~5.4 s | ~110 ms | ~96 ms |
| metatile OFF, SS1, AA off (fast) | ~3.6 s | ~74 ms | ~60 ms |

Per-tile split (SS2): decode + filter ≈ 29 ms, **GDI+ draw ≈ 73 ms**. Built-in sub-function profiler
(gated `Engine.SetProfiling(True)`, methods `TopFuncs`/`TopLayers`) over the whole grid:

| Sub-step | total | what |
|----------|-------|------|
| `DrawLines` (inside StrokeLines) | ~1.74 s | GDI+ line rasterization — the real line cost (94% of StrokeLines; pen-setup 58 ms, point-conv 12 ms) |
| `DrawPath` (fill outline, 1px) | ~0.49 s | GDI+ outline stroke — costs as much as the fill |
| `FillPath` | ~0.47 s | GDI+ polygon fill |
| `FilterEval` | ~0.78 s | layer filter on candidate features (after class-index + filter-elision) |
| `mvtParse` | ~0.41 s | protobuf parse (after lazy feature properties) |
| `decompress` | ~0.14 s | gzip |
| our geometry (`PartToPixels`) | ~0.07 s | negligible |

So the draw is dominated by the GDI+ primitives `DrawLines` + `FillPath`/`DrawPath` (≈ 95% of draw,
all native GDI+ — `DrawLines` alone is 94% of the line cost); decode-side, `FilterEval` then `mvtParse`
lead. There is no algorithmic fat left in the library code — the remaining big levers are **parallelism**
or a **GPU draw layer**.

Optimisations applied: **per-`class` feature index** (layers touch only their class bucket instead
of re-scanning every feature — the big win, 370→158 ms/tile), **per-layer keys/values snapshot** in
the MVT parser, **pixel-duplicate vertex dropping**, **filter-elision** (skip the filter when it is
fully implied by the geometry gate + class bucket), **lazy feature properties** (parallel key/value
arrays, no per-feature dictionary), **persistent GDI+ pen/brush** (no per-feature create), shared
GDI+ surface, decode + metatile-slice caches. Net: **~370 → ~100 ms/tile (≈3.7×)**, with the
remaining ~73 ms/tile being GDI+ primitives (GPU-bound).

The remaining levers are **parallelism** (N engines on a thread pool → ~first-paint / N, e.g. ~0.65 s
per screen at 8 threads, with instant re-paint via the metatile cache) and a **GPU** (Direct2D/Skia)
rewrite of the draw layer. Profiling is built in but gated: `Engine.SetProfiling(True)` then
`TopLayers` / `TopFuncs`; the **Sample**'s *Render* button shows the per-layer / per-function popup.

### Decode-side & correctness work

Beyond the draw layer, the decode path and expression engine were tightened:

- **Zero-copy MVT decode** — packed varints are unpacked inline and layers/features are parsed over
  byte sub-ranges of the source buffer instead of copying intermediate slices.
- **Thread-safe property memoisation** — feature-constant property lookups are cached per thread via
  a `threadvar GActivePropCache`, so the cache is safe when running one engine per thread.
- **`FilterEval` key-interning** — filter keys are interned through an **FNV-1a** key hash, removing
  repeated string compares during filter evaluation.
- **Audit fixes** — exact **cubic-bezier** easing (no approximation), and real
  `interpolate-hcl` / `interpolate-lab` color interpolation computed in **CIELAB / CIELCh**
  (previously an RGB approximation).

### Skia backend

When the draw layer runs on Skia (`Engine.UseSkia := True`), the heavy GDI+ primitives are markedly
faster per primitive:

| Primitive | Skia vs GDI+ |
|-----------|--------------|
| `FillRings` (polygon fill, incl. holes) | **~4.5×** |
| dashed lines | **~1.9×** |
| circles | **~2.2×** |

Output is visually equivalent — see the side-by-side comparison in
[`Docs/skia-vs-gdi/`](Docs/skia-vs-gdi/) (`gdi.png` vs `skia.png`).

---

## Tile generation (reference)

Tiles are generated with **tilemaker** (use the **v2** build; the "root" build crashed on large files):

```sh
cd C:/Tools/tilemaker/v2/resources
tilemaker.exe --input centro.osm.pbf --output roma.mbtiles \
  --config C:/Tools/tilemaker/resources/config-albania.json \
  --process process-openmaptiles.lua --store <tmpdir>
```

OSM extract: `https://download.geofabrik.de/europe/italy/centro-latest.osm.pbf`.
`config-albania.json` skips the global coastline/landcover shapefiles (not needed for a city).
The bundled `roma.mbtiles` (~290 MB) covers Central Italy (Rome included), OpenMapTiles schema,
z0–14, gzip, TMS.

> Note: tilemaker emits dense building footprints already at z14. With styles that gate minor-road
> fill to z15 (e.g. Carto Positron) those buildings can visually bury the thin roads at z14 — this
> is a data/style-threshold effect, not a renderer issue; osm-bright renders white roads at z14.

A fully MapTiler-like pipeline would additionally need: city bbox clipping (osmium/osmconvert),
incremental updates, a sprite/glyph maker, and optionally a tile server (`/{z}/{x}/{y}.pbf` +
TileJSON + sprite + glyph via Indy/WebBroker).

---

## Conventions / gotchas

- MBTiles is **TMS** (Y flipped): the reader computes `tile_row = 2^z-1 - y`. Tiles are **gzip**.
- `TileToPixel` uses the **layer extent** (not the global constant).
- Colors in expressions travel as the canonical string `rgba(r,g,b,a)`.
- `shr` on `Int64` in Delphi is **logical** (not arithmetic) — watch zigzag decoding.
- In `System.JSON`, `TJSONNumber` descends from `TJSONString` — number/string checks must order
  the number test first (handled in the expression/style parsers).

---

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2025 amancini.
