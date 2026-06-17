# Skia vs GDI+ backend — Rome z14 tile 8760/6088

Same renderer, switchable drawing backend (`TPBFDrawSurface` GDI+ base / Skia child,
`Engine.UseSkia`). Flat areas are pixel-identical; differences are AA-edge only.

| GDI+ | Skia |
|------|------|
| ![gdi](gdi.png) | ![skia](skia.png) |

## Per-primitive speedup (surfbench, real surface classes)
| Primitive | GDI+ ms/frame | Skia ms/frame | Speedup |
|---|---|---|---|
| FillRings (+outline) | 43.45 | 9.55 | 4.55x |
| StrokeLines (solid) | 85.60 | 58.60 | 1.46x |
| StrokeLines (dashed) | 127.15 | 67.50 | 1.88x |
| DrawCircle (+stroke) | 11.05 | 5.05 | 2.19x |

End-to-end ~1.3x (text/icons stay GDI in both; CPU decode/filter is backend-independent).
