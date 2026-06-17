unit PBFMap.Engine;

{
  PBFMapRenderer - High-level facade

  Ties together the MBTiles reader, decompression, MVT parser and the
  style-driven renderer: open an .mbtiles, load a local style.json, render a
  z/x/y tile to a VCL canvas.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Diagnostics,
  System.Generics.Collections, System.Types, System.Math,
  Winapi.Windows, Winapi.GDIPAPI, Winapi.GDIPOBJ, Vcl.Graphics,
  RESILog,
  PBFMap.Types, PBFMap.MBTiles, PBFMap.Compression, PBFMap.MVT.Types,
  PBFMap.MVT.Parser, PBFMap.Style.Model, PBFMap.Style.Parser,
  PBFMap.Sprite, PBFMap.Renderer.GL;

type
  TPBFMapEngine = class
  private
    FReader: TPBFMBTilesReader;
    FParser: TMVTTileParser;
    FRenderer: TMGLRenderer;
    FStyle: TMGLStyle;
    FSprite: TMGLSprite;
    FTileSize: Integer;
    FOnLog: TEvLog;
    { Decoded-tile LRU cache: avoids re-running decompress + MVT parse (~90ms)
      when the same z/x/y is rendered again (pan-back, zoom toggling). The cache
      OWNS the tiles; callers must not free them. }
    FTileCache: TObjectDictionary<string, TMVTTile>;
    FCacheOrder: TStringList;
    FCacheCap: Integer;
    { Metatile: render an MxM block as one scene (shared symbol placement) so
      boundary labels stitch across tiles. 1 = off. The resulting per-tile PNGs
      are kept in FSliceCache. }
    FMetatileSize: Integer;
    FSliceCache: TObjectDictionary<string, TBitmap>;
    FSliceOrder: TStringList;
    function CacheKey(AZoom, X, Y: Integer): string;
    function CachedTile(AZoom, X, Y: Integer): TMVTTile;
    procedure SetTileCacheSize(AValue: Integer);
    procedure SetMetatileSize(AValue: Integer);
    procedure RenderMetatileBlock(AZoom, AOriginX, AOriginY: Integer);
    procedure SetTileSize(AValue: Integer);
    procedure SetOnLog(AValue: TEvLog);
    function GetSupersample: Integer;
    procedure SetSupersample(AValue: Integer);
    function GetSyntheticCasing: Boolean;
    procedure SetSyntheticCasing(AValue: Boolean);
    function GetAntialias: Boolean;
    procedure SetAntialias(AValue: Boolean);
    procedure LoadSpriteFor(const AStyleFileName: string);
    { Fires OnLog if assigned (info/timing/warning). Never raises. }
    procedure DoLog(const aFunction, aDescription: String; aLevel: TPLivLog;
      aIsDebug: Boolean = False);
    { Logs via OnLog when assigned; otherwise raises EPBFMapError. }
    procedure LogOrRaise(const aFunction, aDescription: String; aLevel: TPLivLog);
  public
    constructor Create(ATileSize: Integer = PBF_DEFAULT_TILE_SIZE);
    destructor Destroy; override;

    /// <summary>Open the MBTiles tile source.</summary>
    procedure OpenTiles(const AFileName: string);
    /// <summary>Load and apply a local Mapbox GL / MapTiler style.json.</summary>
    procedure LoadStyle(const AFileName: string);

    /// <summary>
    ///   Decode a tile to the TMVT object model (decompresses automatically).
    ///   Returns nil if the tile is absent. Caller owns the result.
    /// </summary>
    function DecodeTile(AZoom, X, Y: Integer): TMVTTile;

    /// <summary>
    ///   Render a tile (with the loaded style) to a canvas. Missing tiles draw
    ///   the style background only. The style zoom used is AZoom.
    /// </summary>
    procedure RenderTile(AZoom, X, Y: Integer; ACanvas: TCanvas);

    { Coarse timing of the last RenderTile pass (ms). Diagnostics only. }
    function LastGeomMs: Int64;
    function LastSymMs: Int64;
    function LastIterCount: Int64;
    function LastDrawCount: Int64;
    function GetDebugSkipDraw: Boolean;
    procedure SetDebugSkipDraw(AValue: Boolean);
    function TopLayers(ACount: Integer): string;
    function TopFuncs(ACount: Integer): string;
    procedure SetProfiling(AValue: Boolean);
    procedure ResetProfile;

    property Reader: TPBFMBTilesReader read FReader;
    property Style: TMGLStyle read FStyle;
    property TileSize: Integer read FTileSize write SetTileSize;
    /// <summary>Supersampling factor (render NxN then downscale). 1 = off.</summary>
    property Supersample: Integer read GetSupersample write SetSupersample;
    /// <summary>
    ///   Synthetic grey casing for light line layers. Leave ON for minimal
    ///   styles without casing layers; turn OFF for styles that define their
    ///   own casing (e.g. osm-bright) to avoid double borders.
    /// </summary>
    property SyntheticCasing: Boolean read GetSyntheticCasing write SetSyntheticCasing;
    /// <summary>GDI+ geometry anti-aliasing (off is faster, jaggier).</summary>
    property Antialias: Boolean read GetAntialias write SetAntialias;
    /// <summary>Max decoded tiles kept in the LRU cache (0 disables caching).</summary>
    property TileCacheSize: Integer read FCacheCap write SetTileCacheSize;
    /// <summary>
    ///   Metatile block size (1 = off). When > 1, RenderTile renders the
    ///   surrounding MxM block as one scene so labels at tile boundaries are
    ///   placed coherently and stitch (no cut/duplicated edge labels). 2 is a
    ///   good default for offline viewers.
    /// </summary>
    property MetatileSize: Integer read FMetatileSize write SetMetatileSize;
    /// <summary>Diagnostics: skip geometry draw + symbol collection (profiling).</summary>
    property DebugSkipDraw: Boolean read GetDebugSkipDraw write SetDebugSkipDraw;
    /// <summary>Drop all cached decoded tiles (e.g. after switching MBTiles).</summary>
    procedure ClearTileCache;

    /// <summary>
    ///   ResiLog event. When assigned, loading/decoding/rendering failures are
    ///   logged and degrade gracefully; when unassigned, they raise instead.
    /// </summary>
    property OnLog: TEvLog read FOnLog write SetOnLog;
  end;

implementation

constructor TPBFMapEngine.Create(ATileSize: Integer);
begin
  inherited Create;
  FTileSize := ATileSize;
  FReader := TPBFMBTilesReader.Create;
  FParser := TMVTTileParser.Create;
  FRenderer := TMGLRenderer.Create(ATileSize);
  FSprite := TMGLSprite.Create;
  FRenderer.Sprite := FSprite;
  FCacheCap := 64;
  FTileCache := TObjectDictionary<string, TMVTTile>.Create([doOwnsValues]);
  FCacheOrder := TStringList.Create;
  FMetatileSize := 2;  // on by default: 2x2 block, edge labels stitch
  FSliceCache := TObjectDictionary<string, TBitmap>.Create([doOwnsValues]);
  FSliceOrder := TStringList.Create;
end;

destructor TPBFMapEngine.Destroy;
begin
  FTileCache.Free;   // owns and frees the cached tiles
  FCacheOrder.Free;
  FSliceCache.Free;  // owns and frees the cached slice bitmaps
  FSliceOrder.Free;
  FStyle.Free;
  FRenderer.Free;
  FSprite.Free;
  FParser.Free;
  FReader.Free;
  inherited;
end;

function TPBFMapEngine.CacheKey(AZoom, X, Y: Integer): string;
begin
  Result := Format('%d/%d/%d', [AZoom, X, Y]);
end;

procedure TPBFMapEngine.ClearTileCache;
begin
  FTileCache.Clear;
  FCacheOrder.Clear;
  FSliceCache.Clear;
  FSliceOrder.Clear;
end;

procedure TPBFMapEngine.SetMetatileSize(AValue: Integer);
begin
  if AValue < 1 then
    AValue := 1;
  if AValue = FMetatileSize then
    Exit;
  FMetatileSize := AValue;
  FSliceCache.Clear;  // block layout changed -> stored slices invalid
  FSliceOrder.Clear;
end;

{ Renders the MxM block whose top-left tile is (AOriginX, AOriginY) as one scene
  (plus a 1-tile buffer so labels crossing the block edge are placed with their
  neighbours), then slices the inner MxM into per-tile bitmaps in FSliceCache. }
procedure TPBFMapEngine.RenderMetatileBlock(AZoom, AOriginX, AOriginY: Integer);
const
  BUFFER = 0;  // 0 = render only the MxM block (~baseline cost, intra-block
               // label stitching). 1 adds a neighbour ring for full stitching
               // but ~Mx more geometry per block (much slower first paint).
var
  M, SS, TilePx, Cols, I, R, C, OX, OY: Integer;
  Tiles: TArray<TMVTTile>;
  Scene: TBitmap;
  G: TGPGraphics;
  Img: TGPBitmap;
  Slice: TBitmap;
  LKey: string;
begin
  M := FMetatileSize;
  SS := FRenderer.Supersample;
  if SS < 1 then SS := 1;
  TilePx := FTileSize * SS;             // supersampled per-tile size
  Cols := M + 2 * BUFFER;               // scene is (M+2) x (M+2) tiles

  // decode every scene tile (cached); row-major, world tile = origin-buffer+offset
  SetLength(Tiles, Cols * Cols);
  for R := 0 to Cols - 1 do
    for C := 0 to Cols - 1 do
      Tiles[R * Cols + C] :=
        CachedTile(AZoom, AOriginX - BUFFER + C, AOriginY - BUFFER + R);

  Scene := TBitmap.Create;
  try
    Scene.PixelFormat := pf32bit;
    Scene.SetSize(Cols * TilePx, Cols * TilePx);
    Scene.Canvas.Brush.Color := clWhite;
    Scene.Canvas.FillRect(Rect(0, 0, Scene.Width, Scene.Height));

    // one scene-wide render: geometry per sub-tile + single symbol placement
    FRenderer.RenderScene(Tiles, Cols, Cols, FStyle, AZoom, Scene.Canvas, TilePx, SS);

    // slice the inner MxM (skip the buffer ring), downscaling SS -> FTileSize
    Img := TGPBitmap.Create(Scene.Handle, 0);
    try
      for R := 0 to M - 1 do
        for C := 0 to M - 1 do
        begin
          OX := (BUFFER + C) * TilePx;
          OY := (BUFFER + R) * TilePx;
          Slice := TBitmap.Create;
          Slice.PixelFormat := pf32bit;
          Slice.SetSize(FTileSize, FTileSize);
          G := TGPGraphics.Create(Slice.Canvas.Handle);
          try
            G.SetInterpolationMode(InterpolationModeHighQualityBicubic);
            G.SetPixelOffsetMode(PixelOffsetModeHighQuality);
            G.DrawImage(Img, MakeRect(0, 0, FTileSize, FTileSize),
              OX, OY, TilePx, TilePx, UnitPixel);
          finally
            G.Free;
          end;
          LKey := CacheKey(AZoom, AOriginX + C, AOriginY + R);
          FSliceCache.AddOrSetValue(LKey, Slice);  // owns/frees old
          if FSliceOrder.IndexOf(LKey) < 0 then
            FSliceOrder.Add(LKey);
        end;
    finally
      Img.Free;
    end;
  finally
    Scene.Free;
  end;

  // bound the slice cache (keep a few blocks' worth)
  while FSliceOrder.Count > Max(M * M * 8, 64) do
  begin
    FSliceCache.Remove(FSliceOrder[0]);
    FSliceOrder.Delete(0);
  end;
end;

procedure TPBFMapEngine.SetTileCacheSize(AValue: Integer);
begin
  if AValue < 0 then
    AValue := 0;
  FCacheCap := AValue;
  while FCacheOrder.Count > FCacheCap do
  begin
    FTileCache.Remove(FCacheOrder[0]);  // frees the tile (doOwnsValues)
    FCacheOrder.Delete(0);
  end;
end;

{ Returns an engine-owned decoded tile (decoding+caching on miss). The cache
  owns the result; callers MUST NOT free it. Returns nil for a missing tile. }
function TPBFMapEngine.CachedTile(AZoom, X, Y: Integer): TMVTTile;
var
  LKey: string;
  LIdx: Integer;
begin
  if FCacheCap <= 0 then
    Exit(DecodeTile(AZoom, X, Y));  // caching off: caller owns (legacy path)

  LKey := CacheKey(AZoom, X, Y);
  if FTileCache.TryGetValue(LKey, Result) then
  begin
    // mark as most-recently-used
    LIdx := FCacheOrder.IndexOf(LKey);
    if LIdx >= 0 then
      FCacheOrder.Delete(LIdx);
    FCacheOrder.Add(LKey);
    Exit;
  end;

  Result := DecodeTile(AZoom, X, Y);  // nil for a missing tile
  FTileCache.AddOrSetValue(LKey, Result);  // cache nil too (avoids re-probing)
  FCacheOrder.Add(LKey);
  while FCacheOrder.Count > FCacheCap do
  begin
    FTileCache.Remove(FCacheOrder[0]);
    FCacheOrder.Delete(0);
  end;
end;

function TPBFMapEngine.LastGeomMs: Int64;
begin
  Result := FRenderer.LastGeomMs;
end;

function TPBFMapEngine.LastSymMs: Int64;
begin
  Result := FRenderer.LastSymMs;
end;

function TPBFMapEngine.LastIterCount: Int64;
begin
  Result := FRenderer.LastIterCount;
end;

function TPBFMapEngine.LastDrawCount: Int64;
begin
  Result := FRenderer.LastDrawCount;
end;

function TPBFMapEngine.GetDebugSkipDraw: Boolean;
begin
  Result := FRenderer.DebugSkipDraw;
end;

procedure TPBFMapEngine.SetDebugSkipDraw(AValue: Boolean);
begin
  FRenderer.DebugSkipDraw := AValue;
end;

function TPBFMapEngine.TopLayers(ACount: Integer): string;
begin
  Result := FRenderer.TopLayers(ACount);
end;

function TPBFMapEngine.TopFuncs(ACount: Integer): string;
begin
  Result := FRenderer.TopFuncs(ACount);
end;

procedure TPBFMapEngine.SetProfiling(AValue: Boolean);
begin
  FRenderer.Profiling := AValue;
end;

procedure TPBFMapEngine.ResetProfile;
begin
  FRenderer.ResetProfile;
end;

procedure TPBFMapEngine.SetTileSize(AValue: Integer);
begin
  FTileSize := AValue;
  FRenderer.TileSize := AValue;
end;

function TPBFMapEngine.GetSupersample: Integer;
begin
  Result := FRenderer.Supersample;
end;

procedure TPBFMapEngine.SetSupersample(AValue: Integer);
begin
  FRenderer.Supersample := AValue;
end;

function TPBFMapEngine.GetSyntheticCasing: Boolean;
begin
  Result := FRenderer.SyntheticCasing;
end;

procedure TPBFMapEngine.SetSyntheticCasing(AValue: Boolean);
begin
  FRenderer.SyntheticCasing := AValue;
end;

function TPBFMapEngine.GetAntialias: Boolean;
begin
  Result := FRenderer.Antialias;
end;

procedure TPBFMapEngine.SetAntialias(AValue: Boolean);
begin
  FRenderer.Antialias := AValue;
end;

procedure TPBFMapEngine.SetOnLog(AValue: TEvLog);
begin
  FOnLog := AValue;
  // Propagate to the sub-components that report their own failures.
  FReader.OnLog := AValue;
end;

procedure TPBFMapEngine.DoLog(const aFunction, aDescription: String;
  aLevel: TPLivLog; aIsDebug: Boolean);
begin
  if not Assigned(FOnLog) then
    Exit;
{$REGION 'Log'}
{TSI:IGNORE ON}
  FOnLog(aFunction, aDescription, aLevel, aIsDebug);
{TSI:IGNORE OFF}
{$ENDREGION}
end;

procedure TPBFMapEngine.LogOrRaise(const aFunction, aDescription: String;
  aLevel: TPLivLog);
begin
  if Assigned(FOnLog) then
    DoLog(aFunction, aDescription, aLevel)
  else
    raise EPBFMapError.Create(aDescription);
end;

procedure TPBFMapEngine.OpenTiles(const AFileName: string);
var
  LSw: TStopwatch;
begin
  // FReader logs/raises through the OnLog it inherited from this engine.
  ClearTileCache;  // tiles from a previous source must not survive
  LSw := TStopwatch.StartNew;
  try
    FReader.Open(AFileName);
  finally
    LSw.Stop;
    DoLog(Format('%s.OpenTiles', [Self.ClassName]),
      Format('OpenTiles "%s" Elapsed=%dms', [AFileName, LSw.ElapsedMilliseconds]),
      tpliv5);
  end;
end;

procedure TPBFMapEngine.LoadStyle(const AFileName: string);
var
  LParser: TMGLStyleParser;
  LSw: TStopwatch;
begin
  LParser := TMGLStyleParser.Create;
  try
    LParser.OnLog := FOnLog;
    LSw := TStopwatch.StartNew;
    FreeAndNil(FStyle);
    FStyle := LParser.ParseFile(AFileName);
    LSw.Stop;
    DoLog(Format('%s.LoadStyle', [Self.ClassName]),
      Format('Loaded style "%s": %d layers Elapsed=%dms',
        [AFileName, FStyle.Layers.Count, LSw.ElapsedMilliseconds]), tpliv4);
  finally
    LParser.Free;
  end;

  LoadSpriteFor(AFileName);
end;

procedure TPBFMapEngine.LoadSpriteFor(const AStyleFileName: string);
var
  LDir, LJson, LPng: string;
begin
  // MapTiler/Mapbox local exports place sprite.json + sprite.png next to the
  // style. Load them if present; the renderer simply skips icons otherwise.
  LDir := ExtractFilePath(AStyleFileName);
  LJson := TPath.Combine(LDir, 'sprite.json');
  LPng := TPath.Combine(LDir, 'sprite.png');
  if FSprite.LoadFromFiles(LJson, LPng) then
    DoLog(Format('%s.LoadStyle', [Self.ClassName]),
      Format('Loaded sprite atlas: %s', [LPng]), tpliv4)
  else
    DoLog(Format('%s.LoadStyle', [Self.ClassName]),
      'No sprite atlas found next to the style', tpliv3);
end;

function TPBFMapEngine.DecodeTile(AZoom, X, Y: Integer): TMVTTile;
var
  LRaw, LPlain: TBytes;
  LProf: Boolean;
  LSw: TStopwatch;
begin
  Result := nil;
  if not FReader.TileExists(AZoom, X, Y) then Exit;
  LProf := FRenderer.Profiling;
  try
    LRaw := FReader.GetTileData(AZoom, X, Y);
    if LProf then LSw := TStopwatch.StartNew;
    LPlain := DecompressTile(LRaw);
    if LProf then
    begin
      LSw.Stop;
      FRenderer.ProfileAddMs('decompress', LSw.Elapsed.TotalMilliseconds);
      LSw := TStopwatch.StartNew;
    end;
    Result := FParser.Parse(LPlain);
    if LProf then
    begin
      LSw.Stop;
      FRenderer.ProfileAddMs('mvtParse', LSw.Elapsed.TotalMilliseconds);
    end;
  except
    on E: Exception do
    begin
      FreeAndNil(Result);
      LogOrRaise(Format('%s.DecodeTile', [Self.ClassName]),
        Format('Decode tile %d/%d/%d failed: %s', [AZoom, X, Y, E.Message]),
        tpliv2);
    end;
  end;
end;

procedure TPBFMapEngine.RenderTile(AZoom, X, Y: Integer; ACanvas: TCanvas);
var
  LTile: TMVTTile;
  LSw: TStopwatch;
  LKey: string;
  LM: Integer;
  LSlice: TBitmap;
begin
  if not Assigned(FStyle) then
  begin
    LogOrRaise(Format('%s.RenderTile', [Self.ClassName]), 'No style loaded',tpliv3);
    Exit;
  end;

  LSw := TStopwatch.StartNew;

  // Metatile path: render/slice the surrounding MxM block (cached), then blit
  // this tile's slice. Boundary labels are placed scene-wide so tiles stitch.
  if FMetatileSize > 1 then
  begin
    LM := FMetatileSize;
    LKey := CacheKey(AZoom, X, Y);
    if not FSliceCache.ContainsKey(LKey) then
      RenderMetatileBlock(AZoom, (X div LM) * LM, (Y div LM) * LM);
    if FSliceCache.TryGetValue(LKey, LSlice) then
      ACanvas.Draw(0, 0, LSlice);
    LSw.Stop;
    DoLog(Format('%s.RenderTile', [Self.ClassName]),
      Format('Rendered tile %d/%d/%d (metatile) Elapsed=%dms',
        [AZoom, X, Y, LSw.ElapsedMilliseconds]), tpliv5);
    Exit;
  end;

  // CachedTile returns an engine-owned tile (cache on) or a caller-owned one
  // (cache off); free only in the latter case.
  LTile := CachedTile(AZoom, X, Y);  // may be nil (missing tile)
  try
    try
      FRenderer.Render(LTile, FStyle, AZoom, ACanvas);
    except
      on E: Exception do
        LogOrRaise(Format('%s.RenderTile', [Self.ClassName]),
          Format('Render tile %d/%d/%d failed: %s', [AZoom, X, Y, E.Message]),
          tpliv1);
    end;
  finally
    if FCacheCap <= 0 then
      LTile.Free;  // caching disabled -> we own this tile
    LSw.Stop;
    DoLog(Format('%s.RenderTile', [Self.ClassName]),
      Format('Rendered tile %d/%d/%d Elapsed=%dms',
        [AZoom, X, Y, LSw.ElapsedMilliseconds]), tpliv5);
  end;
end;

end.
