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
  PBFMap.Sprite, PBFMap.Renderer.GL, PBFMap.TileCache;

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
    { Optional shared decoded-tile cache (SetSharedTileCache). When assigned it
      replaces the private FTileCache: tiles are decoded once and reused across the
      per-thread engines of a pool. NOT owned by the engine. nil = classic per-engine
      caching (default), so a single-engine caller is unaffected. }
    FSharedCache  : TPBFSharedTileCache;
    { Metatile: render an MxM block as one scene (shared symbol placement) so
      boundary labels stitch across tiles. 1 = off. The resulting per-tile PNGs
      are kept in FSliceCache. }
    FMetatileSize : Integer;
    FMetatileBuffer : Integer;  // neighbour-ring tiles around a metatile block
    FMaxDataZoom  : Integer;    // data max zoom; 0 = off (no overzoom)
    FSliceCache   : TObjectDictionary<string, TBitmap>;
    FSliceOrder   : TStringList;
    function CacheKey(AZoom, X, Y: Integer): string;
    function CachedTile(AZoom, X, Y: Integer): TMVTTile;
    procedure RenderOverzoom(AZoom, X, Y: Integer; ACanvas: TCanvas);
    procedure RenderOverzoomBlock(AZoom, AOriginX, AOriginY: Integer; const ASink: TPBFTileSink);
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
    ///   Share one decoded-tile cache across several per-thread engines (a render
    ///   pool), so a data tile is decompressed + parsed once and reused by every
    ///   engine instead of once per engine. The engine does NOT take ownership: the
    ///   caller frees ACache AFTER all engines using it (and their threads) are gone.
    ///   Pass nil to revert to the private per-engine cache. A single-engine caller
    ///   that never calls this keeps the classic behaviour.
    /// </summary>
    procedure SetSharedTileCache(ACache: TPBFSharedTileCache);

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
    ///   render â€” avoids re-rendering the same block once per tile across worker
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
    /// <summary>
    ///   Data max zoom (from the MBTiles metadata). When > 0 and a tile is
    ///   requested ABOVE it, the tile is OVERZOOMED: the ancestor tile at this
    ///   zoom is rendered (vector, at the display zoom's styling) and the relevant
    ///   sub-region is scaled to fill the output â€” so zooming past the data keeps
    ///   a sharp map instead of blank tiles. 0 = off.
    /// </summary>
    property MaxDataZoom: Integer read FMaxDataZoom write FMaxDataZoom;
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

{ Integer NxN box (area) average of a square sub-region of aSrc into aDst. Writes
  aDst's DIB directly via ScanLine (no GDI), so the result is coherent for a later
  ScanLine/slice read. Used for supersampling downscale (aFactor = SS), where the
  box average keeps tiles crisp (the StretchBlt HALFTONE equivalent). }
procedure BoxDownscaleRegion(aDst, aSrc: TBitmap;
  aSrcX, aSrcY, aSrcSize, aDstSize, aFactor: Integer);
var
  LDx, LDy, LIx, LIy, LArea, LBase: Integer;
  LB, LG, LR, LA: Cardinal;
  LSrcRow, LDstRow: PByteArray;
begin
  LArea := aFactor * aFactor;
  for LDy := 0 to aDstSize - 1 do
  begin
    LDstRow := PByteArray(aDst.ScanLine[LDy]);
    for LDx := 0 to aDstSize - 1 do
    begin
      LB := 0; LG := 0; LR := 0; LA := 0;
      for LIy := 0 to aFactor - 1 do
      begin
        LSrcRow := PByteArray(aSrc.ScanLine[aSrcY + LDy * aFactor + LIy]);
        LBase   := (aSrcX + LDx * aFactor) * 4;
        for LIx := 0 to aFactor - 1 do
        begin
          Inc(LB, LSrcRow[LBase    ]);
          Inc(LG, LSrcRow[LBase + 1]);
          Inc(LR, LSrcRow[LBase + 2]);
          Inc(LA, LSrcRow[LBase + 3]);
          Inc(LBase, 4);
        end;
      end;
      LBase := LDx * 4;
      LDstRow[LBase    ] := LB div Cardinal(LArea);
      LDstRow[LBase + 1] := LG div Cardinal(LArea);
      LDstRow[LBase + 2] := LR div Cardinal(LArea);
      LDstRow[LBase + 3] := LA div Cardinal(LArea);
    end;
  end;
end;

{ Bilinear resample of a square sub-region of aSrc into aDst (any ratio; used for
  overzoom upscale). Writes aDst's DIB directly via ScanLine - no GDI StretchBlt,
  so the slice is coherent without depending on the GDI batch flush. }
procedure BilinearResampleRegion(aDst, aSrc: TBitmap;
  aSrcX, aSrcY, aSrcSize, aDstSize: Integer);
