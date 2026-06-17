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
  PBFMap.Types, PBFMap.MBTiles, PBFMap.Compression, PBFMap.MVT.Types,
  PBFMap.MVT.Parser, PBFMap.Style.Model, PBFMap.Style.Parser,
  PBFMap.Sprite, PBFMap.Renderer.GL;

type
  /// <summary>Callback receiving each rendered tile of a block (engine owns ABmp; read-only).</summary>
  TPBFTileSink = reference to procedure(AX, AY: Integer; ABmp: TBitmap);

  TPBFMapEngine = class
  private
    FReader       : TPBFMBTilesReader;
    FParser       : TMVTTileParser;
    FRenderer     : TMGLRenderer;
    FStyle        : TMGLStyle;
    FSprite       : TMGLSprite;
    { Ownership: a shared style/sprite (SetSharedStyle) is owned by the caller and
      must not be freed here. Lets N engines (one per thread) reuse one parsed
      style + sprite atlas instead of each re-parsing the same files. }
    FOwnsStyle    : Boolean;
    FOwnsSprite   : Boolean;
    FTileSize     : Integer;
    FOnLog        : TPBFLogEvent;
    { Decoded-tile LRU cache: avoids re-running decompress + MVT parse (~90ms)
      when the same z/x/y is rendered again (pan-back, zoom toggling). The cache
      OWNS the tiles; callers must not free them. }
    FTileCache    : TObjectDictionary<string, TMVTTile>;
    FCacheOrder   : TStringList;
    FCacheCap     : Integer;
    { Metatile: render an MxM block as one scene (shared symbol placement) so
      boundary labels stitch across tiles. 1 = off. The resulting per-tile PNGs
      are kept in FSliceCache. }
    FMetatileSize : Integer;
    FMetatileBuffer : Integer;  // neighbour-ring tiles around a metatile block
    FSliceCache   : TObjectDictionary<string, TBitmap>;
    FSliceOrder   : TStringList;
    function CacheKey(AZoom, X, Y: Integer): string;
    function CachedTile(AZoom, X, Y: Integer): TMVTTile;
    procedure SetTileCacheSize(AValue: Integer);
    procedure SetMetatileSize(AValue: Integer);
    procedure RenderMetatileBlock(AZoom, AOriginX, AOriginY: Integer);
    procedure SetTileSize(AValue: Integer);
    procedure SetOnLog(AValue: TPBFLogEvent);
    function GetSupersample: Integer;
    procedure SetSupersample(AValue: Integer);
    function GetSyntheticCasing: Boolean;
    procedure SetSyntheticCasing(AValue: Boolean);
    function GetAntialias: Boolean;
    procedure SetAntialias(AValue: Boolean);
    function GetUseSkia: Boolean;
    procedure SetUseSkia(AValue: Boolean);
    procedure LoadSpriteFor(const AStyleFileName: string);
    { Fires OnLog if assigned (info/timing/warning). Never raises. }
    procedure DoLog(const aFunction, aDescription: String; aLevel: TPBFLogLevel;
      aIsDebug: Boolean = False);
    { Logs via OnLog when assigned; otherwise raises EPBFMapError. }
    procedure LogOrRaise(const aFunction, aDescription: String; aLevel: TPBFLogLevel);
  public
    constructor Create(ATileSize: Integer = PBF_DEFAULT_TILE_SIZE);
    destructor Destroy; override;

    /// <summary>Open the MBTiles tile source.</summary>
    procedure OpenTiles(const AFileName: string);
    /// <summary>Load and apply a local Mapbox GL / MapTiler style.json.</summary>
    procedure LoadStyle(const AFileName: string);
    /// <summary>
    ///   Use an externally-parsed style + sprite shared across engines/threads
    ///   (call instead of LoadStyle). The engine does NOT take ownership: the
    ///   caller frees AStyle/ASprite AFTER all engines using them are destroyed.
    ///   Both are read-only during rendering, so one parsed style + sprite atlas
    ///   can be safely shared by N per-thread engines.
    /// </summary>
    procedure SetSharedStyle(AStyle: TMGLStyle; ASprite: TMGLSprite);

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

    /// <summary>
    ///   Render the metatile BLOCK that contains (X,Y) ONCE and hand every inner
    ///   tile bitmap to ASink (so a caller can save all MxM tiles from a single
    ///   render — avoids re-rendering the same block once per tile across worker
    ///   threads). With MetatileSize=1 it renders just (X,Y). The bitmaps passed
    ///   to ASink are engine-owned: use them read-only inside the callback.
    /// </summary>
    procedure RenderBlock(AZoom, X, Y: Integer; const ASink: TPBFTileSink);

    { Coarse timing of the last RenderTile pass (ms). Diagnostics only. }
    function LastGeomMs: Int64;
    function LastSymMs: Int64;
    function LastIterCount: Int64;
    function LastDrawCount: Int64;
    function GetDebugSkipDraw: Boolean;
    procedure SetDebugSkipDraw(AValue: Boolean);
    function TopLayers(ACount: Integer): string;
    function TopFuncs(ACount: Integer): string;
    /// <summary>Per-render label/symbol diagnostics (collected vs placed + drop reasons).</summary>
    function SymbolReport: string;
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
    /// <summary>
    ///   Switch the geometry backend to Skia (fill/line/circle/background drawn
    ///   via an off-screen Skia raster surface; text/icons stay GDI). Only has an
    ///   effect when the library is compiled with the SKIA define; otherwise the
    ///   value is stored but ignored. Skia is ~1.7x faster on dense draw loads.
    /// </summary>
    property UseSkia: Boolean read GetUseSkia write SetUseSkia;
    /// <summary>Max decoded tiles kept in the LRU cache (0 disables caching).</summary>
    property TileCacheSize: Integer read FCacheCap write SetTileCacheSize;
    /// <summary>
    ///   Metatile block size (1 = off). When > 1, RenderTile renders the
    ///   surrounding MxM block as one scene so labels at tile boundaries are
    ///   placed coherently and stitch (no cut/duplicated edge labels). 2 is a
    ///   good default for offline viewers.
    /// </summary>
    property MetatileSize: Integer read FMetatileSize write SetMetatileSize;
    /// <summary>
    ///   Neighbour-ring tiles rendered around each metatile block (0 = off).
    ///   1 makes labels crossing a block boundary stitch instead of being
    ///   clipped, at the cost of ~((MetatileSize+2)/MetatileSize)^2 more
    ///   geometry per block. Requires MetatileSize > 1 to take effect.
    /// </summary>
    property MetatileBuffer: Integer read FMetatileBuffer write FMetatileBuffer;
    /// <summary>Diagnostics: skip geometry draw + symbol collection (profiling).</summary>
    property DebugSkipDraw: Boolean read GetDebugSkipDraw write SetDebugSkipDraw;
    /// <summary>Drop all cached decoded tiles (e.g. after switching MBTiles).</summary>
    procedure ClearTileCache;

    /// <summary>
    ///   Log event. When assigned, loading/decoding/rendering failures are
    ///   logged and degrade gracefully; when unassigned, they raise instead.
    /// </summary>
    property OnLog: TPBFLogEvent read FOnLog write SetOnLog;
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
  FOwnsStyle := True;
  FOwnsSprite := True;
  FCacheCap := 64;
  FTileCache := TObjectDictionary<string, TMVTTile>.Create([doOwnsValues]);
  FCacheOrder := TStringList.Create;
  FMetatileSize := 2;  // on by default: 2x2 block, edge labels stitch
  FMetatileBuffer := 0;  // neighbour ring off by default (opt-in for boundary labels)
  FSliceCache := TObjectDictionary<string, TBitmap>.Create([doOwnsValues]);
  FSliceOrder := TStringList.Create;
