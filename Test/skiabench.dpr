program skiabench;

{ Apples-to-apples: draw the SAME dense set of anti-aliased polylines + filled
  polygons to a 512x512 raster with GDI+ (current renderer) vs Skia (System.Skia
  raster surface), and compare wall-clock. Decides whether a Skia backend is
  worth porting the renderer's draw layer to (the ~50% GDI+ floor). }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Math, System.Diagnostics, System.Types,
  Winapi.Windows, Winapi.GDIPAPI, Winapi.GDIPOBJ, Vcl.Graphics,
  System.Skia;

const
  SZ    = 512;     // supersampled-ish tile
  NLIN  = 4000;    // polylines per pass (dense z14 road tile order of magnitude)
  NFILL = 1500;    // filled polygons (buildings/landuse)
  ITERS = 20;      // repeat to average

var
  Lines: TArray<TArray<TPoint>>;
  Fills: TArray<TArray<TPoint>>;
  Seed: Cardinal = 12345;

function R(AMax: Integer): Integer;
begin
  Seed := Seed * 1103515245 + 12345;
  Result := (Seed shr 16) mod Cardinal(AMax);
end;

procedure GenGeometry;
var i, j, n, x, y: Integer;
begin
  SetLength(Lines, NLIN);
  for i := 0 to NLIN - 1 do
  begin
    n := 2 + R(8);
    SetLength(Lines[i], n);
    x := R(SZ); y := R(SZ);
    for j := 0 to n - 1 do
    begin
      x := EnsureRange(x - 20 + R(40), 0, SZ);
      y := EnsureRange(y - 20 + R(40), 0, SZ);
      Lines[i][j] := Point(x, y);
    end;
  end;
  SetLength(Fills, NFILL);
  for i := 0 to NFILL - 1 do
  begin
    n := 4 + R(6);
    SetLength(Fills[i], n);
    x := R(SZ); y := R(SZ);
    for j := 0 to n - 1 do
      Fills[i][j] := Point(EnsureRange(x - 15 + R(30), 0, SZ),
                           EnsureRange(y - 15 + R(30), 0, SZ));
  end;
end;

function GdiPass: Int64;
var
  Bmp: TBitmap; G: TGPGraphics; Pen: TGPPen; Brush: TGPSolidBrush;
  Pts: array of TGPPoint; Path: TGPGraphicsPath;
  it, i, j: Integer; Sw: TStopwatch;
begin
  Bmp := TBitmap.Create;
  Bmp.PixelFormat := pf32bit; Bmp.SetSize(SZ, SZ);
  G := TGPGraphics.Create(Bmp.Canvas.Handle);
  G.SetSmoothingMode(SmoothingModeAntiAlias);
  G.SetPixelOffsetMode(PixelOffsetModeHalf);
  Pen := TGPPen.Create(MakeColor(255, 80, 80, 90), 2);
  Brush := TGPSolidBrush.Create(MakeColor(255, 200, 180, 160));
  SetLength(Pts, 16);
  Sw := TStopwatch.StartNew;
  for it := 1 to ITERS do
  begin
    Bmp.Canvas.Brush.Color := clWhite; Bmp.Canvas.FillRect(Rect(0,0,SZ,SZ));
    for i := 0 to High(Fills) do
    begin
      if Length(Pts) < Length(Fills[i]) then SetLength(Pts, Length(Fills[i]));
      for j := 0 to High(Fills[i]) do Pts[j] := MakePoint(Fills[i][j].X, Fills[i][j].Y);
      Path := TGPGraphicsPath.Create(FillModeAlternate);
      try
        Path.AddLines(PGPPoint(@Pts[0]), Length(Fills[i])); Path.CloseFigure;
        G.FillPath(Brush, Path);
      finally Path.Free; end;
    end;
    for i := 0 to High(Lines) do
    begin
      if Length(Lines[i]) < 2 then Continue;
      if Length(Pts) < Length(Lines[i]) then SetLength(Pts, Length(Lines[i]));
      for j := 0 to High(Lines[i]) do Pts[j] := MakePoint(Lines[i][j].X, Lines[i][j].Y);
      G.DrawLines(Pen, PGPPoint(@Pts[0]), Length(Lines[i]));
    end;
  end;
  Sw.Stop;
  Pen.Free; Brush.Free; G.Free; Bmp.Free;
  Result := Sw.ElapsedMilliseconds;
end;

function SkiaPass: Int64;
var
  Surf: ISkSurface; Cnv: ISkCanvas; Pen, Fill: ISkPaint;
  PB: ISkPathBuilder;
  it, i, j: Integer; Sw: TStopwatch;
begin
  Surf := TSkSurface.MakeRaster(SZ, SZ);
  Cnv := Surf.Canvas;
  Pen := TSkPaint.Create;
  Pen.AntiAlias := True; Pen.Style := TSkPaintStyle.Stroke;
  Pen.StrokeWidth := 2; Pen.Color := $FF50505A;
  Fill := TSkPaint.Create;
  Fill.AntiAlias := True; Fill.Style := TSkPaintStyle.Fill; Fill.Color := $FFC8B4A0;
  Sw := TStopwatch.StartNew;
  for it := 1 to ITERS do
  begin
    Cnv.Clear($FFFFFFFF);
    for i := 0 to High(Fills) do
    begin
      PB := TSkPathBuilder.Create;
      PB.MoveTo(Fills[i][0].X, Fills[i][0].Y);
      for j := 1 to High(Fills[i]) do PB.LineTo(Fills[i][j].X, Fills[i][j].Y);
      PB.Close;
      Cnv.DrawPath(PB.Detach, Fill);
    end;
    for i := 0 to High(Lines) do
    begin
      if Length(Lines[i]) < 2 then Continue;
      PB := TSkPathBuilder.Create;
      PB.MoveTo(Lines[i][0].X, Lines[i][0].Y);
      for j := 1 to High(Lines[i]) do PB.LineTo(Lines[i][j].X, Lines[i][j].Y);
      Cnv.DrawPath(PB.Detach, Pen);
    end;
  end;
  Sw.Stop;
  Result := Sw.ElapsedMilliseconds;
end;

var g, s: Int64;
begin
  try
    GenGeometry;
    Writeln(Format('Workload: %d polylines + %d fills, %dx%d, x%d iters', [NLIN, NFILL, SZ, SZ, ITERS]));
    g := GdiPass;   // warm + measure
    g := GdiPass;
    s := SkiaPass;
    s := SkiaPass;
    Writeln(Format('GDI+ : %d ms  (%.2f ms/frame)', [g, g/ITERS]));
    Writeln(Format('Skia : %d ms  (%.2f ms/frame)', [s, s/ITERS]));
    if s > 0 then Writeln(Format('Skia speedup: %.2fx', [g/s]));
  except
    on E: Exception do Writeln('ERROR: ', E.ClassName, ': ', E.Message);
  end;
end.
