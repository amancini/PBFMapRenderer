unit PBFMap.Style.Parser;

{
  PBFMapRenderer - Mapbox GL style.json parser

  Reads a local style.json (Mapbox GL / MapTiler) into a TMGLStyle, compiling
  every paint/layout property and the layer filter into expressions.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Math, System.JSON,
  RESILog,
  PBFMap.Types, PBFMap.Color, PBFMap.Expressions, PBFMap.Style.Model;

type
  TMGLStyleParser = class
  private
    FOnLog: TEvLog;
    { Fires OnLog if assigned (info/warning). Never raises. }
    procedure DoLog(const aFunction, aDescription: String; aLevel: TPLivLog;
      aIsDebug: Boolean = False);
    { Logs via OnLog when assigned; otherwise raises EMGLStyleError. }
    procedure LogOrRaise(const aFunction, aDescription: String; aLevel: TPLivLog);
    procedure ParseLayer(AObj: TJSONObject; AStyle: TMGLStyle);
    procedure ParseBag(AObj: TJSONObject; ABag: TMGLPropertyBag);
    function CompilePropValue(AValue: TJSONValue): IExpression;
  public
    /// <summary>Parse a style from a JSON string. Caller owns the result.</summary>
    function ParseString(const AJson: string): TMGLStyle;
    /// <summary>Load and parse a style.json file. Caller owns the result.</summary>
    function ParseFile(const AFileName: string): TMGLStyle;

    /// <summary>Optional ResiLog event fired on parse failures/skipped layers.</summary>
    property OnLog: TEvLog read FOnLog write FOnLog;
  end;

implementation

{ Returns the `class` values a filter REQUIRES (positive ==/in on class, possibly
  nested inside "all"), so the renderer can index features by class and skip the
  rest. Returns nil when the filter does not positively constrain class (then the
  renderer scans all features). The full filter is still evaluated for correctness;
  this only narrows the candidate set, so it must be a SUPERSET of passing classes. }
function ExtractFilterClasses(J: TJSONValue): TArray<string>;
var
  Arr: TJSONArray;
  Op, Key: string;
  I: Integer;
  Sub: TArray<string>;

  // True if Item denotes the "class" property: bare "class" or ["get","class"].
  function IsClassKey(Item: TJSONValue): Boolean;
  var A: TJSONArray;
  begin
    if (Item is TJSONString) and not (Item is TJSONNumber) then
      Exit(TJSONString(Item).Value = 'class');
    if Item is TJSONArray then
    begin
      A := TJSONArray(Item);
      Exit((A.Count = 2) and (A.Items[0] is TJSONString) and
        (TJSONString(A.Items[0]).Value = 'get') and (A.Items[1] is TJSONString) and
        (TJSONString(A.Items[1]).Value = 'class'));
    end;
    Result := False;
  end;

begin
  Result := nil;
  if not (J is TJSONArray) then
    Exit;
  Arr := TJSONArray(J);
  if (Arr.Count = 0) or not (Arr.Items[0] is TJSONString) then
    Exit;
  Op := TJSONString(Arr.Items[0]).Value;

  // ["==", <class>, "value"]
  if (Op = '==') and (Arr.Count = 3) and IsClassKey(Arr.Items[1]) and
     (Arr.Items[2] is TJSONString) and not (Arr.Items[2] is TJSONNumber) then
  begin
    SetLength(Result, 1);
    Result[0] := TJSONString(Arr.Items[2]).Value;
    Exit;
  end;

  // ["in", "class", "a", "b", ...]
  if (Op = 'in') and (Arr.Count >= 3) and IsClassKey(Arr.Items[1]) then
  begin
    for I := 2 to Arr.Count - 1 do
      if (Arr.Items[I] is TJSONString) and not (Arr.Items[I] is TJSONNumber) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := TJSONString(Arr.Items[I]).Value;
      end
      else
        Exit(nil);  // non-string member -> don't narrow
    Exit;
  end;

  // ["all", c1, c2, ...] -> the class constraint of any conjunct narrows the set
  if Op = 'all' then
    for I := 1 to Arr.Count - 1 do
    begin
      Sub := ExtractFilterClasses(Arr.Items[I]);
      if Sub <> nil then
        Exit(Sub);
    end;
end;

{ True if Item denotes the "class" property: bare "class" or ["get","class"]. }
function IsClassKeyJSON(Item: TJSONValue): Boolean;
var A: TJSONArray;
begin
  if (Item is TJSONString) and not (Item is TJSONNumber) then
    Exit(TJSONString(Item).Value = 'class');
  if Item is TJSONArray then
  begin
    A := TJSONArray(Item);
    Exit((A.Count = 2) and (A.Items[0] is TJSONString) and
      (TJSONString(A.Items[0]).Value = 'get') and (A.Items[1] is TJSONString) and
      (TJSONString(A.Items[1]).Value = 'class'));
  end;
  Result := False;
end;

{ True when the WHOLE filter is implied by the renderer's geometry gate
  (fill/fill-extrusion keep only Polygon, circle only Point) plus the class
  bucket — every conjunct is a redundant `$type==` (for the kind) or a positive
  `class ==`/`in`. Then the renderer may skip evaluating the filter entirely.
  Conservative: anything else (line `$type`, `!=`, `!in`, `any`, ranges, …) -> False. }
function ExtractFilterRedundant(J: TJSONValue; AKind: TMGLLayerKind): Boolean;

  function TypeConjunctRedundant(Arr: TJSONArray): Boolean;
  var T: string;
  begin
    // ["==", "$type", "Polygon"|"Point"] — redundant only where the gate is exact
    if (Arr.Count = 3) and (Arr.Items[0] is TJSONString) and
       (TJSONString(Arr.Items[0]).Value = '==') and (Arr.Items[1] is TJSONString) and
       (TJSONString(Arr.Items[1]).Value = '$type') and (Arr.Items[2] is TJSONString) then
    begin
      T := TJSONString(Arr.Items[2]).Value;
      Result := ((AKind in [lkFill, lkFillExtrusion]) and (T = 'Polygon')) or
                ((AKind = lkCircle) and (T = 'Point'));
    end
    else
      Result := False;
  end;

  function ConjunctRedundant(C: TJSONValue): Boolean;
  var Arr: TJSONArray; Op: string;
  begin
    if not (C is TJSONArray) then Exit(False);
    Arr := TJSONArray(C);
    if (Arr.Count = 0) or not (Arr.Items[0] is TJSONString) then Exit(False);
    Op := TJSONString(Arr.Items[0]).Value;
    // class == / in -> guaranteed by the bucket
    if ((Op = '==') and (Arr.Count = 3) and IsClassKeyJSON(Arr.Items[1])) or
       ((Op = 'in') and (Arr.Count >= 3) and IsClassKeyJSON(Arr.Items[1])) then
      Exit(True);
    // $type == -> guaranteed by the gate (exact kinds only)
    Result := TypeConjunctRedundant(Arr);
  end;

var
  Arr: TJSONArray;
  I: Integer;
begin
  Result := False;
  if not (J is TJSONArray) then Exit;
  Arr := TJSONArray(J);
  if (Arr.Count = 0) or not (Arr.Items[0] is TJSONString) then Exit;
  if TJSONString(Arr.Items[0]).Value = 'all' then
  begin
    for I := 1 to Arr.Count - 1 do
      if not ConjunctRedundant(Arr.Items[I]) then Exit(False);
    Result := Arr.Count > 1;  // ["all"] with no children -> not redundant
  end
  else
    Result := ConjunctRedundant(J);  // single-conjunct filter
end;

procedure TMGLStyleParser.DoLog(const aFunction, aDescription: String;
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

procedure TMGLStyleParser.LogOrRaise(const aFunction, aDescription: String;
  aLevel: TPLivLog);
begin
  if Assigned(FOnLog) then
    DoLog(aFunction, aDescription, aLevel)
  else
    raise EMGLStyleError.Create(aDescription);
end;

function TMGLStyleParser.ParseFile(const AFileName: string): TMGLStyle;
begin
  if not TFile.Exists(AFileName) then
  begin
    LogOrRaise(Format('%s.ParseFile', [Self.ClassName]),
      Format('Style file not found: %s', [AFileName]), tpliv1);
    Exit(TMGLStyle.Create);
  end;
  Result := ParseString(TFile.ReadAllText(AFileName, TEncoding.UTF8));
end;

function TMGLStyleParser.ParseString(const AJson: string): TMGLStyle;
var
  Root: TJSONValue;
  Obj: TJSONObject;
  Layers: TJSONArray;
  I: Integer;
  V: TJSONValue;
begin
  Root := nil;
  try
    try
      Root := TJSONObject.ParseJSONValue(AJson);
    except
      // Malformed JSON: treat as an invalid root below (logged or raised once).
      on Exception do
        Root := nil;
    end;

    if not (Root is TJSONObject) then
    begin
      // Result not yet allocated, so LogOrRaise may raise without leaking.
      LogOrRaise(Format('%s.ParseString', [Self.ClassName]),
        'Style root is not a valid JSON object', tpliv1);
      Exit(TMGLStyle.Create);   // empty style when a log handler is present
    end;

    Obj := TJSONObject(Root);
    Result := TMGLStyle.Create;

    if Obj.GetValue('name') is TJSONString then
      Result.Name := TJSONString(Obj.GetValue('name')).Value;

    V := Obj.GetValue('sprite');
    if V is TJSONString then Result.SpriteUrl := TJSONString(V).Value;
    V := Obj.GetValue('glyphs');
    if V is TJSONString then Result.GlyphsUrl := TJSONString(V).Value;

    if Obj.GetValue('layers') is TJSONArray then
    begin
      Layers := TJSONArray(Obj.GetValue('layers'));
      // A single malformed layer is skipped (and logged) rather than aborting
      // the whole style; the renderer simply omits it.
      for I := 0 to Layers.Count - 1 do
        if Layers.Items[I] is TJSONObject then
        try
          ParseLayer(TJSONObject(Layers.Items[I]), Result);
        except
          on E: Exception do
            DoLog(Format('%s.ParseString', [Self.ClassName]),
              Format('Skipped invalid layer #%d: %s', [I, E.Message]), tpliv3);
        end;
    end;
  finally
    Root.Free;
  end;
end;

procedure TMGLStyleParser.ParseLayer(AObj: TJSONObject; AStyle: TMGLStyle);
var
  Layer: TMGLLayer;
  V: TJSONValue;
begin
  Layer := TMGLLayer.Create;
  try
    if AObj.GetValue('id') is TJSONString then
      Layer.Id := TJSONString(AObj.GetValue('id')).Value;
    if AObj.GetValue('type') is TJSONString then
      Layer.Kind := LayerKindFromString(TJSONString(AObj.GetValue('type')).Value);
    if AObj.GetValue('source') is TJSONString then
      Layer.Source := TJSONString(AObj.GetValue('source')).Value;
    if AObj.GetValue('source-layer') is TJSONString then
      Layer.SourceLayer := TJSONString(AObj.GetValue('source-layer')).Value;

    V := AObj.GetValue('minzoom');
    if V is TJSONNumber then Layer.MinZoom := TJSONNumber(V).AsDouble;
    V := AObj.GetValue('maxzoom');
    if V is TJSONNumber then Layer.MaxZoom := TJSONNumber(V).AsDouble;

    V := AObj.GetValue('filter');
    if V <> nil then
    begin
      Layer.Filter := CompileFilter(V);
      Layer.FilterClasses := ExtractFilterClasses(V);  // class-index hint
      Layer.FilterRedundant := ExtractFilterRedundant(V, Layer.Kind);  // skip-eval hint
    end;

    if AObj.GetValue('layout') is TJSONObject then
      ParseBag(TJSONObject(AObj.GetValue('layout')), Layer.Layout);
    if AObj.GetValue('paint') is TJSONObject then
      ParseBag(TJSONObject(AObj.GetValue('paint')), Layer.Paint);

    // visibility lives in layout
    if Layer.Layout.Has('visibility') then
      Layer.Visible := Layer.Layout.EvalString('visibility',
        MakeContext(nil, 0, gtUnknown), 'visible') <> 'none';

    AStyle.AddLayer(Layer);
    Layer := nil;
  finally
    Layer.Free;
  end;
end;

{ Returns True and fills AValues when J is an array of only numeric literals
  (e.g. text-offset [0, 0.5]); these can't be expressed as a single IExpression. }
function TryNumericArray(J: TJSONValue; out AValues: TArray<Double>): Boolean;
var
  Arr: TJSONArray;
  I: Integer;
begin
  Result := False;
  if not (J is TJSONArray) then
    Exit;
  Arr := TJSONArray(J);
  if Arr.Count = 0 then
    Exit;
  SetLength(AValues, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    if not (Arr.Items[I] is TJSONNumber) then
    begin
      AValues := nil;
      Exit;
    end;
    AValues[I] := TJSONNumber(Arr.Items[I]).AsDouble;
  end;
  Result := True;
end;

procedure TMGLStyleParser.ParseBag(AObj: TJSONObject; ABag: TMGLPropertyBag);
var
  Pair: TJSONPair;
  Expr: IExpression;
  Nums: TArray<Double>;
begin
  for Pair in AObj do
  begin
    // Literal numeric arrays (text-offset, icon-offset, *-translate) are kept
    // whole; CompilePropValue would otherwise collapse them to the first value.
    if TryNumericArray(Pair.JsonValue, Nums) then
      ABag.SetFloatArray(Pair.JsonString.Value, Nums);
    Expr := CompilePropValue(Pair.JsonValue);
    if Expr <> nil then
      ABag.SetProp(Pair.JsonString.Value, Expr);
  end;
end;

function TMGLStyleParser.CompilePropValue(AValue: TJSONValue): IExpression;
var
  Arr: TJSONArray;
begin
  // Object with "stops" -> legacy function. Other objects are unsupported and
  // skipped. Arrays -> expression (with literal-array fallback). Scalars ->
  // literal expression.
  if AValue is TJSONObject then
  begin
    if TJSONObject(AValue).GetValue('stops') <> nil then
      Result := CompileFunction(TJSONObject(AValue))
    else
      Result := nil;
    Exit;
  end;

  if AValue is TJSONArray then
  begin
    Arr := TJSONArray(AValue);
    // A plain literal array (e.g. text-font ["Noto Sans Regular"]) is NOT an
    // expression: its head is a string but not a recognised operator. Only
    // treat the array as an expression when the head is a known operator;
    // otherwise fall back to a literal built from the first scalar element.
    try
      if (Arr.Count > 0) and IsJsonOpString(Arr.Items[0]) and
         IsKnownExpressionOp(TJSONString(Arr.Items[0]).Value) then
        Exit(ParseExpression(AValue));
    except
      on EMGLExpressionError do
        ; // fall through to literal
    end;
    if Arr.Count > 0 then
      Result := ParseExpression(Arr.Items[0])   // first scalar as literal
    else
      Result := nil;
    Exit;
  end;

  Result := ParseExpression(AValue);
end;

end.
