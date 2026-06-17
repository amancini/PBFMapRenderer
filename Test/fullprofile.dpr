program fullprofile;

{ Exhaustive per-function profile of the WHOLE pipeline, for BOTH backends.
  Renders the Rome z14 7x7 grid (cold) with profiling on and dumps:
   - Engine.TopFuncs / TopLayers (renderer + draw surface, via the renderer's
     own per-function timers wired through the surface ProfileHook), and
   - PBFMap.Profile.ProfReport (decode/parse/style/collision/sprite scope timers).
  Run once with UseSkia=False and once with =True so every function's cost is
  visible side by side. Profiling adds overhead -> use bench.dpr for absolute ms. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Diagnostics, System.IOUtils, System.Math,
  Vcl.Graphics,
  PBFMap.Types, PBFMap.Engine, PBFMap.Profile,
  PBFMap.Render.Surface.Skia;   // link -> Skia backend available

const
  TILE = 256;
  Z = 14;
  CX = 8760; CY = 6088;
  RADIUS = 3;             // 7x7

var
  Log: TStringList;

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

procedure RunPass(const ATag, AStyle, AMBTiles: string; AUseSkia: Boolean);
var
  Engine: TPBFMapEngine;
  Bmp: TBitmap;
  X, Y: Integer;
begin
  Log.Add('');
  Log.Add('================ PASS ' + ATag + ' (UseSkia=' + BoolToStr(AUseSkia, True) + ') ================');
  Engine := TPBFMapEngine.Create(TILE);
  try
    Engine.OnLog := nil;
    Engine.SyntheticCasing := False;
    Engine.Antialias := True;
    Engine.Supersample := 1;
    Engine.MetatileSize := 1;     // isolate per-tile cost (no scene stitching)
    Engine.MetatileBuffer := 0;
    Engine.TileCacheSize := 0;    // force cold decode every tile
    Engine.UseSkia := AUseSkia;
    Engine.LoadStyle(AStyle);
    Engine.OpenTiles(AMBTiles);

    Bmp := TBitmap.Create;
    try
      Bmp.PixelFormat := pf32bit;
      Bmp.SetSize(TILE, TILE);

      Engine.SetProfiling(True);
      Engine.ResetProfile;
      ProfReset;
      GProfEnabled := True;
      try
        for Y := CY - RADIUS to CY + RADIUS do
          for X := CX - RADIUS to CX + RADIUS do
          begin
            Bmp.Canvas.Brush.Color := clWhite;
            Bmp.Canvas.FillRect(Rect(0, 0, TILE, TILE));
            Engine.RenderTile(Z, X, Y, Bmp.Canvas);
          end;
      finally
        GProfEnabled := False;
        Engine.SetProfiling(False);
      end;

      Log.Add('--- renderer/draw (Engine.TopFuncs) ---');
      Log.Add(Engine.TopFuncs(40));
      Log.Add('--- per-layer (Engine.TopLayers) ---');
      Log.Add(Engine.TopLayers(20));
      Log.Add('--- decode/parse/style/collision/sprite (PBFMap.Profile) ---');
      Log.Add(ProfReport(0));
    finally
      Bmp.Free;
    end;
  finally
    Engine.Free;
  end;
end;

var
  LStyle, LMBTiles: string;
begin
  try
    LMBTiles := FindUp('Sample\BasicViewer\data\roma.mbtiles');
    LStyle := 'C:\OW_D104\Utility\MapsViewerOffline\style.json';
    if not TFile.Exists(LStyle) then
      LStyle := FindUp('Sample\BasicViewer\bright\style.json');
    if (LMBTiles = '') or (LStyle = '') then
    begin
      Writeln('ERROR: data not found'); ExitCode := 1; Exit;
    end;

    Log := TStringList.Create;
    try
      Log.Add('fullprofile - Rome z14 7x7  style=' + LStyle);
      RunPass('GDI', LStyle, LMBTiles, False);
      RunPass('SKIA', LStyle, LMBTiles, True);
      Log.SaveToFile(ExtractFilePath(ParamStr(0)) + 'fullprofile.log');
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
