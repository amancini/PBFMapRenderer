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
  end;

  [TestFixture]
  TGeometryTests = class
  public
    [Test] procedure PolygonWithHole;
    [Test] procedure LineString;
  end;

implementation

uses
  System.SysUtils, System.JSON,
  PBFMap.Types, PBFMap.Geometry, PBFMap.Compression, PBFMap.MVT.Types,
  PBFMap.MVT.Parser, PBFMap.Color, PBFMap.Expressions,
  PBFMap.TestUtils;

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
  // interpolate-hcl must be recognised (approximated linear), not raise.
  Assert.IsTrue(Eval('["interpolate-hcl",["linear"],["zoom"],0,"red",10,"blue"]',
    nil, 5).AsString <> '');
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

initialization
  TDUnitX.RegisterTestFixture(TCompressionTests);
  TDUnitX.RegisterTestFixture(TValueTests);
  TDUnitX.RegisterTestFixture(TColorTests);
  TDUnitX.RegisterTestFixture(TExpressionTests);
  TDUnitX.RegisterTestFixture(TGeometryTests);

end.
