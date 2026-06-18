unit PBFMap.Tests;

{
  PBFMapRenderer - DUnitX test suite

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TCompressionTests = class
  public
    [Test] procedure GzipRoundTrip;
    [Test] procedure RawPassthrough;
  end;

  [TestFixture]
  TValueTests = class
  public
    [Test] procedure IntAsString;
    [Test] procedure DoubleAsString;
    [Test] procedure StringToNumber;
    [Test] procedure NumericEquality;
    [Test] procedure BoolTruthiness;
  end;

  [TestFixture]
  TColorTests = class
  public
    [Test] procedure HexShort;
    [Test] procedure HexLong;
    [Test] procedure RgbFunc;
    [Test] procedure RgbaFunc;
    [Test] procedure NamedColor;
    [Test] procedure InvalidColor;
    [Test] procedure HslColor;
    [Test] procedure Hex8Alpha;
  end;

  [TestFixture]
  TExpressionTests = class
  public
    [Test] procedure LiteralAndGet;
    [Test] procedure Comparison;
    [Test] procedure CaseExpr;
    [Test] procedure MatchExpr;
    [Test] procedure InterpolateLinear;
    [Test] procedure InterpolateColor;
    [Test] procedure StepExpr;
    [Test] procedure LegacyFilterAll;
    [Test] procedure LengthExpr;
    [Test] procedure InterpolateHclParses;
    [Test] procedure CubicBezierIdentityEqualsLinear;
    [Test] procedure CubicBezierEaseInOutSymmetric;
    [Test] procedure InterpolateLabIsGrayBetweenBlackWhite;
    [Test] procedure InterpolateLabDiffersFromRgb;
    [Test] procedure InterpolateHclDiffersFromRgb;
    [Test] procedure GetHashedLookupManyProps;
    [Test] procedure MatchCoercesNumericLabel;
    [Test] procedure CubicBezierMalformedRaisesNotAV;
  end;

  /// <summary>TPBFDecoder zero-copy sub-range view (the parser hot path).</summary>
  [TestFixture]
  TDecoderTests = class
  public
    [Test] procedure SubRangeReadsSameAsFull;
    [Test] procedure SubRangeBoundsGuard;
  end;

  [TestFixture]
  TGeometryTests = class
  public
    [Test] procedure PolygonWithHole;
    [Test] procedure LineString;
  end;

  /// <summary>IExpression.IsFeatureConstant correctness (drives the per-render
  /// property memoisation: a wrong True would cache a feature-dependent value).</summary>
  [TestFixture]
  TFeatureConstantTests = class
  public
    [Test] procedure LiteralIsFC;
    [Test] procedure ZoomIsFC;
    [Test] procedure InterpolateOverZoomIsFC;
    [Test] procedure StepOverZoomIsFC;
    [Test] procedure ArithmeticOverZoomIsFC;
    [Test] procedure GetIsNotFC;
    [Test] procedure InterpolateOverGetIsNotFC;
    [Test] procedure CaseReferencingGetIsNotFC;
    [Test] procedure MatchOnGetIsNotFC;
    [Test] procedure GeometryTypeIsNotFC;
  end;

  /// <summary>TMGLPropertyBag.Eval* correctness for feature-constant vs
  /// feature-dependent properties: a zoom-only property gives the same value for
  /// every feature and tracks zoom; a feature property gives per-feature values.
  /// (Guards any future per-renderer memo of feature-constant properties.)</summary>
  [TestFixture]
  TPropertyBagMemoTests = class
  public
    [Test] procedure FeatureConstantFloatMemoisedCorrectly;
    [Test] procedure MemoRefreshesWhenZoomChanges;
    [Test] procedure FeatureDependentFloatNotMemoised;
    [Test] procedure FeatureConstantColorMemoisedCorrectly;
    [Test] procedure ConstantFloatStillWorks;
    [Test] procedure ActiveCacheMemoisesFeatureConstant;
    [Test] procedure ActiveCacheDoesNotMemoiseFeatureDependent;
  end;

implementation

uses
  System.SysUtils, System.JSON,
  PBFMap.Types, PBFMap.Geometry, PBFMap.Compression, PBFMap.MVT.Types,
  PBFMap.MVT.Parser, PBFMap.Color, PBFMap.Expressions, PBFMap.Style.Model,
  PBFMap.Decoder, PBFMap.TestUtils;

function ParseExpr(const AJson: string): IExpression;
var
  J: TJSONValue;
begin
  J := TJSONObject.ParseJSONValue(AJson);
  try
    Result := ParseExpression(J);
  finally
    J.Free;
  end;
end;

function Eval(const AJson: string; AFeature: TMVTFeature; AZoom: Double): TMVTValue;
var
  J: TJSONValue;
  E: IExpression;
begin
  J := TJSONObject.ParseJSONValue(AJson);
  try
    E := ParseExpression(J);
    Result := E.Eval(MakeContext(AFeature, AZoom, gtPolygon));
  finally
    J.Free;
  end;
end;

{ TCompressionTests }

procedure TCompressionTests.GzipRoundTrip;
var
  Original, Compressed, Decompressed: TBytes;
begin
  Original := TEncoding.UTF8.GetBytes('hello vector tile world');
  Compressed := GzipBytes(Original);
  Assert.AreEqual($1F, Integer(Compressed[0]), 'gzip magic byte 0');
  Decompressed := DecompressTile(Compressed);
  Assert.AreEqual(TEncoding.UTF8.GetString(Original), TEncoding.UTF8.GetString(Decompressed));
end;

procedure TCompressionTests.RawPassthrough;
var
  Raw, Out: TBytes;
begin
  Raw := TBytes.Create(10, 20, 30, 40);
  Out := DecompressTile(Raw);
  Assert.AreEqual(4, Length(Out));
  Assert.AreEqual(20, Integer(Out[1]));
end;

{ TValueTests }

procedure TValueTests.IntAsString;
begin
  Assert.AreEqual('42', TMVTValue.FromInt(42).AsString);
end;

procedure TValueTests.DoubleAsString;
begin
  Assert.AreEqual('1.5', TMVTValue.FromDouble(1.5).AsString);
end;

procedure TValueTests.StringToNumber;
var
  Ok: Boolean;
begin
  Assert.AreEqual(Double(3.14), TMVTValue.FromString('3.14').AsDouble(Ok), 0.0001);
  Assert.IsTrue(Ok);
end;

procedure TValueTests.NumericEquality;
begin
  Assert.IsTrue(TMVTValue.FromInt(5).Equals(TMVTValue.FromDouble(5.0)));
  Assert.IsFalse(TMVTValue.FromString('5').Equals(TMVTValue.FromInt(5)));
end;

procedure TValueTests.BoolTruthiness;
begin
  Assert.IsFalse(TMVTValue.FromInt(0).AsBool);
  Assert.IsTrue(TMVTValue.FromInt(1).AsBool);
  Assert.IsFalse(TMVTValue.FromString('').AsBool);
  Assert.IsTrue(TMVTValue.FromString('x').AsBool);
end;

{ TColorTests }

procedure TColorTests.HexShort;
var
  C: TMGLColor;
begin
  Assert.IsTrue(TryParseColor('#f00', C));
  Assert.AreEqual(Double(1.0), C.R, 0.001);
  Assert.AreEqual(Double(0.0), C.G, 0.001);
end;

procedure TColorTests.HexLong;
var
  C: TMGLColor;
begin
  Assert.IsTrue(TryParseColor('#00ff00', C));
  Assert.AreEqual(Double(1.0), C.G, 0.001);
end;

procedure TColorTests.RgbFunc;
var
  C: TMGLColor;
begin
  Assert.IsTrue(TryParseColor('rgb(255,0,0)', C));
  Assert.AreEqual(Double(1.0), C.R, 0.001);
end;

procedure TColorTests.RgbaFunc;
var
  C: TMGLColor;
begin
  Assert.IsTrue(TryParseColor('rgba(0,0,0,0.5)', C));
  Assert.AreEqual(Double(0.5), C.A, 0.01);
end;

procedure TColorTests.NamedColor;
var
  C: TMGLColor;
begin
  Assert.IsTrue(TryParseColor('blue', C));
  Assert.AreEqual(Double(1.0), C.B, 0.001);
end;

procedure TColorTests.HslColor;
var
  C: TMGLColor;
begin
  // hsl(0,100%,50%) is pure red
  Assert.IsTrue(TryParseColor('hsl(0, 100%, 50%)', C));
  Assert.AreEqual(Double(1.0), C.R, 0.02);
  Assert.AreEqual(Double(0.0), C.G, 0.02);
  Assert.AreEqual(Double(0.0), C.B, 0.02);
end;

procedure TColorTests.Hex8Alpha;
var
  C: TMGLColor;
begin
  // #ff000080 -> red at ~50% alpha
  Assert.IsTrue(TryParseColor('#ff000080', C));
  Assert.AreEqual(Double(1.0), C.R, 0.001);
  Assert.AreEqual(Double(0.5), C.A, 0.02);
end;

procedure TColorTests.InvalidColor;
var
  C: TMGLColor;
begin
  Assert.IsFalse(TryParseColor('notacolor', C));
end;

{ TExpressionTests }

procedure TExpressionTests.LiteralAndGet;
var
  F: TMVTFeature;
begin
  F := TMVTFeature.Create;
  try
    F.SetProp('class', TMVTValue.FromString('motorway'));
    Assert.AreEqual('motorway', Eval('["get","class"]', F, 10).AsString);
    Assert.AreEqual('hi', Eval('"hi"', F, 10).AsString);
  finally
    F.Free;
  end;
end;

procedure TExpressionTests.Comparison;
var
  F: TMVTFeature;
begin
  F := TMVTFeature.Create;
  try
    F.SetProp('n', TMVTValue.FromInt(7));
    Assert.IsTrue(Eval('[">",["get","n"],5]', F, 10).AsBool);
    Assert.IsFalse(Eval('["<",["get","n"],5]', F, 10).AsBool);
    Assert.IsTrue(Eval('["==",["get","n"],7]', F, 10).AsBool);
  finally
    F.Free;
  end;
end;

procedure TExpressionTests.CaseExpr;
var
  F: TMVTFeature;
begin
  F := TMVTFeature.Create;
  try
    F.SetProp('t', TMVTValue.FromString('a'));
    Assert.AreEqual('yes',
      Eval('["case",["==",["get","t"],"a"],"yes","no"]', F, 10).AsString);
  finally
    F.Free;
  end;
end;

procedure TExpressionTests.MatchExpr;
var
  F: TMVTFeature;
begin
  F := TMVTFeature.Create;
  try
    F.SetProp('k', TMVTValue.FromString('b'));
    Assert.AreEqual('two',
      Eval('["match",["get","k"],"a","one","b","two","def"]', F, 10).AsString);
    F.SetProp('k', TMVTValue.FromString('z'));
    Assert.AreEqual('def',
      Eval('["match",["get","k"],"a","one","b","two","def"]', F, 10).AsString);
  finally
    F.Free;
  end;
end;

procedure TExpressionTests.InterpolateLinear;
begin
  // zoom 12 between (10->0) and (14->100) -> 50
  Assert.AreEqual(Double(50.0),
    Eval('["interpolate",["linear"],["zoom"],10,0,14,100]', nil, 12).AsDouble, 0.01);
end;

procedure TExpressionTests.InterpolateColor;
var
  S: string;
begin
  // midway between black and white at zoom 12 -> ~rgb 128
  S := Eval('["interpolate",["linear"],["zoom"],10,"#000000",14,"#ffffff"]', nil, 12).AsString;
  Assert.IsTrue(S.StartsWith('rgba('), 'color result should be canonical rgba: ' + S);
  Assert.IsTrue(S.Contains('127') or S.Contains('128'), 'mid gray expected: ' + S);
end;

procedure TExpressionTests.StepExpr;
begin
  Assert.AreEqual(Double(1.0),
    Eval('["step",["zoom"],1,10,2,14,3]', nil, 5).AsDouble, 0.001);
  Assert.AreEqual(Double(2.0),
    Eval('["step",["zoom"],1,10,2,14,3]', nil, 11).AsDouble, 0.001);
  Assert.AreEqual(Double(3.0),
    Eval('["step",["zoom"],1,10,2,14,3]', nil, 20).AsDouble, 0.001);
end;

procedure TExpressionTests.LegacyFilterAll;
var
  J: TJSONValue;
  E: IExpression;
  F: TMVTFeature;
begin
  F := TMVTFeature.Create;
  try
    F.SetProp('class', TMVTValue.FromString('water'));
    J := TJSONObject.ParseJSONValue('["all",["==","class","water"]]');
    try
      E := CompileFilter(J);
      Assert.IsTrue(E.Eval(MakeContext(F, 10, gtPolygon)).AsBool);
    finally
      J.Free;
    end;
  finally
    F.Free;
  end;
end;

procedure TExpressionTests.LengthExpr;
begin
  Assert.AreEqual('3', Eval('["length","abc"]', nil, 10).AsString);
end;

procedure TExpressionTests.InterpolateHclParses;
begin
  // interpolate-hcl must be recognised, not raise.
  Assert.IsTrue(Eval('["interpolate-hcl",["linear"],["zoom"],0,"red",10,"blue"]',
    nil, 5).AsString <> '');
end;

procedure TExpressionTests.CubicBezierIdentityEqualsLinear;
begin
  // cubic-bezier (0,0,1,1) is the identity curve -> same as linear
  Assert.AreEqual(Double(50.0),
    Eval('["interpolate",["cubic-bezier",0,0,1,1],["zoom"],0,0,10,100]', nil, 5).AsDouble, 0.5,
    'identity bezier == linear');
end;

procedure TExpressionTests.CubicBezierEaseInOutSymmetric;
begin
  // ease-in-out (0.42,0,0.58,1) is symmetric: midpoint stays 50
  Assert.AreEqual(Double(50.0),
    Eval('["interpolate",["cubic-bezier",0.42,0,0.58,1],["zoom"],0,0,10,100]', nil, 5).AsDouble, 1.0,
    'symmetric ease midpoint');
  // and it eases IN: at 25% progress the value is below the linear 25
  Assert.IsTrue(
    Eval('["interpolate",["cubic-bezier",0.42,0,0.58,1],["zoom"],0,0,10,100]', nil, 2.5).AsDouble < 24,
    'ease-in below linear at 25%');
end;

procedure TExpressionTests.InterpolateLabIsGrayBetweenBlackWhite;
var
  C: TMGLColor;
begin
  // LAB midpoint of black..white is neutral gray, but lighter-coded than sRGB 127
  Assert.IsTrue(TryParseColor(
    Eval('["interpolate-lab",["linear"],["zoom"],0,"#000000",10,"#ffffff"]', nil, 5).AsString, C));
  Assert.AreEqual(C.R, C.G, 0.02, 'neutral gray R=G');
  Assert.AreEqual(C.G, C.B, 0.02, 'neutral gray G=B');
  Assert.IsTrue((C.R > 0.40) and (C.R < 0.52), 'L*=50 gray ~0.46');
end;

procedure TExpressionTests.InterpolateLabDiffersFromRgb;
var
  SRgb, SLab: string;
begin
  SRgb := Eval('["interpolate",["linear"],["zoom"],0,"#ff0000",10,"#00ff00"]', nil, 5).AsString;
  SLab := Eval('["interpolate-lab",["linear"],["zoom"],0,"#ff0000",10,"#00ff00"]', nil, 5).AsString;
  Assert.AreNotEqual(SRgb, SLab, 'LAB interpolation must differ from sRGB');
end;

procedure TExpressionTests.InterpolateHclDiffersFromRgb;
var
  SRgb, SHcl: string;
begin
  SRgb := Eval('["interpolate",["linear"],["zoom"],0,"#ff0000",10,"#00ff00"]', nil, 5).AsString;
  SHcl := Eval('["interpolate-hcl",["linear"],["zoom"],0,"#ff0000",10,"#00ff00"]', nil, 5).AsString;
  Assert.AreNotEqual(SRgb, SHcl, 'HCL interpolation must differ from sRGB');
end;

procedure TExpressionTests.GetHashedLookupManyProps;
var
  F: TMVTFeature;
begin
  // many props -> exercises the hashed get-key lookup path (GetPropH)
  F := TMVTFeature.Create;
  try
    F.SetProp('class', TMVTValue.FromString('motorway'));
    F.SetProp('subclass', TMVTValue.FromString('primary'));
    F.SetProp('rank', TMVTValue.FromInt(3));
    F.SetProp('brunnel', TMVTValue.FromString('bridge'));
    F.SetProp('name', TMVTValue.FromString('Via Roma'));
    F.SetProp('oneway', TMVTValue.FromInt(1));
    Assert.AreEqual('motorway', Eval('["get","class"]', F, 14).AsString);
    Assert.AreEqual('bridge', Eval('["get","brunnel"]', F, 14).AsString);
    Assert.AreEqual(Double(3), Eval('["get","rank"]', F, 14).AsDouble, 0.001);
    Assert.IsTrue(Eval('["has","name"]', F, 14).AsBool);
    Assert.IsFalse(Eval('["has","missing"]', F, 14).AsBool, 'absent key');
    Assert.IsTrue(Eval('["get","missing"]', F, 14).IsNull, 'absent get -> null');
    Assert.IsTrue(Eval('["==",["get","subclass"],"primary"]', F, 14).AsBool);
  finally
    F.Free;
  end;
end;

procedure TExpressionTests.MatchCoercesNumericLabel;
var
  F: TMVTFeature;
begin
  // numeric feature value 1 must match the string label "1" (cross-type coercion)
  F := TMVTFeature.Create;
  try
    F.SetProp('rank', TMVTValue.FromInt(1));
    Assert.AreEqual('one',
      Eval('["match",["get","rank"],"1","one","def"]', F, 14).AsString);
  finally
    F.Free;
  end;
end;

procedure TExpressionTests.CubicBezierMalformedRaisesNotAV;
begin
  // too few control points -> typed EMGLExpressionError (graceful), not an AV
  Assert.WillRaise(
    procedure
    begin
      Eval('["interpolate",["cubic-bezier",0,0],["zoom"],0,0,10,100]', nil, 5);
    end, EMGLExpressionError);
end;

{ TDecoderTests }

procedure TDecoderTests.SubRangeReadsSameAsFull;
var
  Data: TBytes;
  D: TPBFDecoder;
begin
  // 0xAA | varint 300 ($AC $02) | 0xBB ; the sub-range [1,2) shares the buffer
  Data := [$AA, $AC, $02, $BB];
  D := TPBFDecoder.Create(Data, 1, 2);
  try
    Assert.AreEqual(UInt64(300), D.ReadVarint, 'varint read from shared sub-range');
    Assert.IsFalse(D.HasMore, 'sub-range is bounded to its 2 bytes (FEnd)');
  finally
    D.Free;
  end;
end;

procedure TDecoderTests.SubRangeBoundsGuard;
var
  Data: TBytes;
  D: TPBFDecoder;
begin
  Data := [$AA, $AC, $02, $BB];
  D := TPBFDecoder.Create(Data, 1, 2);
  try
    D.ReadVarint;  // consume the 2 bytes
    Assert.AreEqual(0, D.Remaining, 'Remaining respects the sub-range end');
    Assert.WillRaise(
      procedure
      begin
        D.ReadVarint;  // past FEnd -> raises, does NOT read into 0xBB
      end, EPBFDecoderError);
  finally
    D.Free;
  end;
end;

{ TGeometryTests }

function BuildPolygonTile: TBytes;
var
  Tile, Layer, Feature: TPBWriter;
  Geom: TGeomBuilder;
  Cmds: TArray<UInt64>;
begin
  // exterior ring (CW) + a reverse-wound hole
  Geom := TGeomBuilder.Create;
  try
    // exterior 0,0 -> 100,0 -> 100,100 -> 0,100
    Geom.MoveTo(0, 0);
    Geom.LineTo(100, 0);
    Geom.LineTo(100, 100);
    Geom.LineTo(0, 100);
    Geom.ClosePath;
    // hole (opposite winding) 25,25 -> 25,75 -> 75,75 -> 75,25
    Geom.MoveTo(25, 25);
    Geom.LineTo(25, 75);
    Geom.LineTo(75, 75);
    Geom.LineTo(75, 25);
    Geom.ClosePath;
    Cmds := Geom.Commands;
  finally
    Geom.Free;
  end;

  Feature := TPBWriter.Create;
  try
    Feature.WriteVarintField(1, 1);          // id
    Feature.WriteVarintField(3, 3);          // type = POLYGON
    Feature.WritePackedVarints(4, Cmds);     // geometry

    Layer := TPBWriter.Create;
    try
      Layer.WriteVarintField(15, 2);         // version
      Layer.WriteStringField(1, 'poly');     // name
      Layer.WriteBytesField(2, Feature.ToBytes); // feature
      Layer.WriteVarintField(5, 4096);       // extent

      Tile := TPBWriter.Create;
      try
        Tile.WriteBytesField(3, Layer.ToBytes);  // layer
        Result := Tile.ToBytes;
      finally
        Tile.Free;
      end;
    finally
      Layer.Free;
    end;
  finally
    Feature.Free;
  end;
end;

procedure TGeometryTests.PolygonWithHole;
var
  Parser: TMVTTileParser;
  Tile: TMVTTile;
  Layer: TMVTLayer;
  Geom: TMVTGeometry;
  ExtCount, IntCount, I: Integer;
begin
  Parser := TMVTTileParser.Create;
  try
    Tile := Parser.Parse(BuildPolygonTile);
    try
      Assert.AreEqual(1, Tile.Layers.Count);
      Layer := Tile.LayerByName('poly');
      Assert.IsNotNull(Layer);
      Assert.AreEqual(1, Layer.Features.Count);
      Geom := Layer.Features[0].Geometry;
      Assert.AreEqual(2, Geom.Parts.Count, 'exterior + hole');

      ExtCount := 0; IntCount := 0;
      for I := 0 to Geom.Parts.Count - 1 do
        if Geom.Parts[I].Role = rrExterior then Inc(ExtCount)
        else if Geom.Parts[I].Role = rrInterior then Inc(IntCount);
      Assert.AreEqual(1, ExtCount, 'one exterior');
      Assert.AreEqual(1, IntCount, 'one hole');

      // first vertex delta-decoded back to (0,0)
      Assert.AreEqual(0, Geom.Parts[0].Points[0].X);
      Assert.AreEqual(0, Geom.Parts[0].Points[0].Y);
      Assert.AreEqual(100, Geom.Parts[0].Points[1].X);
    finally
      Tile.Free;
    end;
  finally
    Parser.Free;
  end;
end;

procedure TGeometryTests.LineString;
var
  Geom: TGeomBuilder;
  Cmds: TArray<UInt64>;
  Feature, Layer, Tile: TPBWriter;
  Parser: TMVTTileParser;
  T: TMVTTile;
  G: TMVTGeometry;
begin
  Geom := TGeomBuilder.Create;
  try
    Geom.MoveTo(0, 0);
    Geom.LineTo(10, 10);
    Geom.MoveTo(50, 50);    // second part
    Geom.LineTo(60, 60);
    Cmds := Geom.Commands;
  finally
    Geom.Free;
  end;

  Feature := TPBWriter.Create;
  Layer := TPBWriter.Create;
  Tile := TPBWriter.Create;
  try
    Feature.WriteVarintField(3, 2);          // LINESTRING
    Feature.WritePackedVarints(4, Cmds);
    Layer.WriteVarintField(15, 2);
    Layer.WriteStringField(1, 'lines');
    Layer.WriteBytesField(2, Feature.ToBytes);
    Tile.WriteBytesField(3, Layer.ToBytes);

    Parser := TMVTTileParser.Create;
    try
      T := Parser.Parse(Tile.ToBytes);
      try
        G := T.LayerByName('lines').Features[0].Geometry;
        Assert.AreEqual(2, G.Parts.Count, 'two line parts');
        Assert.AreEqual(60, G.Parts[1].Points[1].X);
      finally
        T.Free;
      end;
    finally
      Parser.Free;
    end;
  finally
    Feature.Free; Layer.Free; Tile.Free;
  end;
end;

{ TFeatureConstantTests }

procedure TFeatureConstantTests.LiteralIsFC;
begin
  Assert.IsTrue(ParseExpr('5').IsFeatureConstant);
  Assert.IsTrue(ParseExpr('"#ff0000"').IsFeatureConstant);
end;

procedure TFeatureConstantTests.ZoomIsFC;
begin
  Assert.IsTrue(ParseExpr('["zoom"]').IsFeatureConstant);
end;

procedure TFeatureConstantTests.InterpolateOverZoomIsFC;
begin
  Assert.IsTrue(ParseExpr('["interpolate",["linear"],["zoom"],10,1,14,5]').IsFeatureConstant,
    'zoom-interpolate is feature-independent');
end;

procedure TFeatureConstantTests.StepOverZoomIsFC;
begin
  Assert.IsTrue(ParseExpr('["step",["zoom"],1,10,2,14,3]').IsFeatureConstant);
end;

procedure TFeatureConstantTests.ArithmeticOverZoomIsFC;
begin
  Assert.IsTrue(ParseExpr('["*",["zoom"],2]').IsFeatureConstant);
end;

procedure TFeatureConstantTests.GetIsNotFC;
begin
  Assert.IsFalse(ParseExpr('["get","class"]').IsFeatureConstant,
    'get reads the feature -> NOT feature-constant');
end;

procedure TFeatureConstantTests.InterpolateOverGetIsNotFC;
begin
  // input is a feature property -> result varies per feature
  Assert.IsFalse(ParseExpr('["interpolate",["linear"],["get","r"],0,1,10,5]').IsFeatureConstant);
end;

procedure TFeatureConstantTests.CaseReferencingGetIsNotFC;
begin
  Assert.IsFalse(ParseExpr('["case",["==",["get","t"],"a"],1,2]').IsFeatureConstant);
end;

procedure TFeatureConstantTests.MatchOnGetIsNotFC;
begin
  Assert.IsFalse(ParseExpr('["match",["get","k"],"a",1,2]').IsFeatureConstant);
end;

procedure TFeatureConstantTests.GeometryTypeIsNotFC;
begin
  Assert.IsFalse(ParseExpr('["geometry-type"]').IsFeatureConstant);
end;

{ TPropertyBagMemoTests }

procedure TPropertyBagMemoTests.FeatureConstantFloatMemoisedCorrectly;
var
  Bag: TMGLPropertyBag;
  FA, FB: TMVTFeature;
  Expected: Double;
begin
  // line-width = zoom-interpolate 10->1, 14->5; at zoom 12 -> 3 for EVERY feature
  Bag := TMGLPropertyBag.Create;
  FA := TMVTFeature.Create;
  FB := TMVTFeature.Create;
  try
    FA.SetProp('w', TMVTValue.FromInt(99));   // must be ignored (expr is zoom-only)
    FB.SetProp('w', TMVTValue.FromInt(-99));
    Bag.SetProp('line-width', ParseExpr('["interpolate",["linear"],["zoom"],10,1,14,5]'));
    Expected := Eval('["interpolate",["linear"],["zoom"],10,1,14,5]', nil, 12).AsDouble;
    Assert.AreEqual(Expected,
      Bag.EvalFloat('line-width', MakeContext(FA, 12, gtLineString), 0), 0.0001, 'feature A');
    // second feature at same zoom must get the SAME (memoised) value
    Assert.AreEqual(Expected,
      Bag.EvalFloat('line-width', MakeContext(FB, 12, gtLineString), 0), 0.0001, 'feature B reuse');
  finally
    FA.Free; FB.Free; Bag.Free;
  end;
end;

procedure TPropertyBagMemoTests.MemoRefreshesWhenZoomChanges;
var
  Bag: TMGLPropertyBag;
begin
  Bag := TMGLPropertyBag.Create;
  try
    Bag.SetProp('line-width', ParseExpr('["interpolate",["linear"],["zoom"],10,1,14,5]'));
    Assert.AreEqual(Double(1.0), Bag.EvalFloat('line-width', MakeContext(nil, 10, gtLineString), 0), 0.001, 'z10');
    Assert.AreEqual(Double(3.0), Bag.EvalFloat('line-width', MakeContext(nil, 12, gtLineString), 0), 0.001, 'z12 must refresh, not stale 1.0');
    Assert.AreEqual(Double(5.0), Bag.EvalFloat('line-width', MakeContext(nil, 14, gtLineString), 0), 0.001, 'z14');
    Assert.AreEqual(Double(1.0), Bag.EvalFloat('line-width', MakeContext(nil, 10, gtLineString), 0), 0.001, 'back to z10');
  finally
    Bag.Free;
  end;
end;

procedure TPropertyBagMemoTests.FeatureDependentFloatNotMemoised;
var
  Bag: TMGLPropertyBag;
  FA, FB: TMVTFeature;
begin
  // width = feature property -> MUST return per-feature values (not memoised)
  Bag := TMGLPropertyBag.Create;
  FA := TMVTFeature.Create;
  FB := TMVTFeature.Create;
  try
    FA.SetProp('w', TMVTValue.FromInt(5));
    FB.SetProp('w', TMVTValue.FromInt(9));
    Bag.SetProp('line-width', ParseExpr('["get","w"]'));
    Assert.AreEqual(Double(5.0), Bag.EvalFloat('line-width', MakeContext(FA, 12, gtLineString), 0), 0.001, 'feature A=5');
    Assert.AreEqual(Double(9.0), Bag.EvalFloat('line-width', MakeContext(FB, 12, gtLineString), 0), 0.001,
      'feature B=9 (would be 5 if wrongly memoised)');
  finally
    FA.Free; FB.Free; Bag.Free;
  end;
end;

procedure TPropertyBagMemoTests.FeatureConstantColorMemoisedCorrectly;
var
  Bag: TMGLPropertyBag;
  C1, C2: TMGLColor;
begin
  Bag := TMGLPropertyBag.Create;
  try
    Bag.SetProp('fill-color', ParseExpr('["interpolate",["linear"],["zoom"],10,"#000000",14,"#ffffff"]'));
    C1 := Bag.EvalColor('fill-color', MakeContext(nil, 12, gtPolygon), TMGLColor.Black);
    C2 := Bag.EvalColor('fill-color', MakeContext(nil, 12, gtPolygon), TMGLColor.Black);  // memo hit
    Assert.AreEqual(C1.R, C2.R, 0.0001);
    Assert.AreEqual(C1.G, C2.G, 0.0001);
    Assert.IsTrue((C1.R > 0.4) and (C1.R < 0.6), 'mid-gray ~0.5');
  finally
    Bag.Free;
  end;
end;

procedure TPropertyBagMemoTests.ConstantFloatStillWorks;
var
  Bag: TMGLPropertyBag;
begin
  Bag := TMGLPropertyBag.Create;
  try
    Bag.SetProp('line-width', ParseExpr('3'));
    Assert.AreEqual(Double(3.0), Bag.EvalFloat('line-width', MakeContext(nil, 9, gtLineString), 0), 0.001);
    Assert.AreEqual(Double(3.0), Bag.EvalFloat('line-width', MakeContext(nil, 18, gtLineString), 0), 0.001);
  finally
    Bag.Free;
  end;
end;

procedure TPropertyBagMemoTests.ActiveCacheMemoisesFeatureConstant;
var
  Bag: TMGLPropertyBag;
  Cache: TMGLPropEvalCache;
  Cached: Double;
begin
  // With an active per-thread cache, a zoom-only property is stored once and the
  // cached value equals the eval; correct across features at the same zoom.
  Bag := TMGLPropertyBag.Create;
  Cache := TMGLPropEvalCache.Create;
  GActivePropCache := Cache;
  try
    Bag.SetProp('line-width', ParseExpr('["interpolate",["linear"],["zoom"],10,1,14,5]'));
    Assert.AreEqual(Double(3.0), Bag.EvalFloat('line-width', MakeContext(nil, 12, gtLineString), 0), 0.001);
    Assert.IsTrue(Cache.TryFloat('line-width', Cached), 'value cached');
    Assert.AreEqual(Double(3.0), Cached, 0.001, 'cached value correct');
  finally
    GActivePropCache := nil;
    Cache.Free; Bag.Free;
  end;
end;

procedure TPropertyBagMemoTests.ActiveCacheDoesNotMemoiseFeatureDependent;
var
  Bag: TMGLPropertyBag;
  Cache: TMGLPropEvalCache;
  FA, FB: TMVTFeature;
  Dummy: Double;
begin
  // Even WITH an active cache, a feature-dependent property must NOT be cached:
  // each feature gets its own value, and nothing is stored under the name.
  Bag := TMGLPropertyBag.Create;
  Cache := TMGLPropEvalCache.Create;
  FA := TMVTFeature.Create;
  FB := TMVTFeature.Create;
  GActivePropCache := Cache;
  try
    FA.SetProp('w', TMVTValue.FromInt(5));
    FB.SetProp('w', TMVTValue.FromInt(9));
    Bag.SetProp('line-width', ParseExpr('["get","w"]'));
    Assert.AreEqual(Double(5.0), Bag.EvalFloat('line-width', MakeContext(FA, 12, gtLineString), 0), 0.001);
    Assert.AreEqual(Double(9.0), Bag.EvalFloat('line-width', MakeContext(FB, 12, gtLineString), 0), 0.001,
      'feature B distinct (not served from cache)');
    Assert.IsFalse(Cache.TryFloat('line-width', Dummy), 'feature-dependent prop must NOT be cached');
  finally
    GActivePropCache := nil;
    FA.Free; FB.Free; Cache.Free; Bag.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TCompressionTests);
  TDUnitX.RegisterTestFixture(TValueTests);
  TDUnitX.RegisterTestFixture(TColorTests);
  TDUnitX.RegisterTestFixture(TExpressionTests);
  TDUnitX.RegisterTestFixture(TGeometryTests);
  TDUnitX.RegisterTestFixture(TFeatureConstantTests);
  TDUnitX.RegisterTestFixture(TPropertyBagMemoTests);
  TDUnitX.RegisterTestFixture(TDecoderTests);

end.
