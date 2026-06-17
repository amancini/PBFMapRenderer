program labeldiag;

{ Headless label/symbol diagnostic. Renders a Rome z14 block to PNG and logs,
  per tile, how many label candidates were collected vs placed and WHY each was
  dropped (Engine.SymbolReport). Compares both styles (bright + app) and both
  metatile modes (M=1 vs M=2+buffer) to pinpoint the "missing labels" cause.
  No DevExpress / GUI — builds and runs while the app is open. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils,
  Vcl.Graphics, Vcl.Imaging.pngimage,
  PBFMap.Types, PBFMap.Engine;

const
  TILE = 256;
  Z = 14;
  CX = 8760; CY = 6088;   // Rome center z14 (Piazza della Repubblica area)
  RADIUS = 1;             // 3x3 block (center + neighbours)

var
  Log: TStringList;
  OutDir: string;

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

procedure SavePng(ABmp: TBitmap; const AFile: string);
var Png: TPngImage;
begin
  Png := TPngImage.Create;
  try
    Png.Assign(ABmp);
    Png.SaveToFile(AFile);
  finally
    Png.Free;
  end;
end;

{ Render the block in one mode with one style; log per-tile SymbolReport. }
procedure RunPass(const ATag, AStyle, AMBTiles: string; AMeta, ABuffer: Integer);
var
  Engine: TPBFMapEngine;
  Bmp: TBitmap;
  X, Y: Integer;
  Key: string;
begin
  if (AStyle = '') or (AMBTiles = '') then
  begin
    Log.Add(Format('[%s] SKIP - style or mbtiles not found (style=%s mbtiles=%s)',
      [ATag, AStyle, AMBTiles]));
    Exit;
  end;
  Log.Add('');
  Log.Add(Format('===== PASS %s  meta=%d buffer=%d =====', [ATag, AMeta, ABuffer]));
  Log.Add('style=' + AStyle);

  Engine := TPBFMapEngine.Create(TILE);
  try
    Engine.OnLog := nil;
    Engine.SyntheticCasing := False;   // same as the worker (osm-bright)
    Engine.Antialias       := True;
    Engine.Supersample     := 1;
    Engine.MetatileSize    := AMeta;
    Engine.MetatileBuffer  := ABuffer;
    Engine.TileCacheSize   := 64;      // diag: avoid eviction so reports are clean
    Engine.LoadStyle(AStyle);
    Engine.OpenTiles(AMBTiles);
    Engine.SetProfiling(True);
    Engine.ResetProfile;

    Bmp := TBitmap.Create;
    try
      Bmp.PixelFormat := pf32bit;
      Bmp.SetSize(TILE, TILE);
      for Y := CY - RADIUS to CY + RADIUS do
        for X := CX - RADIUS to CX + RADIUS do
        begin
          Key := Format('%d_%d_%d', [Z, X, Y]);
          // fresh render per tile so SymbolReport reflects THIS tile (or its block)
          Engine.ClearTileCache;
          Bmp.Canvas.Brush.Color := clWhite;
          Bmp.Canvas.FillRect(Rect(0, 0, TILE, TILE));
          Engine.RenderTile(Z, X, Y, Bmp.Canvas);
          SavePng(Bmp, Format('%s%s_%s.png', [OutDir, ATag, Key]));
          Log.Add(Format('  %s  iter=%d draw=%d geomMs=%d symMs=%d | %s',
            [Key, Engine.LastIterCount, Engine.LastDrawCount,
             Engine.LastGeomMs, Engine.LastSymMs, Engine.SymbolReport]));
        end;
    finally
      Bmp.Free;
    end;

    Engine.SetProfiling(False);
    Log.Add('  -- top layers --');
    Log.Add('  ' + StringReplace(Engine.TopLayers(12), sLineBreak, sLineBreak + '  ', [rfReplaceAll]));
    Log.Add('  -- top funcs --');
    Log.Add('  ' + StringReplace(Engine.TopFuncs(20), sLineBreak, sLineBreak + '  ', [rfReplaceAll]));
  finally
    Engine.Free;
  end;
end;

procedure TestRenderBlock(const AStyle, AMBTiles: string);
var
  Engine: TPBFMapEngine;
  N: Integer;
begin
  if (AStyle = '') or (AMBTiles = '') then Exit;
  Engine := TPBFMapEngine.Create(TILE);
  try
    Engine.SyntheticCasing := False;
    Engine.Supersample := 1;
    Engine.MetatileSize := 2;
    Engine.MetatileBuffer := 1;
    Engine.TileCacheSize := 24;
    Engine.LoadStyle(AStyle);
    Engine.OpenTiles(AMBTiles);
    N := 0;
    // block containing 8760/6088 -> origin 8760/6088 (both even)
    Engine.RenderBlock(Z, 8760, 6088,
      procedure(AX, AY: Integer; ABmp: TBitmap)
      begin
        Inc(N);
        if ABmp <> nil then
          SavePng(ABmp, Format('%sblock_%d_%d_%d.png', [OutDir, Z, AX, AY]));
      end);
    Log.Add(Format('RenderBlock(8760,6088) emitted %d tiles (expected 4)', [N]));
  finally
    Engine.Free;
  end;
end;

var
  LBright, LApp, LMBTiles: string;
begin
  try
    OutDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'diag_output');
    TDirectory.CreateDirectory(OutDir);
    Log := TStringList.Create;
    try
      LMBTiles := FindUp('Sample\BasicViewer\data\roma.mbtiles');
      LBright  := FindUp('Sample\BasicViewer\bright\style.json');
      LApp     := 'C:\OW_D104\Utility\MapsViewerOffline\style.json';
      if not TFile.Exists(LApp) then LApp := '';

      Log.Add('labeldiag - Rome z14 block ' + Format('%d..%d / %d..%d',
        [CX - RADIUS, CX + RADIUS, CY - RADIUS, CY + RADIUS]));
      Log.Add('mbtiles=' + LMBTiles);

      // verify Engine.RenderBlock emits every inner tile of a 2x2 block in ONE render
      TestRenderBlock(LBright, LMBTiles);

      // bright style, both metatile modes
      RunPass('bright_m1',   LBright, LMBTiles, 1, 0);
      RunPass('bright_m2buf', LBright, LMBTiles, 2, 1);
      // app style (the one actually deployed), both modes
      RunPass('app_m1',    LApp, LMBTiles, 1, 0);
      RunPass('app_m2buf', LApp, LMBTiles, 2, 1);

      Log.SaveToFile(OutDir + 'diagnostic.log');
      Writeln('OK -> ', OutDir);
      Writeln(Log.Text);
    finally
      Log.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
