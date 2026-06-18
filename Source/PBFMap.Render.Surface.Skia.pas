unit PBFMap.Render.Surface.Skia;

{
  PBFMapRenderer - Skia drawing backend

  TPBFSkiaSurface overrides the GDI+ primitives of TPBFDrawSurface with Skia
  (System.Skia). Geometry is drawn to an off-screen Skia raster surface; on
  FlushGeometry the pixels are copied into a 32-bit TBitmap, the host then draws
  the GDI symbols (text/icons) on top of that bitmap, and EndFrame blits it to
  the target canvas. Text/icons are NOT (yet) ported to Skia and keep using GDI
  via TextCanvas -> future primitives (DrawText, DrawIcon) can be added here and
  overridden to migrate them too.

  Including this unit in a project auto-registers the Skia factory (initialization
  section) so CreateDrawSurface(True, ...) returns a Skia surface. Projects that
  do not include this unit have no sk4d.dll dependency.

  MIT License
  Copyright (c) 2025 amancini
}

interface

implementation

uses
  Winapi.Windows, Winapi.GDIPAPI, Winapi.GDIPOBJ,
  System.SysUtils, System.Types, System.Math, System.UITypes,
  Vcl.Graphics, Vcl.Skia,
  System.Skia,
  PBFMap.Color, PBFMap.Render.Surface, PBFMap.Sprite;

type
  TPBFSkiaSurface = class(TPBFDrawSurface)
  private
    FW, FH: Integer;
    FSurface: ISkSurface;
    FSkCanvas: ISkCanvas;
    FPixmap: ISkPixmap;
    FBmp: TBitmap;            // raster read-back target + final blit source
    FSkFill: ISkPaint;
    FSkStroke: ISkPaint;
    FSkText: ISkPaint;        // text fill
    FSkHalo: ISkPaint;        // text halo (stroke)
    { cached font (rebuilt only when name/size/style change) }
    FFont: ISkFont;
    FFontName: string;
    FFontSize: Integer;
    FFontStyle: TFontStyles;
    { cached Skia image of the sprite atlas (built once per sprite) }
    FAtlasImg: ISkImage;
    FAtlasSprite: TMGLSprite;
    function SkCol(const C: TMGLColor): TAlphaColor;
    function SkCap(ACap: TLineCap): TSkStrokeCap;
    function SkJoin(AJoin: TLineJoin): TSkStrokeJoin;
    function PathFromRings(const ARings: TArray<TArray<TPoint>>): ISkPath;
    function GetFont(const AName: string; APxHeight: Integer;
      AStyle: TFontStyles): ISkFont;
    procedure ReadbackRaster;   // copy the Skia raster into FBmp
  public
    constructor Create(ACanvas: TCanvas; AAntialias: Boolean); override;
    destructor Destroy; override;
    function SupportsPattern: Boolean; override;
    procedure BeginFrame(AWidth, AHeight: Integer); override;
    procedure FlushGeometry; override;
    procedure EndFrame; override;
    function TextCanvas: TCanvas; override;
    function PatternCanvas: TCanvas; override;
    procedure FillRect(const ARect: TRect; const AColor: TMGLColor); override;
    procedure FillRings(const ARings: TArray<TArray<TPoint>>; const AFill: TMGLColor;
      AHasOutline: Boolean; const AOutline: TMGLColor); override;
    procedure StrokeLines(const AParts: TArray<TArray<TPoint>>; const AColor: TMGLColor;
      AWidth: Integer; const ADashUnits: TArray<Double>;
      ACap: TLineCap; AJoin: TLineJoin); override;
    procedure DrawCircle(ACx, ACy: Integer; ARadius, AStrokeWidth: Single;
      const AFill: TMGLColor; AHasStroke: Boolean; const AStroke: TMGLColor;
      ABlurFrac: Double); override;
    procedure DrawTextBlock(const ALines: TArray<string>; ABX, ABY, ABlockW, ALineH,
      AJustify, ALetterExtra, APxHeight: Integer; const AFontName: string;
      AFontStyle: TFontStyles; const ATextColor, AHaloColor: TMGLColor;
      AHaloWidth: Double); override;
    procedure DrawRotatedText(const AText: string; ACx, ACy, APxHeight: Integer;
      AAngleDeg: Double; ATextW, ALetterExtra: Integer; const AFontName: string;
      AFontStyle: TFontStyles; const ATextColor, AHaloColor: TMGLColor;
      AHaloWidth: Double); override;
    procedure DrawIcon(ASprite: TMGLSprite; const AName: string; ACx, ACy: Integer;
      AScale, ARotateDeg, AOpacity: Double; ATint: TColor); override;
    function MeasureTextWidth(const AText: string; APxHeight, ALetterExtra: Integer;
      const AFontName: string; AFontStyle: TFontStyles): Integer; override;
    function MeasureTextHeight(APxHeight: Integer; const AFontName: string;
      AFontStyle: TFontStyles): Integer; override;
  end;

