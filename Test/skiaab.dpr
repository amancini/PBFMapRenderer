program skiaab;

{ A/B verification of the Skia geometry backend vs GDI+. Renders the SAME Rome
  z14 tiles with Engine.UseSkia=False and =True, dumps both PNGs, and reports a
  pixel-diff (mean/max channel delta, % pixels differing) + timing. Geometry goes
  through Skia when UseSkia=True; text/icons stay GDI+ in both. A small diff is
  expected (different AA rasteriser); a HUGE diff means the port is broken.

  Build (requires SKIA define for the Skia path to do anything):
    build_test.bat -DSKIA skiaab.dpr
  Without -DSKIA the UseSkia flag is inert and both passes are identical (sanity). }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Diagnostics, System.Math,
  Winapi.Windows,
  Vcl.Graphics, Vcl.Imaging.pngimage,
  PBFMap.Types, PBFMap.Engine,
  PBFMap.Render.Surface.Skia;   // linking this unit enables the Skia backend

const
  TILE = 256;
  Z = 14;
  CX = 8760; CY = 6088;   // Rome center z14
  RADIUS = 1;             // 3x3 block

var
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

{ Mean/max per-channel delta + % differing pixels between two 32-bit bitmaps. }
procedure DiffBitmaps(A, B: TBitmap; out AMeanDelta, AMaxDelta: Double;
  out APctDiff: Double);
var
  X, Y, D, MaxD: Integer;
  PA, PB: PRGBQuad;
  Sum: Int64;
  NDiff, NTot: Int64;
begin
  Sum := 0; MaxD := 0; NDiff := 0; NTot := 0;
  for Y := 0 to A.Height - 1 do
  begin
    PA := A.ScanLine[Y];
    PB := B.ScanLine[Y];
    for X := 0 to A.Width - 1 do
    begin
      D := Abs(PA.rgbRed - PB.rgbRed) + Abs(PA.rgbGreen - PB.rgbGreen) +
           Abs(PA.rgbBlue - PB.rgbBlue);
      Sum := Sum + D;
      if D > MaxD then MaxD := D;
      if D > 12 then Inc(NDiff);   // >4/channel avg = visibly different
      Inc(NTot);
      Inc(PA); Inc(PB);
    end;
  end;
  AMeanDelta := Sum / Max(1, NTot) / 3;
  AMaxDelta := MaxD / 3;
  APctDiff := NDiff / Max(1, NTot) * 100;
end;

function RenderOne(AEngine: TPBFMapEngine; X, Y: Integer; ABmp: TBitmap): Int64;
var Sw: TStopwatch;
begin
  AEngine.ClearTileCache;
  ABmp.Canvas.Brush.Color := clWhite;
  ABmp.Canvas.FillRect(Rect(0, 0, TILE, TILE));
  Sw := TStopwatch.StartNew;
  AEngine.RenderTile(Z, X, Y, ABmp.Canvas);
  Sw.Stop;
  Result := Sw.ElapsedMilliseconds;
end;

procedure ConfigEngine(AEngine: TPBFMapEngine; AStyle, AMBTiles: string; ASkia: Boolean);
begin
  AEngine.OnLog := nil;
  AEngine.SyntheticCasing := False;
  AEngine.Antialias := True;
  AEngine.Supersample := 1;
  AEngine.MetatileSize := 1;     // isolate per-tile, no scene stitching
  AEngine.MetatileBuffer := 0;
  AEngine.TileCacheSize := 8;
  AEngine.UseSkia := ASkia;
  AEngine.LoadStyle(AStyle);
  AEngine.OpenTiles(AMBTiles);
end;

var
  LStyle, LMBTiles, LKey: string;
  EG, ES: TPBFMapEngine;
  BG, BS: TBitmap;
  X, Y: Integer;
  TG, TS, SumG, SumS: Int64;
  MeanD, MaxD, PctD: Double;
  Log: TStringList;
begin
  try
    OutDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'skia_ab');
    TDirectory.CreateDirectory(OutDir);
    LMBTiles := FindUp('Sample\BasicViewer\data\roma.mbtiles');
    LStyle := 'C:\OW_D104\Utility\MapsViewerOffline\style.json';
    if not TFile.Exists(LStyle) then
      LStyle := FindUp('Sample\BasicViewer\bright\style.json');

    if (LMBTiles = '') or (LStyle = '') then
    begin
      Writeln('ERROR: data not found (mbtiles=', LMBTiles, ' style=', LStyle, ')');
      ExitCode := 1;
      Exit;
    end;

    Log := TStringList.Create;
    EG := TPBFMapEngine.Create(TILE);
    ES := TPBFMapEngine.Create(TILE);
    BG := TBitmap.Create;
    BS := TBitmap.Create;
    try
      BG.PixelFormat := pf32bit; BG.SetSize(TILE, TILE);
      BS.PixelFormat := pf32bit; BS.SetSize(TILE, TILE);
      ConfigEngine(EG, LStyle, LMBTiles, False);
      ConfigEngine(ES, LStyle, LMBTiles, True);

      Log.Add('Skia A/B  style=' + LStyle);
      Log.Add(Format('tile %d  block %d..%d / %d..%d',
        [Z, CX - RADIUS, CX + RADIUS, CY - RADIUS, CY + RADIUS]));
      SumG := 0; SumS := 0;

      for Y := CY - RADIUS to CY + RADIUS do
        for X := CX - RADIUS to CX + RADIUS do
        begin
          LKey := Format('%d_%d_%d', [Z, X, Y]);
          TG := RenderOne(EG, X, Y, BG);
          TS := RenderOne(ES, X, Y, BS);
          SumG := SumG + TG; SumS := SumS + TS;
          SavePng(BG, OutDir + 'gdi_' + LKey + '.png');
          SavePng(BS, OutDir + 'skia_' + LKey + '.png');
          DiffBitmaps(BG, BS, MeanD, MaxD, PctD);
          Log.Add(Format('  %s  gdi=%dms skia=%dms | meanDelta=%.2f maxDelta=%.0f pctDiff=%.2f%%',
            [LKey, TG, TS, MeanD, MaxD, PctD]));
        end;

      Log.Add(Format('TOTAL gdi=%dms skia=%dms  speedup=%.2fx',
        [SumG, SumS, SumG / Max(1, SumS)]));
      Log.SaveToFile(OutDir + 'skia_ab.log');
      Writeln(Log.Text);
      Writeln('OK -> ', OutDir);
    finally
      BG.Free; BS.Free; EG.Free; ES.Free; Log.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