end;

destructor TPBFMapEngine.Destroy;
begin
  FTileCache.Free;   // owns and frees the cached tiles
  FCacheOrder.Free;
  FSliceCache.Free;  // owns and frees the cached slice bitmaps
  FSliceOrder.Free;
  if FOwnsStyle then
    FStyle.Free;     // a shared style is freed by its owner, not here
  FRenderer.Free;
  if FOwnsSprite then
    FSprite.Free;    // a shared sprite is freed by its owner, not here
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
var
  // BUFFER = neighbour ring added around the MxM block. 0 = render only the
  // block (intra-block label stitching only; labels crossing a block boundary
  // are clipped). 1 = place labels with neighbour geometry then slice the inner
  // block -> boundary labels are drawn whole and stitch across blocks
  // (~((M+2)/M)^2 more geometry per block). Set via MetatileBuffer.
  BUFFER: Integer;
  M, SS, TilePx, Cols, I, R, C, OX, OY: Integer;
  Tiles: TArray<TMVTTile>;
  Scene: TBitmap;
  G: TGPGraphics;
  Img: TGPBitmap;
  Slice: TBitmap;
  LKey: string;
begin
  BUFFER := FMetatileBuffer;
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

    // one scene-wide render: geometry for the inner MxM only, symbols collected
    // scene-wide (the BUFFER ring supplies label context without drawing its
    // geometry, which is sliced out) + single symbol placement.
    FRenderer.RenderScene(Tiles, Cols, Cols, FStyle, AZoom, Scene.Canvas, TilePx, SS,
      BUFFER, M);

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

function TPBFMapEngine.SymbolReport: string;
begin
  Result := FRenderer.SymbolReport;
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

function TPBFMapEngine.GetUseSkia: Boolean;
begin
  Result := FRenderer.UseSkia;
end;

procedure TPBFMapEngine.SetUseSkia(AValue: Boolean);
begin
  FRenderer.UseSkia := AValue;