{ TPBFSkiaSurface }

constructor TPBFSkiaSurface.Create(ACanvas: TCanvas; AAntialias: Boolean);
begin
  inherited Create(ACanvas, AAntialias);
  FBmp := TBitmap.Create;
  FSkFill := TSkPaint.Create;
  FSkFill.Style := TSkPaintStyle.Fill;
  FSkStroke := TSkPaint.Create;
  FSkStroke.Style := TSkPaintStyle.Stroke;
  FSkFill.AntiAlias := AAntialias;
  FSkStroke.AntiAlias := AAntialias;
  FSkText := TSkPaint.Create;
  FSkText.Style := TSkPaintStyle.Fill;
  FSkText.AntiAlias := True;          // text always AA
  FSkHalo := TSkPaint.Create;
  FSkHalo.Style := TSkPaintStyle.Stroke;
  FSkHalo.AntiAlias := True;
  FSkHalo.StrokeJoin := TSkStrokeJoin.Round;  // smooth halo corners
end;

destructor TPBFSkiaSurface.Destroy;
begin
  FBmp.Free;
  inherited;
end;

function TPBFSkiaSurface.SupportsPattern: Boolean;
begin
  Result := False;   // fill/line pattern stamping is GDI-only -> host uses solid
end;

function TPBFSkiaSurface.SkCol(const C: TMGLColor): TAlphaColor;  // $AARRGGBB
begin
  Result := (Cardinal(C.AlphaByte) shl 24) or
            (Cardinal(EnsureRange(Round(C.R * 255), 0, 255)) shl 16) or
            (Cardinal(EnsureRange(Round(C.G * 255), 0, 255)) shl 8) or
             Cardinal(EnsureRange(Round(C.B * 255), 0, 255));
end;

function TPBFSkiaSurface.SkCap(ACap: TLineCap): TSkStrokeCap;
begin
  if ACap = LineCapSquare then Result := TSkStrokeCap.Square
  else if ACap = LineCapFlat then Result := TSkStrokeCap.Butt
  else Result := TSkStrokeCap.Round;
end;

function TPBFSkiaSurface.SkJoin(AJoin: TLineJoin): TSkStrokeJoin;
begin
  if AJoin = LineJoinBevel then Result := TSkStrokeJoin.Bevel
  else if AJoin = LineJoinMiter then Result := TSkStrokeJoin.Miter
  else Result := TSkStrokeJoin.Round;
end;

function TPBFSkiaSurface.PathFromRings(
  const ARings: TArray<TArray<TPoint>>): ISkPath;
var
  PB: ISkPathBuilder;
  Ring: TArray<TPoint>;
  I: Integer;
begin
  PB := TSkPathBuilder.Create;
  PB.FillType := TSkPathFillType.EvenOdd;
  for Ring in ARings do
  begin
    if Length(Ring) < 3 then Continue;
    PB.MoveTo(Ring[0].X, Ring[0].Y);
    for I := 1 to High(Ring) do
      PB.LineTo(Ring[I].X, Ring[I].Y);
    PB.Close;
  end;
  Result := PB.Detach;
end;

procedure TPBFSkiaSurface.BeginFrame(AWidth, AHeight: Integer);
begin
  FW := Max(1, AWidth);
  FH := Max(1, AHeight);
  FSurface := TSkSurface.MakeRaster(FW, FH);
  FSkCanvas := FSurface.Canvas;
  FPixmap := FSurface.PeekPixels;
  // Start from the SAME opaque base the GDI+ backend draws onto: the host's
  // canvas is prefilled (white) and the background layer paints over it. Clearing
  // to opaque white keeps every pixel alpha=255, so the readback RGB is exact
  // (no premultiplied darkening) and the opaque blit matches GDI+ pixel for pixel.
  FSkCanvas.Clear(TAlphaColors.White);
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(FW, FH);
end;

