unit PBFMap.Expressions;

{
  PBFMapRenderer - Mapbox GL expression engine

  Parses Mapbox GL style expressions (and legacy function-stops / legacy
  filter arrays) into an IExpression tree evaluated against a feature + zoom
  context. The result currency is TMVTValue. Colors are carried as canonical
  "rgba(r,g,b,a)" strings so they round-trip through TMVTValue.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.StrUtils, System.Math, System.JSON,
  System.Generics.Collections,
  PBFMap.Types, PBFMap.MVT.Types, PBFMap.Color;

type
  /// <summary>Evaluation context for an expression</summary>
  TExprContext = record
    Feature: TMVTFeature;            // nil for background / source-less layers
    Zoom: Double;
    GeometryType: TPBFGeometryType;
    LineProgress: Double;            // 0..1 along a line (for line-gradient)
    Vars: TDictionary<string, TMVTValue>;  // let/var scope, may be nil
  end;

  /// <summary>An evaluatable expression node</summary>
  IExpression = interface
    ['{2B9F4E10-7C3A-4D2E-9C1B-6F0A2D5E8C71}']
    function Eval(const Ctx: TExprContext): TMVTValue;
    /// <summary>
    ///   True when Eval is independent of BOTH zoom and feature (a literal/const):
    ///   its result never changes, so callers may cache the parsed value instead
    ///   of re-evaluating + re-parsing it per feature.
    /// </summary>
    function IsConstant: Boolean;
    /// <summary>
    ///   True when Eval does NOT depend on the feature (no get/has/id/geometry-type
    ///   /line-progress in the subtree) - it may still depend on zoom. Lets a
    ///   caller evaluate ONCE per (layer, zoom) and reuse the value for every
    ///   feature, instead of re-running e.g. a zoom-interpolate per feature.
    ///   Conservative: unknown nodes return False (correct, just not memoised).
    /// </summary>
    function IsFeatureConstant: Boolean;
  end;

  /// <summary>Parse a JSON value into an expression tree.</summary>
  function ParseExpression(AJson: TJSONValue): IExpression;

  /// <summary>Compile a legacy function-stops object into an expression.</summary>
  function CompileFunction(AObj: TJSONObject): IExpression;

  /// <summary>
  ///   Compile a style "filter" (legacy array form OR expression form) into a
  ///   boolean-yielding expression. Returns nil for an empty/absent filter.
  /// </summary>
  function CompileFilter(AJson: TJSONValue): IExpression;

  /// <summary>Helper: build a context with sensible defaults.</summary>
  function MakeContext(AFeature: TMVTFeature; AZoom: Double;
    AGeomType: TPBFGeometryType): TExprContext;

  /// <summary>
  ///   True when J is a JSON string usable as an operator. In System.JSON
  ///   TJSONNumber descends from TJSONString, so a bare "is TJSONString" test
  ///   wrongly matches numbers; this excludes them (e.g. so a literal array
  ///   like [0, 0.5] is not mistaken for an expression with operator "0").
  /// </summary>
  function IsJsonOpString(J: TJSONValue): Boolean;

  /// <summary>
  ///   True when Op is a recognised expression operator. Used to tell a real
  ///   expression from a plain literal array (e.g. a "text-font" font stack
  ///   like ["Noto Sans Regular"], whose head is a string but not an operator).
  /// </summary>
  function IsKnownExpressionOp(const Op: string): Boolean;

implementation

type
  TExpr = class(TInterfacedObject, IExpression)
    function Eval(const Ctx: TExprContext): TMVTValue; virtual; abstract;
    function IsConstant: Boolean; virtual;  // conservative default: not constant
    function IsFeatureConstant: Boolean; virtual;  // conservative default: feature-dependent
  end;

  TLiteralExpr = class(TExpr)
    FValue: TMVTValue;
    constructor Create(const AValue: TMVTValue);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsConstant: Boolean; override;  // a literal never changes
    function IsFeatureConstant: Boolean; override;
  end;

  TGetExpr = class(TExpr)
    FKey: IExpression;
    FConstKey: string;        // resolved key when FKey is constant (the common case)
    FConstHash: Cardinal;     // its MVTKeyHash, so per-feature lookup skips the scan
    FKeyIsConst: Boolean;
    constructor Create(AKey: IExpression);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
  end;

  THasExpr = class(TExpr)
    FKey: IExpression;
    FConstKey: string;
    FConstHash: Cardinal;
    FKeyIsConst: Boolean;
    constructor Create(AKey: IExpression);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
  end;

  TZoomExpr = class(TExpr)
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;  // depends on zoom, not feature
  end;

  TLineProgressExpr = class(TExpr)
    function Eval(const Ctx: TExprContext): TMVTValue; override;
  end;

  TGeomTypeExpr = class(TExpr)
    function Eval(const Ctx: TExprContext): TMVTValue; override;
  end;

  TIdExpr = class(TExpr)
    function Eval(const Ctx: TExprContext): TMVTValue; override;
  end;

  TVarExpr = class(TExpr)
    FName: string;
    constructor Create(const AName: string);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
  end;

  TLetExpr = class(TExpr)
    FNames: TArray<string>;
    FValues: TArray<IExpression>;
    FBody: IExpression;
    function Eval(const Ctx: TExprContext): TMVTValue; override;
  end;

  TCompareKind = (ckEq, ckNeq, ckLt, ckLe, ckGt, ckGe);
  TCompareExpr = class(TExpr)
    FKind: TCompareKind;
    FA, FB: IExpression;
    constructor Create(AKind: TCompareKind; A, B: IExpression);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TBoolKind = (bkAll, bkAny, bkNot);
  TBoolExpr = class(TExpr)
    FKind: TBoolKind;
    FArgs: TArray<IExpression>;
    constructor Create(AKind: TBoolKind; const AArgs: TArray<IExpression>);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TInExpr = class(TExpr)
    FNeedle: IExpression;
    FHaystack: TArray<IExpression>;  // either list items, or single string/collection expr
    constructor Create(ANeedle: IExpression; const AHaystack: TArray<IExpression>);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TCaseExpr = class(TExpr)
    FConds, FOutputs: TArray<IExpression>;
    FElse: IExpression;
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TMatchExpr = class(TExpr)
    FInput: IExpression;
    FLabels: TArray<TArray<TMVTValue>>;  // each branch may have multiple labels
    FOutputs: TArray<IExpression>;
    FDefault: IExpression;
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TStepExpr = class(TExpr)
    FInput: IExpression;
    FBase: IExpression;          // output for input < first stop
    FStops: TArray<Double>;
    FOutputs: TArray<IExpression>;
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TInterpMode = (imLinear, imExponential, imCubicBezier);
  TInterpColorSpace = (icsRgb, icsLab, icsHcl);  // interpolate / -lab / -hcl
  TInterpolateExpr = class(TExpr)
    FMode: TInterpMode;
    FColorSpace: TInterpColorSpace;
    FBase: Double;
    FBezX1, FBezY1, FBezX2, FBezY2: Double;
    FInput: IExpression;
    FStops: TArray<Double>;
    FOutputs: TArray<IExpression>;
    function Factor(X: Double; Lo, Hi: Double): Double;
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TCoalesceExpr = class(TExpr)
    FArgs: TArray<IExpression>;
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TConcatExpr = class(TExpr)
    FArgs: TArray<IExpression>;
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TCoerceKind = (ckToString, ckToNumber, ckToBoolean, ckToColor, ckTypeof);
  TCoerceExpr = class(TExpr)
    FKind: TCoerceKind;
    FArgs: TArray<IExpression>;
    constructor Create(AKind: TCoerceKind; const AArgs: TArray<IExpression>);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TStringFnKind = (sfUpcase, sfDowncase, sfLength);
  TStringFnExpr = class(TExpr)
    FKind: TStringFnKind;
    FArg: IExpression;
    constructor Create(AKind: TStringFnKind; AArg: IExpression);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TMathKind = (mkAdd, mkSub, mkMul, mkDiv, mkMod, mkPow, mkMin, mkMax,
               mkAbs, mkFloor, mkCeil, mkRound, mkSqrt, mkSin, mkCos, mkTan,
               mkLn, mkLog10, mkLog2, mkE, mkPi);
  TMathExpr = class(TExpr)
    FKind: TMathKind;
    FArgs: TArray<IExpression>;
    constructor Create(AKind: TMathKind; const AArgs: TArray<IExpression>);
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

  TRgbExpr = class(TExpr)
    FHasAlpha: Boolean;
    FArgs: TArray<IExpression>;
    function Eval(const Ctx: TExprContext): TMVTValue; override;
    function IsFeatureConstant: Boolean; override;
  end;

{ ---- helpers ---- }

function MakeContext(AFeature: TMVTFeature; AZoom: Double;
  AGeomType: TPBFGeometryType): TExprContext;
begin
  Result.Feature := AFeature;
  Result.Zoom := AZoom;
  Result.GeometryType := AGeomType;
  Result.LineProgress := 0;
  Result.Vars := nil;
end;

function IsJsonOpString(J: TJSONValue): Boolean;
begin
  Result := (J is TJSONString) and not (J is TJSONNumber);
end;

function IsKnownExpressionOp(const Op: string): Boolean;
begin
  // Must list every operator handled by ParseExpression below.
  Result := MatchStr(Op, [
    'literal', 'get', 'has', 'zoom', 'line-progress', 'geometry-type', 'id', 'var', 'let',
    '==', '!=', '<', '<=', '>', '>=', 'all', 'any', '!', 'in',
    'case', 'match', 'step', 'interpolate', 'interpolate-hcl', 'interpolate-lab',
    'coalesce', 'concat', 'format',
    'number-format', 'image', 'to-string', 'to-number', 'to-boolean',
    'to-color', 'typeof', 'upcase', 'downcase', 'length',
    '+', '-', '*', '/', '%', '^', 'min', 'max', 'abs', 'floor', 'ceil',
    'round', 'sqrt', 'sin', 'cos', 'tan', 'ln', 'log10', 'log2', 'e', 'pi',
    'rgb', 'rgba']);
end;

function JsonScalarToValue(J: TJSONValue): TMVTValue;
var
  I64: Int64;
begin
  if (J = nil) or (J is TJSONNull) then
    Result := TMVTValue.Null
  else if J is TJSONBool then
    Result := TMVTValue.FromBool(TJSONBool(J).AsBoolean)
  // NB: in System.JSON, TJSONNumber descends from TJSONString, so numbers must
  // be tested BEFORE strings - otherwise every numeric literal becomes a string
  // and numeric comparisons/filters silently fail.
  else if J is TJSONNumber then
  begin
    // keep integers as ints when possible
    if TryStrToInt64(TJSONNumber(J).ToString, I64) then
      Result := TMVTValue.FromInt(I64)
    else
      Result := TMVTValue.FromDouble(TJSONNumber(J).AsDouble);
  end
  else if J is TJSONString then
    Result := TMVTValue.FromString(TJSONString(J).Value)
  else
    Result := TMVTValue.Null;
end;

function GeomTypeName(T: TPBFGeometryType): string;
begin
  case T of
    gtPoint:      Result := 'Point';
    gtLineString: Result := 'LineString';
    gtPolygon:    Result := 'Polygon';
  else
    Result := 'Unknown';
  end;
end;

{ TLiteralExpr }
function TExpr.IsConstant: Boolean;
begin
  Result := False;  // conservative: only nodes that prove constancy override
end;

function TExpr.IsFeatureConstant: Boolean;
begin
  Result := False;  // conservative: assume feature-dependent unless proven otherwise
end;

{ True only if EVERY listed sub-expression is feature-constant (nil = constant). }
function AllFeatureConstant(const AExprs: array of IExpression): Boolean;
var
  E: IExpression;
begin
  for E in AExprs do
    if Assigned(E) and not E.IsFeatureConstant then
      Exit(False);
  Result := True;
end;

constructor TLiteralExpr.Create(const AValue: TMVTValue);
begin
  inherited Create;
  FValue := AValue;
end;
function TLiteralExpr.Eval(const Ctx: TExprContext): TMVTValue;
begin
  Result := FValue;
end;
function TLiteralExpr.IsConstant: Boolean;
begin
  Result := True;
end;
function TLiteralExpr.IsFeatureConstant: Boolean;
begin
  Result := True;
end;

{ TGetExpr }
constructor TGetExpr.Create(AKey: IExpression);
var
  Empty: TExprContext;
begin
  inherited Create;
  FKey := AKey;
  // Resolve a constant key once (e.g. ["get","class"]) + cache its hash, so per
  // feature we skip the key sub-eval/AsString and use the fast hashed lookup.
  FKeyIsConst := AKey.IsConstant;
  if FKeyIsConst then
  begin
    Empty := MakeContext(nil, 0, gtUnknown);
    FConstKey := AKey.Eval(Empty).AsString;
    FConstHash := MVTKeyHash(FConstKey);
  end;
end;
function TGetExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  K: string;
begin
  Result := TMVTValue.Null;
  if Ctx.Feature = nil then
    Exit;
  if FKeyIsConst then
  begin
    if not Ctx.Feature.GetPropH(FConstKey, FConstHash, Result) then
      Result := TMVTValue.Null;
    Exit;
  end;
  K := FKey.Eval(Ctx).AsString;
  if not Ctx.Feature.GetProp(K, Result) then
    Result := TMVTValue.Null;
end;

{ THasExpr }
constructor THasExpr.Create(AKey: IExpression);
var
  Empty: TExprContext;
begin
  inherited Create;
  FKey := AKey;
  FKeyIsConst := AKey.IsConstant;
  if FKeyIsConst then
  begin
    Empty := MakeContext(nil, 0, gtUnknown);
    FConstKey := AKey.Eval(Empty).AsString;
    FConstHash := MVTKeyHash(FConstKey);
  end;
end;
function THasExpr.Eval(const Ctx: TExprContext): TMVTValue;
begin
  if not Assigned(Ctx.Feature) then
    Exit(TMVTValue.FromBool(False));
  if FKeyIsConst then
    Exit(TMVTValue.FromBool(Ctx.Feature.HasPropH(FConstKey, FConstHash)));
  Result := TMVTValue.FromBool(Ctx.Feature.HasProp(FKey.Eval(Ctx).AsString));
end;

{ TZoomExpr }
function TZoomExpr.Eval(const Ctx: TExprContext): TMVTValue;
begin
  Result := TMVTValue.FromDouble(Ctx.Zoom);
end;
function TZoomExpr.IsFeatureConstant: Boolean;
begin
  Result := True;  // depends on zoom only, never on the feature
end;

{ TLineProgressExpr }
function TLineProgressExpr.Eval(const Ctx: TExprContext): TMVTValue;
begin
  Result := TMVTValue.FromDouble(Ctx.LineProgress);
end;

{ TGeomTypeExpr }
function TGeomTypeExpr.Eval(const Ctx: TExprContext): TMVTValue;
begin
  Result := TMVTValue.FromString(GeomTypeName(Ctx.GeometryType));
end;

{ TIdExpr }
function TIdExpr.Eval(const Ctx: TExprContext): TMVTValue;
begin
  if Assigned(Ctx.Feature) then
    Result := TMVTValue.FromUInt(Ctx.Feature.ID)
  else
    Result := TMVTValue.Null;
end;

{ TVarExpr }
constructor TVarExpr.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;
function TVarExpr.Eval(const Ctx: TExprContext): TMVTValue;
begin
  if Assigned(Ctx.Vars) and Ctx.Vars.TryGetValue(FName, Result) then
    Exit;
  Result := TMVTValue.Null;
end;

{ TLetExpr }
function TLetExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  Local: TDictionary<string, TMVTValue>;
  Inner: TExprContext;
  I: Integer;
  Pair: TPair<string, TMVTValue>;
begin
  Local := TDictionary<string, TMVTValue>.Create;
  try
    if Assigned(Ctx.Vars) then
      for Pair in Ctx.Vars do
        Local.AddOrSetValue(Pair.Key, Pair.Value);
    Inner := Ctx;
    Inner.Vars := Local;
    for I := 0 to High(FNames) do
      Local.AddOrSetValue(FNames[I], FValues[I].Eval(Inner));
    Result := FBody.Eval(Inner);
  finally
    Local.Free;
  end;
end;

{ TCompareExpr }
constructor TCompareExpr.Create(AKind: TCompareKind; A, B: IExpression);
begin
  inherited Create;
  FKind := AKind;
  FA := A;
  FB := B;
end;
function TCompareExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  VA, VB: TMVTValue;
  Cmp: Integer;
  Ok: Boolean;
  Res: Boolean;
begin
  VA := FA.Eval(Ctx);
  VB := FB.Eval(Ctx);
  case FKind of
    ckEq:  Res := VA.Equals(VB);
    ckNeq: Res := not VA.Equals(VB);
  else
    Cmp := VA.Compare(VB, Ok);
    if not Ok then
      Exit(TMVTValue.FromBool(False));
    case FKind of
      ckLt: Res := Cmp < 0;
      ckLe: Res := Cmp <= 0;
      ckGt: Res := Cmp > 0;
      ckGe: Res := Cmp >= 0;
    else
      Res := False;
    end;
  end;
  Result := TMVTValue.FromBool(Res);
end;
function TCompareExpr.IsFeatureConstant: Boolean;
begin
  Result := AllFeatureConstant([FA, FB]);
end;

{ TBoolExpr }
constructor TBoolExpr.Create(AKind: TBoolKind; const AArgs: TArray<IExpression>);
begin
  inherited Create;
  FKind := AKind;
  FArgs := AArgs;
end;
function TBoolExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  E: IExpression;
begin
  case FKind of
    bkAll:
      begin
        for E in FArgs do
          if not E.Eval(Ctx).AsBool then
            Exit(TMVTValue.FromBool(False));
        Result := TMVTValue.FromBool(True);
      end;
    bkAny:
      begin
        for E in FArgs do
          if E.Eval(Ctx).AsBool then
            Exit(TMVTValue.FromBool(True));
        Result := TMVTValue.FromBool(False);
      end;
    bkNot:
      Result := TMVTValue.FromBool(not FArgs[0].Eval(Ctx).AsBool);
  else
    Result := TMVTValue.FromBool(False);
  end;
end;
function TBoolExpr.IsFeatureConstant: Boolean;
begin
  Result := AllFeatureConstant(FArgs);
end;

{ TInExpr }
constructor TInExpr.Create(ANeedle: IExpression; const AHaystack: TArray<IExpression>);
begin
  inherited Create;
  FNeedle := ANeedle;
  FHaystack := AHaystack;
end;
function TInExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  N, H: TMVTValue;
  E: IExpression;
begin
  N := FNeedle.Eval(Ctx);
  // single collection arg that is a string -> substring test
  if Length(FHaystack) = 1 then
  begin
    H := FHaystack[0].Eval(Ctx);
    if (H.Kind = vkString) and (N.Kind = vkString) then
      Exit(TMVTValue.FromBool(H.AsString.Contains(N.AsString)));
    Exit(TMVTValue.FromBool(N.Equals(H)));
  end;
  for E in FHaystack do
    if N.Equals(E.Eval(Ctx)) then
      Exit(TMVTValue.FromBool(True));
  Result := TMVTValue.FromBool(False);
end;
function TInExpr.IsFeatureConstant: Boolean;
begin
  Result := FNeedle.IsFeatureConstant and AllFeatureConstant(FHaystack);
end;

{ TCaseExpr }
function TCaseExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  I: Integer;
begin
  for I := 0 to High(FConds) do
    if FConds[I].Eval(Ctx).AsBool then
      Exit(FOutputs[I].Eval(Ctx));
  if Assigned(FElse) then
    Result := FElse.Eval(Ctx)
  else
    Result := TMVTValue.Null;
end;
function TCaseExpr.IsFeatureConstant: Boolean;
begin
  Result := AllFeatureConstant(FConds) and AllFeatureConstant(FOutputs) and
            ((FElse = nil) or FElse.IsFeatureConstant);
end;

{ TMatchExpr }
function TMatchExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  V, Lbl: TMVTValue;
  I, J: Integer;
begin
  V := FInput.Eval(Ctx);
  for I := 0 to High(FLabels) do
    for J := 0 to High(FLabels[I]) do
    begin
      Lbl := FLabels[I][J];
      if V.Equals(Lbl) then
        Exit(FOutputs[I].Eval(Ctx));
    end;
  if Assigned(FDefault) then
    Result := FDefault.Eval(Ctx)
  else
    Result := TMVTValue.Null;
end;
function TMatchExpr.IsFeatureConstant: Boolean;
begin
  Result := FInput.IsFeatureConstant and AllFeatureConstant(FOutputs) and
            ((FDefault = nil) or FDefault.IsFeatureConstant);
end;

{ TStepExpr }
function TStepExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  X: Double;
  I, Sel: Integer;
begin
  X := FInput.Eval(Ctx).AsDouble(0);
  if (Length(FStops) = 0) or (X < FStops[0]) then
    Exit(FBase.Eval(Ctx));
  Sel := 0;
  for I := 0 to High(FStops) do
    if X >= FStops[I] then
      Sel := I
    else
      Break;
  Result := FOutputs[Sel].Eval(Ctx);
end;
function TStepExpr.IsFeatureConstant: Boolean;
begin
  Result := FInput.IsFeatureConstant and
            ((FBase = nil) or FBase.IsFeatureConstant) and
            AllFeatureConstant(FOutputs);
end;

{ Cubic-bezier easing y for progress x on the curve (0,0)(x1,y1)(x2,y2)(1,1).
  CSS/WebKit-style: Newton-Raphson on Bx(t)=x, then return By(t). }
function CubicBezierEase(X1, Y1, X2, Y2, X: Double): Double;

  function SampleX(T: Double): Double;
  begin  // 3(1-t)^2 t x1 + 3(1-t) t^2 x2 + t^3
    Result := 3 * Sqr(1 - T) * T * X1 + 3 * (1 - T) * Sqr(T) * X2 + T * T * T;
  end;
  function SampleY(T: Double): Double;
  begin
    Result := 3 * Sqr(1 - T) * T * Y1 + 3 * (1 - T) * Sqr(T) * Y2 + T * T * T;
  end;
  function SampleDX(T: Double): Double;  // dBx/dt
  begin
    Result := 3 * Sqr(1 - T) * X1 + 6 * (1 - T) * T * (X2 - X1) + 3 * Sqr(T) * (1 - X2);
  end;

var
  T, XEst, D, Lo, Hi: Double;
  I: Integer;
begin
  if X <= 0 then Exit(0);
  if X >= 1 then Exit(1);
  T := X;  // initial guess
  for I := 0 to 7 do
  begin
    XEst := SampleX(T) - X;
    if Abs(XEst) < 1e-6 then
      Exit(SampleY(T));
    D := SampleDX(T);
    if Abs(D) < 1e-6 then
      Break;
    T := T - XEst / D;
  end;
  // Newton failed to converge -> bisection on a bracketed root.
  Lo := 0; Hi := 1; T := X;
  for I := 0 to 31 do
  begin
    XEst := SampleX(T);
    if Abs(XEst - X) < 1e-6 then
      Break;
    if X > XEst then Lo := T else Hi := T;
    T := (Lo + Hi) / 2;
  end;
  Result := SampleY(T);
end;

{ TInterpolateExpr }
function TInterpolateExpr.Factor(X: Double; Lo, Hi: Double): Double;
begin
  if Hi <= Lo then
    Exit(0);
  if X <= Lo then Exit(0);
  if X >= Hi then Exit(1);
  case FMode of
    imExponential:
      if SameValue(FBase, 1.0) then
        Result := (X - Lo) / (Hi - Lo)
      else
        Result := (Power(FBase, X - Lo) - 1) / (Power(FBase, Hi - Lo) - 1);
    imCubicBezier:
      Result := CubicBezierEase(FBezX1, FBezY1, FBezX2, FBezY2, (X - Lo) / (Hi - Lo));
  else
    Result := (X - Lo) / (Hi - Lo);  // linear
  end;
end;

function TInterpolateExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  X, T: Double;
  I, Lo, Hi: Integer;
  VLo, VHi: TMVTValue;
  CLo, CHi: TMGLColor;
  OkLo, OkHi: Boolean;
  ALo, AHi: Double;
begin
  X := FInput.Eval(Ctx).AsDouble(0);
  if Length(FStops) = 0 then
    Exit(TMVTValue.Null);

  if X <= FStops[0] then
    Exit(FOutputs[0].Eval(Ctx));
  if X >= FStops[High(FStops)] then
    Exit(FOutputs[High(FStops)].Eval(Ctx));

  Lo := 0;
  for I := 0 to High(FStops) - 1 do
    if (X >= FStops[I]) and (X < FStops[I + 1]) then
    begin
      Lo := I;
      Break;
    end;
  Hi := Lo + 1;

  T := Factor(X, FStops[Lo], FStops[Hi]);
  VLo := FOutputs[Lo].Eval(Ctx);
  VHi := FOutputs[Hi].Eval(Ctx);

  // color interpolation if both endpoints parse as colors, in the requested space
  OkLo := (VLo.Kind = vkString) and TryParseColor(VLo.AsString, CLo);
  OkHi := (VHi.Kind = vkString) and TryParseColor(VHi.AsString, CHi);
  if OkLo and OkHi then
    case FColorSpace of
      icsLab: Exit(TMVTValue.FromString(CLo.LerpLab(CHi, T).ToCanonical));
      icsHcl: Exit(TMVTValue.FromString(CLo.LerpHcl(CHi, T).ToCanonical));
    else
      Exit(TMVTValue.FromString(CLo.Lerp(CHi, T).ToCanonical));
    end;

  // numeric interpolation
  ALo := VLo.AsDouble(OkLo);
  AHi := VHi.AsDouble(OkHi);
  Result := TMVTValue.FromDouble(ALo + (AHi - ALo) * T);
end;
function TInterpolateExpr.IsFeatureConstant: Boolean;
begin
  Result := FInput.IsFeatureConstant and AllFeatureConstant(FOutputs);
end;

{ TCoalesceExpr }
function TCoalesceExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  E: IExpression;
  V: TMVTValue;
begin
  for E in FArgs do
  begin
    V := E.Eval(Ctx);
    if not V.IsNull then
      Exit(V);
  end;
  Result := TMVTValue.Null;
end;
function TCoalesceExpr.IsFeatureConstant: Boolean;
begin
  Result := AllFeatureConstant(FArgs);
end;

{ TConcatExpr }
function TConcatExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  E: IExpression;
  S: string;
begin
  S := '';
  for E in FArgs do
    S := S + E.Eval(Ctx).AsString;
  Result := TMVTValue.FromString(S);
end;
function TConcatExpr.IsFeatureConstant: Boolean;
begin
  Result := AllFeatureConstant(FArgs);
end;

{ TCoerceExpr }
constructor TCoerceExpr.Create(AKind: TCoerceKind; const AArgs: TArray<IExpression>);
begin
  inherited Create;
  FKind := AKind;
  FArgs := AArgs;
end;
function TCoerceExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  V: TMVTValue;
  D: Double;
  Ok: Boolean;
  Col: TMGLColor;
  E: IExpression;
begin
  V := FArgs[0].Eval(Ctx);
  case FKind of
    ckToString:
      Result := TMVTValue.FromString(V.AsString);
    ckToNumber:
      begin
        // try each arg until one coerces
        for E in FArgs do
        begin
          D := E.Eval(Ctx).AsDouble(Ok);
          if Ok then
            Exit(TMVTValue.FromDouble(D));
        end;
        Result := TMVTValue.Null;
      end;
    ckToBoolean:
      Result := TMVTValue.FromBool(V.AsBool);
    ckToColor:
      begin
        for E in FArgs do
          if TryParseColor(E.Eval(Ctx).AsString, Col) then
            Exit(TMVTValue.FromString(Col.ToCanonical));
        Result := TMVTValue.Null;
      end;
    ckTypeof:
      case V.Kind of
        vkNull:   Result := TMVTValue.FromString('null');
        vkString: Result := TMVTValue.FromString('string');
        vkBool:   Result := TMVTValue.FromString('boolean');
      else
        Result := TMVTValue.FromString('number');
      end;
  else
    Result := V;
  end;
end;
function TCoerceExpr.IsFeatureConstant: Boolean;
begin
  Result := AllFeatureConstant(FArgs);
end;

{ TStringFnExpr }
constructor TStringFnExpr.Create(AKind: TStringFnKind; AArg: IExpression);
begin
  inherited Create;
  FKind := AKind;
  FArg := AArg;
end;
function TStringFnExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  S: string;
begin
  S := FArg.Eval(Ctx).AsString;
  case FKind of
    sfUpcase:   Result := TMVTValue.FromString(S.ToUpper);
    sfDowncase: Result := TMVTValue.FromString(S.ToLower);
    sfLength:   Result := TMVTValue.FromInt(Length(S));
  else
    Result := TMVTValue.FromString(S);
  end;
end;
function TStringFnExpr.IsFeatureConstant: Boolean;
begin
  Result := FArg.IsFeatureConstant;
end;

{ TMathExpr }
constructor TMathExpr.Create(AKind: TMathKind; const AArgs: TArray<IExpression>);
begin
  inherited Create;
  FKind := AKind;
  FArgs := AArgs;
end;
function TMathExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  A, B, R: Double;
  I: Integer;
begin
  // nullary constants
  case FKind of
    mkE:  Exit(TMVTValue.FromDouble(Exp(1)));
    mkPi: Exit(TMVTValue.FromDouble(Pi));
  end;

  A := 0;
  if Length(FArgs) > 0 then
    A := FArgs[0].Eval(Ctx).AsDouble(0);

  case FKind of
    mkAdd:
      begin R := 0; for I := 0 to High(FArgs) do R := R + FArgs[I].Eval(Ctx).AsDouble(0); end;
    mkMul:
      begin R := 1; for I := 0 to High(FArgs) do R := R * FArgs[I].Eval(Ctx).AsDouble(0); end;
    mkSub:
      if Length(FArgs) = 1 then R := -A
      else begin R := A; for I := 1 to High(FArgs) do R := R - FArgs[I].Eval(Ctx).AsDouble(0); end;
    mkDiv:
      begin
        R := A;
        for I := 1 to High(FArgs) do
        begin
          B := FArgs[I].Eval(Ctx).AsDouble(0);
          if B = 0 then Exit(TMVTValue.Null);
          R := R / B;
        end;
      end;
    mkMod:
      begin
        B := FArgs[1].Eval(Ctx).AsDouble(0);
        if B = 0 then Exit(TMVTValue.Null);
        R := A - B * Floor(A / B);
      end;
    mkPow: R := Power(A, FArgs[1].Eval(Ctx).AsDouble(0));
    mkMin:
      begin R := A; for I := 1 to High(FArgs) do R := Min(R, FArgs[I].Eval(Ctx).AsDouble(0)); end;
    mkMax:
      begin R := A; for I := 1 to High(FArgs) do R := Max(R, FArgs[I].Eval(Ctx).AsDouble(0)); end;
    mkAbs:   R := Abs(A);
    mkFloor: R := Floor(A);
    mkCeil:  R := Ceil(A);
    mkRound: R := Round(A);
    mkSqrt:  R := Sqrt(A);
    mkSin:   R := Sin(A);
    mkCos:   R := Cos(A);
    mkTan:   R := Tan(A);
    mkLn:    R := Ln(A);
    mkLog10: R := Log10(A);
    mkLog2:  R := Log2(A);
  else
    R := A;
  end;
  Result := TMVTValue.FromDouble(R);
end;
function TMathExpr.IsFeatureConstant: Boolean;
begin
  Result := AllFeatureConstant(FArgs);
end;

{ TRgbExpr }
function TRgbExpr.Eval(const Ctx: TExprContext): TMVTValue;
var
  Col: TMGLColor;
  A: Double;
begin
  A := 1;
  if FHasAlpha then
    A := FArgs[3].Eval(Ctx).AsDouble(1);
  Col := TMGLColor.Create(
    FArgs[0].Eval(Ctx).AsDouble(0) / 255,
    FArgs[1].Eval(Ctx).AsDouble(0) / 255,
    FArgs[2].Eval(Ctx).AsDouble(0) / 255,
    A);
  Result := TMVTValue.FromString(Col.ToCanonical);
end;
function TRgbExpr.IsFeatureConstant: Boolean;
begin
  Result := AllFeatureConstant(FArgs);
end;

{ ---- parser ---- }

function ParseArgs(A: TJSONArray; AStart: Integer): TArray<IExpression>; forward;

function ParseExpression(AJson: TJSONValue): IExpression;
var
  Arr: TJSONArray;
  Op: string;
  Args: TArray<IExpression>;

  function Sub(I: Integer): IExpression;
  begin
    Result := ParseExpression(Arr.Items[I]);
  end;

  function ParseValueList(J: TJSONValue): TArray<TMVTValue>;
  var
    LA: TJSONArray;
    K: Integer;
  begin
    if J is TJSONArray then
    begin
      LA := TJSONArray(J);
      SetLength(Result, LA.Count);
      for K := 0 to LA.Count - 1 do
        Result[K] := JsonScalarToValue(LA.Items[K]);
    end
    else
    begin
      SetLength(Result, 1);
      Result[0] := JsonScalarToValue(J);
    end;
  end;

begin
  // scalars -> literal
  if not (AJson is TJSONArray) then
    Exit(TLiteralExpr.Create(JsonScalarToValue(AJson)));

  Arr := TJSONArray(AJson);
  if Arr.Count = 0 then
    Exit(TLiteralExpr.Create(TMVTValue.Null));

  // first element must be an operator string (numbers are TJSONString too,
  // so a number-led array is a literal, not an expression)
  if not IsJsonOpString(Arr.Items[0]) then
    Exit(TLiteralExpr.Create(TMVTValue.Null));

  Op := TJSONString(Arr.Items[0]).Value;

  if Op = 'literal' then
  begin
    // ["literal", scalar]  (arrays/objects handled by callers needing lists)
    if (Arr.Count >= 2) and not (Arr.Items[1] is TJSONArray) then
      Exit(TLiteralExpr.Create(JsonScalarToValue(Arr.Items[1])));
    Exit(TLiteralExpr.Create(TMVTValue.Null));
  end;

  if Op = 'get' then
    Exit(TGetExpr.Create(Sub(1)));
  if Op = 'has' then
    Exit(THasExpr.Create(Sub(1)));
  if Op = 'zoom' then
    Exit(TZoomExpr.Create);
  if Op = 'line-progress' then
    Exit(TLineProgressExpr.Create);
  if Op = 'geometry-type' then
    Exit(TGeomTypeExpr.Create);
  if Op = 'id' then
    Exit(TIdExpr.Create);

  if Op = 'var' then
    Exit(TVarExpr.Create(TJSONString(Arr.Items[1]).Value));

  if Op = 'let' then
  begin
    var L := TLetExpr.Create;
    var N := (Arr.Count - 2) div 2;
    SetLength(L.FNames, N);
    SetLength(L.FValues, N);
    for var I := 0 to N - 1 do
    begin
      L.FNames[I] := TJSONString(Arr.Items[1 + I * 2]).Value;
      L.FValues[I] := Sub(2 + I * 2);
    end;
    L.FBody := Sub(Arr.Count - 1);
    Exit(L);
  end;

  // comparisons
  if Op = '==' then Exit(TCompareExpr.Create(ckEq, Sub(1), Sub(2)));
  if Op = '!=' then Exit(TCompareExpr.Create(ckNeq, Sub(1), Sub(2)));
  if Op = '<'  then Exit(TCompareExpr.Create(ckLt, Sub(1), Sub(2)));
  if Op = '<=' then Exit(TCompareExpr.Create(ckLe, Sub(1), Sub(2)));
  if Op = '>'  then Exit(TCompareExpr.Create(ckGt, Sub(1), Sub(2)));
  if Op = '>=' then Exit(TCompareExpr.Create(ckGe, Sub(1), Sub(2)));

  if Op = 'all' then Exit(TBoolExpr.Create(bkAll, ParseArgs(Arr, 1)));
  if Op = 'any' then Exit(TBoolExpr.Create(bkAny, ParseArgs(Arr, 1)));
  if Op = '!'   then Exit(TBoolExpr.Create(bkNot, ParseArgs(Arr, 1)));

  if Op = 'in' then
    Exit(TInExpr.Create(Sub(1), ParseArgs(Arr, 2)));

  if Op = 'case' then
  begin
    var C := TCaseExpr.Create;
    var N := (Arr.Count - 1) div 2;  // last is else
    SetLength(C.FConds, N);
    SetLength(C.FOutputs, N);
    for var I := 0 to N - 1 do
    begin
      C.FConds[I] := Sub(1 + I * 2);
      C.FOutputs[I] := Sub(2 + I * 2);
    end;
    if (Arr.Count - 1) mod 2 = 1 then
      C.FElse := Sub(Arr.Count - 1);
    Exit(C);
  end;

  if Op = 'match' then
  begin
    var M := TMatchExpr.Create;
    M.FInput := Sub(1);
    // branches: label,output pairs from index 2; if odd trailing -> default
    var Body := Arr.Count - 2;
    var HasDefault := Body mod 2 = 1;
    var N := Body div 2;
    SetLength(M.FLabels, N);
    SetLength(M.FOutputs, N);
    for var I := 0 to N - 1 do
    begin
      M.FLabels[I] := ParseValueList(Arr.Items[2 + I * 2]);
      M.FOutputs[I] := Sub(3 + I * 2);
    end;
    if HasDefault then
      M.FDefault := Sub(Arr.Count - 1);
    Exit(M);
  end;

  if Op = 'step' then
  begin
    var S := TStepExpr.Create;
    S.FInput := Sub(1);
    S.FBase := Sub(2);
    var N := (Arr.Count - 3) div 2;
    SetLength(S.FStops, N);
    SetLength(S.FOutputs, N);
    for var I := 0 to N - 1 do
    begin
      S.FStops[I] := JsonScalarToValue(Arr.Items[3 + I * 2]).AsDouble(0);
      S.FOutputs[I] := Sub(4 + I * 2);
    end;
    Exit(S);
  end;

  // interpolate (sRGB) / interpolate-lab (CIELAB) / interpolate-hcl (CIELCh)
  if (Op = 'interpolate') or (Op = 'interpolate-hcl') or (Op = 'interpolate-lab') then
  begin
    var It := TInterpolateExpr.Create;
    It.FBase := 1;
    if Op = 'interpolate-hcl' then It.FColorSpace := icsHcl
    else if Op = 'interpolate-lab' then It.FColorSpace := icsLab
    else It.FColorSpace := icsRgb;
    var Interp := Arr.Items[1] as TJSONArray;
    var Mode := TJSONString(Interp.Items[0]).Value;
    if Mode = 'linear' then It.FMode := imLinear
    else if Mode = 'exponential' then
    begin
      It.FMode := imExponential;
      It.FBase := JsonScalarToValue(Interp.Items[1]).AsDouble(1);
    end
    else if Mode = 'cubic-bezier' then
    begin
      It.FMode := imCubicBezier;
      It.FBezX1 := JsonScalarToValue(Interp.Items[1]).AsDouble(0);
      It.FBezY1 := JsonScalarToValue(Interp.Items[2]).AsDouble(0);
      It.FBezX2 := JsonScalarToValue(Interp.Items[3]).AsDouble(0);
      It.FBezY2 := JsonScalarToValue(Interp.Items[4]).AsDouble(0);
    end;
    It.FInput := Sub(2);
    var N := (Arr.Count - 3) div 2;
    SetLength(It.FStops, N);
    SetLength(It.FOutputs, N);
    for var I := 0 to N - 1 do
    begin
      It.FStops[I] := JsonScalarToValue(Arr.Items[3 + I * 2]).AsDouble(0);
      It.FOutputs[I] := Sub(4 + I * 2);
    end;
    Exit(It);
  end;

  if Op = 'coalesce' then
  begin
    var Co := TCoalesceExpr.Create;
    Co.FArgs := ParseArgs(Arr, 1);
    Exit(Co);
  end;

  if Op = 'concat' then
  begin
    var Cc := TConcatExpr.Create;
    Cc.FArgs := ParseArgs(Arr, 1);
    Exit(Cc);
  end;

  if Op = 'format' then
  begin
    // ["format", text, opts, text, opts, ...] - concatenate text sections,
    // formatting option objects evaluate to '' and drop out.
    var Fmt := TConcatExpr.Create;
    Fmt.FArgs := ParseArgs(Arr, 1);
    Exit(Fmt);
  end;

  if Op = 'number-format' then
    Exit(TCoerceExpr.Create(ckToString, [Sub(1)]));

  if Op = 'image' then
    Exit(TCoerceExpr.Create(ckToString, [Sub(1)]));

  if Op = 'to-string'  then Exit(TCoerceExpr.Create(ckToString, ParseArgs(Arr, 1)));
  if Op = 'to-number'  then Exit(TCoerceExpr.Create(ckToNumber, ParseArgs(Arr, 1)));
  if Op = 'to-boolean' then Exit(TCoerceExpr.Create(ckToBoolean, ParseArgs(Arr, 1)));
  if Op = 'to-color'   then Exit(TCoerceExpr.Create(ckToColor, ParseArgs(Arr, 1)));
  if Op = 'typeof'     then Exit(TCoerceExpr.Create(ckTypeof, ParseArgs(Arr, 1)));

  if Op = 'upcase'   then Exit(TStringFnExpr.Create(sfUpcase, Sub(1)));
  if Op = 'downcase' then Exit(TStringFnExpr.Create(sfDowncase, Sub(1)));
  if Op = 'length'   then Exit(TStringFnExpr.Create(sfLength, Sub(1)));

  if Op = '+' then Exit(TMathExpr.Create(mkAdd, ParseArgs(Arr, 1)));
  if Op = '-' then Exit(TMathExpr.Create(mkSub, ParseArgs(Arr, 1)));
  if Op = '*' then Exit(TMathExpr.Create(mkMul, ParseArgs(Arr, 1)));
  if Op = '/' then Exit(TMathExpr.Create(mkDiv, ParseArgs(Arr, 1)));
  if Op = '%' then Exit(TMathExpr.Create(mkMod, ParseArgs(Arr, 1)));
  if Op = '^' then Exit(TMathExpr.Create(mkPow, ParseArgs(Arr, 1)));
  if Op = 'min'   then Exit(TMathExpr.Create(mkMin, ParseArgs(Arr, 1)));
  if Op = 'max'   then Exit(TMathExpr.Create(mkMax, ParseArgs(Arr, 1)));
  if Op = 'abs'   then Exit(TMathExpr.Create(mkAbs, ParseArgs(Arr, 1)));
  if Op = 'floor' then Exit(TMathExpr.Create(mkFloor, ParseArgs(Arr, 1)));
  if Op = 'ceil'  then Exit(TMathExpr.Create(mkCeil, ParseArgs(Arr, 1)));
  if Op = 'round' then Exit(TMathExpr.Create(mkRound, ParseArgs(Arr, 1)));
  if Op = 'sqrt'  then Exit(TMathExpr.Create(mkSqrt, ParseArgs(Arr, 1)));
  if Op = 'sin'   then Exit(TMathExpr.Create(mkSin, ParseArgs(Arr, 1)));
  if Op = 'cos'   then Exit(TMathExpr.Create(mkCos, ParseArgs(Arr, 1)));
  if Op = 'tan'   then Exit(TMathExpr.Create(mkTan, ParseArgs(Arr, 1)));
  if Op = 'ln'    then Exit(TMathExpr.Create(mkLn, ParseArgs(Arr, 1)));
  if Op = 'log10' then Exit(TMathExpr.Create(mkLog10, ParseArgs(Arr, 1)));
  if Op = 'log2'  then Exit(TMathExpr.Create(mkLog2, ParseArgs(Arr, 1)));
  if Op = 'e'  then Exit(TMathExpr.Create(mkE, nil));
  if Op = 'pi' then Exit(TMathExpr.Create(mkPi, nil));

  if (Op = 'rgb') or (Op = 'rgba') then
  begin
    var Rc := TRgbExpr.Create;
    Rc.FHasAlpha := Op = 'rgba';
    Rc.FArgs := ParseArgs(Arr, 1);
    Exit(Rc);
  end;

  raise EMGLExpressionError.CreateFmt('Unknown expression operator: "%s"', [Op]);
end;

function ParseArgs(A: TJSONArray; AStart: Integer): TArray<IExpression>;
var
  I: Integer;
begin
  SetLength(Result, A.Count - AStart);
  for I := AStart to A.Count - 1 do
    Result[I - AStart] := ParseExpression(A.Items[I]);
end;

{ ---- legacy function compiler ---- }

function CompileFunction(AObj: TJSONObject): IExpression;
var
  StopsArr: TJSONArray;
  FnType, Prop: string;
  Base: Double;
  InputExpr: IExpression;
  N, I: Integer;
  DefVal: TJSONValue;

  function StopInput(Item: TJSONArray): TJSONValue;
  begin
    // [input, output] or [{zoom:..,value:..}, output]
    Result := Item.Items[0];
  end;
begin
  if not (AObj.GetValue('stops') is TJSONArray) then
    raise EMGLStyleError.Create('Function without stops');

  StopsArr := AObj.GetValue('stops') as TJSONArray;
  FnType := 'exponential';
  if AObj.GetValue('type') is TJSONString then
    FnType := TJSONString(AObj.GetValue('type')).Value;
  Prop := '';
  if AObj.GetValue('property') is TJSONString then
    Prop := TJSONString(AObj.GetValue('property')).Value;
  Base := 1;
  if AObj.GetValue('base') is TJSONNumber then
    Base := TJSONNumber(AObj.GetValue('base')).AsDouble;

  if Prop <> '' then
    InputExpr := TGetExpr.Create(TLiteralExpr.Create(TMVTValue.FromString(Prop)))
  else
    InputExpr := TZoomExpr.Create;

  N := StopsArr.Count;

  if FnType = 'identity' then
    Exit(InputExpr);

  if FnType = 'categorical' then
  begin
    var M := TMatchExpr.Create;
    M.FInput := InputExpr;
    SetLength(M.FLabels, N);
    SetLength(M.FOutputs, N);
    for I := 0 to N - 1 do
    begin
      var Item := StopsArr.Items[I] as TJSONArray;
      SetLength(M.FLabels[I], 1);
      M.FLabels[I][0] := JsonScalarToValue(StopInput(Item));
      M.FOutputs[I] := ParseExpression(Item.Items[1]);
    end;
    DefVal := AObj.GetValue('default');
    if Assigned(DefVal) then
      M.FDefault := ParseExpression(DefVal);
    Exit(M);
  end;

  if FnType = 'interval' then
  begin
    var S := TStepExpr.Create;
    S.FInput := InputExpr;
    // base output = first stop output; remaining become step pairs
    var Item0 := StopsArr.Items[0] as TJSONArray;
    S.FBase := ParseExpression(Item0.Items[1]);
    SetLength(S.FStops, N - 1);
    SetLength(S.FOutputs, N - 1);
    for I := 1 to N - 1 do
    begin
      var Item := StopsArr.Items[I] as TJSONArray;
      S.FStops[I - 1] := JsonScalarToValue(StopInput(Item)).AsDouble(0);
      S.FOutputs[I - 1] := ParseExpression(Item.Items[1]);
    end;
    Exit(S);
  end;

  // default: exponential interpolation
  var It := TInterpolateExpr.Create;
  It.FMode := imExponential;
  It.FBase := Base;
  It.FInput := InputExpr;
  SetLength(It.FStops, N);
  SetLength(It.FOutputs, N);
  for I := 0 to N - 1 do
  begin
    var Item := StopsArr.Items[I] as TJSONArray;
    It.FStops[I] := JsonScalarToValue(StopInput(Item)).AsDouble(0);
    It.FOutputs[I] := ParseExpression(Item.Items[1]);
  end;
  Result := It;
end;

{ ---- legacy filter compiler ---- }

function KeyExpr(const AKey: string): IExpression;
begin
  if AKey = '$type' then
    Result := TGeomTypeExpr.Create
  else if AKey = '$id' then
    Result := TIdExpr.Create
  else
    Result := TGetExpr.Create(TLiteralExpr.Create(TMVTValue.FromString(AKey)));
end;

function CompileFilter(AJson: TJSONValue): IExpression;
var
  Arr: TJSONArray;
  Op: string;
  Children: TArray<IExpression>;
  I: Integer;

  function IsExpressionForm: Boolean;
  begin
    // legacy comparison: arg[1] is a plain string key. Expression form: arg[1]
    // is itself an array (e.g. ["get","x"]).
    Result := (Arr.Count > 1) and (Arr.Items[1] is TJSONArray);
  end;

begin
  if not (AJson is TJSONArray) then
    Exit(nil);
  Arr := TJSONArray(AJson);
  if Arr.Count = 0 then
    Exit(nil);
  if not IsJsonOpString(Arr.Items[0]) then
    Exit(ParseExpression(AJson));

  Op := TJSONString(Arr.Items[0]).Value;

  if (Op = 'all') or (Op = 'any') or (Op = 'none') then
  begin
    SetLength(Children, Arr.Count - 1);
    for I := 1 to Arr.Count - 1 do
      Children[I - 1] := CompileFilter(Arr.Items[I]);
    if Op = 'all' then
      Exit(TBoolExpr.Create(bkAll, Children))
    else if Op = 'any' then
      Exit(TBoolExpr.Create(bkAny, Children))
    else
      Exit(TBoolExpr.Create(bkNot, [TBoolExpr.Create(bkAny, Children) as IExpression]));
  end;

  if (Op = '==') or (Op = '!=') or (Op = '<') or (Op = '<=') or
     (Op = '>') or (Op = '>=') then
  begin
    if IsExpressionForm then
      Exit(ParseExpression(AJson));
    var KE := KeyExpr(TJSONString(Arr.Items[1]).Value);
    var VE: IExpression := TLiteralExpr.Create(JsonScalarToValue(Arr.Items[2]));
    var K: TCompareKind;
    if Op = '==' then K := ckEq
    else if Op = '!=' then K := ckNeq
    else if Op = '<' then K := ckLt
    else if Op = '<=' then K := ckLe
    else if Op = '>' then K := ckGt
    else K := ckGe;
    Exit(TCompareExpr.Create(K, KE, VE));
  end;

  if (Op = 'has') or (Op = '!has') then
  begin
    var H: IExpression := THasExpr.Create(
      TLiteralExpr.Create(TMVTValue.FromString(TJSONString(Arr.Items[1]).Value)));
    if Op = '!has' then
      Exit(TBoolExpr.Create(bkNot, [H]));
    Exit(H);
  end;

  if (Op = 'in') or (Op = '!in') then
  begin
    var KE := KeyExpr(TJSONString(Arr.Items[1]).Value);
    SetLength(Children, Arr.Count - 2);
    for I := 2 to Arr.Count - 1 do
      Children[I - 2] := TLiteralExpr.Create(JsonScalarToValue(Arr.Items[I]));
    var InE: IExpression := TInExpr.Create(KE, Children);
    if Op = '!in' then
      Exit(TBoolExpr.Create(bkNot, [InE]));
    Exit(InE);
  end;

  // anything else: treat as a full expression
  Result := ParseExpression(AJson);
end;

end.
