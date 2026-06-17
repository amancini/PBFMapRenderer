unit PBFMap.Renderer.GL;

{
  PBFMapRenderer - Style-driven VCL renderer

  Renders a decoded TMVTTile to a VCL TCanvas using a parsed Mapbox GL style.
  Layers are drawn in style order; each feature is filtered and painted with
  expression-evaluated paint properties at the requested zoom.

  Pragmatic boundary: symbol layers render TEXT only (VCL fonts). SDF glyph
  atlases and sprite icons are not yet implemented (style props are parsed).

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  Winapi.Windows, Winapi.GDIPAPI, Winapi.GDIPOBJ,
  System.SysUtils, System.StrUtils, System.Types, System.Math, System.UITypes,
  System.Diagnostics,
  System.Classes, System.Generics.Collections, System.Generics.Defaults,
  Vcl.Graphics,
  PBFMap.Types, PBFMap.Geometry, PBFMap.MVT.Types, PBFMap.Color,
  PBFMap.Expressions, PBFMap.Style.Model, PBFMap.Sprite, PBFMap.Collision,
  PBFMap.Render.Surface, PBFMap.Profile;

type
  /// <summary>An anchor along a line (or a point), with its baseline angle.</summary>
  TSymAnchor = record
    Pos: TPoint;
    AngleDeg: Double;
  end;

  /// <summary>One way to place a symbol: its collision boxes + a draw action.</summary>
  TPlacementOption = record
    Boxes: TArray<TRect>;
    Draw: TProc;
  end;

  /// <summary>A winning symbol's draw call, queued so placement priority
  /// (later layers first) can differ from paint order (earlier layers first).</summary>
  TSymDrawOp = record
    Layer: Integer;     // style layer index (paint order key)
    Order: Integer;     // placement-sorted position (tie-break within a layer)
    Sub: Integer;       // 0 = icon, 1 = text (icon under text)
    Proc: TProc;
  end;

  /// <summary>
  ///   A symbol to be placed after all layers are collected. Icon and text are
  ///   placed independently (MapLibre's text-optional / icon-optional model):
  ///   a required part that cannot be placed hides the whole symbol; an
  ///   optional part is simply dropped. Text tries its options (variable-anchor)
  ///   in order.
  /// </summary>
  TSymbolCandidate = record
    LayerIndex: Integer;
    SortKey: Double;
    DedupKey: string;     // normalized text; '' disables dedup
    DedupPos: TPoint;
    Spacing: Integer;     // symbol-spacing (dedup distance)
    HasIcon: Boolean;
    IconBox: TRect;
    IconDraw: TProc;
    IconAllowOverlap: Boolean;
    IconOptional: Boolean;
    IconIgnorePlacement: Boolean;   // placed icon does NOT block other symbols
    HasText: Boolean;
    TextOptions: TArray<TPlacementOption>;
    TextAllowOverlap: Boolean;
    TextOptional: Boolean;
    TextIgnorePlacement: Boolean;   // placed text does NOT block other symbols
  end;

  TMGLRenderer = class
  private
    FTileSize: Integer;
    FSprite: TMGLSprite;     // icon/pattern atlas, not owned
    FSyntheticCasing: Boolean; // draw a grey under-stroke for light (road) lines
    FSupersample: Integer;   // SSAA factor: render NxN then downscale (1 = off)
    FAntialias: Boolean;     // GDI+ anti-aliasing for geometry (speed/quality lever)
    FScale: Double;          // current px multiplier during a supersampled pass
    FOffsetX: Integer;       // sub-tile origin in scene px (metatile rendering)
    FOffsetY: Integer;
    FGeomSkip: Boolean;      // metatile buffer ring: collect symbols but DON'T draw
                             // geometry (fills/lines/circles are sliced out anyway;
                             // the ring only supplies label-placement context)
    { Drawing backend for the current render (created per RenderContent/RenderScene
      by CreateDrawSurface). Base class = GDI+; a Skia subclass overrides the
      primitives. The renderer holds NO GDI+/Skia objects directly. }
    FSurface: TPBFDrawSurface;
    { Render backend switch: when True, geometry (fill/line/circle/background) is
      drawn with Skia instead of GDI+; text/icons stay GDI+. Effective only if a
      Skia surface factory is registered (the host includes PBFMap.Render.Surface.Skia). }
    FUseSkia: Boolean;
    { Per-render, per-THREAD cache of feature-constant (zoom-only) property values,
      published to the shared style bags via the GActivePropCache threadvar while a
      layer's features are drawn. Owned here (renderer is one-per-thread) so it is
      never shared between workers -> safe even when they render different zooms. }
    FPropCache: TMGLPropEvalCache;
    FGrid: TGridIndex;       // collision index (per render)
    FCandidates: TList<TSymbolCandidate>;          // symbols to place (per render)
    FPlaced: TObjectDictionary<string, TList<TPoint>>; // dedup: text -> positions
    { Per-render symbol diagnostics (allocation-free counters). Why each label
      candidate was dropped, to debug "missing labels". Reset per render. }
    FSymDiag: record
      Collected, PlacedText, PlacedIcon: Integer;
      DropEmptyText, DropLineShort, DropNoAnchor: Integer;
      DropIconColl, DropTextColl, DropDedup, DropRequired: Integer;
    end;
  private
    FLayerMs: TDictionary<string, Double>;  // per-layer accumulated draw ms (profiling)
    FFuncMs: TDictionary<string, Double>;   // per-function accumulated ms (profiling)
    FProfiling: Boolean;  // gate: per-function timers run only when profiling
    procedure AddFunc(const AName: string; AStartTicks: Int64);
  public
    { Diagnostics: when True, geometry draw + symbol collection are skipped
      (iterate + filter still run). Used to split draw-time vs filter-time. }
    DebugSkipDraw: Boolean;
    { Coarse profiling of the last RenderContent pass (ms). Diagnostics only. }
    LastGeomMs: Int64;
    LastSymMs: Int64;
    LastIterCount: Int64;   // feature-iterations across all layers (re-scan cost)
    LastDrawCount: Int64;   // features that actually passed the filter and drew
    { Per-layer / per-function accumulated time (ms) since ResetProfile.
      Set Profiling := True to enable the (slightly costly) per-function timers. }
    property Profiling: Boolean read FProfiling write FProfiling;
    { Push an externally-measured timing (e.g. decode steps from the engine)
      into the per-function profile. No-op unless Profiling is on. }
    procedure ProfileAddMs(const AName: string; AMs: Double);
    function TopLayers(ACount: Integer): string;
    function TopFuncs(ACount: Integer): string;
    procedure ResetProfile;
    { Per-render symbol/label diagnostics: candidates collected vs placed and the
      reason each was dropped (empty text, line too short, collision, dedup...). }
    function SymbolReport: string;
  private
    function TileToPixel(const P: TPBFPoint; AExtent: Integer): TPoint;
    function PartToPixels(const APart: TArray<TPBFPoint>; AExtent: Integer): TArray<TPoint>;
    function FeatureAnchor(AFeature: TMVTFeature; AExtent: Integer): TPoint;

    procedure PaintBackground(ACanvas: TCanvas; ALayer: TMGLLayer; AZoom: Double);
    procedure PaintFill(ACanvas: TCanvas; ALayer: TMGLLayer; AFeature: TMVTFeature;
      const Ctx: TExprContext; AExtent: Integer);
    procedure PaintLine(ACanvas: TCanvas; ALayer: TMGLLayer; AFeature: TMVTFeature;
      const Ctx: TExprContext; AExtent: Integer);
    procedure PaintCircle(ACanvas: TCanvas; ALayer: TMGLLayer; AFeature: TMVTFeature;
      const Ctx: TExprContext; AExtent: Integer);

    { Symbol placement engine (collect -> sort -> place -> draw). }
    procedure CollectSymbol(ACanvas: TCanvas; ALayer: TMGLLayer; ALayerIndex: Integer;
      AFeature: TMVTFeature; const Ctx: TExprContext; AExtent: Integer);
    procedure PlaceAndDrawSymbols;
    { Wires the active surface's per-primitive profiling timers to AddFunc (only
      when profiling is on). }
    procedure InstallProfileHook;
    { Renders the whole tile content to ACanvas at the current FTileSize/FScale. }
    procedure RenderContent(ATile: TMVTTile; AStyle: TMGLStyle; AZoom: Double;
      ACanvas: TCanvas);
    { Draws one tile's layers (geometry + symbol collection) at the current
      FOffset/FScale onto the active FSurface. Shared by RenderContent (single
      tile) and RenderScene (metatile). Does NOT place symbols. }
    procedure RenderTileLayers(ATile: TMVTTile; AStyle: TMGLStyle; AZoom: Double;
      ACanvas: TCanvas);
    { High-quality bicubic downscale of the supersampled bitmap to ATarget px. }
    procedure Downscale(ASrc: TBitmap; ADest: TCanvas; ATarget: Integer);
    function DedupTooClose(const AKey: string; const APos: TPoint; ASpacing: Integer): Boolean;
    procedure RecordPlacement(const AKey: string; const APos: TPoint);
    function LineAnchors(AFeature: TMVTFeature; AExtent, ASpacing,
      ATextW: Integer): TArray<TSymAnchor>;
    function RotatedBoxes(const APos: TPoint; AAngleDeg: Double;
      ATextW, ALineH, APad: Integer): TArray<TRect>;
    { Closures (by-value capture) that draw a placed symbol during placement. }
    function MakeBlockProc(ACanvas: TCanvas; const ALines: TArray<string>;
      ABX, ABY, ABlockW, ALineH, AFontPt, AJustify, ALetterExtra: Integer;
      const ATextColor, AHaloColor: TMGLColor; AHaloWidth: Double;
      const AFontName: string; AFontStyle: TFontStyles): TProc;
    function MakeRotatedProc(ACanvas: TCanvas; const AText: string;
      ACx, ACy, AFontPt: Integer; AAngleDeg: Double; ATextW, ALetterExtra: Integer;
      const ATextColor, AHaloColor: TMGLColor; AHaloWidth: Double;
      const AFontName: string; AFontStyle: TFontStyles): TProc;
    function MakeIconProc(ACanvas: TCanvas; const AName: string;
      ACx, ACy: Integer; AScale, ARotateDeg, AOpacity: Double;
      ATint: TColor): TProc;

    procedure FillRings(const ARings: TArray<TArray<TPoint>>;
      const AFill: TMGLColor; AHasOutline: Boolean; const AOutline: TMGLColor);
    procedure FillRingsPattern(ACanvas: TCanvas;
      const ARings: TArray<TArray<TPoint>>; const aPattern: string);
    procedure StampLinePattern(ACanvas: TCanvas; const APts: TArray<TPoint>;
      const aPattern: string);
    { Feature parts as pixel polylines, shifted by (line-translate) px. }
    function FeatureLines(AFeature: TMVTFeature; AExtent, ATransX,
      ATransY: Integer): TArray<TArray<TPoint>>;
    { A polyline shifted perpendicular by AOffset px (line-offset / gap edges). }
    function OffsetPolyline(const APts: TArray<TPoint>; AOffset: Double): TArray<TPoint>;
    { Strokes polylines with a geometric pen; ADashUnits (line-width units) ->
      PS_USERSTYLE dash pattern when non-empty. }
    procedure StrokeLines(const AParts: TArray<TArray<TPoint>>;
      const AColor: TMGLColor; AWidth: Integer; const ADashUnits: TArray<Double>;
      ACap: TLineCap; AJoin: TLineJoin);
    { line-gradient: stroke each segment with the colour the gradient expression
      yields at that segment's line-progress (0..1 along the whole part). }
    procedure StrokeGradient(const AParts: TArray<TArray<TPoint>>;
      const AGradient: IExpression; const ACtx: TExprContext;
      AWidth: Integer; ACap: TLineCap; AJoin: TLineJoin);
  public
    constructor Create(ATileSize: Integer = PBF_DEFAULT_TILE_SIZE);
    destructor Destroy; override;

    /// <summary>Render a tile with a style at a given zoom to a canvas.</summary>
    procedure Render(ATile: TMVTTile; AStyle: TMGLStyle; AZoom: Double;
      ACanvas: TCanvas);

    /// <summary>
    ///   Render an ACols x ARows block of tiles (row-major in ATiles, nil = empty)
    ///   into ACanvas as ONE scene: each sub-tile offset by ATilePx, with a single
    ///   scene-wide symbol placement pass. Lets edge labels be placed using
    ///   neighbour geometry so tiles stitch (no cut/duplicated boundary labels).
    ///   ATilePx is the per-tile pixel size already scaled by AScale (supersample).
    /// </summary>
    procedure RenderScene(const ATiles: TArray<TMVTTile>; ACols, ARows: Integer;
      AStyle: TMGLStyle; AZoom: Double; ACanvas: TCanvas; ATilePx: Integer;
      AScale: Double; AInnerOfs: Integer = 0; AInnerN: Integer = MaxInt);

    property TileSize: Integer read FTileSize write FTileSize;
    /// <summary>
    ///   Supersampling factor for tile quality: the tile is rendered at
    ///   (TileSize*N) with all sizes scaled, then downscaled to TileSize with
    ///   HALFTONE. 1 = off, 2 = good default for 256px tiles.
    /// </summary>
    property Supersample: Integer read FSupersample write FSupersample;
    /// <summary>GDI+ geometry anti-aliasing. Off ~halves draw time, jaggier lines.</summary>
    property Antialias: Boolean read FAntialias write FAntialias;
    /// <summary>
    ///   Switch the geometry backend to Skia (fills/lines/circles/background) at
    ///   runtime; text/icons stay GDI+. No effect unless compiled with SKIA.
    /// </summary>
    property UseSkia: Boolean read FUseSkia write FUseSkia;
    /// <summary>Sprite atlas for icon-image / fill-pattern / line-pattern (not owned).</summary>
    property Sprite: TMGLSprite read FSprite write FSprite;
    /// <summary>
    ///   Draw a grey under-stroke (casing) for light-colored line layers so
    ///   roads read against the background even when the style defines no
    ///   explicit casing layer. Default True.
    /// </summary>
    property SyntheticCasing: Boolean read FSyntheticCasing write FSyntheticCasing;
  end;

implementation

const
  // Synthetic casing: grey under-stroke drawn for light lines (roads).
  CASING_EXTRA    = 2;                   // casing is fill width + this (final px)
  CASING_LUMA_MIN = 0.78;                // only lines lighter than this get casing
  CASING_MIN_FILL = 2;                   // skip casing on thinner roads (avoids
                                         // the "double grey line" on hairlines)
  // Symbol placement (MapLibre-style defaults).
  SYMBOL_SPACING_DEFAULT = 250;          // px between repeated line labels / dedup
  TEXT_PADDING_DEFAULT   = 2;            // px around text collision boxes
  ICON_PADDING_DEFAULT   = 2;            // px around icon collision boxes
  GRID_CELL              = 64;           // collision grid cell size (px)
  TEXT_PT_RATIO          = 0.75;         // px -> pt approximation for VCL fonts

{ utility }

function Luminance(const C: TMGLColor): Double;
begin
  Result := 0.299 * C.R + 0.587 * C.G + 0.114 * C.B;
end;

// "Noto Sans Regular" -> family "Noto Sans" + style; weight/style words dropped.
procedure ParseFontStack(const AStack: string; out AName: string;
  out AStyle: TFontStyles);
var
  Words: TArray<string>;
  W, Lower: string;
begin
  AStyle := [];
  AName := '';
  if AStack = '' then
    Exit;
  Lower := AStack.ToLower;
  if Lower.Contains('bold') then Include(AStyle, fsBold);
  if Lower.Contains('italic') or Lower.Contains('oblique') then
    Include(AStyle, fsItalic);
  for W in AStack.Split([' ']) do
    if not MatchText(W, ['Regular', 'Bold', 'Italic', 'Oblique', 'Medium',
      'Light', 'SemiBold', 'Semibold', 'Thin', 'Black', 'Condensed', 'Normal']) then
    begin
      if AName <> '' then AName := AName + ' ';
      AName := AName + W;
    end;
  if AName = '' then
    AName := AStack;
end;

function GPCap(const ACap: string): TLineCap;
begin
  if SameText(ACap, 'square') then Result := LineCapSquare
  else if SameText(ACap, 'butt') then Result := LineCapFlat
  else Result := LineCapRound;
end;

function GPJoin(const AJoin: string): TLineJoin;
begin
  if SameText(AJoin, 'bevel') then Result := LineJoinBevel
  else if SameText(AJoin, 'miter') then Result := LineJoinMiter
  else Result := LineJoinRound;
end;

// Greedy word wrap: split AText so each line's rendered width <= AMaxPx.
function WrapText(ACanvas: TCanvas; const AText: string;
  AMaxPx: Integer): TArray<string>;
var
  Words: TArray<string>;
  Line, Candidate, W: string;
  Lines: TList<string>;
  Total, Target, LineCount: Integer;
begin
  // MapLibre-style balanced wrapping: instead of greedily filling each line to
  // the max width (which leaves a long line + a short remainder), compute how
  // many lines the text needs and aim for an even target width per line. This
  // matches the competition's line breaking and avoids wide blocks that spill
  // past the tile edge.
  Words := AText.Split([' ']);
  Lines := TList<string>.Create;
  try
    Total := ACanvas.TextWidth(AText);
    if (AMaxPx <= 0) or (Total <= AMaxPx) then
    begin
      // single line (still split into provided words to drop doubles)
      Line := '';
      for W in Words do
        if W <> '' then
          if Line = '' then Line := W else Line := Line + ' ' + W;
      if Line <> '' then Lines.Add(Line);
      Exit(Lines.ToArray);
    end;
    LineCount := Max(1, Ceil(Total / AMaxPx));
    Target := Ceil(Total / LineCount);   // balanced per-line width

    Line := '';
    for W in Words do
    begin
      if W = '' then
        Continue;
      if Line = '' then
        Candidate := W
      else
        Candidate := Line + ' ' + W;
      // break when the line reaches the balanced target (hard-capped at max)
      if (Line <> '') and (ACanvas.TextWidth(Candidate) > Target) and
         (ACanvas.TextWidth(Line) >= Target div 2) then
      begin
        Lines.Add(Line);
        Line := W;
      end
      else
        Line := Candidate;
    end;
    if Line <> '' then
      Lines.Add(Line);
    Result := Lines.ToArray;
  finally
    Lines.Free;
  end;
end;

function ExpandTokens(const S: string; AFeature: TMVTFeature): string;
var
  I: Integer;
  Key, Val: string;
  V: TMVTValue;
begin
  // Legacy "{field}" token substitution used by older text-field values.
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '{' then
    begin
      Key := '';
      Inc(I);
      while (I <= Length(S)) and (S[I] <> '}') do
      begin
        Key := Key + S[I];
        Inc(I);
      end;
      if I <= Length(S) then Inc(I);  // skip '}'
      Val := '';
      if Assigned(AFeature) and AFeature.GetProp(Key, V) then
        Val := V.AsString;
      Result := Result + Val;
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

{ TMGLRenderer }

constructor TMGLRenderer.Create(ATileSize: Integer);
begin
  inherited Create;
  FTileSize := ATileSize;
  FSyntheticCasing := True;
  FSupersample := 2;   // SSAA on by default for crisp small tiles
  FAntialias := True;
  FScale := 1.0;
  FOffsetX := 0;
  FOffsetY := 0;
  FPropCache := TMGLPropEvalCache.Create;
  FGrid := TGridIndex.Create(GRID_CELL);
  FCandidates := TList<TSymbolCandidate>.Create;
  FPlaced := TObjectDictionary<string, TList<TPoint>>.Create([doOwnsValues]);
  FLayerMs := TDictionary<string, Double>.Create;
  FFuncMs := TDictionary<string, Double>.Create;
end;

destructor TMGLRenderer.Destroy;
begin
  FFuncMs.Free;
  FLayerMs.Free;
  FPlaced.Free;
  FCandidates.Free;
  FGrid.Free;
  FPropCache.Free;
  inherited;
end;

procedure TMGLRenderer.ResetProfile;
begin
  FLayerMs.Clear;
  FFuncMs.Clear;
end;

procedure TMGLRenderer.AddFunc(const AName: string; AStartTicks: Int64);
var
  V: Double;
begin
  V := 0;
  FFuncMs.TryGetValue(AName, V);
  FFuncMs.AddOrSetValue(AName,
    V + (TStopwatch.GetTimeStamp - AStartTicks) / TStopwatch.Frequency * 1000);
end;

procedure TMGLRenderer.ProfileAddMs(const AName: string; AMs: Double);
var
  V: Double;
begin
  if not FProfiling then
    Exit;
  V := 0;
  FFuncMs.TryGetValue(AName, V);
  FFuncMs.AddOrSetValue(AName, V + AMs);
end;

{ Sorts a name->ms map descending and formats the top ACount lines. }
function FormatTop(AMap: TDictionary<string, Double>; ACount: Integer): string;
var
  Pairs: TArray<TPair<string, Double>>;
  I: Integer;
begin
  Pairs := AMap.ToArray;
  TArray.Sort<TPair<string, Double>>(Pairs,
    TComparer<TPair<string, Double>>.Construct(
      function(const L, R: TPair<string, Double>): Integer
      begin
        Result := CompareValue(R.Value, L.Value);  // descending
      end));
  Result := '';
  for I := 0 to Min(ACount, Length(Pairs)) - 1 do
    Result := Result + Format('  %-30s %.0f ms'#13#10, [Pairs[I].Key, Pairs[I].Value]);
end;

function TMGLRenderer.TopLayers(ACount: Integer): string;
begin
  Result := FormatTop(FLayerMs, ACount);
end;

function TMGLRenderer.TopFuncs(ACount: Integer): string;
begin
  Result := FormatTop(FFuncMs, ACount);
end;

function TMGLRenderer.SymbolReport: string;
begin
  with FSymDiag do
    Result := Format('collected=%d placed(text=%d icon=%d) drops(empty=%d ' +
      'lineShort=%d noAnchor=%d iconColl=%d textColl=%d dedup=%d required=%d)',
      [Collected, PlacedText, PlacedIcon, DropEmptyText, DropLineShort,
       DropNoAnchor, DropIconColl, DropTextColl, DropDedup, DropRequired]);
end;

function TMGLRenderer.TileToPixel(const P: TPBFPoint; AExtent: Integer): TPoint;
begin
  if AExtent <= 0 then
    AExtent := PBF_TILE_EXTENT;
  Result.X := Round(P.X * FTileSize / AExtent) + FOffsetX;
  Result.Y := Round(P.Y * FTileSize / AExtent) + FOffsetY;
end;

function TMGLRenderer.PartToPixels(const APart: TArray<TPBFPoint>;
  AExtent: Integer): TArray<TPoint>;
var
  I, N, K, AX, AY: Integer;
  P: TPoint;
  LT: Int64;
  LTol, DX, DY, Denom, Dist: Double;
begin
  LT := 0;
  if FProfiling then LT := TStopwatch.GetTimeStamp;
  try
  // Project to pixels and drop consecutive points that land on the SAME pixel:
  // at 256/512px many extent-4096 vertices collapse, so this cuts the vertex
  // count GDI+ must process (draw is vertex-bound) with no visible change.
  SetLength(Result, Length(APart));
  N := 0;
  for I := 0 to High(APart) do
  begin
    P := TileToPixel(APart[I], AExtent);
    if (N = 0) or (P.X <> Result[N - 1].X) or (P.Y <> Result[N - 1].Y) then
    begin
      Result[N] := P;
      Inc(N);
    end;
  end;
  SetLength(Result, N);

  // 2nd pass: drop near-collinear middle vertices. GDI+ draw is vertex-bound;
  // removing a point whose perpendicular distance from its neighbours is below
  // ~0.5 output px is invisible after the (super)sampled downscale. LTol is in
  // the current pixel space (FScale = supersample factor), so it stays ~0.5px
  // in the final tile. Dense z14 road/landuse parts shed many vertices here.
  if N > 2 then
  begin
    LTol := 0.5 * FScale;
    if LTol < 0.5 then LTol := 0.5;
    K := 1;  // Result[0] is always kept
    for I := 1 to N - 2 do
    begin
      AX := Result[K - 1].X; AY := Result[K - 1].Y;  // last kept vertex
      DX := Result[I + 1].X - AX;                      // segment kept..next
      DY := Result[I + 1].Y - AY;
      Denom := Hypot(DX, DY);
      if Denom < 1e-6 then
        Dist := Hypot(Result[I].X - AX, Result[I].Y - AY)
      else
        Dist := Abs(DX * (AY - Result[I].Y) - (AX - Result[I].X) * DY) / Denom;
      if Dist > LTol then
      begin
        Result[K] := Result[I];
        Inc(K);
      end;
    end;
    Result[K] := Result[N - 1];  // last vertex always kept
    Inc(K);
    SetLength(Result, K);
  end;
  finally
    if FProfiling then AddFunc('PartToPixels', LT);
  end;
end;

function TMGLRenderer.FeatureAnchor(AFeature: TMVTFeature; AExtent: Integer): TPoint;
var
  G: TMVTGeometry;
  Part: TMVTPart;
  SumX, SumY, N: Int64;
  P: TPBFPoint;
begin
  Result := Point(0, 0);
  G := AFeature.Geometry;
  if (G = nil) or (G.Parts.Count = 0) then
    Exit;
  Part := G.Parts[0];
  if Length(Part.Points) = 0 then
    Exit;

  case G.GeometryType of
    gtPoint:
      Result := TileToPixel(Part.Points[0], AExtent);
    gtLineString:
      // midpoint vertex of the first part
      Result := TileToPixel(Part.Points[Length(Part.Points) div 2], AExtent);
  else
    begin
      // polygon: centroid of first ring vertices
      SumX := 0; SumY := 0; N := 0;
      for P in Part.Points do
      begin
        Inc(SumX, P.X); Inc(SumY, P.Y); Inc(N);
      end;
      if N > 0 then
        Result := TileToPixel(TPBFPoint.Create(Integer(SumX div N), Integer(SumY div N)), AExtent);
    end;
  end;
end;

procedure TMGLRenderer.Render(ATile: TMVTTile; AStyle: TMGLStyle; AZoom: Double;
  ACanvas: TCanvas);
var
  LTarget, LBig: Integer;
  LBmp: TBitmap;
begin
  if (AStyle = nil) or (ACanvas = nil) then
    Exit;

  if FSupersample <= 1 then
  begin
    RenderContent(ATile, AStyle, AZoom, ACanvas);
    Exit;
  end;

  // Supersampling: render NxN with all sizes scaled, then downscale with a
  // high-quality GDI+ bicubic filter (HALFTONE/StretchBlt thins hairlines).
  LTarget := FTileSize;
  LBig := LTarget * FSupersample;
  LBmp := TBitmap.Create;
  try
    LBmp.PixelFormat := pf24bit;
    LBmp.SetSize(LBig, LBig);
    LBmp.Canvas.Brush.Color := clWhite;
    LBmp.Canvas.FillRect(Rect(0, 0, LBig, LBig));
    FScale := FSupersample;
    FTileSize := LBig;
    try
      RenderContent(ATile, AStyle, AZoom, LBmp.Canvas);
    finally
      FTileSize := LTarget;
      FScale := 1.0;
    end;
    Downscale(LBmp, ACanvas, LTarget);
  finally
    LBmp.Free;
  end;
end;

procedure TMGLRenderer.Downscale(ASrc: TBitmap; ADest: TCanvas; ATarget: Integer);
var
  G: TGPGraphics;
  Img: TGPBitmap;
begin
  G := TGPGraphics.Create(ADest.Handle);
  Img := TGPBitmap.Create(ASrc.Handle, 0);
  try
    G.SetInterpolationMode(InterpolationModeHighQualityBicubic);
    G.SetPixelOffsetMode(PixelOffsetModeHighQuality);
    G.DrawImage(Img, 0, 0, ATarget, ATarget);
  finally
    Img.Free;
    G.Free;
  end;
end;

procedure TMGLRenderer.RenderTileLayers(ATile: TMVTTile; AStyle: TMGLStyle;
  AZoom: Double; ACanvas: TCanvas);
var
  Layer: TMGLLayer;
  Src: TMVTLayer;
  Feature: TMVTFeature;
  LayerIndex: Integer;
  SortList: TList<TMVTFeature>;
  SortName, Cls: string;
  HasSort: Boolean;
  ClassIdx: TObjectDictionary<string, TObjectDictionary<string, TList<TMVTFeature>>>;
  LIdx: TObjectDictionary<string, TList<TMVTFeature>>;
  LBucket: TList<TMVTFeature>;
  LStart: Int64;

  procedure BumpLayer(const AId: string; AStartTicks: Int64);
  var
    V: Double;
  begin
    V := 0;
    FLayerMs.TryGetValue(AId, V);
    FLayerMs.AddOrSetValue(AId,
      V + (TStopwatch.GetTimeStamp - AStartTicks) / TStopwatch.Frequency * 1000);
  end;

  { fill/line/circle sort-key property name (symbol-sort-key is handled in
    placement). '' when the layer kind has no sort-key. }
  function SortKeyName(AKind: TMGLLayerKind): string;
  begin
    case AKind of
      lkFill, lkFillExtrusion: Result := 'fill-sort-key';
      lkLine: Result := 'line-sort-key';
      lkCircle: Result := 'circle-sort-key';
    else
      Result := '';
    end;
  end;

  procedure DrawOne(AFeat: TMVTFeature);
  var
    LCtx: TExprContext;
    LT: Int64;
  begin
    if DebugSkipDraw or FGeomSkip then
      Exit;
    LCtx := MakeContext(AFeat, AZoom, AFeat.Geometry.GeometryType);
    LT := 0;
    if FProfiling then LT := TStopwatch.GetTimeStamp;
    case Layer.Kind of
      lkFill, lkFillExtrusion:
        begin PaintFill(ACanvas, Layer, AFeat, LCtx, Src.Extent);
          if FProfiling then AddFunc('PaintFill(incl)', LT); end;
      lkLine:
        begin PaintLine(ACanvas, Layer, AFeat, LCtx, Src.Extent);
          if FProfiling then AddFunc('PaintLine(incl)', LT); end;
      lkCircle:
        begin PaintCircle(ACanvas, Layer, AFeat, LCtx, Src.Extent);
          if FProfiling then AddFunc('PaintCircle(incl)', LT); end;
    end;
  end;

  { Per-tile feature index by `class`, built once per source-layer: lets a
    class-constrained layer touch only its buckets instead of re-scanning all
    features (the dominant cost on layered styles). }
  function ClassIndexFor(ASrc: TMVTLayer): TObjectDictionary<string, TList<TMVTFeature>>;
  var
    F: TMVTFeature;
    V: TMVTValue;
    K: string;
    Lst: TList<TMVTFeature>;
    LBuildT: Int64;
  begin
    if ClassIdx.TryGetValue(ASrc.Name, Result) then
      Exit;
    LBuildT := 0;
    if FProfiling then LBuildT := TStopwatch.GetTimeStamp;
    Result := TObjectDictionary<string, TList<TMVTFeature>>.Create([doOwnsValues]);
    for F in ASrc.Features do
    begin
      if F.GetProp('class', V) then K := V.AsString else K := '';
      if not Result.TryGetValue(K, Lst) then
      begin
        Lst := TList<TMVTFeature>.Create;
        Result.Add(K, Lst);
      end;
      Lst.Add(F);
    end;
    ClassIdx.Add(ASrc.Name, Result);
    if FProfiling then AddFunc('ClassIndexBuild', LBuildT);
  end;

  procedure Handle(AFeat: TMVTFeature);
  var
    LCtx: TExprContext;
    LFiltT: Int64;
  begin
    if AFeat.Geometry = nil then
      Exit;
    // Geometry-type gate: skip features the layer kind can never draw BEFORE the
    // costlier filter eval (a line layer can't draw points, etc.).
    case Layer.Kind of
      lkFill, lkFillExtrusion:
        if AFeat.Geometry.GeometryType <> gtPolygon then Exit;
      lkCircle:
        if AFeat.Geometry.GeometryType <> gtPoint then Exit;
      lkLine:
        if AFeat.Geometry.GeometryType = gtPoint then Exit;
    end;

    Inc(LastIterCount);
    LCtx := MakeContext(AFeat, AZoom, AFeat.Geometry.GeometryType);
    // Skip the filter eval entirely when the filter is fully implied by the
    // geometry gate (already applied) + the class bucket (already selected).
    if Assigned(Layer.Filter) and not Layer.FilterRedundant then
    begin
      if FProfiling then LFiltT := TStopwatch.GetTimeStamp;
      if not Layer.Filter.Eval(LCtx).AsBool then
      begin
        if FProfiling then AddFunc('FilterEval', LFiltT);
        Exit;
      end;
      if FProfiling then AddFunc('FilterEval', LFiltT);
    end;
    Inc(LastDrawCount);

    if Layer.Kind = lkSymbol then
    begin
      if FProfiling then LFiltT := TStopwatch.GetTimeStamp;
      CollectSymbol(ACanvas, Layer, LayerIndex, AFeat, LCtx, Src.Extent);
      if FProfiling then AddFunc('CollectSymbol', LFiltT);
    end
    else if HasSort then
      SortList.Add(AFeat)
    else
      DrawOne(AFeat);
  end;

begin
  SortList := TList<TMVTFeature>.Create;
  ClassIdx := TObjectDictionary<string,
    TObjectDictionary<string, TList<TMVTFeature>>>.Create([doOwnsValues]);
  // Publish this (per-thread) renderer's feature-constant cache to the shared
  // style bags for the duration of the layer loop; cleared per layer (property
  // names are unique within a layer, render zoom is fixed). Symbol placement runs
  // AFTER this returns with the cache detached, so it never sees stale values.
  GActivePropCache := FPropCache;
  try
    LayerIndex := -1;
    for Layer in AStyle.Layers do
    begin
      Inc(LayerIndex);
      FPropCache.Clear;   // fresh feature-constant cache per layer
      if not Layer.VisibleAtZoom(AZoom) then
        Continue;

      // buffer ring: only symbol layers matter (we collect labels for placement
      // context); skip iterating fill/line/circle features entirely.
      if FGeomSkip and (Layer.Kind <> lkSymbol) then
        Continue;

      if Layer.Kind = lkBackground then
      begin
        if FGeomSkip then Continue;  // ring tile: background is sliced out
        LStart := TStopwatch.GetTimeStamp;
        PaintBackground(ACanvas, Layer, AZoom);
        if FProfiling then BumpLayer(Layer.Id, LStart);
        Continue;
      end;

      // skip kinds we do not raster
      if not (Layer.Kind in [lkFill, lkLine, lkCircle, lkSymbol, lkFillExtrusion]) then
        Continue;

      if ATile = nil then
        Continue;
      Src := ATile.LayerByName(Layer.SourceLayer);
      if Src = nil then
        Continue;

      SortName := SortKeyName(Layer.Kind);
      HasSort := (SortName <> '') and Layer.Layout.Has(SortName);
      SortList.Clear;
      LStart := TStopwatch.GetTimeStamp;

      // Class-index fast path: when the filter pins `class`, visit only those
      // buckets (the full filter still runs for correctness). Else scan all.
      if Length(Layer.FilterClasses) > 0 then
      begin
        LIdx := ClassIndexFor(Src);
        for Cls in Layer.FilterClasses do
          if LIdx.TryGetValue(Cls, LBucket) then
            for Feature in LBucket do
              Handle(Feature);
      end
      else
        for Feature in Src.Features do
          Handle(Feature);

      // *-sort-key: draw features ascending (lower = drawn first/under).
      if HasSort and (SortList.Count > 0) then
      begin
        SortList.Sort(TComparer<TMVTFeature>.Construct(
          function(const L, R: TMVTFeature): Integer
          var
            KL, KR: Double;
          begin
            KL := Layer.Layout.EvalFloat(SortName, MakeContext(L, AZoom, gtUnknown), 0.0);
            KR := Layer.Layout.EvalFloat(SortName, MakeContext(R, AZoom, gtUnknown), 0.0);
            Result := CompareValue(KL, KR);
          end));
        for Feature in SortList do
          DrawOne(Feature);
      end;

      if FProfiling then BumpLayer(Layer.Id, LStart);
    end;
  finally
    GActivePropCache := nil;  // detach before symbol placement / next tile
    SortList.Free;
    ClassIdx.Free;  // owns the per-source class buckets
  end;
end;

procedure TMGLRenderer.InstallProfileHook;
begin
  // Forward the surface's per-primitive timers into the renderer profile only
  // when profiling is on (zero overhead otherwise: the surface won't even read
  // the timestamps when ProfileHook is unassigned).
  if Assigned(FSurface) and FProfiling then
    FSurface.ProfileHook :=
      procedure(const AName: string; AStartTicks: Int64)
      begin
        AddFunc(AName, AStartTicks);
      end;
end;

procedure TMGLRenderer.RenderContent(ATile: TMVTTile; AStyle: TMGLStyle;
  AZoom: Double; ACanvas: TCanvas);
var
  LSwGeom, LSwSym: TStopwatch;
begin
  LastIterCount := 0;
  LastDrawCount := 0;
  FGrid.Clear;
  FCandidates.Clear;
  FPlaced.Clear;
  FillChar(FSymDiag, SizeOf(FSymDiag), 0);
  FOffsetX := 0;
  FOffsetY := 0;

  // One drawing surface for the whole tile (GDI+ or Skia, chosen by FUseSkia).
  // Geometry draws via the surface primitives; symbols (GDI text/icons) draw on
  // FSurface.TextCanvas AFTER FlushGeometry; EndFrame blits (Skia) or no-ops (GDI).
  FSurface := CreateDrawSurface(FUseSkia, ACanvas, FAntialias);
  try
    InstallProfileHook;
    FSurface.BeginFrame(FTileSize, FTileSize);
    LSwGeom := TStopwatch.StartNew;
    RenderTileLayers(ATile, AStyle, AZoom, FSurface.TextCanvas);
    FSurface.FlushGeometry;
    LSwGeom.Stop;
    LastGeomMs := LSwGeom.ElapsedMilliseconds;
    LSwSym := TStopwatch.StartNew;
    PlaceAndDrawSymbols;
    LSwSym.Stop;
    LastSymMs := LSwSym.ElapsedMilliseconds;
    FSurface.EndFrame;
  finally
    FreeAndNil(FSurface);
  end;
end;

procedure TMGLRenderer.RenderScene(const ATiles: TArray<TMVTTile>;
  ACols, ARows: Integer; AStyle: TMGLStyle; AZoom: Double; ACanvas: TCanvas;
  ATilePx: Integer; AScale: Double; AInnerOfs: Integer; AInnerN: Integer);
var
  R, C, I, LSaveTile: Integer;
  LSaveScale: Double;
begin
  if AStyle = nil then
    Exit;
  LastIterCount := 0;
  LastDrawCount := 0;
  FGrid.Clear;
  FCandidates.Clear;
  FPlaced.Clear;
  FillChar(FSymDiag, SizeOf(FSymDiag), 0);
  LSaveTile := FTileSize;
  LSaveScale := FScale;
  FTileSize := ATilePx;
  FScale := AScale;

  FSurface := CreateDrawSurface(FUseSkia, ACanvas, FAntialias);
  try
    InstallProfileHook;
    FSurface.BeginFrame(ACols * ATilePx, ARows * ATilePx);

    // geometry + symbol collection for every sub-tile, offset into the scene.
    // Tiles OUTSIDE the inner [AInnerOfs..AInnerOfs+AInnerN-1] block are the
    // buffer ring: only COLLECT their symbols (for label-placement context) and
    // skip drawing their geometry, which gets sliced out anyway. This avoids the
    // ~3-4x cost of drawing neighbour fills/lines just to discard them.
    for R := 0 to ARows - 1 do
      for C := 0 to ACols - 1 do
      begin
        I := R * ACols + C;
        if (I > High(ATiles)) or (ATiles[I] = nil) then
          Continue;
        FGeomSkip := (R < AInnerOfs) or (R >= AInnerOfs + AInnerN) or
                     (C < AInnerOfs) or (C >= AInnerOfs + AInnerN);
        FOffsetX := C * ATilePx;
        FOffsetY := R * ATilePx;
        RenderTileLayers(ATiles[I], AStyle, AZoom, FSurface.TextCanvas);
      end;

    FGeomSkip := False;
    FOffsetX := 0;
    FOffsetY := 0;
    FSurface.FlushGeometry;
    // single scene-wide placement: edge labels see neighbour geometry, dedup and
    // collision span the whole block -> tiles stitch without cut/dup labels.
    PlaceAndDrawSymbols;
    FSurface.EndFrame;
  finally
    FreeAndNil(FSurface);
    FTileSize := LSaveTile;
    FScale := LSaveScale;
    FOffsetX := 0;
    FOffsetY := 0;
  end;
end;

procedure TMGLRenderer.PaintBackground(ACanvas: TCanvas; ALayer: TMGLLayer;
  AZoom: Double);
var
  Ctx: TExprContext;
  Col: TMGLColor;
  LPattern: string;
  LRing: TArray<TArray<TPoint>>;
begin
  Ctx := MakeContext(nil, AZoom, gtUnknown);
  Col := ALayer.Paint.EvalColor('background-color', Ctx, TMGLColor.Create(0, 0, 0, 0));
  Col.A := Col.A * ALayer.Paint.EvalFloat('background-opacity', Ctx, 1.0);
  FSurface.FillRect(Rect(FOffsetX, FOffsetY, FOffsetX + FTileSize, FOffsetY + FTileSize), Col);

  // background-pattern: tile a sprite icon over the whole tile (reuses the
  // fill-pattern path with a full-tile rectangle as the clip ring). GDI-only.
  if FSurface.SupportsPattern and Assigned(FSprite) and FSprite.Loaded and
     ALayer.Paint.Has('background-pattern') then
  begin
    LPattern := ALayer.Paint.EvalString('background-pattern', Ctx, '').Trim;
    if FSprite.HasIcon(LPattern) then
    begin
      SetLength(LRing, 1);
      LRing[0] := [Point(FOffsetX, FOffsetY), Point(FOffsetX + FTileSize, FOffsetY),
                   Point(FOffsetX + FTileSize, FOffsetY + FTileSize),
                   Point(FOffsetX, FOffsetY + FTileSize)];
      FillRingsPattern(FSurface.PatternCanvas, LRing, LPattern);
    end;
  end;
end;

procedure TMGLRenderer.FillRings(const ARings: TArray<TArray<TPoint>>;
  const AFill: TMGLColor; AHasOutline: Boolean; const AOutline: TMGLColor);
begin
  FSurface.FillRings(ARings, AFill, AHasOutline, AOutline);
end;

procedure TMGLRenderer.FillRingsPattern(ACanvas: TCanvas;
  const ARings: TArray<TArray<TPoint>>; const aPattern: string);
var
  DC: HDC;
  Ring: TArray<TPoint>;
  P: TPoint;
  Icon: TMGLSpriteIcon;
  Box: TRect;
  X, Y, IW, IH, I: Integer;
  Blend: TBlendFunction;
begin
  if (Length(ARings) = 0) or not FSprite.TryGetIcon(aPattern, Icon) then
    Exit;
  IW := Round(Icon.Width / Icon.PixelRatio);
  IH := Round(Icon.Height / Icon.PixelRatio);
  if (IW <= 0) or (IH <= 0) then
    Exit;

  // Clip drawing to the polygon path, then tile the sprite across its bbox.
  DC := ACanvas.Handle;
  BeginPath(DC);
  for Ring in ARings do
  begin
    if Length(Ring) < 2 then
      Continue;
    MoveToEx(DC, Ring[0].X, Ring[0].Y, nil);
    for I := 1 to High(Ring) do
      LineTo(DC, Ring[I].X, Ring[I].Y);
    CloseFigure(DC);
  end;
  EndPath(DC);
  SetPolyFillMode(DC, ALTERNATE);
  SelectClipPath(DC, RGN_COPY);

  Box := TRect.Create(MaxInt, MaxInt, -MaxInt, -MaxInt);
  for Ring in ARings do
    for P in Ring do
    begin
      Box.Left := Min(Box.Left, P.X);
      Box.Top := Min(Box.Top, P.Y);
      Box.Right := Max(Box.Right, P.X);
      Box.Bottom := Max(Box.Bottom, P.Y);
    end;

  Blend.BlendOp := AC_SRC_OVER;
  Blend.BlendFlags := 0;
  Blend.SourceConstantAlpha := 255;
  Blend.AlphaFormat := AC_SRC_ALPHA;
  Y := Box.Top;
  while Y < Box.Bottom do
  begin
    X := Box.Left;
    while X < Box.Right do
    begin
      Winapi.Windows.AlphaBlend(DC, X, Y, IW, IH, FSprite.Bitmap.Canvas.Handle,
        Icon.X, Icon.Y, Icon.Width, Icon.Height, Blend);
      Inc(X, IW);
    end;
    Inc(Y, IH);
  end;
  SelectClipRgn(DC, 0);  // drop the clip region
end;

procedure TMGLRenderer.StampLinePattern(ACanvas: TCanvas;
  const APts: TArray<TPoint>; const aPattern: string);
var
  Icon: TMGLSpriteIcon;
  Drawn: TRect;
  I, IW, CX, CY: Integer;
  SegLen, Cursor, T: Double;
begin
  if (Length(APts) < 2) or not FSprite.TryGetIcon(aPattern, Icon) then
    Exit;
  IW := Round(Icon.Width / Icon.PixelRatio);
  if IW <= 0 then
    Exit;

  for I := 0 to High(APts) - 1 do
  begin
    SegLen := Hypot(APts[I + 1].X - APts[I].X, APts[I + 1].Y - APts[I].Y);
    Cursor := 0;
    while Cursor <= SegLen do
    begin
      T := Cursor / Max(1.0, SegLen);
      CX := Round(APts[I].X + (APts[I + 1].X - APts[I].X) * T);
      CY := Round(APts[I].Y + (APts[I + 1].Y - APts[I].Y) * T);
      FSprite.DrawIconCentered(ACanvas, aPattern, CX, CY, Drawn);
      Cursor := Cursor + IW;  // spacing = icon width
    end;
  end;
end;

procedure TMGLRenderer.PaintFill(ACanvas: TCanvas; ALayer: TMGLLayer;
  AFeature: TMVTFeature; const Ctx: TExprContext; AExtent: Integer);
var
  Groups: TArray<TArray<TArray<TPBFPoint>>>;
  Rings: TArray<TArray<TPoint>>;
  Grp: TArray<TArray<TPBFPoint>>;
  Ring: TArray<TPBFPoint>;
  Fill, Outline: TMGLColor;
  Opacity: Double;
  HasOutline: Boolean;
  LPattern: string;
  Translate: TArray<Double>;
  TransX, TransY, J: Integer;
  Pix: TArray<TPoint>;
begin
  if (AFeature.Geometry = nil) or (AFeature.Geometry.GeometryType <> gtPolygon) then
    Exit;

  // fill-extrusion (3D) is rendered as a flat footprint, but its paint props are
  // named fill-extrusion-* (different from fill-*). Reading the wrong names made
  // 3D-building layers fall back to the black default (e.g. OSM Liberty).
  if ALayer.Kind = lkFillExtrusion then
  begin
    Opacity := ALayer.Paint.EvalFloat('fill-extrusion-opacity', Ctx, 1.0);
    Fill := ALayer.Paint.EvalColor('fill-extrusion-color', Ctx, TMGLColor.FromRGBA(0, 0, 0, 255));
    Fill.A := Fill.A * Opacity;
    HasOutline := False;  // extrusion footprints have no outline
    Outline := Fill;
  end
  else
  begin
    Opacity := ALayer.Paint.EvalFloat('fill-opacity', Ctx, 1.0);
    Fill := ALayer.Paint.EvalColor('fill-color', Ctx, TMGLColor.FromRGBA(0, 0, 0, 255));
    Fill.A := Fill.A * Opacity;
    HasOutline := ALayer.Paint.Has('fill-outline-color');
    Outline := ALayer.Paint.EvalColor('fill-outline-color', Ctx, Fill);
    // MapLibre draws the 1px outline at the layer's fill-opacity, not opaque.
    Outline.A := Outline.A * Opacity;
  end;

  // fill-translate: shift the fill by [x,y] px (screen space)
  // fill-translate-anchor ("map"/"viewport") read for completeness; coincide on flat tiles.
  ALayer.Paint.EvalString('fill-translate-anchor', Ctx, 'map');
  Translate := ALayer.Paint.GetFloatArray('fill-translate', []);
  TransX := 0; TransY := 0;
  if Length(Translate) >= 2 then
  begin
    TransX := Round(Translate[0] * FScale);
    TransY := Round(Translate[1] * FScale);
  end;

  LPattern := '';
  if FSurface.SupportsPattern and Assigned(FSprite) and FSprite.Loaded and
     ALayer.Paint.Has('fill-pattern') then
  begin
    LPattern := ExpandTokens(ALayer.Paint.EvalString('fill-pattern', Ctx, ''),
      AFeature).Trim;
    if not FSprite.HasIcon(LPattern) then
      LPattern := '';
  end;

  Groups := AFeature.Geometry.ExteriorWithHoles;
  for Grp in Groups do
  begin
    SetLength(Rings, 0);
    for Ring in Grp do
    begin
      Pix := PartToPixels(Ring, AExtent);
      if (TransX <> 0) or (TransY <> 0) then
        for J := 0 to High(Pix) do
        begin
          Pix[J].X := Pix[J].X + TransX;
          Pix[J].Y := Pix[J].Y + TransY;
        end;
      SetLength(Rings, Length(Rings) + 1);
      Rings[High(Rings)] := Pix;
    end;
    if LPattern <> '' then
      FillRingsPattern(FSurface.PatternCanvas, Rings, LPattern)
    else
      FillRings(Rings, Fill, HasOutline, Outline);
  end;
end;

function TMGLRenderer.FeatureLines(AFeature: TMVTFeature;
  AExtent, ATransX, ATransY: Integer): TArray<TArray<TPoint>>;
var
  I, J, N: Integer;
  Pts: TArray<TPoint>;
begin
  N := AFeature.Geometry.Parts.Count;
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    Pts := PartToPixels(AFeature.Geometry.Parts[I].Points, AExtent);
    for J := 0 to High(Pts) do
    begin
      Pts[J].X := Pts[J].X + ATransX;
      Pts[J].Y := Pts[J].Y + ATransY;
    end;
    Result[I] := Pts;
  end;
end;

function TMGLRenderer.OffsetPolyline(const APts: TArray<TPoint>;
  AOffset: Double): TArray<TPoint>;
var
  I: Integer;
  NX, NY, Len, DX, DY: Double;
begin
  SetLength(Result, Length(APts));
  if Length(APts) < 2 then
  begin
    Result := Copy(APts);
    Exit;
  end;
  for I := 0 to High(APts) do
  begin
    // normal of the segment touching vertex I (use previous for the last point)
    if I < High(APts) then
    begin
      DX := APts[I + 1].X - APts[I].X;
      DY := APts[I + 1].Y - APts[I].Y;
    end
    else
    begin
      DX := APts[I].X - APts[I - 1].X;
      DY := APts[I].Y - APts[I - 1].Y;
    end;
    Len := Hypot(DX, DY);
    if Len <= 0 then
    begin
      NX := 0; NY := 0;
    end
    else
    begin
      NX := -DY / Len;  // left normal
      NY := DX / Len;
    end;
    Result[I].X := Round(APts[I].X + NX * AOffset);
    Result[I].Y := Round(APts[I].Y + NY * AOffset);
  end;
end;

procedure TMGLRenderer.StrokeLines(const AParts: TArray<TArray<TPoint>>;
  const AColor: TMGLColor; AWidth: Integer; const ADashUnits: TArray<Double>;
  ACap: TLineCap; AJoin: TLineJoin);
begin
  FSurface.StrokeLines(AParts, AColor, AWidth, ADashUnits, ACap, AJoin);
end;

procedure TMGLRenderer.StrokeGradient(const AParts: TArray<TArray<TPoint>>;
  const AGradient: IExpression; const ACtx: TExprContext;
  AWidth: Integer; ACap: TLineCap; AJoin: TLineJoin);
var
  Part: TArray<TPoint>;
  Lens: TArray<Double>;
  Total, Prog: Double;
  I: Integer;
  LCtx: TExprContext;
  Col: TMGLColor;
  Seg: TArray<TArray<TPoint>>;
begin
  if not Assigned(AGradient) then
    Exit;
  if AWidth < 1 then
    AWidth := 1;
  LCtx := ACtx;
  SetLength(Seg, 1);
  SetLength(Seg[0], 2);
  for Part in AParts do
  begin
    if Length(Part) < 2 then
      Continue;
    // cumulative segment lengths -> progress 0..1
    SetLength(Lens, Length(Part));
    Lens[0] := 0;
    Total := 0;
    for I := 1 to High(Part) do
    begin
      Total := Total + Hypot(Part[I].X - Part[I - 1].X, Part[I].Y - Part[I - 1].Y);
      Lens[I] := Total;
    end;
    if Total <= 0 then
      Continue;
    for I := 1 to High(Part) do
    begin
      Prog := ((Lens[I - 1] + Lens[I]) / 2) / Total;  // midpoint progress
      LCtx.LineProgress := Prog;
      if not TryParseColor(AGradient.Eval(LCtx).AsString, Col) then
        Continue;
      // Draw each segment as its own solid stroke -> backend-agnostic gradient.
      Seg[0][0] := Part[I - 1];
      Seg[0][1] := Part[I];
      FSurface.StrokeLines(Seg, Col, AWidth, nil, ACap, AJoin);
    end;
  end;
end;

procedure TMGLRenderer.PaintLine(ACanvas: TCanvas; ALayer: TMGLLayer;
  AFeature: TMVTFeature; const Ctx: TExprContext; AExtent: Integer);
var
  Part: TMVTPart;
  Col, BlurCol: TMGLColor;
  Width, Opacity, LineOffset, GapWidth, LBlur: Double;
  LPattern: string;
  LCap: TLineCap;
  LJoin: TLineJoin;
  LWidth, I: Integer;
  Dash, Translate: TArray<Double>;
  TransX, TransY: Integer;
  Parts, Left, Right: TArray<TArray<TPoint>>;
  HasGradient: Boolean;
begin
  if AFeature.Geometry = nil then
    Exit;

  // line-pattern (best-effort): stamp the sprite icon along the polyline.
  // GDI-only path; under a backend without pattern support the line falls through
  // to a solid stroke.
  if FSurface.SupportsPattern and Assigned(FSprite) and FSprite.Loaded and
     ALayer.Paint.Has('line-pattern') then
  begin
    LPattern := ExpandTokens(ALayer.Paint.EvalString('line-pattern', Ctx, ''),
      AFeature).Trim;
    if FSprite.HasIcon(LPattern) then
    begin
      for Part in AFeature.Geometry.Parts do
        StampLinePattern(FSurface.PatternCanvas, PartToPixels(Part.Points, AExtent), LPattern);
      Exit;
    end;
  end;

  Opacity := ALayer.Paint.EvalFloat('line-opacity', Ctx, 1.0);
  Col := ALayer.Paint.EvalColor('line-color', Ctx, TMGLColor.Black);
  Col.A := Col.A * Opacity;
  Width := ALayer.Paint.EvalFloat('line-width', Ctx, 1.0);
  LineOffset := ALayer.Paint.EvalFloat('line-offset', Ctx, 0.0);
  GapWidth := ALayer.Paint.EvalFloat('line-gap-width', Ctx, 0.0);
  Dash := ALayer.Paint.GetFloatArray('line-dasharray', []);
  LBlur := ALayer.Paint.EvalFloat('line-blur', Ctx, 0.0) * FScale;
  // line-translate-anchor read for completeness; on a north-up untilted tile
  // "map" and "viewport" coincide, so it has no visual effect here.
  ALayer.Paint.EvalString('line-translate-anchor', Ctx, 'map');
  HasGradient := ALayer.Paint.Has('line-gradient');

  // line-translate: shift the whole geometry by [x,y] px (screen space)
  Translate := ALayer.Paint.GetFloatArray('line-translate', []);
  TransX := 0; TransY := 0;
  if Length(Translate) >= 2 then
  begin
    TransX := Round(Translate[0] * FScale);
    TransY := Round(Translate[1] * FScale);
  end;

  // MapLibre defaults: line-cap "butt", line-join "miter" (styles usually
  // override to round for roads).
  LCap := GPCap(ALayer.Layout.EvalString('line-cap', Ctx, 'butt'));
  LJoin := GPJoin(ALayer.Layout.EvalString('line-join', Ctx, 'miter'));
  Width := Width * FScale;
  LineOffset := LineOffset * FScale;
  GapWidth := GapWidth * FScale;
  LWidth := Max(1, Round(Width));

  Parts := FeatureLines(AFeature, AExtent, TransX, TransY);

  if GapWidth > 0 then
  begin
    // two parallel lines either side of the path, separated by the gap
    SetLength(Left, Length(Parts));
    SetLength(Right, Length(Parts));
    for I := 0 to High(Parts) do
    begin
      Left[I] := OffsetPolyline(Parts[I], (GapWidth + Width) / 2);
      Right[I] := OffsetPolyline(Parts[I], -(GapWidth + Width) / 2);
    end;
    StrokeLines(Left, Col, LWidth, Dash, LCap, LJoin);
    StrokeLines(Right, Col, LWidth, Dash, LCap, LJoin);
    Exit;
  end;

  if LineOffset <> 0 then
    for I := 0 to High(Parts) do
      Parts[I] := OffsetPolyline(Parts[I], LineOffset);

  // Synthetic casing: grey under-stroke for light (road) lines (no explicit case).
  if FSyntheticCasing and (Length(Dash) = 0) and (Luminance(Col) > CASING_LUMA_MIN) and
     (LWidth >= Round(CASING_MIN_FILL * FScale)) then
    StrokeLines(Parts, TMGLColor.FromRGBA(210, 210, 210, 255),
      LWidth + Round(CASING_EXTRA * FScale), nil, LCap, LJoin);

  // line-blur: approximate the soft edge with a wider, faded under-stroke.
  if LBlur > 0.5 then
  begin
    BlurCol := Col;
    BlurCol.A := BlurCol.A * 0.45;
    StrokeLines(Parts, BlurCol, LWidth + Round(LBlur * 2), Dash, LCap, LJoin);
  end;

  if HasGradient then
    StrokeGradient(Parts, ALayer.Paint.Get('line-gradient'), Ctx, LWidth, LCap, LJoin)
  else
    StrokeLines(Parts, Col, LWidth, Dash, LCap, LJoin);
end;

procedure TMGLRenderer.PaintCircle(ACanvas: TCanvas; ALayer: TMGLLayer;
  AFeature: TMVTFeature; const Ctx: TExprContext; AExtent: Integer);
var
  Part: TMVTPart;
  P: TPBFPoint;
  C: TPoint;
  Fill, Stroke: TMGLColor;
  Radius, StrokeW, Opacity, Blur: Double;
  HasStroke: Boolean;
  Translate: TArray<Double>;
  TransX, TransY: Integer;
begin
  if AFeature.Geometry = nil then
    Exit;

  Radius := ALayer.Paint.EvalFloat('circle-radius', Ctx, 5.0);
  Opacity := ALayer.Paint.EvalFloat('circle-opacity', Ctx, 1.0);
  Fill := ALayer.Paint.EvalColor('circle-color', Ctx, TMGLColor.Black);
  Fill.A := Fill.A * Opacity;
  StrokeW := ALayer.Paint.EvalFloat('circle-stroke-width', Ctx, 0.0);
  HasStroke := StrokeW > 0;
  Stroke := ALayer.Paint.EvalColor('circle-stroke-color', Ctx, TMGLColor.Black);
  Stroke.A := Stroke.A * ALayer.Paint.EvalFloat('circle-stroke-opacity', Ctx, 1.0);
  Blur := ALayer.Paint.EvalFloat('circle-blur', Ctx, 0.0);  // fraction of radius
  // circle-pitch-scale/-alignment and circle-translate-anchor read for
  // completeness; they only matter with map pitch/bearing (not on flat tiles).
  ALayer.Paint.EvalString('circle-pitch-scale', Ctx, 'map');
  ALayer.Paint.EvalString('circle-pitch-alignment', Ctx, 'viewport');
  ALayer.Paint.EvalString('circle-translate-anchor', Ctx, 'map');

  Translate := ALayer.Paint.GetFloatArray('circle-translate', []);
  TransX := 0; TransY := 0;
  if Length(Translate) >= 2 then
  begin
    TransX := Round(Translate[0] * FScale);
    TransY := Round(Translate[1] * FScale);
  end;

  Radius := Radius * FScale;
  StrokeW := StrokeW * FScale;

  // Backend-agnostic: one DrawCircle per point feature (fill + optional blur halo
  // + optional stroke). The surface owns the GDI+/Skia specifics.
  for Part in AFeature.Geometry.Parts do
    for P in Part.Points do
    begin
      C := TileToPixel(P, AExtent);
      FSurface.DrawCircle(C.X + TransX, C.Y + TransY, Radius, StrokeW,
        Fill, HasStroke, Stroke, Blur);
    end;
end;

function TMGLRenderer.DedupTooClose(const AKey: string; const APos: TPoint;
  ASpacing: Integer): Boolean;
var
  List: TList<TPoint>;
  P: TPoint;
begin
  Result := False;
  if FPlaced.TryGetValue(AKey, List) then
    for P in List do
      if Sqr(P.X - APos.X) + Sqr(P.Y - APos.Y) < Sqr(ASpacing) then
        Exit(True);
end;

procedure TMGLRenderer.RecordPlacement(const AKey: string; const APos: TPoint);
var
  List: TList<TPoint>;
begin
  if not FPlaced.TryGetValue(AKey, List) then
  begin
    List := TList<TPoint>.Create;
    FPlaced.Add(AKey, List);
  end;
  List.Add(APos);
end;

function TMGLRenderer.LineAnchors(AFeature: TMVTFeature;
  AExtent, ASpacing, ATextW: Integer): TArray<TSymAnchor>;
var
  G: TMVTGeometry;
  Pts: TArray<TPoint>;
  Res: TList<TSymAnchor>;
  A: TSymAnchor;
  I: Integer;
  Total, Half, Dist: Double;

  { Pose (position + upright angle) at AAt pixels along the polyline. }
  function PoseAt(AAt: Double; out APose: TSymAnchor): Boolean;
  var
    J: Integer;
    DX, DY, SegLen, T, Acc: Double;
  begin
    Result := False;
    Acc := 0;
    for J := 0 to High(Pts) - 1 do
    begin
      DX := Pts[J + 1].X - Pts[J].X;
      DY := Pts[J + 1].Y - Pts[J].Y;
      SegLen := Hypot(DX, DY);
      if SegLen <= 0 then
        Continue;
      if AAt <= Acc + SegLen then
      begin
        T := (AAt - Acc) / SegLen;
        APose.Pos := Point(Round(Pts[J].X + DX * T), Round(Pts[J].Y + DY * T));
        APose.AngleDeg := RadToDeg(ArcTan2(-DY, DX));
        if APose.AngleDeg > 90 then APose.AngleDeg := APose.AngleDeg - 180
        else if APose.AngleDeg < -90 then APose.AngleDeg := APose.AngleDeg + 180;
        Exit(True);
      end;
      Acc := Acc + SegLen;
    end;
  end;

begin
  Result := nil;
  G := AFeature.Geometry;
  if (G = nil) or (G.Parts.Count = 0) then
    Exit;
  Pts := PartToPixels(G.Parts[0].Points, AExtent);
  if Length(Pts) < 2 then
    Exit;

  Total := 0;
  for I := 0 to High(Pts) - 1 do
    Total := Total + Hypot(Pts[I + 1].X - Pts[I].X, Pts[I + 1].Y - Pts[I].Y);
  Half := ATextW / 2;
  // MapLibre rule: a line shorter than the label gets no label at all.
  if Total < ATextW then
  begin
    Inc(FSymDiag.DropLineShort);
    Exit;
  end;

  Res := TList<TSymAnchor>.Create;
  try
    // spaced anchors; emit only where the whole label fits inside the line
    Dist := ASpacing / 2;
    while Dist <= Total do
    begin
      if (Dist - Half >= 0) and (Dist + Half <= Total) and PoseAt(Dist, A) then
        Res.Add(A);
      Dist := Dist + ASpacing;
    end;
    if (Res.Count = 0) then
      if PoseAt(Total / 2, A) then  // one centered label
        Res.Add(A)
      else
        Inc(FSymDiag.DropNoAnchor);
    Result := Res.ToArray;
  finally
    Res.Free;
  end;
end;

function TMGLRenderer.RotatedBoxes(const APos: TPoint; AAngleDeg: Double;
  ATextW, ALineH, APad: Integer): TArray<TRect>;
var
  N, I, Box: Integer;
  Rad, Half, Off, CX, CY: Double;
  R: TRect;
begin
  Box := Max(1, ALineH);
  N := Max(1, ATextW div Box);
  Rad := DegToRad(AAngleDeg);
  Half := ATextW / 2;
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    Off := -Half + (I + 0.5) * (ATextW / N);
    CX := APos.X + Cos(Rad) * Off;
    CY := APos.Y - Sin(Rad) * Off;
    R := Rect(Round(CX) - Box div 2, Round(CY) - Box div 2,
              Round(CX) + Box div 2, Round(CY) + Box div 2);
    R.Inflate(APad, APad);
    Result[I] := R;
  end;
end;

function TMGLRenderer.MakeBlockProc(ACanvas: TCanvas; const ALines: TArray<string>;
  ABX, ABY, ABlockW, ALineH, AFontPt, AJustify, ALetterExtra: Integer;
  const ATextColor, AHaloColor: TMGLColor; AHaloWidth: Double;
  const AFontName: string; AFontStyle: TFontStyles): TProc;
begin
  Result :=
    procedure
    begin
      FSurface.DrawTextBlock(ALines, ABX, ABY, ABlockW, ALineH, AJustify,
        ALetterExtra, AFontPt, AFontName, AFontStyle, ATextColor, AHaloColor, AHaloWidth);
    end;
end;

function TMGLRenderer.MakeRotatedProc(ACanvas: TCanvas; const AText: string;
  ACx, ACy, AFontPt: Integer; AAngleDeg: Double; ATextW, ALetterExtra: Integer;
  const ATextColor, AHaloColor: TMGLColor; AHaloWidth: Double;
  const AFontName: string; AFontStyle: TFontStyles): TProc;
begin
  Result :=
    procedure
    begin
      FSurface.DrawRotatedText(AText, ACx, ACy, AFontPt, AAngleDeg, ATextW,
        ALetterExtra, AFontName, AFontStyle, ATextColor, AHaloColor, AHaloWidth);
    end;
end;

function TMGLRenderer.MakeIconProc(ACanvas: TCanvas; const AName: string;
  ACx, ACy: Integer; AScale, ARotateDeg, AOpacity: Double; ATint: TColor): TProc;
begin
  Result :=
    procedure
    begin
      FSurface.DrawIcon(FSprite, AName, ACx, ACy, AScale, ARotateDeg, AOpacity, ATint);
    end;
end;



procedure TMGLRenderer.CollectSymbol(ACanvas: TCanvas; ALayer: TMGLLayer;
  ALayerIndex: Integer; AFeature: TMVTFeature; const Ctx: TExprContext;
  AExtent: Integer);
var
  Text, Transform, IconName, JustStr, FontName: string;
  FontStyle: TFontStyles;
  TextColor, HaloColor: TMGLColor;
  TextSize, HaloWidth, SortKey, LineHeight: Double;
  FontPt, LineH, BlockW, TotalH, TextPad, IconPad, Spacing, I, JustifyVal,
  LetterExtra: Integer;
  IconScale, IconOpacity: Double;
  IconTint: TColor;
  IconW, IconH: Integer;
  HasIcon, IsLine: Boolean;
  TextAllowOverlap, IconAllowOverlap, TextOptional, IconOptional: Boolean;
  Icon: TMGLSpriteIcon;
  Offset: TArray<Double>;
  OffsetX, OffsetY: Integer;
  Lines: TArray<string>;
  Sz: TSize;
  E: IExpression;
  Anchors: TArray<TSymAnchor>;
  Base: TPoint;
  Cand: TSymbolCandidate;

  procedure AddPointCandidate;
  var
    AnchorKinds: TArray<string>;
    K, IAnchor: string;
    BX, BY, ICx, ICy: Integer;
    IOff: TArray<Double>;
    PC: TSymbolCandidate;
    Opt: TPlacementOption;
  begin
    PC := Default(TSymbolCandidate);
    PC.LayerIndex := ALayerIndex;
    PC.SortKey := SortKey;
    PC.Spacing := Spacing;
    PC.DedupKey := Text.ToLower;
    PC.DedupPos := Base;

    // icon part (placed independently of the text)
    PC.HasIcon := HasIcon;
    PC.IconAllowOverlap := IconAllowOverlap;
    PC.IconOptional := IconOptional;
    PC.IconIgnorePlacement := ALayer.Layout.EvalBool('icon-ignore-placement', Ctx, False);
    if HasIcon then
    begin
      // icon-offset (px, scaled by icon-size) + icon-anchor
      ICx := Base.X;
      ICy := Base.Y;
      IOff := ALayer.Layout.GetFloatArray('icon-offset', []);
      if Length(IOff) >= 2 then
      begin
        ICx := ICx + Round(IOff[0] * IconScale * FScale);
        ICy := ICy + Round(IOff[1] * IconScale * FScale);
      end;
      IAnchor := ALayer.Layout.EvalString('icon-anchor', Ctx, 'center');
      if IAnchor.Contains('left') then ICx := ICx + IconW div 2
      else if IAnchor.Contains('right') then ICx := ICx - IconW div 2;
      if IAnchor.Contains('top') then ICy := ICy + IconH div 2
      else if IAnchor.Contains('bottom') then ICy := ICy - IconH div 2;

      PC.IconBox := Rect(ICx - IconW div 2, ICy - IconH div 2,
        ICx - IconW div 2 + IconW, ICy - IconH div 2 + IconH);
      PC.IconBox.Inflate(IconPad, IconPad);
      PC.IconDraw := MakeIconProc(ACanvas, IconName, ICx, ICy, IconScale * FScale,
        ALayer.Layout.EvalFloat('icon-rotate', Ctx, 0.0), IconOpacity, IconTint);
    end;

    // text part (variable-anchor options)
    PC.HasText := Text <> '';
    PC.TextAllowOverlap := TextAllowOverlap;
    PC.TextOptional := TextOptional;
    PC.TextIgnorePlacement := ALayer.Layout.EvalBool('text-ignore-placement', Ctx, False);
    if PC.HasText then
    begin
      if ALayer.Layout.Has('text-variable-anchor') then
        AnchorKinds := ['center', 'top', 'bottom', 'left', 'right']
      else
        AnchorKinds := [ALayer.Layout.EvalString('text-anchor', Ctx, 'center')];
      for K in AnchorKinds do
      begin
        BX := Base.X - BlockW div 2 + OffsetX;
        BY := Base.Y - TotalH div 2 + OffsetY;
        if K.Contains('left') then BX := Base.X + OffsetX
        else if K.Contains('right') then BX := Base.X - BlockW + OffsetX;
        if K.Contains('top') then BY := Base.Y + OffsetY
        else if K.Contains('bottom') then BY := Base.Y - TotalH + OffsetY;

        Opt.Boxes := [TRect.Create(BX, BY, BX + BlockW, BY + TotalH)];
        Opt.Boxes[0].Inflate(TextPad, TextPad);
        Opt.Draw := MakeBlockProc(ACanvas, Lines, BX, BY, BlockW, LineH, FontPt,
          JustifyVal, LetterExtra, TextColor, HaloColor, HaloWidth, FontName, FontStyle);
        SetLength(PC.TextOptions, Length(PC.TextOptions) + 1);
        PC.TextOptions[High(PC.TextOptions)] := Opt;
      end;
    end;
    FCandidates.Add(PC);
  end;

begin
  if DebugSkipDraw or (AFeature.Geometry = nil) then
    Exit;

  // text
  Text := '';
  E := ALayer.Layout.Get('text-field');
  if E <> nil then
    Text := ExpandTokens(E.Eval(Ctx).AsString, AFeature).Trim;
  Transform := ALayer.Layout.EvalString('text-transform', Ctx, 'none');
  if SameText(Transform, 'uppercase') then Text := Text.ToUpper
  else if SameText(Transform, 'lowercase') then Text := Text.ToLower;

  // icon
  HasIcon := False;
  IconName := '';
  IconScale := ALayer.Layout.EvalFloat('icon-size', Ctx, 1.0);
  if Assigned(FSprite) and FSprite.Loaded and ALayer.Layout.Has('icon-image') then
  begin
    IconName := ExpandTokens(ALayer.Layout.EvalString('icon-image', Ctx, ''), AFeature).Trim;
    HasIcon := (IconName <> '') and FSprite.TryGetIcon(IconName, Icon);
  end;

  // icon-opacity (paint, default 1) and icon-color (SDF tint; only when the
  // style sets it, otherwise raster sprites would be flooded black).
  IconOpacity := ALayer.Paint.EvalFloat('icon-opacity', Ctx, 1.0);
  if ALayer.Paint.Has('icon-color') then
    IconTint := ALayer.Paint.EvalColor('icon-color', Ctx, TMGLColor.Black).ToColor
  else
    IconTint := clNone;

  if (Text = '') and not HasIcon then
  begin
    Inc(FSymDiag.DropEmptyText);
    Exit;
  end;

  TextColor := ALayer.Paint.EvalColor('text-color', Ctx, TMGLColor.Black);
  // MapLibre default text-halo-color is transparent (styles set it when used).
  HaloColor := ALayer.Paint.EvalColor('text-halo-color', Ctx, TMGLColor.Transparent);
  HaloWidth := ALayer.Paint.EvalFloat('text-halo-width', Ctx, 0.0);
  TextSize := ALayer.Layout.EvalFloat('text-size', Ctx, 16.0);
  // font height in PIXELS (negative): DPI-independent, so labels are exactly
  // text-size px regardless of the display scaling (Font.Size in pt inflates).
  FontPt := Max(1, Round(TextSize * FScale));
  SortKey := ALayer.Layout.EvalFloat('symbol-sort-key', Ctx, 0.0);
  TextPad := Round(ALayer.Layout.EvalFloat('text-padding', Ctx, TEXT_PADDING_DEFAULT) * FScale);
  IconPad := Round(ALayer.Layout.EvalFloat('icon-padding', Ctx, ICON_PADDING_DEFAULT) * FScale);
  TextAllowOverlap := ALayer.Layout.EvalBool('text-allow-overlap', Ctx, False);
  IconAllowOverlap := ALayer.Layout.EvalBool('icon-allow-overlap', Ctx, False);
  TextOptional := ALayer.Layout.EvalBool('text-optional', Ctx, False);
  IconOptional := ALayer.Layout.EvalBool('icon-optional', Ctx, False);
  Spacing := Max(1, Round(ALayer.Layout.EvalFloat('symbol-spacing', Ctx, SYMBOL_SPACING_DEFAULT) * FScale));
  LineHeight := ALayer.Layout.EvalFloat('text-line-height', Ctx, 1.2);  // ems
  JustStr := ALayer.Layout.EvalString('text-justify', Ctx, 'center');
  if SameText(JustStr, 'left') then JustifyVal := 0
  else if SameText(JustStr, 'right') then JustifyVal := 2
  else JustifyVal := 1;
  ParseFontStack(ALayer.Layout.EvalString('text-font', Ctx, ''), FontName, FontStyle);
  LetterExtra := Round(ALayer.Layout.EvalFloat('text-letter-spacing', Ctx, 0.0) * TextSize * FScale);

  Offset := ALayer.Layout.GetFloatArray('text-offset', []);  // in ems
  OffsetX := 0;
  OffsetY := 0;
  if Length(Offset) >= 2 then
  begin
    OffsetX := Round(Offset[0] * TextSize * FScale);
    OffsetY := Round(Offset[1] * TextSize * FScale);
  end;

  // measure text with the right font/size on the canvas (px height)
  if FontName <> '' then ACanvas.Font.Name := FontName;
  ACanvas.Font.Style := FontStyle;
  ACanvas.Font.Height := -FontPt;
  LineH := 0;
  BlockW := 0;
  Lines := nil;
  Sz := Default(TSize);
  if Text <> '' then
  begin
    SetTextCharacterExtra(ACanvas.Handle, LetterExtra);  // measure with spacing
    Sz := ACanvas.TextExtent(Text);
    // MapLibre line spacing = text-size * line-height (em-based). TextExtent.cy
    // includes GDI external leading and over-inflates multi-line gaps, so use the
    // em metric (floored at the glyph cap so single lines never clip).
    LineH := Max(Round(TextSize * FScale), Round(TextSize * LineHeight * FScale));
    Lines := WrapText(ACanvas, Text,
      Max(1, Round(ALayer.Layout.EvalFloat('text-max-width', Ctx, 10.0) * TextSize * FScale)));
    for I := 0 to High(Lines) do
      BlockW := Max(BlockW, ACanvas.TextWidth(Lines[I]));
    SetTextCharacterExtra(ACanvas.Handle, 0);
  end;
  TotalH := Length(Lines) * LineH;

  IconW := 0;
  IconH := 0;
  if HasIcon then
  begin
    IconW := Round(Icon.Width / Icon.PixelRatio * IconScale * FScale);
    IconH := Round(Icon.Height / Icon.PixelRatio * IconScale * FScale);
  end;

  IsLine := SameText(ALayer.Layout.EvalString('symbol-placement', Ctx, 'point'), 'line')
            and (AFeature.Geometry.GeometryType = gtLineString) and (Text <> '');

  if IsLine then
  begin
    // one candidate per spaced anchor along the line (symbol-spacing).
    // Sz.cx = label width: lines shorter than this are not labelled.
    Anchors := LineAnchors(AFeature, AExtent, Spacing, Sz.cx);
    for I := 0 to High(Anchors) do
    begin
      Cand := Default(TSymbolCandidate);
      Cand.LayerIndex := ALayerIndex;
      Cand.SortKey := SortKey;
      Cand.Spacing := Spacing;
      Cand.DedupKey := Text.ToLower;
      Cand.DedupPos := Anchors[I].Pos;
      Cand.HasText := True;
      Cand.TextAllowOverlap := TextAllowOverlap;
      Cand.TextOptional := False;  // a line label with no text makes no sense
      SetLength(Cand.TextOptions, 1);
      Cand.TextOptions[0].Boxes := RotatedBoxes(Anchors[I].Pos, Anchors[I].AngleDeg,
        Sz.cx, LineH, TextPad);
      Cand.TextOptions[0].Draw := MakeRotatedProc(ACanvas, Text, Anchors[I].Pos.X,
        Anchors[I].Pos.Y, FontPt, Anchors[I].AngleDeg, Sz.cx, LetterExtra,
        TextColor, HaloColor, HaloWidth, FontName, FontStyle);
      FCandidates.Add(Cand);
    end;
    Exit;
  end;

  Base := FeatureAnchor(AFeature, AExtent);
  AddPointCandidate;
end;

procedure TMGLRenderer.PlaceAndDrawSymbols;
var
  Arr: TArray<TSymbolCandidate>;
  Ops: TList<TSymDrawOp>;
  Op: TSymDrawOp;
  Idx, I, TextIdx: Integer;
  IconReq, TextReq, IconPlaced, TextPlaced, TextDeduped: Boolean;

  procedure Enqueue(ALayer, AOrder, ASub: Integer; const AProc: TProc);
  var
    O: TSymDrawOp;
  begin
    if not Assigned(AProc) then
      Exit;
    O.Layer := ALayer; O.Order := AOrder; O.Sub := ASub; O.Proc := AProc;
    Ops.Add(O);
  end;

begin
  var LProf := ProfScope('Sym.PlaceAndDraw');
  Arr := FCandidates.ToArray;
  Inc(FSymDiag.Collected, Length(Arr));
  // PLACEMENT PRIORITY: later style layers win collision space first (osm-bright
  // orders poi BEFORE place, yet cities must beat POIs -> higher layer index =
  // higher priority). Within a layer, lower symbol-sort-key wins (MapLibre rule).
  TArray.Sort<TSymbolCandidate>(Arr, TComparer<TSymbolCandidate>.Construct(
    function(const L, R: TSymbolCandidate): Integer
    begin
      Result := R.LayerIndex - L.LayerIndex;        // descending layer
      if Result = 0 then
        Result := CompareValue(L.SortKey, R.SortKey);
    end));

  Ops := TList<TSymDrawOp>.Create;
  try
    for Idx := 0 to High(Arr) do
    begin
      // Icon and text place independently (MapLibre text-optional / icon-optional).
      IconPlaced := Arr[Idx].HasIcon and
        (Arr[Idx].IconAllowOverlap or FGrid.CanPlace([Arr[Idx].IconBox]));

      TextDeduped := Arr[Idx].HasText and (Arr[Idx].DedupKey <> '') and
        not Arr[Idx].TextAllowOverlap and
        DedupTooClose(Arr[Idx].DedupKey, Arr[Idx].DedupPos, Arr[Idx].Spacing);

      TextPlaced := False;
      TextIdx := -1;
      if Arr[Idx].HasText and not TextDeduped then
        for I := 0 to High(Arr[Idx].TextOptions) do
          if Arr[Idx].TextAllowOverlap or FGrid.CanPlace(Arr[Idx].TextOptions[I].Boxes) then
          begin
            TextIdx := I;
            TextPlaced := True;
            Break;
          end;

      // diagnostics: why a candidate's text/icon didn't make it
      if Arr[Idx].HasText then
        if TextDeduped then Inc(FSymDiag.DropDedup)
        else if not TextPlaced then Inc(FSymDiag.DropTextColl);
      if Arr[Idx].HasIcon and not IconPlaced then
        Inc(FSymDiag.DropIconColl);

      // a required part that can't be placed hides the whole symbol
      IconReq := Arr[Idx].HasIcon and not Arr[Idx].IconOptional;
      TextReq := Arr[Idx].HasText and not Arr[Idx].TextOptional;
      if IconReq and not IconPlaced then
      begin
        Inc(FSymDiag.DropRequired);
        Continue;
      end;
      if TextReq and not TextPlaced then
      begin
        Inc(FSymDiag.DropRequired);
        Continue;
      end;
      if not IconReq and not TextReq and not (IconPlaced or TextPlaced) then
        Continue;

      if Arr[Idx].HasIcon and IconPlaced then
      begin
        // *-ignore-placement: the placed part is drawn but not added to the
        // collision index, so it never blocks other symbols.
        if not Arr[Idx].IconIgnorePlacement then
          FGrid.Insert([Arr[Idx].IconBox]);
        Enqueue(Arr[Idx].LayerIndex, Idx, 0, Arr[Idx].IconDraw);
        Inc(FSymDiag.PlacedIcon);
      end;
      if TextPlaced then
      begin
        if not Arr[Idx].TextIgnorePlacement then
          FGrid.Insert(Arr[Idx].TextOptions[TextIdx].Boxes);
        Enqueue(Arr[Idx].LayerIndex, Idx, 1, Arr[Idx].TextOptions[TextIdx].Draw);
        Inc(FSymDiag.PlacedText);
        if Arr[Idx].DedupKey <> '' then
          RecordPlacement(Arr[Idx].DedupKey, Arr[Idx].DedupPos);
      end;
    end;

    // PAINT ORDER: ascending layer (so place draws on top of poi), then placement
    // order, then icon before text. Decoupled from placement priority above.
    Ops.Sort(TComparer<TSymDrawOp>.Construct(
      function(const L, R: TSymDrawOp): Integer
      begin
        Result := L.Layer - R.Layer;
        if Result = 0 then Result := L.Order - R.Order;
        if Result = 0 then Result := L.Sub - R.Sub;
      end));
    for Op in Ops do
      Op.Proc();
  finally
    Ops.Free;
  end;
end;

end.