procedure TPBFSkiaSurface.ReadbackRaster;
var
  I, LStride: Integer;
  Src: PByte;
begin
  if FPixmap = nil then
    Exit;
  // Copy the Skia raster (top-down) into the bitmap's bottom-up DIB rows.
  LStride := FW * 4;
  Src := FPixmap.Pixels;
  for I := 0 to FH - 1 do
    Move(Src[I * FPixmap.RowBytes], FBmp.ScanLine[I]^, LStride);
end;

procedure TPBFSkiaSurface.FlushGeometry;
begin
  // No-op: unlike GDI (which flushes to the DC so GDI text can draw on top), the
  // Skia backend draws text/icons on the SAME raster too, so the read-back is
  // deferred to EndFrame (after PlaceAndDrawSymbols).
end;

procedure TPBFSkiaSurface.EndFrame;
begin
  ReadbackRaster;        // raster now holds geometry + symbols
  // Opaque base (cleared to white in BeginFrame) -> every pixel alpha=255 ->
  // opaque copy reproduces the output exactly.
  FBmp.AlphaFormat := afIgnored;
  FCanvas.Draw(0, 0, FBmp);
  FSkCanvas := nil;
  FSurface := nil;
  FPixmap := nil;
end;

function TPBFSkiaSurface.GetFont(const AName: string; APxHeight: Integer;
  AStyle: TFontStyles): ISkFont;
var
  Tf: ISkTypeface;
  FS: TSkFontStyle;
begin
  if (FFont <> nil) and (AName = FFontName) and (APxHeight = FFontSize) and
     (AStyle = FFontStyle) then
    Exit(FFont);
  if (fsBold in AStyle) and (fsItalic in AStyle) then FS := TSkFontStyle.BoldItalic
  else if fsBold in AStyle then FS := TSkFontStyle.Bold
  else if fsItalic in AStyle then FS := TSkFontStyle.Italic
  else FS := TSkFontStyle.Normal;
  if AName <> '' then
    Tf := TSkTypeface.MakeFromName(AName, FS)
  else
    Tf := TSkTypeface.MakeFromName('Segoe UI', FS);
  FFont := TSkFont.Create(Tf, APxHeight);
  FFontName := AName; FFontSize := APxHeight; FFontStyle := AStyle;
  Result := FFont;
end;

function TPBFSkiaSurface.TextCanvas: TCanvas;
begin
  Result := FBmp.Canvas;   // symbols draw on the bitmap holding the geometry
end;

function TPBFSkiaSurface.PatternCanvas: TCanvas;
begin
  Result := FBmp.Canvas;
end;

procedure TPBFSkiaSurface.FillRect(const ARect: TRect; const AColor: TMGLColor);
begin
  if AColor.A <= 0 then
    Exit;
  FSkFill.Color := SkCol(AColor);
  FSkCanvas.DrawRect(TRectF.Create(ARect.Left, ARect.Top, ARect.Right, ARect.Bottom),
    FSkFill);
end;

procedure TPBFSkiaSurface.FillRings(const ARings: TArray<TArray<TPoint>>;
  const AFill: TMGLColor; AHasOutline: Boolean; const AOutline: TMGLColor);
var
  LPath: ISkPath;
begin
  if Length(ARings) = 0 then
    Exit;
  LPath := PathFromRings(ARings);
  FSkFill.Color := SkCol(AFill);
  FSkCanvas.DrawPath(LPath, FSkFill);
  if AHasOutline then
  begin
    FSkStroke.Color := SkCol(AOutline);
    FSkStroke.StrokeWidth := 1;
    FSkStroke.PathEffect := nil;
    FSkCanvas.DrawPath(LPath, FSkStroke);
  end;
end;

procedure TPBFSkiaSurface.StrokeLines(const AParts: TArray<TArray<TPoint>>;
  const AColor: TMGLColor; AWidth: Integer; const ADashUnits: TArray<Double>;
  ACap: TLineCap; AJoin: TLineJoin);
var
  Part: TArray<TPoint>;
  PB: ISkPathBuilder;
  Iv: TArray<Single>;
  I: Integer;
