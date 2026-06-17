unit PBFMap.Sprite;

{
  PBFMapRenderer - Sprite atlas loader

  Loads a Mapbox/MapTiler sprite sheet (sprite.png + sprite.json index) and
  exposes per-name source rectangles. The atlas bitmap is kept as 32-bit
  premultiplied-alpha so it can be alpha-blended (icons) or tiled (patterns).

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Classes, System.Types, System.JSON,
  System.Generics.Collections, System.IOUtils,
  Winapi.Windows, Winapi.GDIPAPI, Winapi.GDIPOBJ,
  Vcl.Graphics, Vcl.Imaging.PNGImage,
  PBFMap.Types;

type
  /// <summary>One entry of the sprite index (atlas source rect + ratio)</summary>
  TMGLSpriteIcon = record
    X, Y, Width, Height: Integer;
    PixelRatio: Double;
  end;

  /// <summary>Sprite atlas: PNG sheet + name -> source-rect index</summary>
  TMGLSprite = class
  private
    FBitmap: TBitmap;
    FAtlasGP: TGPBitmap;   // GDI+ view of the atlas (PARGB), for rotated icons
    FIcons: TDictionary<string, TMGLSpriteIcon>;
    FLoaded: Boolean;
    procedure ParseIndex(const aJson: string);
    procedure LoadImage(const aPngFile: string);
    procedure BuildAtlasGP;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>Load atlas from a JSON index + PNG sheet. False if either is missing.</summary>
    function LoadFromFiles(const aJsonFile, aPngFile: string): Boolean;

    /// <summary>True if the named icon exists in the index.</summary>
    function HasIcon(const aName: string): Boolean;
    /// <summary>Look up an icon's source rect; False when absent.</summary>
    function TryGetIcon(const aName: string; out aIcon: TMGLSpriteIcon): Boolean;

    /// <summary>
    ///   Alpha-blend the named icon centered at (aCx, aCy). Returns the painted
    ///   destination rect in aDrawn; False when the icon is unknown.
    /// </summary>
    /// <param name="aOpacity">icon-opacity multiplier (0..1).</param>
    /// <param name="aTint">
    ///   icon-color: when not clNone the icon is recolored (SDF tint) keeping
    ///   the source alpha as a mask. clNone leaves the sprite pixels untouched.
    /// </param>
    function DrawIconCentered(ACanvas: TCanvas; const aName: string;
      aCx, aCy: Integer; out aDrawn: TRect; aScale: Double = 1.0;
      aRotateDeg: Double = 0.0; aOpacity: Double = 1.0;
      aTint: TColor = clNone): Boolean;

    /// <summary>The atlas bitmap (premultiplied alpha), for pattern tiling.</summary>
    property Bitmap: TBitmap read FBitmap;
    property Loaded: Boolean read FLoaded;
  end;

implementation

const
  DEFAULT_PIXEL_RATIO = 1.0;

function JsonInt(AObj: TJSONObject; const aName: string; aDefault: Integer): Integer;
var
  LValue: TJSONValue;
begin
  LValue := AObj.GetValue(aName);
  if LValue is TJSONNumber then
    Result := TJSONNumber(LValue).AsInt
  else
    Result := aDefault;
end;

{ TMGLSprite }

constructor TMGLSprite.Create;
begin
  inherited Create;
  FBitmap := TBitmap.Create;
  FIcons := TDictionary<string, TMGLSpriteIcon>.Create;
end;

destructor TMGLSprite.Destroy;
begin
  FAtlasGP.Free;
  FIcons.Free;
  FBitmap.Free;
  inherited;
end;

procedure TMGLSprite.BuildAtlasGP;
var
  Stride: Integer;
begin
  FreeAndNil(FAtlasGP);
  if (FBitmap.Width = 0) or (FBitmap.Height = 0) then
    Exit;
  // GDI+ view sharing FBitmap's premultiplied pixels (no copy). VCL DIBs are
  // bottom-up, so the stride between scanlines is negative.
  if FBitmap.Height > 1 then
    Stride := NativeInt(FBitmap.ScanLine[1]) - NativeInt(FBitmap.ScanLine[0])
  else
    Stride := FBitmap.Width * 4;
  FAtlasGP := TGPBitmap.Create(FBitmap.Width, FBitmap.Height, Stride,
    PixelFormat32bppPARGB, PByte(FBitmap.ScanLine[0]));
end;

procedure TMGLSprite.ParseIndex(const aJson: string);
var
  LRoot: TJSONValue;
  LPair: TJSONPair;
  LObj: TJSONObject;
  LIcon: TMGLSpriteIcon;
  LRatio: TJSONValue;
begin
  FIcons.Clear;
  LRoot := TJSONObject.ParseJSONValue(aJson);
  try
    if not (LRoot is TJSONObject) then
      Exit;
    for LPair in TJSONObject(LRoot) do
    begin
      if not (LPair.JsonValue is TJSONObject) then
        Continue;
      LObj := TJSONObject(LPair.JsonValue);
      LIcon.X := JsonInt(LObj, 'x', 0);
      LIcon.Y := JsonInt(LObj, 'y', 0);
      LIcon.Width := JsonInt(LObj, 'width', 0);
      LIcon.Height := JsonInt(LObj, 'height', 0);
      LRatio := LObj.GetValue('pixelRatio');
      if LRatio is TJSONNumber then
        LIcon.PixelRatio := TJSONNumber(LRatio).AsDouble
      else
        LIcon.PixelRatio := DEFAULT_PIXEL_RATIO;
      if (LIcon.Width > 0) and (LIcon.Height > 0) then
        FIcons.AddOrSetValue(LPair.JsonString.Value, LIcon);
    end;
  finally
    LRoot.Free;
  end;
end;

procedure TMGLSprite.LoadImage(const aPngFile: string);
var
  LPng: TPngImage;
begin
  LPng := TPngImage.Create;
  try
    LPng.LoadFromFile(aPngFile);
    FBitmap.Assign(LPng);
    FBitmap.PixelFormat := pf32bit;
    // Premultiplied alpha is required by Winapi AlphaBlend with AC_SRC_ALPHA.
    FBitmap.AlphaFormat := afPremultiplied;
  finally
    LPng.Free;
  end;
  BuildAtlasGP;
end;

function TMGLSprite.LoadFromFiles(const aJsonFile, aPngFile: string): Boolean;
begin
  FLoaded := False;
  if not (TFile.Exists(aJsonFile) and TFile.Exists(aPngFile)) then
    Exit(False);
  ParseIndex(TFile.ReadAllText(aJsonFile, TEncoding.UTF8));
  LoadImage(aPngFile);
  FLoaded := FIcons.Count > 0;
  Result := FLoaded;
end;

function TMGLSprite.HasIcon(const aName: string): Boolean;
begin
  Result := FLoaded and FIcons.ContainsKey(aName);
end;

function TMGLSprite.TryGetIcon(const aName: string;
  out aIcon: TMGLSpriteIcon): Boolean;
begin
  Result := FLoaded and FIcons.TryGetValue(aName, aIcon);
end;

{ Builds a GDI+ color matrix: scales alpha by aOpacity and, when aTint is a real
  color, replaces RGB with the tint (SDF recolor) keeping the source alpha mask. }
function BuildIconMatrix(aOpacity: Double; aTint: TColor): TColorMatrix;
var
  LR, LG, LB: Single;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result[4, 4] := 1;
  Result[3, 3] := aOpacity;           // out.A = src.A * opacity
  if aTint = clNone then
  begin
    // identity RGB, alpha scaled
    Result[0, 0] := 1;
    Result[1, 1] := 1;
    Result[2, 2] := 1;
  end
  else
  begin
    // constant tint RGB (SDF), independent of source color
    LR := GetRValue(ColorToRGB(aTint)) / 255;
    LG := GetGValue(ColorToRGB(aTint)) / 255;
    LB := GetBValue(ColorToRGB(aTint)) / 255;
    Result[4, 0] := LR;
    Result[4, 1] := LG;
    Result[4, 2] := LB;
  end;
end;

function TMGLSprite.DrawIconCentered(ACanvas: TCanvas; const aName: string;
  aCx, aCy: Integer; out aDrawn: TRect; aScale: Double; aRotateDeg: Double;
  aOpacity: Double; aTint: TColor): Boolean;
var
  LIcon: TMGLSpriteIcon;
  LBlend: TBlendFunction;
  LDestW, LDestH, LDestX, LDestY: Integer;
  LNeedGP: Boolean;
  G: TGPGraphics;
  LAttr: TGPImageAttributes;
  LMatrix: TColorMatrix;
begin
  aDrawn := TRect.Empty;
  if not TryGetIcon(aName, LIcon) then
    Exit(False);

  // Displayed size accounts for the sprite's pixel ratio (2x sheets -> half)
  // and the style's icon-size scale factor.
  LDestW := Round(LIcon.Width / LIcon.PixelRatio * aScale);
  LDestH := Round(LIcon.Height / LIcon.PixelRatio * aScale);
  LDestX := aCx - LDestW div 2;
  LDestY := aCy - LDestH div 2;
  aDrawn := TRect.Create(LDestX, LDestY, LDestX + LDestW, LDestY + LDestH);

  // The GDI+ path handles rotation, partial opacity and SDF tint; the plain
  // AlphaBlend fast path covers the common "just draw it" case.
  LNeedGP := Assigned(FAtlasGP) and
    ((aRotateDeg <> 0) or (aOpacity < 1.0) or (aTint <> clNone));
  if LNeedGP then
  begin
    G := TGPGraphics.Create(ACanvas.Handle);
    LAttr := nil;
    try
      G.SetSmoothingMode(SmoothingModeAntiAlias);
      G.SetInterpolationMode(InterpolationModeHighQualityBicubic);
      G.TranslateTransform(aCx, aCy);
      if aRotateDeg <> 0 then
        G.RotateTransform(aRotateDeg);
      if (aOpacity < 1.0) or (aTint <> clNone) then
      begin
        LMatrix := BuildIconMatrix(aOpacity, aTint);
        LAttr := TGPImageAttributes.Create;
        LAttr.SetColorMatrix(LMatrix);
      end;
      G.DrawImage(FAtlasGP,
        MakeRect(Single(-LDestW / 2), Single(-LDestH / 2), Single(LDestW), Single(LDestH)),
        Single(LIcon.X), Single(LIcon.Y), Single(LIcon.Width), Single(LIcon.Height),
        UnitPixel, LAttr);
    finally
      LAttr.Free;
      G.Free;
    end;
    Exit(True);
  end;

  LBlend.BlendOp := AC_SRC_OVER;
  LBlend.BlendFlags := 0;
  LBlend.SourceConstantAlpha := 255;
  LBlend.AlphaFormat := AC_SRC_ALPHA;
  Winapi.Windows.AlphaBlend(ACanvas.Handle, LDestX, LDestY, LDestW, LDestH,
    FBitmap.Canvas.Handle, LIcon.X, LIcon.Y, LIcon.Width, LIcon.Height, LBlend);
  Result := True;
end;

end.
