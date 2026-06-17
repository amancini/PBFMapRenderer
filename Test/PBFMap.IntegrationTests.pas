unit PBFMap.IntegrationTests;

{
  PBFMapRenderer - Integration + decoder tests

  Exercises the loading/decoding/rendering pipeline against the real sample
  data shipped with the repo (Sample\BasicViewer\style.json and
  data\roma.mbtiles) plus low-level decoder coverage on synthetic bytes.

  The sample files are REQUIRED: the file-backed fixtures fail if they are
  absent (run from a checkout that includes Sample\BasicViewer\data).

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TMBTilesIntegrationTests = class
  public
    [Test] procedure OpenRealFile;
    [Test] procedure MetadataFormatIsPbf;
    [Test] procedure RomaTileExists;
    [Test] procedure RomaTileDataIsGzip;
    [Test] procedure MissingTileReturnsFalse;
  end;

  [TestFixture]
  TStyleParserIntegrationTests = class
  public
    [Test] procedure ParseRealStyle;
    [Test] procedure LayersHavePaintOrLayout;
    [Test] procedure MalformedJsonRaisesWhenNoLog;
    [Test] procedure MalformedJsonLogsWhenWired;
    [Test] procedure NumberLedArrayIsNotAnOperator;
    [Test] procedure RealStyleParsesWithoutErrors;
    [Test] procedure FontStackIsNotKnownOperator;
  end;

  [TestFixture]
  TEngineIntegrationTests = class
  public
    [Test] procedure OpenAndLoadReportsInfo;
    [Test] procedure DecodeRomaTileHasFeatures;
    [Test] procedure RenderRomaTilePaints;
    [Test] procedure OpenMissingFileLogsException;
  end;

  [TestFixture]
  TPlacementTests = class
  public
    [Test] procedure GridRejectsOverlap;
    [Test] procedure GridAllowsDisjoint;
    [Test] procedure TextOffsetArrayParsed;
    [Test] procedure FontStackArrayNotNumeric;
  end;

  [TestFixture]
  TSpriteTests = class
  public
    [Test] procedure LoadRealSprite;
    [Test] procedure KnownIconRect;
    [Test] procedure MissingIconIsFalse;
  end;

  [TestFixture]
  TDecoderTests = class
  public
    [Test] procedure Varint;
    [Test] procedure SignedZigZag;
    [Test] procedure Fixed32;
    [Test] procedure Fixed64;
    [Test] procedure TagThenString;
    [Test] procedure PackedVarints;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.UITypes,
  Vcl.Graphics,
  PBFMap.Types, PBFMap.Decoder, PBFMap.Compression, PBFMap.MBTiles,
  PBFMap.MVT.Types, PBFMap.Expressions, PBFMap.Style.Model, PBFMap.Style.Parser,
  PBFMap.Sprite, PBFMap.Collision, PBFMap.Engine, PBFMap.TestUtils;

const
  // Rome z14 (XYZ). The reader flips Y to the TMS row internally.
  ROMA_Z = 14;
  ROMA_X = 8760;
  ROMA_Y = 6088;

{ Collects OnLog callbacks so tests can assert what the library reported. }
type
  TLogCollector = class
  private
    FMessages: TStringList;
    FExceptionCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnLog(const aFunction, aDescription: String; aLevel: TPBFLogLevel;
      aIsDebug: Boolean = False);
    property Messages: TStringList read FMessages;
    property ExceptionCount: Integer read FExceptionCount;
  end;

constructor TLogCollector.Create;
begin
  inherited Create;
  FMessages := TStringList.Create;
  FExceptionCount := 0;
end;

destructor TLogCollector.Destroy;
begin
  FMessages.Free;
  inherited;
end;

procedure TLogCollector.OnLog(const aFunction, aDescription: String;
  aLevel: TPBFLogLevel; aIsDebug: Boolean);
begin
  FMessages.Add(Format('%s: %s', [aFunction, aDescription]));
  if aLevel = tplivException then
    Inc(FExceptionCount);
end;

{ Walk up from the test exe to locate a sample file; fails the test if absent. }
function RequireSampleFile(const ARelPath: string): string;
var
  LBase, LCandidate: string;
  I: Integer;
begin
  LBase := ExtractFilePath(ParamStr(0));
  for I := 0 to 8 do
  begin
    LCandidate := TPath.Combine(LBase, TPath.Combine('Sample\BasicViewer', ARelPath));
    if TFile.Exists(LCandidate) then
      Exit(LCandidate);
    LBase := ExtractFilePath(ExcludeTrailingPathDelimiter(LBase));
    if LBase = '' then
      Break;
  end;
  Assert.Fail(Format('Required sample file not found walking up from "%s": %s',
    [ExtractFilePath(ParamStr(0)), ARelPath]));
  Result := '';
end;

function RequireStyle: string;
begin
  Result := RequireSampleFile('style.json');
end;

function RequireTiles: string;
begin
  Result := RequireSampleFile('data\roma.mbtiles');
end;

{ TMBTilesIntegrationTests }

procedure TMBTilesIntegrationTests.OpenRealFile;
var
  LReader: TPBFMBTilesReader;
begin
  LReader := TPBFMBTilesReader.Create;
  try
    LReader.Open(RequireTiles);
    Assert.IsTrue(LReader.IsOpen, 'Reader should be open after Open()');
  finally
    LReader.Free;
  end;
end;

procedure TMBTilesIntegrationTests.MetadataFormatIsPbf;
var
  LReader: TPBFMBTilesReader;
begin
  LReader := TPBFMBTilesReader.Create;
  try
    LReader.Open(RequireTiles);
    Assert.AreEqual('pbf', LowerCase(LReader.GetFormat));
  finally
    LReader.Free;
  end;
end;

procedure TMBTilesIntegrationTests.RomaTileExists;
var
  LReader: TPBFMBTilesReader;
begin
  LReader := TPBFMBTilesReader.Create;
  try
    LReader.Open(RequireTiles);
    Assert.IsTrue(LReader.TileExists(ROMA_Z, ROMA_X, ROMA_Y),
      'Rome z14 tile should exist');
  finally
    LReader.Free;
  end;
end;

procedure TMBTilesIntegrationTests.RomaTileDataIsGzip;
var
  LReader: TPBFMBTilesReader;
  LData: TBytes;
begin
  LReader := TPBFMBTilesReader.Create;
  try
    LReader.Open(RequireTiles);
    LData := LReader.GetTileData(ROMA_Z, ROMA_X, ROMA_Y);
    Assert.IsTrue(Length(LData) > 0, 'Tile data should not be empty');
    Assert.AreEqual(Integer($1F), Integer(LData[0]), 'Expected gzip magic byte 0');
    Assert.AreEqual(Integer($8B), Integer(LData[1]), 'Expected gzip magic byte 1');
  finally
    LReader.Free;
  end;
end;

procedure TMBTilesIntegrationTests.MissingTileReturnsFalse;
var
  LReader: TPBFMBTilesReader;
begin
  LReader := TPBFMBTilesReader.Create;
  try
    LReader.Open(RequireTiles);
    Assert.IsFalse(LReader.TileExists(ROMA_Z, 0, 0),
      'A clearly-absent tile must return False without raising');
  finally
    LReader.Free;
  end;
end;

{ TStyleParserIntegrationTests }

procedure TStyleParserIntegrationTests.ParseRealStyle;
var
  LParser: TMGLStyleParser;
  LStyle: TMGLStyle;
begin
  LParser := TMGLStyleParser.Create;
  try
    LStyle := LParser.ParseFile(RequireStyle);
    try
      Assert.IsTrue(LStyle.Layers.Count > 0, 'Style should have layers');
    finally
      LStyle.Free;
    end;
  finally
    LParser.Free;
  end;
end;

procedure TStyleParserIntegrationTests.LayersHavePaintOrLayout;
var
  LParser: TMGLStyleParser;
  LStyle: TMGLStyle;
  LLayer: TMGLLayer;
  LFound: Boolean;
begin
  LParser := TMGLStyleParser.Create;
  try
    LStyle := LParser.ParseFile(RequireStyle);
    try
      LFound := False;
      for LLayer in LStyle.Layers do
        if (LLayer.Kind in [lkFill, lkLine]) and
           (LLayer.Paint.Has('fill-color') or LLayer.Paint.Has('line-color')) then
        begin
          LFound := True;
          Break;
        end;
      Assert.IsTrue(LFound, 'Expected at least one fill/line layer with a paint color');
    finally
      LStyle.Free;
    end;
  finally
    LParser.Free;
  end;
end;

procedure TStyleParserIntegrationTests.MalformedJsonRaisesWhenNoLog;
var
  LParser: TMGLStyleParser;
begin
  LParser := TMGLStyleParser.Create;
  try
    // No OnLog wired -> the parser must raise on an invalid root.
    Assert.WillRaise(
      procedure
      begin
        LParser.ParseString('this is not json').Free;
      end,
      EMGLStyleError);
  finally
    LParser.Free;
  end;
end;

procedure TStyleParserIntegrationTests.MalformedJsonLogsWhenWired;
var
  LParser: TMGLStyleParser;
  LStyle: TMGLStyle;
  LLog: TLogCollector;
begin
  LLog := TLogCollector.Create;
  LParser := TMGLStyleParser.Create;
  try
    LParser.OnLog := LLog.OnLog;
    // With OnLog wired the parser logs and returns an empty (non-nil) style.
    LStyle := LParser.ParseString('this is not json');
    try
      Assert.IsNotNull(LStyle, 'Should return an empty style, not nil');
      Assert.AreEqual(0, LStyle.Layers.Count);
      Assert.IsTrue(LLog.ExceptionCount > 0, 'Expected an exception-level log entry');
    finally
      LStyle.Free;
    end;
  finally
    LParser.Free;
    LLog.Free;
  end;
end;

procedure TStyleParserIntegrationTests.NumberLedArrayIsNotAnOperator;
var
  LParser: TMGLStyleParser;
  LStyle: TMGLStyle;
  LLog: TLogCollector;
begin
  // Regression: a number-led array (e.g. text-offset [0, 0.5]) must NOT be
  // taken for an expression with operator "0" (TJSONNumber is a TJSONString).
  LLog := TLogCollector.Create;
  LParser := TMGLStyleParser.Create;
  try
    LParser.OnLog := LLog.OnLog;
    LStyle := LParser.ParseString(
      '{"layers":[{"id":"l","type":"symbol","layout":{"text-offset":[0,0.5]}}]}');
    try
      Assert.AreEqual(1, LStyle.Layers.Count, 'Layer should not be skipped');
      Assert.AreEqual(0, LLog.ExceptionCount,
        'No expression error should be raised for a number-led array');
    finally
      LStyle.Free;
    end;
  finally
    LParser.Free;
    LLog.Free;
  end;
end;

procedure TStyleParserIntegrationTests.RealStyleParsesWithoutErrors;
var
  LParser: TMGLStyleParser;
  LStyle: TMGLStyle;
  LLog: TLogCollector;
begin
  LLog := TLogCollector.Create;
  LParser := TMGLStyleParser.Create;
  try
    LParser.OnLog := LLog.OnLog;
    LStyle := LParser.ParseFile(RequireStyle);
    try
      Assert.IsTrue(LStyle.Layers.Count > 0, 'Style should have layers');
      Assert.AreEqual(0, LLog.ExceptionCount,
        Format('Real style parsed with %d exception-level log entries (expected 0)',
          [LLog.ExceptionCount]));
    finally
      LStyle.Free;
    end;
  finally
    LParser.Free;
    LLog.Free;
  end;
end;

procedure TStyleParserIntegrationTests.FontStackIsNotKnownOperator;
begin
  // Regression: a text-font stack like ["Noto Sans Regular"] must not be taken
  // for an expression (its head is a string but not an operator).
  Assert.IsFalse(IsKnownExpressionOp('Noto Sans Regular'),
    'A font name must not be a known operator');
  Assert.IsTrue(IsKnownExpressionOp('interpolate'));
  Assert.IsTrue(IsKnownExpressionOp('get'));
  Assert.IsTrue(IsKnownExpressionOp('=='));
end;

{ TEngineIntegrationTests }

procedure TEngineIntegrationTests.OpenAndLoadReportsInfo;
var
  LEngine: TPBFMapEngine;
  LLog: TLogCollector;
begin
  LLog := TLogCollector.Create;
  LEngine := TPBFMapEngine.Create(256);
  try
    LEngine.OnLog := LLog.OnLog;
    LEngine.OpenTiles(RequireTiles);
    LEngine.LoadStyle(RequireStyle);
    Assert.IsTrue(LEngine.Reader.IsOpen, 'Tiles should be open');
    Assert.IsTrue(Assigned(LEngine.Style) and (LEngine.Style.Layers.Count > 0),
      'Style should be loaded');
    Assert.IsTrue(LLog.Messages.Count > 0, 'Engine should have logged progress');
  finally
    LEngine.Free;
    LLog.Free;
  end;
end;

procedure TEngineIntegrationTests.DecodeRomaTileHasFeatures;
var
  LEngine: TPBFMapEngine;
  LTile: TMVTTile;
  LLayer: TMVTLayer;
  LTotal: Integer;
begin
  LEngine := TPBFMapEngine.Create(256);
  try
    LEngine.OpenTiles(RequireTiles);
    LTile := LEngine.DecodeTile(ROMA_Z, ROMA_X, ROMA_Y);
    try
      Assert.IsNotNull(LTile, 'Rome z14 tile should decode');
      Assert.IsTrue(LTile.Layers.Count > 0, 'Decoded tile should have layers');
      LTotal := 0;
      for LLayer in LTile.Layers do
        Inc(LTotal, LLayer.Features.Count);
      Assert.IsTrue(LTotal > 1000,
        Format('Expected a busy Rome tile (>1000 features), got %d', [LTotal]));
    finally
      LTile.Free;
    end;
  finally
    LEngine.Free;
  end;
end;

procedure TEngineIntegrationTests.RenderRomaTilePaints;
const
  SENTINEL = TColor($00ABCDEF);
var
  LEngine: TPBFMapEngine;
  LBmp: TBitmap;
  X, Y: Integer;
  LChanged: Boolean;
begin
  LEngine := TPBFMapEngine.Create(256);
  LBmp := TBitmap.Create;
  try
    LBmp.PixelFormat := pf32bit;
    LBmp.SetSize(256, 256);
    LBmp.Canvas.Brush.Color := SENTINEL;
    LBmp.Canvas.FillRect(Rect(0, 0, 256, 256));

    LEngine.OpenTiles(RequireTiles);
    LEngine.LoadStyle(RequireStyle);
    LEngine.RenderTile(ROMA_Z, ROMA_X, ROMA_Y, LBmp.Canvas);

    LChanged := False;
    for Y := 0 to 255 do
    begin
      for X := 0 to 255 do
        if LBmp.Canvas.Pixels[X, Y] <> SENTINEL then
        begin
          LChanged := True;
          Break;
        end;
      if LChanged then
        Break;
    end;
    Assert.IsTrue(LChanged, 'Rendering should have painted over the sentinel fill');
  finally
    LBmp.Free;
    LEngine.Free;
  end;
end;

procedure TEngineIntegrationTests.OpenMissingFileLogsException;
var
  LEngine: TPBFMapEngine;
  LLog: TLogCollector;
begin
  LLog := TLogCollector.Create;
  LEngine := TPBFMapEngine.Create(256);
  try
    LEngine.OnLog := LLog.OnLog;
    // With OnLog wired, opening a missing file logs an exception-level entry
    // and does NOT raise; the reader stays closed.
    LEngine.OpenTiles('Z:\does\not\exist.mbtiles');
    Assert.IsFalse(LEngine.Reader.IsOpen, 'Reader must stay closed on failure');
    Assert.IsTrue(LLog.ExceptionCount > 0, 'Expected an exception-level log entry');
  finally
    LEngine.Free;
    LLog.Free;
  end;
end;

{ TPlacementTests }

procedure TPlacementTests.GridRejectsOverlap;
var
  G: TGridIndex;
begin
  G := TGridIndex.Create(64);
  try
    G.Insert([Rect(10, 10, 50, 50)]);
    Assert.IsFalse(G.CanPlace([Rect(40, 40, 80, 80)]),
      'An overlapping box must be rejected');
  finally
    G.Free;
  end;
end;

procedure TPlacementTests.GridAllowsDisjoint;
var
  G: TGridIndex;
begin
  G := TGridIndex.Create(64);
  try
    G.Insert([Rect(10, 10, 50, 50)]);
    Assert.IsTrue(G.CanPlace([Rect(200, 200, 240, 240)]),
      'A disjoint box must be allowed');
  finally
    G.Free;
  end;
end;

procedure TPlacementTests.TextOffsetArrayParsed;
var
  P: TMGLStyleParser;
  St: TMGLStyle;
  Arr: TArray<Double>;
begin
  // The numeric literal array [0, 0.5] must be kept whole (not collapsed to 0).
  P := TMGLStyleParser.Create;
  try
    St := P.ParseString(
      '{"layers":[{"id":"l","type":"symbol","layout":{"text-offset":[0,0.5]}}]}');
    try
      Assert.AreEqual(1, St.Layers.Count);
      Arr := St.Layers[0].Layout.GetFloatArray('text-offset', []);
      Assert.AreEqual(2, Length(Arr), 'text-offset should keep both components');
      Assert.AreEqual(Double(0.0), Arr[0], 0.001);
      Assert.AreEqual(Double(0.5), Arr[1], 0.001);
    finally
      St.Free;
    end;
  finally
    P.Free;
  end;
end;

procedure TPlacementTests.FontStackArrayNotNumeric;
var
  P: TMGLStyleParser;
  St: TMGLStyle;
begin
  // A string array (font stack) must NOT be stored as a numeric array.
  P := TMGLStyleParser.Create;
  try
    St := P.ParseString(
      '{"layers":[{"id":"l","type":"symbol","layout":{"text-font":["Noto Sans Regular"]}}]}');
    try
      Assert.AreEqual(0, Length(St.Layers[0].Layout.GetFloatArray('text-font', [])),
        'A font stack is not a numeric array');
    finally
      St.Free;
    end;
  finally
    P.Free;
  end;
end;

{ TSpriteTests }

procedure TSpriteTests.LoadRealSprite;
var
  LSprite: TMGLSprite;
begin
  LSprite := TMGLSprite.Create;
  try
    Assert.IsTrue(LSprite.LoadFromFiles(RequireSampleFile('sprite.json'),
      RequireSampleFile('sprite.png')), 'Sprite atlas should load');
    Assert.IsTrue(LSprite.Loaded);
    Assert.IsTrue(LSprite.HasIcon('airport_11'), 'Expected a known icon');
  finally
    LSprite.Free;
  end;
end;

procedure TSpriteTests.KnownIconRect;
var
  LSprite: TMGLSprite;
  LIcon: TMGLSpriteIcon;
begin
  LSprite := TMGLSprite.Create;
  try
    LSprite.LoadFromFiles(RequireSampleFile('sprite.json'),
      RequireSampleFile('sprite.png'));
    Assert.IsTrue(LSprite.TryGetIcon('airport_11', LIcon));
    Assert.IsTrue(LIcon.Width > 0, 'Icon should have a positive width');
    Assert.IsTrue(LIcon.Height > 0, 'Icon should have a positive height');
  finally
    LSprite.Free;
  end;
end;

procedure TSpriteTests.MissingIconIsFalse;
var
  LSprite: TMGLSprite;
begin
  LSprite := TMGLSprite.Create;
  try
    LSprite.LoadFromFiles(RequireSampleFile('sprite.json'),
      RequireSampleFile('sprite.png'));
    Assert.IsFalse(LSprite.HasIcon('definitely-not-an-icon'));
  finally
    LSprite.Free;
  end;
end;

{ TDecoderTests }

procedure TDecoderTests.Varint;
var
  LWriter: TPBWriter;
  LDecoder: TPBFDecoder;
begin
  LWriter := TPBWriter.Create;
  try
    LWriter.WriteVarint(300);
    LDecoder := TPBFDecoder.Create(LWriter.ToBytes);
    try
      Assert.AreEqual(Int64(300), Int64(LDecoder.ReadVarint));
    finally
      LDecoder.Free;
    end;
  finally
    LWriter.Free;
  end;
end;

procedure TDecoderTests.SignedZigZag;
var
  LWriter: TPBWriter;
  LDecoder: TPBFDecoder;
begin
  LWriter := TPBWriter.Create;
  try
    // zigzag(-5) = 9
    LWriter.WriteVarint(9);
    LDecoder := TPBFDecoder.Create(LWriter.ToBytes);
    try
      Assert.AreEqual(Int64(-5), LDecoder.ReadSignedVarint);
    finally
      LDecoder.Free;
    end;
  finally
    LWriter.Free;
  end;
end;

procedure TDecoderTests.Fixed32;
var
  LData: TBytes;
  LDecoder: TPBFDecoder;
begin
  SetLength(LData, 4);
  // little-endian $12345678
  LData[0] := $78; LData[1] := $56; LData[2] := $34; LData[3] := $12;
  LDecoder := TPBFDecoder.Create(LData);
  try
    Assert.AreEqual(Int64($12345678), Int64(LDecoder.ReadFixed32));
  finally
    LDecoder.Free;
  end;
end;

procedure TDecoderTests.Fixed64;
var
  LData: TBytes;
  LDecoder: TPBFDecoder;
begin
  SetLength(LData, 8);
  // little-endian $00000000DEADBEEF
  LData[0] := $EF; LData[1] := $BE; LData[2] := $AD; LData[3] := $DE;
  LData[4] := $00; LData[5] := $00; LData[6] := $00; LData[7] := $00;
  LDecoder := TPBFDecoder.Create(LData);
  try
    Assert.AreEqual(Int64($DEADBEEF), Int64(LDecoder.ReadFixed64));
  finally
    LDecoder.Free;
  end;
end;

procedure TDecoderTests.TagThenString;
var
  LWriter: TPBWriter;
  LDecoder: TPBFDecoder;
  LField: Integer;
  LWire: TPBFWireType;
begin
  LWriter := TPBWriter.Create;
  try
    LWriter.WriteStringField(1, 'roma');
    LDecoder := TPBFDecoder.Create(LWriter.ToBytes);
    try
      Assert.IsTrue(LDecoder.ReadTag(LField, LWire), 'Expected a tag');
      Assert.AreEqual(1, LField);
      Assert.IsTrue(LWire = wtLengthDelimited, 'Expected length-delimited wire type');
      Assert.AreEqual('roma', LDecoder.ReadString);
    finally
      LDecoder.Free;
    end;
  finally
    LWriter.Free;
  end;
end;

procedure TDecoderTests.PackedVarints;
var
  LWriter: TPBWriter;
  LDecoder: TPBFDecoder;
  LField: Integer;
  LWire: TPBFWireType;
  LVals: TArray<UInt64>;
begin
  LWriter := TPBWriter.Create;
  try
    LWriter.WritePackedVarints(4, [1, 2, 300]);
    LDecoder := TPBFDecoder.Create(LWriter.ToBytes);
    try
      Assert.IsTrue(LDecoder.ReadTag(LField, LWire), 'Expected a tag');
      Assert.AreEqual(4, LField);
      LVals := LDecoder.ReadPackedVarint;
      Assert.AreEqual(3, Length(LVals));
      Assert.AreEqual(Int64(1), Int64(LVals[0]));
      Assert.AreEqual(Int64(2), Int64(LVals[1]));
      Assert.AreEqual(Int64(300), Int64(LVals[2]));
    finally
      LDecoder.Free;
    end;
  finally
    LWriter.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TMBTilesIntegrationTests);
  TDUnitX.RegisterTestFixture(TStyleParserIntegrationTests);
  TDUnitX.RegisterTestFixture(TEngineIntegrationTests);
  TDUnitX.RegisterTestFixture(TPlacementTests);
  TDUnitX.RegisterTestFixture(TSpriteTests);
  TDUnitX.RegisterTestFixture(TDecoderTests);

end.