begin
  if AWidth < 1 then
    AWidth := 1;
  FSkStroke.Color := SkCol(AColor);
  FSkStroke.StrokeWidth := AWidth;
  FSkStroke.StrokeCap := SkCap(ACap);
  FSkStroke.StrokeJoin := SkJoin(AJoin);
  if Length(ADashUnits) > 0 then
  begin
    SetLength(Iv, Length(ADashUnits));
    for I := 0 to High(ADashUnits) do
      Iv[I] := Max(0.1, ADashUnits[I]) * AWidth;  // Skia dash = absolute px
    FSkStroke.PathEffect := TSkPathEffect.MakeDash(Iv, 0);
  end
  else
    FSkStroke.PathEffect := nil;
  for Part in AParts do
    if Length(Part) >= 2 then
    begin
      PB := TSkPathBuilder.Create;
      PB.MoveTo(Part[0].X, Part[0].Y);
      for I := 1 to High(Part) do
        PB.LineTo(Part[I].X, Part[I].Y);
      FSkCanvas.DrawPath(PB.Detach, FSkStroke);
    end;
end;

procedure TPBFSkiaSurface.DrawCircle(ACx, ACy: Integer; ARadius, AStrokeWidth: Single;
  const AFill: TMGLColor; AHasStroke: Boolean; const AStroke: TMGLColor;
  ABlurFrac: Double);
var
  BD: Single;
  BlurCol: TMGLColor;
begin
  if ABlurFrac > 0.01 then
  begin
    BD := (ARadius + ABlurFrac * ARadius) * 2;
    BlurCol := AFill;
    BlurCol.A := BlurCol.A * 0.45;
    FSkFill.Color := SkCol(BlurCol);
    FSkCanvas.DrawOval(TRectF.Create(ACx - BD / 2, ACy - BD / 2,
      ACx + BD / 2, ACy + BD / 2), FSkFill);
  end;
  FSkFill.Color := SkCol(AFill);
  FSkCanvas.DrawOval(TRectF.Create(ACx - ARadius, ACy - ARadius,
    ACx + ARadius, ACy + ARadius), FSkFill);
  if AHasStroke then
  begin
    FSkStroke.Color := SkCol(AStroke);
    FSkStroke.StrokeWidth := Max(1, AStrokeWidth);
    FSkStroke.PathEffect := nil;
    FSkCanvas.DrawOval(TRectF.Create(ACx - ARadius, ACy - ARadius,
      ACx + ARadius, ACy + ARadius), FSkStroke);
  end;
end;

procedure TPBFSkiaSurface.DrawTextBlock(const ALines: TArray<string>;
  ABX, ABY, ABlockW, ALineH, AJustify, ALetterExtra, APxHeight: Integer;
  const AFontName: string; AFontStyle: TFontStyles;
  const ATextColor, AHaloColor: TMGLColor; AHaloWidth: Double);
var
  Font: ISkFont;
  M: TSkFontMetrics;
  I, LineX, Slack: Integer;
  BaseY, W: Single;
  S: string;
begin
  if Length(ALines) = 0 then
    Exit;
  Font := GetFont(AFontName, APxHeight, AFontStyle);
  Font.GetMetrics(M);
  FSkText.Color := SkCol(ATextColor);
  if AHaloWidth > 0 then
  begin
    FSkHalo.Color := SkCol(AHaloColor);
    FSkHalo.StrokeWidth := AHaloWidth * 2;  // halo radius = AHaloWidth on each side
  end;
  for I := 0 to High(ALines) do
  begin
    S := ALines[I];
    W := Font.MeasureText(S);
    Slack := ABlockW - Round(W);
    case AJustify of
      0: LineX := ABX;                 // left
      2: LineX := ABX + Slack;         // right
    else
      LineX := ABX + Slack div 2;      // center
    end;
    // GDI TextOut is top-aligned; Skia draws from the baseline -> add |ascent|.
    BaseY := ABY + I * ALineH - M.Ascent;
    if AHaloWidth > 0 then
      FSkCanvas.DrawSimpleText(S, LineX, BaseY, Font, FSkHalo);
    FSkCanvas.DrawSimpleText(S, LineX, BaseY, Font, FSkText);
  end;
end;

procedure TPBFSkiaSurface.DrawRotatedText(const AText: string;
  ACx, ACy, APxHeight: Integer; AAngleDeg: Double; ATextW, ALetterExtra: Integer;
  const AFontName: string; AFontStyle: TFontStyles;
  const ATextColor, AHaloColor: TMGLColor; AHaloWidth: Double);