var
  LDx, LDy, LX0, LX1, LY0, LY1, LMax, LC, LI0, LI1: Integer;
  LScale, LSx, LSy, LFx, LFy, LTop, LBot: Double;
  LRow0, LRow1, LDstRow: PByteArray;
begin
  LScale := aSrcSize / aDstSize;   // < 1 upscale, > 1 downscale
  LMax   := aSrcSize - 1;
  for LDy := 0 to aDstSize - 1 do
  begin
    LSy := (LDy + 0.5) * LScale - 0.5;
    LY0 := Floor(LSy);
    LFy := LSy - LY0;
    LY1 := LY0 + 1;
    if LY0 < 0 then LY0 := 0 else if LY0 > LMax then LY0 := LMax;
    if LY1 < 0 then LY1 := 0 else if LY1 > LMax then LY1 := LMax;
    LRow0   := PByteArray(aSrc.ScanLine[aSrcY + LY0]);
    LRow1   := PByteArray(aSrc.ScanLine[aSrcY + LY1]);
    LDstRow := PByteArray(aDst.ScanLine[LDy]);
    for LDx := 0 to aDstSize - 1 do
    begin
      LSx := (LDx + 0.5) * LScale - 0.5;
      LX0 := Floor(LSx);
      LFx := LSx - LX0;
      LX1 := LX0 + 1;
      if LX0 < 0 then LX0 := 0 else if LX0 > LMax then LX0 := LMax;
      if LX1 < 0 then LX1 := 0 else if LX1 > LMax then LX1 := LMax;
      LI0 := (aSrcX + LX0) * 4;
      LI1 := (aSrcX + LX1) * 4;
      for LC := 0 to 3 do
      begin
        LTop := LRow0[LI0 + LC] * (1 - LFx) + LRow0[LI1 + LC] * LFx;
        LBot := LRow1[LI0 + LC] * (1 - LFx) + LRow1[LI1 + LC] * LFx;
        LDstRow[LDx * 4 + LC] := Round(LTop * (1 - LFy) + LBot * LFy);
      end;
    end;
  end;
end;

{ Copy a square region of aSrc into aDst (sized aDstSize). aSrc is filled by the
  renderer straight into its DIB (surface.TargetBitmap), so reading it via ScanLine
  is exact and coherent. All three paths write aDst's DIB directly (no GDI), so the
  destination is coherent for the slice/PNG read that follows: 1:1 -> memory copy;
  integer downscale (supersampling) -> NxN box average; otherwise (overzoom upscale)
  -> bilinear. }
procedure BlitSceneRegion(aDst, aSrc: TBitmap; aSrcX, aSrcY, aSrcSize, aDstSize: Integer);
var
  LRow, LBytes: Integer;
  LSrc, LDst: PByte;
begin
  if aSrcSize = aDstSize then
  begin
    // 1:1 (metatile, SS=1): exact ScanLine memory copy.
    LBytes := aDstSize * 4;  // pf32bit
    for LRow := 0 to aDstSize - 1 do
    begin
      LSrc := PByte(aSrc.ScanLine[aSrcY + LRow]);
      Inc(LSrc, aSrcX * 4);
      LDst := PByte(aDst.ScanLine[LRow]);
      Move(LSrc^, LDst^, LBytes);
    end;
  end
  else if (aSrcSize > aDstSize) and (aSrcSize mod aDstSize = 0) then
    // Supersampling downscale by an integer factor: exact area average.
    BoxDownscaleRegion(aDst, aSrc, aSrcX, aSrcY, aSrcSize, aDstSize, aSrcSize div aDstSize)
  else
    // Overzoom upscale (or non-integer ratio): bilinear.
    BilinearResampleRegion(aDst, aSrc, aSrcX, aSrcY, aSrcSize, aDstSize);
end;

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
  M, SS, TilePx, Cols, R, C, OX, OY: Integer;
  Tiles: TArray<TMVTTile>;
  Scene: TBitmap;
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
    // scene-wide (the BUFFER ring supplies label context; its geometry is sliced
    // out) + single symbol placement. Scene as target bitmap -> Skia writes its DIB
    // directly, so the ScanLine slice below reads coherent pixels (no blank tiles).
    FRenderer.RenderScene(Tiles, Cols, Cols, FStyle, AZoom, Scene.Canvas, TilePx, SS,
      BUFFER, M, Scene);

    // slice the inner MxM (skip the buffer ring), downscaling SS -> FTileSize.
    for R := 0 to M - 1 do
      for C := 0 to M - 1 do
      begin
        OX := (BUFFER + C) * TilePx;
        OY := (BUFFER + R) * TilePx;
        Slice := TBitmap.Create;
        Slice.PixelFormat := pf32bit;
        Slice.SetSize(FTileSize, FTileSize);
        BlitSceneRegion(Slice, Scene, OX, OY, TilePx, FTileSize);
        LKey := CacheKey(AZoom, AOriginX + C, AOriginY + R);
        FSliceCache.AddOrSetValue(LKey, Slice);  // owns/frees old
        if FSliceOrder.IndexOf(LKey) < 0 then
          FSliceOrder.Add(LKey);
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
  // Shared pool cache: decode once across engines. The tile is owned and pinned by
  // the cache; the caller must not free it (the engine's RenderTile/RenderBlock
  // release the thread's pins on exit). Takes precedence over the private cache.
  if Assigned(FSharedCache) then
  begin
    if not FSharedCache.Acquire(AZoom, X, Y, Result) then
    begin
      Result := DecodeTile(AZoom, X, Y);     // miss: decode (Result may be nil)
      FSharedCache.Add(AZoom, X, Y, Result); // cache takes ownership + pins; may swap Result
    end;
    Exit;
  end;

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

