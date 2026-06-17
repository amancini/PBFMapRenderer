program bench;

{ Performance benchmark: render a full z14 grid of 256px tiles the way
  MapsViewerOffline requests them, and report the TOTAL time to paint the whole
  grid (cold = caches empty, warm = re-paint) under several configs. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Diagnostics, System.IOUtils, System.Math,
  Vcl.Graphics,
  PBFMap.Types, PBFMap.Engine;

const
  TILE = 256;
  Z = 14;
  CX = 8760; CY = 6088;   // Rome center z14
  RADIUS = 3;             // 7x7 = 49 tiles (~ a screen)

var
  Engine: TPBFMapEngine;
  Bmp: TBitmap;
  GMs: Int64;

function FindUp(const ARel: string): string;
var LBase, LCand: string; I: Integer;
begin
  LBase := ExtractFilePath(ParamStr(0));
  for I := 0 to 6 do
  begin
    LCand := TPath.Combine(LBase, ARel);
    if TFile.Exists(LCand) then Exit(LCand);
    LBase := ExtractFilePath(ExcludeTrailingPathDelimiter(LBase));
    if LBase = '' then Break;
  end;
  Result := '';
end;

function GridMs: Int64;
var X, Y: Integer; Sw: TStopwatch;
begin
  Sw := TStopwatch.StartNew;
  for Y := CY - RADIUS to CY + RADIUS do
    for X := CX - RADIUS to CX + RADIUS do
    begin
      Bmp.Canvas.Brush.Color := clWhite;
      Bmp.Canvas.FillRect(Rect(0, 0, TILE, TILE));
      Engine.RenderTile(Z, X, Y, Bmp.Canvas);
    end;
  Sw.Stop;
  Result := Sw.ElapsedMilliseconds;
end;

procedure Measure(const ALabel: string; AMeta, ASS: Integer; AAA: Boolean);
var N: Integer; Cold, Warm: Int64;
begin
  Engine.MetatileSize := AMeta;
  Engine.Supersample := ASS;
  Engine.Antialias := AAA;
  Engine.ClearTileCache;
  N := Sqr(2 * RADIUS + 1);
  Cold := GridMs;                 // caches empty
  Warm := GridMs;                 // re-paint, caches warm
  Writeln(Format('%-26s grid %d tiles: COLD=%dms (%.0fms/tile, %.1f t/s)  WARM=%dms (%.0fms/tile)',
    [ALabel, N, Cold, Cold / N, 1000.0 * N / Max(1, Cold), Warm, Warm / N]));
end;

begin
  try
    Engine := TPBFMapEngine.Create(TILE);
    try
      if Pos('bright', FindUp('Sample\BasicViewer\bright\style.json')) > 0 then
        Engine.SyntheticCasing := False;
      Engine.LoadStyle(FindUp('Sample\BasicViewer\bright\style.json'));
      Engine.OpenTiles(FindUp('Sample\BasicViewer\data\roma.mbtiles'));

      Bmp := TBitmap.Create;
      try
        Bmp.PixelFormat := pf32bit; Bmp.SetSize(TILE, TILE);
        Engine.RenderTile(Z, CX, CY, Bmp.Canvas);  // warm-up (not timed)

        Writeln('Full ', 2*RADIUS+1, 'x', 2*RADIUS+1, ' grid around Rome z14:');
        Measure('metatile OFF, SS2 AA',   1, 2, True);
        Measure('metatile OFF, SS2 noAA', 1, 2, False);
        Measure('metatile OFF, SS1 noAA', 1, 1, False);
        Measure('metatile ON(2), SS2 AA', 2, 2, True);

        // split: skip-draw isolates decode+iterate+filter; full - that = draw time
        Engine.MetatileSize := 1; Engine.Supersample := 2; Engine.Antialias := True;
        Engine.ClearTileCache; Engine.DebugSkipDraw := True;
        GMs := GridMs;
        Writeln(Format('  [skip-draw] decode+iterate+filter only: %dms (%.0fms/tile)',
          [GMs, GMs / Sqr(2*RADIUS+1)]));
        Engine.DebugSkipDraw := False;

        // per-layer profiling: which layers cost the most over the whole grid
        Engine.MetatileSize := 1; Engine.Supersample := 2; Engine.Antialias := True;
        Engine.ClearTileCache; Engine.SetProfiling(True); Engine.ResetProfile;
        GridMs;
        Engine.SetProfiling(False);
        Writeln('Top layers by draw time (whole grid):');
        Write(Engine.TopLayers(12));
        Writeln('Top functions by time (whole grid):');
        Write(Engine.TopFuncs(20));
      finally
        Bmp.Free;
      end;
    finally
      Engine.Free;
    end;
  except
    on E: Exception do
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
  end;
end.