var
  Font: ISkFont;
  M: TSkFontMetrics;
  W, BaseY: Single;
begin
  Font := GetFont(AFontName, APxHeight, AFontStyle);
  Font.GetMetrics(M);
  W := Font.MeasureText(AText);
  FSkText.Color := SkCol(ATextColor);
  if AHaloWidth > 0 then
  begin
    FSkHalo.Color := SkCol(AHaloColor);
    FSkHalo.StrokeWidth := AHaloWidth * 2;
  end;
  // vertical centre of the glyph band on the anchor point
  BaseY := -(M.Ascent + M.Descent) / 2;
  FSkCanvas.Save;
  try
    FSkCanvas.Translate(ACx, ACy);
    FSkCanvas.Rotate(-AAngleDeg);   // GDI escapement is CCW; Skia rotate is CW (y-down)
    if AHaloWidth > 0 then
      FSkCanvas.DrawSimpleText(AText, -W / 2, BaseY, Font, FSkHalo);
    FSkCanvas.DrawSimpleText(AText, -W / 2, BaseY, Font, FSkText);
  finally
    FSkCanvas.Restore;
  end;
end;

procedure TPBFSkiaSurface.DrawIcon(ASprite: TMGLSprite; const AName: string;
  ACx, ACy: Integer; AScale, ARotateDeg, AOpacity: Double; ATint: TColor);
var
  Icon: TMGLSpriteIcon;
  DW, DH: Single;
  Src, Dst: TRectF;
  P: ISkPaint;
begin
  if not Assigned(ASprite) or not ASprite.Loaded then
    Exit;
  if not ASprite.TryGetIcon(AName, Icon) then
    Exit;
  // Build (and cache) the atlas image once per sprite.
  if (FAtlasImg = nil) or (FAtlasSprite <> ASprite) then
  begin
    FAtlasImg := ASprite.Bitmap.ToSkImage;
    FAtlasSprite := ASprite;
  end;
  if FAtlasImg = nil then
    Exit;
  DW := (Icon.Width / Icon.PixelRatio) * AScale;
  DH := (Icon.Height / Icon.PixelRatio) * AScale;
  if (DW <= 0) or (DH <= 0) then
    Exit;
  Src := TRectF.Create(Icon.X, Icon.Y, Icon.X + Icon.Width, Icon.Y + Icon.Height);
  Dst := TRectF.Create(ACx - DW / 2, ACy - DH / 2, ACx + DW / 2, ACy + DH / 2);
  P := TSkPaint.Create;
  P.AntiAlias := True;
  if AOpacity < 1.0 then
    P.AlphaF := AOpacity;
  if ARotateDeg <> 0 then
  begin
    FSkCanvas.Save;
    try
      FSkCanvas.Translate(ACx, ACy);
      FSkCanvas.Rotate(ARotateDeg);
      FSkCanvas.Translate(-ACx, -ACy);
      FSkCanvas.DrawImageRect(FAtlasImg, Src, Dst, P);
    finally
      FSkCanvas.Restore;
    end;
  end
  else
    FSkCanvas.DrawImageRect(FAtlasImg, Src, Dst, P);
end;

function TPBFSkiaSurface.MeasureTextWidth(const AText: string; APxHeight, ALetterExtra: Integer;
  const AFontName: string; AFontStyle: TFontStyles): Integer;
begin
  // ALetterExtra ignored: the Skia text draw doesn't apply per-glyph spacing
  // either, so measure and draw stay consistent.
  Result := Round(GetFont(AFontName, APxHeight, AFontStyle).MeasureText(AText));
end;

function TPBFSkiaSurface.MeasureTextHeight(APxHeight: Integer;
  const AFontName: string; AFontStyle: TFontStyles): Integer;
var
  M: TSkFontMetrics;
begin
  GetFont(AFontName, APxHeight, AFontStyle).GetMetrics(M);
  Result := Round(M.Descent - M.Ascent);  // glyph band height (ascent is negative)
end;

function MakeSkiaSurface(ACanvas: TCanvas; AAntialias: Boolean): TPBFDrawSurface;
begin
  Result := TPBFSkiaSurface.Create(ACanvas, AAntialias);
end;

initialization
  GPBFSkiaSurfaceFactory := MakeSkiaSurface;
end.