procedure TPBFMapEngine.SetSharedTileCache(ACache: TPBFSharedTileCache);
begin
  FSharedCache := ACache;  // not owned; nil reverts to the private per-engine cache
  DoLog(Format('%s.SetSharedTileCache', [Self.ClassName]),
    Format('Shared tile cache %s', [BoolToStr(Assigned(ACache), True)]), tplivInfo);
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

procedure TPBFMapEngine.RenderOverzoom(AZoom, X, Y: Integer; ACanvas: TCanvas);
const
  MAX_RENDER_F = 4;   // cap the temp bitmap at FTileSize*4 = 1024px (32-bit memory bound)
var
  dz, F, RenderF, BigSize, SubSize, ax, ay, subX, subY, LSaveTS, LSaveSS: Integer;
  AncTile: TMVTTile;
  Big, LResult: TBitmap;
begin
  dz := AZoom - FMaxDataZoom;
  F := 1 shl dz;
  RenderF := F;
  if RenderF > MAX_RENDER_F then RenderF := MAX_RENDER_F;
  ax := X shr dz; ay := Y shr dz;                 // ancestor tile at FMaxDataZoom
  subX := X - (ax shl dz); subY := Y - (ay shl dz);
  AncTile := CachedTile(FMaxDataZoom, ax, ay);
  try
    if AncTile = nil then
      Exit;  // no data for the ancestor -> caller shows notiles (out of coverage)
    BigSize := FTileSize * RenderF;
    Big := TBitmap.Create;
    try
      Big.PixelFormat := pf32bit;
      Big.SetSize(BigSize, BigSize);
      Big.Canvas.Brush.Color := clWhite;
      Big.Canvas.FillRect(Rect(0, 0, BigSize, BigSize));
      // Render the ancestor at the bigger size, styled for the DISPLAY zoom (so
      // line widths / text sizes match the zoomed-in view). SS off (we upscale).
      LSaveTS := FRenderer.TileSize;
      LSaveSS := FRenderer.Supersample;
      FRenderer.TileSize := BigSize;
      FRenderer.Supersample := 1;
      try
        FRenderer.Render(AncTile, FStyle, AZoom, Big.Canvas, Big);  // Big as target DIB
      finally
        FRenderer.TileSize := LSaveTS;
        FRenderer.Supersample := LSaveSS;
      end;
      // The requested tile is 1/F of the ancestor -> its px size in Big is BigSize/F.
      SubSize := BigSize div F;
      // Crop+scale via the robust ScanLine-based BlitSceneRegion (avoids the blank
      // tiles a direct GDI DC read of the Skia-rendered Big produced), then blit.
      LResult := TBitmap.Create;
      try
        LResult.PixelFormat := pf32bit;
        LResult.SetSize(FTileSize, FTileSize);
        BlitSceneRegion(LResult, Big, subX * SubSize, subY * SubSize, SubSize, FTileSize);
        ACanvas.Draw(0, 0, LResult);
      finally
        LResult.Free;
      end;
    finally
      Big.Free;
    end;
  finally
    if (FCacheCap <= 0) and not Assigned(FSharedCache) then
      AncTile.Free;  // own it only when neither cache holds it
  end;
end;

procedure TPBFMapEngine.RenderOverzoomBlock(AZoom, AOriginX, AOriginY: Integer;
  const ASink: TPBFTileSink);
const
  MAX_RENDER_F = 4;   // cap the ancestor render at FTileSize*4 = 1024px
var
  dz, F, RenderF, BigSize, SubSize, M, R, C, TileX, TileY: Integer;
  ax, ay, LastAx, LastAy, SubX, SubY, LSaveTS, LSaveSS: Integer;
  AncTile: TMVTTile;
  Big, LBmp: TBitmap;
  G: TGPGraphics;
  Img: TGPBitmap;