end;

procedure TPBFMapEngine.SetOnLog(AValue: TPBFLogEvent);
begin
  FOnLog := AValue;
  // Propagate to the sub-components that report their own failures.
  FReader.OnLog := AValue;
end;

procedure TPBFMapEngine.DoLog(const aFunction, aDescription: String;
  aLevel: TPBFLogLevel; aIsDebug: Boolean);
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
  aLevel: TPBFLogLevel);
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
      tplivTiming);
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
    if FOwnsStyle then
      FreeAndNil(FStyle)        // don't free a previously-shared style
    else
      FStyle := nil;
    FStyle := LParser.ParseFile(AFileName);
    FOwnsStyle := True;
    LSw.Stop;
    DoLog(Format('%s.LoadStyle', [Self.ClassName]),
      Format('Loaded style "%s": %d layers Elapsed=%dms',
        [AFileName, FStyle.Layers.Count, LSw.ElapsedMilliseconds]), tplivInfo);
  finally
    LParser.Free;
  end;

  LoadSpriteFor(AFileName);
end;

procedure TPBFMapEngine.SetSharedStyle(AStyle: TMGLStyle; ASprite: TMGLSprite);
begin
  if FOwnsStyle then
    FreeAndNil(FStyle);   // drop the engine's own style; the shared one is not ours
  FStyle := AStyle;
  FOwnsStyle := False;

  if FOwnsSprite then
    FreeAndNil(FSprite);  // drop the engine's own sprite; the shared one is not ours
  FSprite := ASprite;
  FOwnsSprite := False;
  FRenderer.Sprite := FSprite;

  DoLog(Format('%s.SetSharedStyle', [Self.ClassName]),
    'Using shared style + sprite atlas', tplivInfo);
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
      Format('Loaded sprite atlas: %s', [LPng]), tplivInfo)
  else
    DoLog(Format('%s.LoadStyle', [Self.ClassName]),
      'No sprite atlas found next to the style', tplivWarning);
end;

function TPBFMapEngine.DecodeTile(AZoom, X, Y: Integer): TMVTTile;
var
  LRaw, LPlain: TBytes;
  LProf: Boolean;
  LSw: TStopwatch;
begin
  Result := nil;
  LProf := FRenderer.Profiling;
  try
    // One query per tile: GetTileData returns empty for a missing tile, so the
    // separate TileExists round-trip (a 2nd prepared-statement Open per tile) is
    // redundant in the hot path.
    LRaw := FReader.GetTileData(AZoom, X, Y);
    if Length(LRaw) = 0 then
      Exit;
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
        tplivError);
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
    LogOrRaise(Format('%s.RenderTile', [Self.ClassName]), 'No style loaded',tplivWarning);
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
        [AZoom, X, Y, LSw.ElapsedMilliseconds]), tplivTiming,true);
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
          tplivException);
    end;
  finally
    if FCacheCap <= 0 then
      LTile.Free;  // caching disabled -> we own this tile
    LSw.Stop;
    DoLog(Format('%s.RenderTile', [Self.ClassName]),
      Format('Rendered tile %d/%d/%d Elapsed=%dms',
        [AZoom, X, Y, LSw.ElapsedMilliseconds]), tplivTiming,true);
  end;
end;

procedure TPBFMapEngine.RenderBlock(AZoom, X, Y: Integer; const ASink: TPBFTileSink);
var
  LM, LOX, LOY, R, C: Integer;
  LKey: string;
  LSlice, LBmp: TBitmap;
begin
  if not Assigned(FStyle) then
  begin
    LogOrRaise(Format('%s.RenderBlock', [Self.ClassName]), 'No style loaded', tplivWarning);
    Exit;
  end;
  if not Assigned(ASink) then
    Exit;

  // No metatile: render just (X,Y) into a temp bitmap and sink it.
  if FMetatileSize <= 1 then
  begin
    LBmp := TBitmap.Create;
    try
      LBmp.PixelFormat := pf32bit;
      LBmp.SetSize(FTileSize, FTileSize);
      RenderTile(AZoom, X, Y, LBmp.Canvas);
      ASink(X, Y, LBmp);
    finally
      LBmp.Free;
    end;
    Exit;
  end;

  // Render the whole MxM block ONCE (caches all inner slices), then sink each.
  LM := FMetatileSize;
  LOX := (X div LM) * LM;
  LOY := (Y div LM) * LM;
  RenderMetatileBlock(AZoom, LOX, LOY);
  for R := 0 to LM - 1 do
    for C := 0 to LM - 1 do
    begin
      LKey := CacheKey(AZoom, LOX + C, LOY + R);
      if FSliceCache.TryGetValue(LKey, LSlice) then
        ASink(LOX + C, LOY + R, LSlice);  // engine-owned bitmap, read-only in sink
    end;
end;

end.
