unit PBFMap.Style.Model;

{
  PBFMapRenderer - Mapbox GL style object model

  In-memory representation of a parsed style.json: ordered layers, each with a
  kind, source-layer, zoom range, filter and paint/layout property bags whose
  values are compiled expressions.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  PBFMap.Types, PBFMap.MVT.Types, PBFMap.Color, PBFMap.Expressions,
  PBFMap.Profile;

type
  TMGLLayerKind = (lkBackground, lkFill, lkLine, lkSymbol, lkCircle,
                   lkFillExtrusion, lkRaster, lkHeatmap, lkHillshade, lkUnknown);

  /// <summary>
  ///   Per-render cache of FEATURE-CONSTANT (zoom-only) property values, owned by
  ///   the per-thread renderer and published via the GActivePropCache threadvar.
  ///   The shared style/bags hold NO mutable per-render state, so concurrent
  ///   workers at different zooms never corrupt each other. Keyed by property name;
  ///   the renderer Clears it per layer (names are unique within a layer) and the
  ///   render zoom is fixed, so cached values are always valid for the lookups.
  /// </summary>
  TMGLPropEvalCache = class
  private
    FFloat: TDictionary<string, Double>;
    FColor: TDictionary<string, TMGLColor>;
    FStr: TDictionary<string, string>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function TryFloat(const AName: string; out AValue: Double): Boolean;
    procedure PutFloat(const AName: string; AValue: Double);
    function TryColor(const AName: string; out AValue: TMGLColor): Boolean;
    procedure PutColor(const AName: string; const AValue: TMGLColor);
    function TryStr(const AName: string; out AValue: string): Boolean;
    procedure PutStr(const AName, AValue: string);
  end;

  /// <summary>Named bag of compiled property expressions (paint or layout)</summary>
  TMGLPropertyBag = class
  private
    FProps: TDictionary<string, IExpression>;
    FFloatArrays: TDictionary<string, TArray<Double>>;
    { Typed result cache for CONSTANT (literal) properties: avoids re-evaluating
      and (for colours) re-parsing the same value for every feature. Constants
      never change, so no invalidation is needed. }
    FConstColor: TDictionary<string, TMGLColor>;
    FConstFloat: TDictionary<string, Double>;
    FConstStr: TDictionary<string, string>;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetProp(const AName: string; AExpr: IExpression);
    { Stores a literal numeric array (e.g. text-offset [0,0.5]) alongside the
      compiled expressions, since IExpression yields a single scalar. }
    procedure SetFloatArray(const AName: string; const AValues: TArray<Double>);
    function Get(const AName: string): IExpression;
    function Has(const AName: string): Boolean;

    function EvalColor(const AName: string; const Ctx: TExprContext;
      const ADefault: TMGLColor): TMGLColor;
    function EvalFloat(const AName: string; const Ctx: TExprContext;
      ADefault: Double): Double;
    function EvalString(const AName: string; const Ctx: TExprContext;
      const ADefault: string): string;
    function EvalBool(const AName: string; const Ctx: TExprContext;
      ADefault: Boolean): Boolean;
    { Returns a stored literal numeric array, or ADefault if absent. }
    function GetFloatArray(const AName: string;
      const ADefault: TArray<Double>): TArray<Double>;
  end;

  TMGLLayer = class
  private
    FId: string;
    FKind: TMGLLayerKind;
    FSource: string;
    FSourceLayer: string;
    FMinZoom: Double;   // NaN = unbounded
    FMaxZoom: Double;   // NaN = unbounded
    FVisible: Boolean;
    FFilter: IExpression;
    FFilterClasses: TArray<string>;  // class values the filter constrains to ('' entry = absent allowed); nil = scan all
    FFilterRedundant: Boolean;  // filter fully implied by geometry-gate + class-bucket -> skip Eval
    FLayout: TMGLPropertyBag;
    FPaint: TMGLPropertyBag;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>True when AZoom is within [MinZoom, MaxZoom)</summary>
    function VisibleAtZoom(AZoom: Double): Boolean;

    property Id: string read FId write FId;
    property Kind: TMGLLayerKind read FKind write FKind;
    property Source: string read FSource write FSource;
    property SourceLayer: string read FSourceLayer write FSourceLayer;
    property MinZoom: Double read FMinZoom write FMinZoom;
    property MaxZoom: Double read FMaxZoom write FMaxZoom;
    property Visible: Boolean read FVisible write FVisible;
    property Filter: IExpression read FFilter write FFilter;
    /// <summary>
    ///   When the filter constrains the `class` property to a fixed set, those
    ///   values (lets the renderer index features by class and skip the rest).
    ///   nil/empty = no class constraint, scan all features.
    /// </summary>
    property FilterClasses: TArray<string> read FFilterClasses write FFilterClasses;
    /// <summary>
    ///   True when the filter is fully implied by the renderer's geometry-type
    ///   gate (fill→Polygon, circle→Point) plus the class bucket — i.e. every
    ///   conjunct is a redundant `$type`/`class` test. The renderer can then skip
    ///   evaluating the filter entirely.
    /// </summary>
    property FilterRedundant: Boolean read FFilterRedundant write FFilterRedundant;
    property Layout: TMGLPropertyBag read FLayout;
    property Paint: TMGLPropertyBag read FPaint;
  end;

  TMGLStyle = class
  private
    FName: string;
    FLayers: TObjectList<TMGLLayer>;
    FSpriteUrl: string;
    FGlyphsUrl: string;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddLayer(ALayer: TMGLLayer);

    property Name: string read FName write FName;
    property Layers: TObjectList<TMGLLayer> read FLayers;
    property SpriteUrl: string read FSpriteUrl write FSpriteUrl;
    property GlyphsUrl: string read FGlyphsUrl write FGlyphsUrl;
  end;

function LayerKindFromString(const S: string): TMGLLayerKind;

threadvar
  /// <summary>Active per-thread feature-constant cache, or nil (no memoisation).
  /// Set by the renderer around a render; the property bag consults it.</summary>
  GActivePropCache: TMGLPropEvalCache;

implementation

function LayerKindFromString(const S: string): TMGLLayerKind;
begin
  if S = 'background' then Result := lkBackground
  else if S = 'fill' then Result := lkFill
  else if S = 'line' then Result := lkLine
  else if S = 'symbol' then Result := lkSymbol
  else if S = 'circle' then Result := lkCircle
  else if S = 'fill-extrusion' then Result := lkFillExtrusion
  else if S = 'raster' then Result := lkRaster
  else if S = 'heatmap' then Result := lkHeatmap
  else if S = 'hillshade' then Result := lkHillshade
  else Result := lkUnknown;
end;

{ TMGLPropEvalCache }

constructor TMGLPropEvalCache.Create;
begin
  inherited Create;
  FFloat := TDictionary<string, Double>.Create;
  FColor := TDictionary<string, TMGLColor>.Create;
  FStr := TDictionary<string, string>.Create;
end;

destructor TMGLPropEvalCache.Destroy;
begin
  FStr.Free;
  FColor.Free;
  FFloat.Free;
  inherited;
end;

procedure TMGLPropEvalCache.Clear;
begin
  FFloat.Clear;
  FColor.Clear;
  FStr.Clear;
end;

function TMGLPropEvalCache.TryFloat(const AName: string; out AValue: Double): Boolean;
begin
  Result := FFloat.TryGetValue(AName, AValue);
end;

procedure TMGLPropEvalCache.PutFloat(const AName: string; AValue: Double);
begin
  FFloat.AddOrSetValue(AName, AValue);
end;

function TMGLPropEvalCache.TryColor(const AName: string; out AValue: TMGLColor): Boolean;
begin
  Result := FColor.TryGetValue(AName, AValue);
end;

procedure TMGLPropEvalCache.PutColor(const AName: string; const AValue: TMGLColor);
begin
  FColor.AddOrSetValue(AName, AValue);
end;

function TMGLPropEvalCache.TryStr(const AName: string; out AValue: string): Boolean;
begin
  Result := FStr.TryGetValue(AName, AValue);
end;

procedure TMGLPropEvalCache.PutStr(const AName, AValue: string);
begin
  FStr.AddOrSetValue(AName, AValue);
end;

{ TMGLPropertyBag }

constructor TMGLPropertyBag.Create;
begin
  inherited Create;
  FProps := TDictionary<string, IExpression>.Create;
  FFloatArrays := TDictionary<string, TArray<Double>>.Create;
  FConstColor := TDictionary<string, TMGLColor>.Create;
  FConstFloat := TDictionary<string, Double>.Create;
  FConstStr := TDictionary<string, string>.Create;
end;

destructor TMGLPropertyBag.Destroy;
begin
  FConstStr.Free;
  FConstFloat.Free;
  FConstColor.Free;
  FFloatArrays.Free;
  FProps.Free;  // interface values released automatically
  inherited;
end;

procedure TMGLPropertyBag.SetProp(const AName: string; AExpr: IExpression);
begin
  FProps.AddOrSetValue(AName, AExpr);
  // a property's expression can be replaced (ref layers) -> drop stale caches
  FConstColor.Remove(AName);
  FConstFloat.Remove(AName);
  FConstStr.Remove(AName);
end;

procedure TMGLPropertyBag.SetFloatArray(const AName: string;
  const AValues: TArray<Double>);
begin
  FFloatArrays.AddOrSetValue(AName, AValues);
end;

function TMGLPropertyBag.GetFloatArray(const AName: string;
  const ADefault: TArray<Double>): TArray<Double>;
begin
  if not FFloatArrays.TryGetValue(AName, Result) then
    Result := ADefault;
end;

function TMGLPropertyBag.Get(const AName: string): IExpression;
begin
  if not FProps.TryGetValue(AName, Result) then
    Result := nil;
end;

function TMGLPropertyBag.Has(const AName: string): Boolean;
begin
  Result := FProps.ContainsKey(AName);
end;

function TMGLPropertyBag.EvalColor(const AName: string; const Ctx: TExprContext;
  const ADefault: TMGLColor): TMGLColor;
var
  E: IExpression;
  Col: TMGLColor;
  LProf: IProfScope;
begin
  LProf := ProfScope('Style.EvalColor');
  E := Get(AName);
  if E = nil then
    Exit(ADefault);
  // Constant property: parse the colour once, then reuse (kills per-feature reparse).
  if E.IsConstant then
  begin
    if FConstColor.TryGetValue(AName, Result) then
      Exit;
    if TryParseColor(E.Eval(Ctx).AsString, Col) then
    begin
      Result := Col;
      FConstColor.Add(AName, Result);
      Exit;
    end;
    Exit(ADefault);  // unparseable constant -> default (don't cache the default)
  end;
  // Feature-constant (zoom-only) property: evaluate once per (name, zoom) into the
  // per-THREAD renderer cache (GActivePropCache) and reuse for every feature.
  if (GActivePropCache <> nil) and E.IsFeatureConstant then
  begin
    if GActivePropCache.TryColor(AName, Result) then
      Exit;
    if TryParseColor(E.Eval(Ctx).AsString, Col) then
    begin
      Result := Col;
      GActivePropCache.PutColor(AName, Result);
      Exit;
    end;
    Exit(ADefault);
  end;
  if TryParseColor(E.Eval(Ctx).AsString, Col) then
    Result := Col
  else
    Result := ADefault;
end;

function TMGLPropertyBag.EvalFloat(const AName: string; const Ctx: TExprContext;
  ADefault: Double): Double;
var
  E: IExpression;
  Ok: Boolean;
  V: Double;
  LProf: IProfScope;
begin
  LProf := ProfScope('Style.EvalFloat');
  E := Get(AName);
  if E = nil then
    Exit(ADefault);
  if E.IsConstant then
  begin
    if FConstFloat.TryGetValue(AName, Result) then
      Exit;
    V := E.Eval(Ctx).AsDouble(Ok);
    if Ok then
    begin
      Result := V;
      FConstFloat.Add(AName, Result);
      Exit;
    end;
    Exit(ADefault);
  end;
  if (GActivePropCache <> nil) and E.IsFeatureConstant then
  begin
    if GActivePropCache.TryFloat(AName, Result) then
      Exit;
    V := E.Eval(Ctx).AsDouble(Ok);
    if Ok then
    begin
      Result := V;
      GActivePropCache.PutFloat(AName, Result);
      Exit;
    end;
    Exit(ADefault);
  end;
  V := E.Eval(Ctx).AsDouble(Ok);
  if Ok then Result := V else Result := ADefault;
end;

function TMGLPropertyBag.EvalString(const AName: string; const Ctx: TExprContext;
  const ADefault: string): string;
var
  E: IExpression;
  V: TMVTValue;
  LProf: IProfScope;
begin
  LProf := ProfScope('Style.EvalString');
  E := Get(AName);
  if E = nil then
    Exit(ADefault);
  if E.IsConstant then
  begin
    if FConstStr.TryGetValue(AName, Result) then
      Exit;
    V := E.Eval(Ctx);
    if V.IsNull then Result := ADefault else Result := V.AsString;
    FConstStr.Add(AName, Result);
    Exit;
  end;
  if (GActivePropCache <> nil) and E.IsFeatureConstant then
  begin
    if GActivePropCache.TryStr(AName, Result) then
      Exit;
    V := E.Eval(Ctx);
    if V.IsNull then Result := ADefault else Result := V.AsString;
    GActivePropCache.PutStr(AName, Result);
    Exit;
  end;
  V := E.Eval(Ctx);
  if V.IsNull then Result := ADefault else Result := V.AsString;
end;

function TMGLPropertyBag.EvalBool(const AName: string; const Ctx: TExprContext;
  ADefault: Boolean): Boolean;
var
  E: IExpression;
begin
  E := Get(AName);
  if E = nil then Result := ADefault else Result := E.Eval(Ctx).AsBool;
end;

{ TMGLLayer }

constructor TMGLLayer.Create;
begin
  inherited Create;
  FMinZoom := NaN;
  FMaxZoom := NaN;
  FVisible := True;
  FLayout := TMGLPropertyBag.Create;
  FPaint := TMGLPropertyBag.Create;
end;

destructor TMGLLayer.Destroy;
begin
  FLayout.Free;
  FPaint.Free;
  FFilter := nil;
  inherited;
end;

function TMGLLayer.VisibleAtZoom(AZoom: Double): Boolean;
begin
  Result := FVisible;
  if Result and not IsNan(FMinZoom) and (AZoom < FMinZoom) then
    Result := False;
  if Result and not IsNan(FMaxZoom) and (AZoom >= FMaxZoom) then
    Result := False;
end;

{ TMGLStyle }

constructor TMGLStyle.Create;
begin
  inherited Create;
  FLayers := TObjectList<TMGLLayer>.Create(True);
end;

destructor TMGLStyle.Destroy;
begin
  FLayers.Free;
  inherited;
end;

procedure TMGLStyle.AddLayer(ALayer: TMGLLayer);
begin
  FLayers.Add(ALayer);
end;

end.