begin
  // Overzoom for a whole MxM block. Unlike the per-tile RenderOverzoom (which
  // re-rendered the SAME ancestor once per tile = 4x the work and 4x the peak),
  // render each distinct data-max ancestor ONCE at a capped BigSize and crop every
  // sub-tile from it. For M=2 the whole block shares one ancestor -> one render.
  dz      := AZoom - FMaxDataZoom;
  F       := 1 shl dz;
  RenderF := F;
  if RenderF > MAX_RENDER_F then RenderF := MAX_RENDER_F;
  BigSize := FTileSize * RenderF;
  SubSize := BigSize div F;            // px of one display tile inside Big
  M := FMetatileSize;
  if M < 1 then M := 1;

  Big    := nil;
  LastAx := -1; LastAy := -1;
  LSaveTS := FRenderer.TileSize;
  LSaveSS := FRenderer.Supersample;
  try
    for R := 0 to M - 1 do
      for C := 0 to M - 1 do
      begin
        TileX := AOriginX + C; TileY := AOriginY + R;
        ax := TileX shr dz; ay := TileY shr dz;
        // (re)render the ancestor only when it changes (once per distinct ancestor)
        if (ax <> LastAx) or (ay <> LastAy) then
        begin
          FreeAndNil(Big);
          AncTile := CachedTile(FMaxDataZoom, ax, ay);
          try
            if AncTile <> nil then
            begin
              Big := TBitmap.Create;
              Big.PixelFormat := pf32bit;
              Big.SetSize(BigSize, BigSize);
              Big.Canvas.Brush.Color := clWhite;
              Big.Canvas.FillRect(Rect(0, 0, BigSize, BigSize));
              FRenderer.TileSize := BigSize;
              FRenderer.Supersample := 1;
              FRenderer.Render(AncTile, FStyle, AZoom, Big.Canvas, Big);  // Big as target DIB
            end;
          finally
            if (FCacheCap <= 0) and not Assigned(FSharedCache) then
              AncTile.Free;  // own it only when neither cache holds it
          end;
          LastAx := ax; LastAy := ay;
        end;

        // crop this display tile out of the (shared) ancestor render
        LBmp := TBitmap.Create;
        try
          LBmp.PixelFormat := pf32bit;
          LBmp.SetSize(FTileSize, FTileSize);
          LBmp.Canvas.Brush.Color := clWhite;
          LBmp.Canvas.FillRect(Rect(0, 0, FTileSize, FTileSize));
          if Big <> nil then
          begin
            SubX := TileX - (ax shl dz);
            SubY := TileY - (ay shl dz);
            // GDI blit (thread-safe) instead of GDI+ DrawImage - see BlitSceneRegion.
            BlitSceneRegion(LBmp, Big, SubX * SubSize, SubY * SubSize, SubSize, FTileSize);
          end;
          ASink(TileX, TileY, LBmp);
        finally
          LBmp.Free;
        end;
      end;
  finally
    FRenderer.TileSize := LSaveTS;
    FRenderer.Supersample := LSaveSS;
    Big.Free;
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

  // Release this thread's shared-cache pins on every exit path (a no-op when no
  // shared cache is set). Tiles acquired by RenderOverzoom/RenderMetatileBlock or
  // the single-tile path below are only read during this pass.
  try
    // Overzoom: above the data max zoom there are no tiles -> scale the ancestor.
    if (FMaxDataZoom > 0) and (AZoom > FMaxDataZoom) then
    begin
      RenderOverzoom(AZoom, X, Y, ACanvas);
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
      if (FCacheCap <= 0) and not Assigned(FSharedCache) then
        LTile.Free;  // caching disabled -> we own this tile (shared cache owns it otherwise)
      LSw.Stop;
      DoLog(Format('%s.RenderTile', [Self.ClassName]),
        Format('Rendered tile %d/%d/%d Elapsed=%dms',
          [AZoom, X, Y, LSw.ElapsedMilliseconds]), tplivTiming,true);
    end;
  finally
    if Assigned(FSharedCache) then
      FSharedCache.ReleaseThread;
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

  // Release this thread's shared-cache pins once the whole block is sinked (no-op
  // without a shared cache). The block's scene tiles stay pinned only for the pass.
  try
    // Overzoom: above the data max zoom there are no tiles. Render the data-max
    // ancestor ONCE per block (capped size) and crop the MxM sub-tiles from it.
    if (FMaxDataZoom > 0) and (AZoom > FMaxDataZoom) then
    begin
      LM := FMetatileSize;
      if LM < 1 then LM := 1;
      LOX := (X div LM) * LM;
      LOY := (Y div LM) * LM;
      RenderOverzoomBlock(AZoom, LOX, LOY, ASink);
      Exit;
    end;

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
  finally
    if Assigned(FSharedCache) then
      FSharedCache.ReleaseThread;
  end;
end;

end.
