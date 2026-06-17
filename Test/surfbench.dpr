program surfbench;

{ Per-primitive micro-benchmark of the REAL drawing surfaces (TPBFDrawSurface GDI+
  vs the Skia subclass), not duplicated code. Times FillRings, StrokeLines (solid +
  dashed) and DrawCircle on a dense synthetic workload (z14-tile order of magnitude)
  for each backend and reports ms/frame + speedup per primitive. Linking
  PBFMap.Render.Surface.Skia registers the Skia factory used by CreateDrawSurface. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Math, System.Diagnostics, System.Types,
  Winapi.Windows, Winapi.GDIPAPI, Winapi.GDIPOBJ,
  Vcl.Graphics,
  PBFMap.Color, PBFMap.Render.Surface, PBFMap.Render.Surface.Skia;

const
  SZ    = 512;
  NLIN  = 4000;
  NFILL = 1500;
  NCIRC = 1500;
  ITERS = 20;

var
  Lines: TArray<TArray<TPoint>>;
  Fills: TArray<TArray<TPoint>>;
  Circs: TArray<TPoint>;
  Seed: Cardinal = 12345;

function R(AMax: Integer): Integer;
begin
  Seed := Seed * 1103515245 + 12345;
  Result := (Seed shr 16) mod Cardinal(AMax);
end;

procedure Gen;
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
  SetLength(Circs, NCIRC);
  for i := 0 to NCIRC - 1 do
    Circs[i] := Point(R(SZ), R(SZ));
end;

type
  TPrim = (pFill, pLine, pDash, pCirc);

function Pass(AUseSkia: Boolean; APrim: TPrim): Int64;
var
  Bmp: TBitmap;
  Surf: TPBFDrawSurface;
  Sw: TStopwatch;
  it, i: Integer;
  Fill, Outline, Stroke: TMGLColor;
  Ring: TArray<TArray<TPoint>>;
  Part: TArray<TArray<TPoint>>;
  Dash: TArray<Double>;
begin
  Fill := TMGLColor.FromRGBA(200, 180, 160, 255);
  Outline := TMGLColor.FromRGBA(120, 110, 100, 255);
  Stroke := TMGLColor.FromRGBA(80, 80, 90, 255);
  Dash := [2.0, 2.0];
  Bmp := TBitmap.Create;
  try
    Bmp.PixelFormat := pf32bit;
    Bmp.SetSize(SZ, SZ);
    Surf := CreateDrawSurface(AUseSkia, Bmp.Canvas, True);
    try
      SetLength(Ring, 1);
      SetLength(Part, 1);
      Sw := TStopwatch.StartNew;
      for it := 1 to ITERS do
      begin
        Surf.BeginFrame(SZ, SZ);
        case APrim of
          pFill:
            for i := 0 to High(Fills) do
            begin
              Ring[0] := Fills[i];
              Surf.FillRings(Ring, Fill, True, Outline);
            end;
          pLine:
            for i := 0 to High(Lines) do
            begin
              Part[0] := Lines[i];
              Surf.StrokeLines(Part, Stroke, 2, nil, LineCapRound, LineJoinRound);
            end;
          pDash:
            for i := 0 to High(Lines) do
            begin
              Part[0] := Lines[i];
              Surf.StrokeLines(Part, Stroke, 2, Dash, LineCapFlat, LineJoinRound);
            end;
          pCirc:
            for i := 0 to High(Circs) do
              Surf.DrawCircle(Circs[i].X, Circs[i].Y, 4, 1, Fill, True, Stroke, 0);
        end;
        Surf.FlushGeometry;
        Surf.EndFrame;
      end;
      Sw.Stop;
      Result := Sw.ElapsedMilliseconds;
    finally
      Surf.Free;
    end;
  finally
    Bmp.Free;
  end;
end;

procedure Report(const AName: string; APrim: TPrim);
var g, s: Int64;
begin
  g := Pass(False, APrim); g := Pass(False, APrim);  // warm + measure
  s := Pass(True, APrim);  s := Pass(True, APrim);
  Writeln(Format('%-22s GDI=%4d ms (%.2f/f)  Skia=%4d ms (%.2f/f)  speedup=%.2fx',
    [AName, g, g / ITERS, s, s / ITERS, g / Max(1, s)]));
end;

begin
  try
    Gen;
    Writeln(Format('surfbench  %dx%d  fills=%d lines=%d circles=%d  x%d iters',
      [SZ, SZ, NFILL, NLIN, NCIRC, ITERS]));
    Report('FillRings(+outline)', pFill);
    Report('StrokeLines(solid)', pLine);
    Report('StrokeLines(dashed)', pDash);
    Report('DrawCircle(+stroke)', pCirc);
  except
    on E: Exception do
    begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
