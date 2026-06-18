unit PBFMap.Render.Surface;

{
  PBFMapRenderer - drawing-backend abstraction

  TPBFDrawSurface decouples the renderer's geometry drawing from the underlying
  raster API. The BASE class IS the GDI+ backend (the original behaviour). A
  subclass (e.g. TPBFSkiaSurface in PBFMap.Render.Surface.Skia) overrides only
  the primitives it reimplements; anything left un-overridden falls back to the
  GDI+ base, so the backend can be migrated one primitive at a time.

  The renderer talks to a TPBFDrawSurface and never references a concrete
  backend, so there are no compile-time conditionals in the renderer body. The
  Skia backend lives in a separate unit that self-registers a factory; a host
  that does not include that unit has no Skia (sk4d.dll) dependency at all.

  Frame lifecycle:
    BeginFrame(w,h)
    FillRect / FillRings / StrokeLines / DrawCircle ...   (geometry)
    FlushGeometry
    <host draws GDI symbols on TextCanvas>
    EndFrame

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  Winapi.Windows, Winapi.GDIPAPI, Winapi.GDIPOBJ,
  System.SysUtils, System.Types, System.Math, System.Diagnostics,
  Vcl.Graphics,
  PBFMap.Color, PBFMap.Sprite;

type
  /// <summary>Profiling sink: (function name, start-ticks) -> accumulate ms.</summary>
  TPBFProfileProc = reference to procedure(const AName: string; AStartTicks: Int64);

  /// <summary>
  ///   GDI+ drawing backend (and base for other backends). Subclasses override
  ///   individual primitives; un-overridden ones keep the GDI+ behaviour.
  /// </summary>
  TPBFDrawSurface = class
  protected
    FCanvas: TCanvas;             // final target (the host's canvas)
    FAntialias: Boolean;
    FGP: TGPGraphics;             // GDI+ surface bound to FCanvas for this frame
    FGPPts: array of TGPPoint;    // reused point buffer (grow-only)
    FLinePen: TGPPen;             // persistent pen/brush reused across features
    FFillBrush: TGPSolidBrush;
    FFillPen: TGPPen;
    FProfile: TPBFProfileProc;
    procedure Prof(const AName: string; AStart: Int64);
    function Ticks: Int64;  // real start-tick when profiling, else 0 (no overhead)
  public
    constructor Create(ACanvas: TCanvas; AAntialias: Boolean); virtual;
    destructor Destroy; override;

    { Capability. The host queries this and falls back to a solid fill when a
      backend cannot honour GDI-only pattern stamping (clip-path + AlphaBlend on
      a DC). Base GDI+ supports it; gradient strokes need NO capability because
      they are drawn segment-by-segment via StrokeLines on any backend. }
    function SupportsPattern: Boolean; virtual;

    { Frame lifecycle. AWidth/AHeight are the scene pixel size (used by backends
      that render off-screen, e.g. Skia). }
    procedure BeginFrame(AWidth, AHeight: Integer); virtual;
    procedure FlushGeometry; virtual;
    procedure EndFrame; virtual;

    { Canvas the host draws GDI symbols on AFTER FlushGeometry (and measures text
      on during collection). Base: the target canvas itself. }
    function TextCanvas: TCanvas; virtual;
    { Canvas for GDI-only pattern stamping (only used when SupportsPattern). }
    function PatternCanvas: TCanvas; virtual;

    { Geometry primitives (pixel-space, absolute scene coordinates). }
    procedure FillRect(const ARect: TRect; const AColor: TMGLColor); virtual;
    procedure FillRings(const ARings: TArray<TArray<TPoint>>; const AFill: TMGLColor;
      AHasOutline: Boolean; const AOutline: TMGLColor); virtual;
    procedure StrokeLines(const AParts: TArray<TArray<TPoint>>; const AColor: TMGLColor;
      AWidth: Integer; const ADashUnits: TArray<Double>;
      ACap: TLineCap; AJoin: TLineJoin); virtual;
    procedure DrawCircle(ACx, ACy: Integer; ARadius, AStrokeWidth: Single;
      const AFill: TMGLColor; AHasStroke: Boolean; const AStroke: TMGLColor;
      ABlurFrac: Double); virtual;

    { Symbol primitives. The host MEASURES text on TextCanvas (GDI metrics) during
      collection, then calls these to DRAW during placement. Base = GDI (TextOut +
      8-offset halo; sprite AlphaBlend); a backend may override (e.g. Skia: glyphs
      with a real stroke halo in one pass). }
    procedure DrawTextBlock(const ALines: TArray<string>; ABX, ABY, ABlockW, ALineH,
      AJustify, ALetterExtra, APxHeight: Integer; const AFontName: string;
      AFontStyle: TFontStyles; const ATextColor, AHaloColor: TMGLColor;
      AHaloWidth: Double); virtual;
    procedure DrawRotatedText(const AText: string; ACx, ACy, APxHeight: Integer;
      AAngleDeg: Double; ATextW, ALetterExtra: Integer; const AFontName: string;
      AFontStyle: TFontStyles; const ATextColor, AHaloColor: TMGLColor;
      AHaloWidth: Double); virtual;
    procedure DrawIcon(ASprite: TMGLSprite; const AName: string; ACx, ACy: Integer;
      AScale, ARotateDeg, AOpacity: Double; ATint: TColor); virtual;
    { fill-pattern: clip to the rings and tile the sprite icon across their bbox. }
    procedure FillPattern(ASprite: TMGLSprite; const ARings: TArray<TArray<TPoint>>;
      const AName: string); virtual;

    { Text MEASUREMENT — MUST share the backend of DrawTextBlock so the symbol
      placement boxes match the painted glyph advances (GDI base measures via the
      canvas; the Skia backend overrides to use the same ISkFont it draws with). }
    function MeasureTextWidth(const AText: string; APxHeight, ALetterExtra: Integer;
      const AFontName: string; AFontStyle: TFontStyles): Integer; virtual;
    function MeasureTextHeight(APxHeight: Integer; const AFontName: string;
      AFontStyle: TFontStyles): Integer; virtual;

    property Antialias: Boolean read FAntialias;
    property ProfileHook: TPBFProfileProc read FProfile write FProfile;
  end;

  TPBFSurfaceFactory = function(ACanvas: TCanvas; AAntialias: Boolean): TPBFDrawSurface;

{ TMGLColor -> GDI+ ARGB. }
function GPColor(const C: TMGLColor): ARGB;

{ Returns a Skia surface when AUseSkia and a Skia backend has registered itself
  (by the host including PBFMap.Render.Surface.Skia); otherwise a GDI+ surface. }
function CreateDrawSurface(AUseSkia: Boolean; ACanvas: TCanvas;
  AAntialias: Boolean): TPBFDrawSurface;

var
  { Set by PBFMap.Render.Surface.Skia's initialization when that unit is linked. }
  GPBFSkiaSurfaceFactory: TPBFSurfaceFactory = nil;

implementation

function GPColor(const C: TMGLColor): ARGB;
begin
  Result := MakeColor(C.AlphaByte, EnsureRange(Round(C.R * 255), 0, 255),
    EnsureRange(Round(C.G * 255), 0, 255), EnsureRange(Round(C.B * 255), 0, 255));
end;

function CreateDrawSurface(AUseSkia: Boolean; ACanvas: TCanvas;
  AAntialias: Boolean): TPBFDrawSurface;
begin
  if AUseSkia and Assigned(GPBFSkiaSurfaceFactory) then
    Result := GPBFSkiaSurfaceFactory(ACanvas, AAntialias)
  else
    Result := TPBFDrawSurface.Create(ACanvas, AAntialias);
end;

{ TPBFDrawSurface }

constructor TPBFDrawSurface.Create(ACanvas: TCanvas; AAntialias: Boolean);
begin
  inherited Create;
  FCanvas := ACanvas;
  FAntialias := AAntialias;
  FLinePen := TGPPen.Create(MakeColor(0, 0, 0, 0), 1);
  FFillBrush := TGPSolidBrush.Create(MakeColor(0, 0, 0, 0));
  FFillPen := TGPPen.Create(MakeColor(0, 0, 0, 0), 1);
end;

destructor TPBFDrawSurface.Destroy;
begin
  FreeAndNil(FGP);
  FLinePen.Free;
  FFillBrush.Free;
  FFillPen.Free;
  inherited;
end;

procedure TPBFDrawSurface.Prof(const AName: string; AStart: Int64);
begin
  if Assigned(FProfile) then
    FProfile(AName, AStart);
end;

function TPBFDrawSurface.Ticks: Int64;
begin
  if Assigned(FProfile) then
    Result := TStopwatch.GetTimeStamp
  else
    Result := 0;
end;

function TPBFDrawSurface.SupportsPattern: Boolean;
begin
  Result := True;
end;

procedure TPBFDrawSurface.BeginFrame(AWidth, AHeight: Integer);
begin
  // One GDI+ surface for the whole frame: TGPGraphics.FromHDC is costly, so it
  // is created once instead of per feature.
  FGP := TGPGraphics.Create(FCanvas.Handle);
  if FAntialias then
    FGP.SetSmoothingMode(SmoothingModeAntiAlias)
  else
    FGP.SetSmoothingMode(SmoothingModeHighSpeed);
  FGP.SetPixelOffsetMode(PixelOffsetModeHalf);
end;

procedure TPBFDrawSurface.FlushGeometry;
begin
  if Assigned(FGP) then
    FGP.Flush(FlushIntentionSync);
end;

procedure TPBFDrawSurface.EndFrame;
begin
  if Assigned(FGP) then
    FGP.Flush(FlushIntentionSync);
  FreeAndNil(FGP);
end;

function TPBFDrawSurface.TextCanvas: TCanvas;
begin
  Result := FCanvas;   // GDI text draws straight on the target
end;

function TPBFDrawSurface.PatternCanvas: TCanvas;
begin
  Result := FCanvas;
end;

procedure TPBFDrawSurface.FillRect(const ARect: TRect; const AColor: TMGLColor);
begin
  if AColor.A <= 0 then
    Exit;
  FCanvas.Brush.Color := AColor.ToColor;
  FCanvas.Brush.Style := bsSolid;
  FCanvas.FillRect(ARect);
end;

procedure TPBFDrawSurface.FillRings(const ARings: TArray<TArray<TPoint>>;
  const AFill: TMGLColor; AHasOutline: Boolean; const AOutline: TMGLColor);
var
  Path: TGPGraphicsPath;
  Ring: TArray<TPoint>;
  I: Integer;
  LT, LT2: Int64;
begin
  if Length(ARings) = 0 then
    Exit;
  LT := Ticks; LT2 := 0;
  // alpha + holes (FillModeAlternate) + anti-aliasing, no temp buffer.
  Path := TGPGraphicsPath.Create(FillModeAlternate);
  try
    for Ring in ARings do
    begin
      if Length(Ring) < 3 then
        Continue;
      if Length(FGPPts) < Length(Ring) then
        SetLength(FGPPts, Length(Ring));
      for I := 0 to High(Ring) do
        FGPPts[I] := MakePoint(Ring[I].X, Ring[I].Y);
      Path.StartFigure;
      Path.AddLines(PGPPoint(@FGPPts[0]), Length(Ring));
      Path.CloseFigure;
    end;
    Prof('FR.buildPath', LT); LT2 := Ticks;
    FFillBrush.SetColor(GPColor(AFill));   // persistent brush, only colour updated
    FGP.FillPath(FFillBrush, Path);
    Prof('FR.FillPath', LT2); LT2 := Ticks;
    if AHasOutline then
    begin
      FFillPen.SetColor(GPColor(AOutline));
      FFillPen.SetWidth(1);
      FGP.DrawPath(FFillPen, Path);
      Prof('FR.DrawPath', LT2);
    end;
  finally
    Path.Free;
    Prof('FillRings', LT);
  end;
end;

procedure TPBFDrawSurface.StrokeLines(const AParts: TArray<TArray<TPoint>>;
  const AColor: TMGLColor; AWidth: Integer; const ADashUnits: TArray<Double>;
  ACap: TLineCap; AJoin: TLineJoin);
var
  Pen: TGPPen;
  Part: TArray<TPoint>;
  Dashes: array of Single;
  I: Integer;
  LT, LT2: Int64;
begin
  if AWidth < 1 then
    AWidth := 1;
  LT := Ticks; LT2 := 0;
  Pen := FLinePen;  // persistent: only update its properties (no per-feature Create)
  Pen.SetColor(GPColor(AColor));
  Pen.SetWidth(AWidth);
  Pen.SetLineJoin(AJoin);
  Pen.SetStartCap(ACap);
  Pen.SetEndCap(ACap);
  if Length(ADashUnits) > 0 then
  begin
    // GDI+ dash lengths are in pen-width units (= line-width units)
    SetLength(Dashes, Length(ADashUnits));
    for I := 0 to High(ADashUnits) do
      Dashes[I] := Max(0.1, ADashUnits[I]);
    Pen.SetDashPattern(PSingle(@Dashes[0]), Length(Dashes));
  end
  else
    Pen.SetDashStyle(DashStyleSolid);  // reset any dash from a previous call
  Prof('SL.penSetup', LT);
  for Part in AParts do
    if Length(Part) >= 2 then
    begin
      LT2 := Ticks;
      if Length(FGPPts) < Length(Part) then
        SetLength(FGPPts, Length(Part));
      for I := 0 to High(Part) do
        FGPPts[I] := MakePoint(Part[I].X, Part[I].Y);
      FGP.DrawLines(Pen, PGPPoint(@FGPPts[0]), Length(Part));
      Prof('SL.DrawLines', LT2);
    end;
  Prof('StrokeLines', LT);
end;

procedure TPBFDrawSurface.DrawCircle(ACx, ACy: Integer; ARadius, AStrokeWidth: Single;
  const AFill: TMGLColor; AHasStroke: Boolean; const AStroke: TMGLColor;
  ABlurFrac: Double);
var
  D, BD: Single;
  BlurCol: TMGLColor;
  BlurBrush: TGPSolidBrush;
begin
  D := ARadius * 2;
  if ABlurFrac > 0.01 then
  begin
    BD := (ARadius + ABlurFrac * ARadius) * 2;
    BlurCol := AFill;
    BlurCol.A := BlurCol.A * 0.45;  // faded halo approximating the blur
    BlurBrush := TGPSolidBrush.Create(GPColor(BlurCol));
    try
      FGP.FillEllipse(BlurBrush, ACx - BD / 2, ACy - BD / 2, BD, BD);
    finally
      BlurBrush.Free;
    end;
  end;
  FFillBrush.SetColor(GPColor(AFill));
  FGP.FillEllipse(FFillBrush, ACx - ARadius, ACy - ARadius, D, D);
  if AHasStroke then
  begin
    FLinePen.SetColor(GPColor(AStroke));
    FLinePen.SetWidth(Max(1, AStrokeWidth));
    FLinePen.SetDashStyle(DashStyleSolid);
    FGP.DrawEllipse(FLinePen, ACx - ARadius, ACy - ARadius, D, D);
  end;
end;

procedure TPBFDrawSurface.DrawTextBlock(const ALines: TArray<string>;
  ABX, ABY, ABlockW, ALineH, AJustify, ALetterExtra, APxHeight: Integer;
  const AFontName: string; AFontStyle: TFontStyles;
  const ATextColor, AHaloColor: TMGLColor; AHaloWidth: Double);
var
  I, LineX, LineY, DX, DY, Slack: Integer;
  S: string;
begin
  if Length(ALines) = 0 then
    Exit;
  if AFontName <> '' then FCanvas.Font.Name := AFontName;
  FCanvas.Font.Style := AFontStyle;
  FCanvas.Font.Height := -APxHeight;
  FCanvas.Brush.Style := bsClear;
  FCanvas.Font.Quality := fqAntialiased;  // grayscale AA, composites on any bg
  SetTextCharacterExtra(FCanvas.Handle, ALetterExtra);  // text-letter-spacing
  for I := 0 to High(ALines) do
  begin
    S := ALines[I];
    Slack := ABlockW - FCanvas.TextWidth(S);
    case AJustify of
      0: LineX := ABX;                 // left
      2: LineX := ABX + Slack;         // right
    else
      LineX := ABX + Slack div 2;      // center (default)
    end;
    LineY := ABY + I * ALineH;
    if AHaloWidth > 0 then
    begin
      FCanvas.Font.Color := AHaloColor.ToColor;
      for DX := -1 to 1 do
        for DY := -1 to 1 do
          if (DX <> 0) or (DY <> 0) then
            FCanvas.TextOut(LineX + DX, LineY + DY, S);
    end;
    FCanvas.Font.Color := ATextColor.ToColor;
    FCanvas.TextOut(LineX, LineY, S);
  end;
  SetTextCharacterExtra(FCanvas.Handle, 0);  // restore
end;

procedure TPBFDrawSurface.DrawRotatedText(const AText: string;
  ACx, ACy, APxHeight: Integer; AAngleDeg: Double; ATextW, ALetterExtra: Integer;
  const AFontName: string; AFontStyle: TFontStyles;
  const ATextColor, AHaloColor: TMGLColor; AHaloWidth: Double);
var
  LF: TLogFont;
  LFont, LOld: HFONT;
  DC: HDC;
  Rad, HalfW: Double;
  StartX, StartY, DX, DY: Integer;
begin
  if AFontName <> '' then FCanvas.Font.Name := AFontName;
  FCanvas.Font.Style := AFontStyle;
  FCanvas.Font.Height := -APxHeight;
  DC := FCanvas.Handle;
  // Build a rotated copy of the current font (escapement in tenths of degree).
  GetObject(FCanvas.Font.Handle, SizeOf(LF), @LF);
  LF.lfEscapement := Round(AAngleDeg * 10);
  LF.lfOrientation := LF.lfEscapement;
  LF.lfQuality := ANTIALIASED_QUALITY;  // smooth rotated street labels
  LFont := CreateFontIndirect(LF);
  LOld := SelectObject(DC, LFont);
  SetTextCharacterExtra(DC, ALetterExtra);  // text-letter-spacing
  try
    Rad := DegToRad(AAngleDeg);
    HalfW := ATextW / 2;
    // move baseline start back by half the width along the text direction
    StartX := ACx - Round(Cos(Rad) * HalfW);
    StartY := ACy + Round(Sin(Rad) * HalfW);
    SetBkMode(DC, TRANSPARENT);
    if AHaloWidth > 0 then
    begin
      SetTextColor(DC, AHaloColor.ToColor);
      for DX := -1 to 1 do
        for DY := -1 to 1 do
          if (DX <> 0) or (DY <> 0) then
            Winapi.Windows.TextOut(DC, StartX + DX, StartY + DY, PChar(AText), Length(AText));
    end;
    SetTextColor(DC, ATextColor.ToColor);
    Winapi.Windows.TextOut(DC, StartX, StartY, PChar(AText), Length(AText));
  finally
    SetTextCharacterExtra(DC, 0);
    SelectObject(DC, LOld);
    DeleteObject(LFont);
  end;
end;

procedure TPBFDrawSurface.DrawIcon(ASprite: TMGLSprite; const AName: string;
  ACx, ACy: Integer; AScale, ARotateDeg, AOpacity: Double; ATint: TColor);
var
  LDrawn: TRect;
begin
  if Assigned(ASprite) then
    ASprite.DrawIconCentered(FCanvas, AName, ACx, ACy, LDrawn, AScale,
      ARotateDeg, AOpacity, ATint);
end;

function TPBFDrawSurface.MeasureTextWidth(const AText: string; APxHeight, ALetterExtra: Integer;
  const AFontName: string; AFontStyle: TFontStyles): Integer;
begin
  if AFontName <> '' then FCanvas.Font.Name := AFontName;
  FCanvas.Font.Style := AFontStyle;
  FCanvas.Font.Height := -APxHeight;
  SetTextCharacterExtra(FCanvas.Handle, ALetterExtra);
  Result := FCanvas.TextWidth(AText);
  SetTextCharacterExtra(FCanvas.Handle, 0);
end;

function TPBFDrawSurface.MeasureTextHeight(APxHeight: Integer;
  const AFontName: string; AFontStyle: TFontStyles): Integer;
begin
  if AFontName <> '' then FCanvas.Font.Name := AFontName;
  FCanvas.Font.Style := AFontStyle;
  FCanvas.Font.Height := -APxHeight;
  Result := FCanvas.TextHeight('Mg');
end;

procedure TPBFDrawSurface.FillPattern(ASprite: TMGLSprite;
  const ARings: TArray<TArray<TPoint>>; const AName: string);
var
  DC: HDC;
  Ring: TArray<TPoint>;
  P: TPoint;
  Icon: TMGLSpriteIcon;
  Box: TRect;
  X, Y, IW, IH, I: Integer;
  Blend: TBlendFunction;
begin
  if (Length(ARings) = 0) or not Assigned(ASprite) or
     not ASprite.TryGetIcon(AName, Icon) then
    Exit;
  IW := Round(Icon.Width / Icon.PixelRatio);
  IH := Round(Icon.Height / Icon.PixelRatio);
  if (IW <= 0) or (IH <= 0) then
    Exit;
  // Clip to the polygon path, then tile the sprite across its bbox (GDI+AlphaBlend).
  DC := FCanvas.Handle;
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
  try
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
        Winapi.Windows.AlphaBlend(DC, X, Y, IW, IH, ASprite.Bitmap.Canvas.Handle,
          Icon.X, Icon.Y, Icon.Width, Icon.Height, Blend);
        Inc(X, IW);
      end;
      Inc(Y, IH);
    end;
  finally
    SelectClipRgn(DC, 0);  // always drop the clip, even if AlphaBlend raises
  end;
end;

end.
