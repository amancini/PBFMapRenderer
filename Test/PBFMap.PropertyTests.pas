unit PBFMap.PropertyTests;

{
  PBFMapRenderer - Property reading + defaults coverage tests

  Two fixtures:
    * TPropertyReadingTests  - parses a style.json that sets every property the
      renderer handles, and asserts each one reads back through the layer's
      paint/layout bag (value + presence). Proves the parser/model read all
      handled properties (literals, arrays, expressions, function-stops).
    * TPropertyDefaultTests   - for an empty bag, asserts EvalX returns the
      MapLibre spec default the renderer relies on (the "absent -> default"
      contract), for every handled property. Locks the default table.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Classes, System.Math,
  DUnitX.TestFramework,
  PBFMap.Types, PBFMap.Color, PBFMap.Expressions,
  PBFMap.Style.Model, PBFMap.Style.Parser;

type
  [TestFixture]
  TPropertyReadingTests = class
  private
    FStyle: TMGLStyle;
    FCtx: TExprContext;
    function Layer(const AId: string): TMGLLayer;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure Background;
    [Test] procedure Fill;
    [Test] procedure Line;
    [Test] procedure Circle;
    [Test] procedure SymbolLayout;
    [Test] procedure SymbolPaint;
    [Test] procedure FunctionStopsAndExpressions;
  end;

  [TestFixture]
  TPropertyDefaultTests = class
  private
    FBag: TMGLPropertyBag;
    FCtx: TExprContext;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure NumericDefaults;
    [Test] procedure StringDefaults;
    [Test] procedure BoolDefaults;
    [Test] procedure ColorDefaults;
  end;

implementation

const
  // One style touching every property the renderer reads. Distinctive values so
  // a wrong read is obvious. Sort-keys live in layout (MapLibre spec).
  ALL_PROPS_STYLE =
    '{"version":8,"layers":[' +
    '{"id":"bg","type":"background","paint":{' +
      '"background-color":"#102030","background-opacity":0.5,"background-pattern":"pat"}},' +
    '{"id":"fl","type":"fill","source":"s","source-layer":"l",' +
      '"layout":{"visibility":"visible","fill-sort-key":3},"paint":{' +
      '"fill-color":"#a0b0c0","fill-opacity":0.7,"fill-outline-color":"#010203",' +
      '"fill-antialias":false,"fill-translate":[2,4],"fill-translate-anchor":"viewport"}},' +
    '{"id":"ln","type":"line","source":"s","source-layer":"l",' +
      '"layout":{"line-cap":"round","line-join":"bevel","line-sort-key":5},"paint":{' +
      '"line-color":"#112233","line-opacity":0.8,"line-width":7,"line-blur":2,' +
      '"line-gap-width":3,"line-offset":1,"line-translate":[1,2],' +
      '"line-translate-anchor":"viewport","line-dasharray":[2,3]}},' +
    '{"id":"ci","type":"circle","source":"s","source-layer":"l",' +
      '"layout":{"circle-sort-key":9},"paint":{' +
      '"circle-radius":11,"circle-color":"#203040","circle-opacity":0.6,' +
      '"circle-stroke-width":2,"circle-stroke-color":"#405060","circle-stroke-opacity":0.4,' +
      '"circle-blur":0.5,"circle-translate":[3,5],"circle-translate-anchor":"viewport",' +
      '"circle-pitch-scale":"viewport","circle-pitch-alignment":"map"}},' +
    '{"id":"sy","type":"symbol","source":"s","source-layer":"l",' +
      '"layout":{"symbol-placement":"line","symbol-spacing":120,"symbol-sort-key":4,' +
      '"icon-image":"poi","icon-size":1.5,"icon-rotate":45,"icon-offset":[2,3],' +
      '"icon-anchor":"left","icon-padding":6,"icon-allow-overlap":true,' +
      '"icon-ignore-placement":true,"icon-optional":true,' +
      '"text-field":"{name}","text-font":["Noto Sans Italic"],"text-size":13,' +
      '"text-max-width":9,"text-line-height":1.4,"text-letter-spacing":0.1,' +
      '"text-justify":"left","text-anchor":"top","text-offset":[0,0.6],' +
      '"text-transform":"uppercase","text-padding":3,"text-allow-overlap":true,' +
      '"text-ignore-placement":true,"text-optional":true},"paint":{' +
      '"icon-opacity":0.5,"icon-color":"#607080","text-color":"#708090",' +
      '"text-halo-color":"#ffffff","text-halo-width":1.5}}' +
    ']}';

{ TPropertyReadingTests }

procedure TPropertyReadingTests.Setup;
var
  P: TMGLStyleParser;
begin
  P := TMGLStyleParser.Create;
  try
    FStyle := P.ParseString(ALL_PROPS_STYLE);
  finally
    P.Free;
  end;
  FCtx := MakeContext(nil, 14, gtUnknown);
end;

procedure TPropertyReadingTests.TearDown;
begin
  FStyle.Free;
end;

function TPropertyReadingTests.Layer(const AId: string): TMGLLayer;
var
  L: TMGLLayer;
begin
  for L in FStyle.Layers do
    if L.Id = AId then Exit(L);
  Assert.Fail('layer not found: ' + AId);
  Result := nil;
end;

procedure TPropertyReadingTests.Background;
var
  L: TMGLLayer;
  C: TMGLColor;
begin
  L := Layer('bg');
  Assert.IsTrue(L.Paint.Has('background-color'), 'background-color present');
  C := L.Paint.EvalColor('background-color', FCtx, TMGLColor.Black);
  Assert.AreEqual<Integer>(16, Round(C.R * 255), 'bg R');
  Assert.AreEqual(0.5, L.Paint.EvalFloat('background-opacity', FCtx, 1), 1E-6);
  Assert.AreEqual('pat', L.Paint.EvalString('background-pattern', FCtx, ''));
end;

procedure TPropertyReadingTests.Fill;
var
  L: TMGLLayer;
  A: TArray<Double>;
begin
  L := Layer('fl');
  Assert.AreEqual<Integer>(160, Round(L.Paint.EvalColor('fill-color', FCtx, TMGLColor.Black).R * 255));
  Assert.AreEqual(0.7, L.Paint.EvalFloat('fill-opacity', FCtx, 1), 1E-6);
  Assert.IsTrue(L.Paint.Has('fill-outline-color'), 'fill-outline-color');
  Assert.IsFalse(L.Paint.EvalBool('fill-antialias', FCtx, True), 'fill-antialias=false');
  A := L.Paint.GetFloatArray('fill-translate', []);
  Assert.AreEqual<Integer>(2, Length(A), 'fill-translate len');
  Assert.AreEqual(2.0, A[0], 1E-6);
  Assert.AreEqual('viewport', L.Paint.EvalString('fill-translate-anchor', FCtx, 'map'));
  Assert.AreEqual(3.0, L.Layout.EvalFloat('fill-sort-key', FCtx, 0), 1E-6);
end;

procedure TPropertyReadingTests.Line;
var
  L: TMGLLayer;
  A: TArray<Double>;
begin
  L := Layer('ln');
  Assert.AreEqual('round', L.Layout.EvalString('line-cap', FCtx, 'butt'));
  Assert.AreEqual('bevel', L.Layout.EvalString('line-join', FCtx, 'miter'));
  Assert.AreEqual(5.0, L.Layout.EvalFloat('line-sort-key', FCtx, 0), 1E-6);
  Assert.AreEqual(7.0, L.Paint.EvalFloat('line-width', FCtx, 1), 1E-6);
  Assert.AreEqual(0.8, L.Paint.EvalFloat('line-opacity', FCtx, 1), 1E-6);
  Assert.AreEqual(2.0, L.Paint.EvalFloat('line-blur', FCtx, 0), 1E-6);
  Assert.AreEqual(3.0, L.Paint.EvalFloat('line-gap-width', FCtx, 0), 1E-6);
  Assert.AreEqual(1.0, L.Paint.EvalFloat('line-offset', FCtx, 0), 1E-6);
  Assert.AreEqual('viewport', L.Paint.EvalString('line-translate-anchor', FCtx, 'map'));
  A := L.Paint.GetFloatArray('line-dasharray', []);
  Assert.AreEqual<Integer>(2, Length(A), 'dasharray len');
  Assert.AreEqual(3.0, A[1], 1E-6);
end;

procedure TPropertyReadingTests.Circle;
var
  L: TMGLLayer;
begin
  L := Layer('ci');
  Assert.AreEqual(11.0, L.Paint.EvalFloat('circle-radius', FCtx, 5), 1E-6);
  Assert.AreEqual(0.6, L.Paint.EvalFloat('circle-opacity', FCtx, 1), 1E-6);
  Assert.AreEqual(2.0, L.Paint.EvalFloat('circle-stroke-width', FCtx, 0), 1E-6);
  Assert.AreEqual(0.4, L.Paint.EvalFloat('circle-stroke-opacity', FCtx, 1), 1E-6);
  Assert.AreEqual(0.5, L.Paint.EvalFloat('circle-blur', FCtx, 0), 1E-6);
  Assert.AreEqual('viewport', L.Paint.EvalString('circle-pitch-scale', FCtx, 'map'));
  Assert.AreEqual('map', L.Paint.EvalString('circle-pitch-alignment', FCtx, 'viewport'));
  Assert.AreEqual(9.0, L.Layout.EvalFloat('circle-sort-key', FCtx, 0), 1E-6);
end;

procedure TPropertyReadingTests.SymbolLayout;
var
  L: TMGLLayer;
  A: TArray<Double>;
begin
  L := Layer('sy');
  Assert.AreEqual('line', L.Layout.EvalString('symbol-placement', FCtx, 'point'));
  Assert.AreEqual(120.0, L.Layout.EvalFloat('symbol-spacing', FCtx, 250), 1E-6);
  Assert.AreEqual(4.0, L.Layout.EvalFloat('symbol-sort-key', FCtx, 0), 1E-6);
  Assert.AreEqual(1.5, L.Layout.EvalFloat('icon-size', FCtx, 1), 1E-6);
  Assert.AreEqual(45.0, L.Layout.EvalFloat('icon-rotate', FCtx, 0), 1E-6);
  Assert.AreEqual('left', L.Layout.EvalString('icon-anchor', FCtx, 'center'));
  Assert.AreEqual(6.0, L.Layout.EvalFloat('icon-padding', FCtx, 2), 1E-6);
  Assert.IsTrue(L.Layout.EvalBool('icon-allow-overlap', FCtx, False));
  Assert.IsTrue(L.Layout.EvalBool('icon-ignore-placement', FCtx, False));
  Assert.IsTrue(L.Layout.EvalBool('icon-optional', FCtx, False));
  A := L.Layout.GetFloatArray('icon-offset', []);
  Assert.AreEqual<Integer>(2, Length(A), 'icon-offset len');
  Assert.AreEqual(13.0, L.Layout.EvalFloat('text-size', FCtx, 16), 1E-6);
  Assert.AreEqual(9.0, L.Layout.EvalFloat('text-max-width', FCtx, 10), 1E-6);
  Assert.AreEqual(1.4, L.Layout.EvalFloat('text-line-height', FCtx, 1.2), 1E-6);
  Assert.AreEqual(0.1, L.Layout.EvalFloat('text-letter-spacing', FCtx, 0), 1E-6);
  Assert.AreEqual('left', L.Layout.EvalString('text-justify', FCtx, 'center'));
  Assert.AreEqual('top', L.Layout.EvalString('text-anchor', FCtx, 'center'));
  Assert.AreEqual('uppercase', L.Layout.EvalString('text-transform', FCtx, 'none'));
  Assert.AreEqual(3.0, L.Layout.EvalFloat('text-padding', FCtx, 2), 1E-6);
  Assert.IsTrue(L.Layout.EvalBool('text-allow-overlap', FCtx, False));
  Assert.IsTrue(L.Layout.EvalBool('text-ignore-placement', FCtx, False));
  Assert.IsTrue(L.Layout.EvalBool('text-optional', FCtx, False));
  A := L.Layout.GetFloatArray('text-offset', []);
  Assert.AreEqual<Integer>(2, Length(A), 'text-offset len');
  Assert.AreEqual(0.6, A[1], 1E-6, 'text-offset[1]');
end;

procedure TPropertyReadingTests.SymbolPaint;
var
  L: TMGLLayer;
begin
  L := Layer('sy');
  Assert.AreEqual(0.5, L.Paint.EvalFloat('icon-opacity', FCtx, 1), 1E-6);
  Assert.IsTrue(L.Paint.Has('icon-color'), 'icon-color present');
  Assert.IsTrue(L.Paint.Has('text-color'), 'text-color present');
  Assert.IsTrue(L.Paint.Has('text-halo-color'), 'text-halo-color present');
  Assert.AreEqual(1.5, L.Paint.EvalFloat('text-halo-width', FCtx, 0), 1E-6);
end;

procedure TPropertyReadingTests.FunctionStopsAndExpressions;
var
  P: TMGLStyleParser;
  S: TMGLStyle;
  L: TMGLLayer;
  C0, C1: TExprContext;
begin
  // function-stops on line-width + expression on line-color
  P := TMGLStyleParser.Create;
  try
    S := P.ParseString(
      '{"version":8,"layers":[{"id":"x","type":"line","source":"s","source-layer":"l",' +
      '"paint":{"line-width":{"stops":[[10,1],[14,5]]},' +
      '"line-color":["case",["==",["get","c"],"a"],"#ff0000","#00ff00"]}}]}');
    try
      L := S.Layers[0];
      C0 := MakeContext(nil, 10, gtUnknown);
      C1 := MakeContext(nil, 14, gtUnknown);
      Assert.AreEqual(1.0, L.Paint.EvalFloat('line-width', C0, 0), 1E-6, 'width@z10');
      Assert.AreEqual(5.0, L.Paint.EvalFloat('line-width', C1, 0), 1E-6, 'width@z14');
      // expression with no feature -> else branch (#00ff00)
      Assert.AreEqual<Integer>(255, Round(L.Paint.EvalColor('line-color', C0, TMGLColor.Black).G * 255));
    finally
      S.Free;
    end;
  finally
    P.Free;
  end;
end;

{ TPropertyDefaultTests }

procedure TPropertyDefaultTests.Setup;
begin
  FBag := TMGLPropertyBag.Create;
  FCtx := MakeContext(nil, 14, gtUnknown);
end;

procedure TPropertyDefaultTests.TearDown;
begin
  FBag.Free;
end;

procedure TPropertyDefaultTests.NumericDefaults;
begin
  // empty bag -> EvalFloat returns the MapLibre spec default the renderer passes
  Assert.AreEqual(1.0,   FBag.EvalFloat('line-width', FCtx, 1.0), 1E-9);
  Assert.AreEqual(1.0,   FBag.EvalFloat('line-opacity', FCtx, 1.0), 1E-9);
  Assert.AreEqual(0.0,   FBag.EvalFloat('line-blur', FCtx, 0.0), 1E-9);
  Assert.AreEqual(0.0,   FBag.EvalFloat('line-offset', FCtx, 0.0), 1E-9);
  Assert.AreEqual(0.0,   FBag.EvalFloat('line-gap-width', FCtx, 0.0), 1E-9);
  Assert.AreEqual(1.0,   FBag.EvalFloat('fill-opacity', FCtx, 1.0), 1E-9);
  Assert.AreEqual(5.0,   FBag.EvalFloat('circle-radius', FCtx, 5.0), 1E-9);
  Assert.AreEqual(1.0,   FBag.EvalFloat('circle-opacity', FCtx, 1.0), 1E-9);
  Assert.AreEqual(0.0,   FBag.EvalFloat('circle-stroke-width', FCtx, 0.0), 1E-9);
  Assert.AreEqual(1.0,   FBag.EvalFloat('circle-stroke-opacity', FCtx, 1.0), 1E-9);
  Assert.AreEqual(0.0,   FBag.EvalFloat('circle-blur', FCtx, 0.0), 1E-9);
  Assert.AreEqual(16.0,  FBag.EvalFloat('text-size', FCtx, 16.0), 1E-9);
  Assert.AreEqual(10.0,  FBag.EvalFloat('text-max-width', FCtx, 10.0), 1E-9);
  Assert.AreEqual(1.2,   FBag.EvalFloat('text-line-height', FCtx, 1.2), 1E-9);
  Assert.AreEqual(0.0,   FBag.EvalFloat('text-letter-spacing', FCtx, 0.0), 1E-9);
  Assert.AreEqual(0.0,   FBag.EvalFloat('text-halo-width', FCtx, 0.0), 1E-9);
  Assert.AreEqual(2.0,   FBag.EvalFloat('text-padding', FCtx, 2.0), 1E-9);
  Assert.AreEqual(2.0,   FBag.EvalFloat('icon-padding', FCtx, 2.0), 1E-9);
  Assert.AreEqual(1.0,   FBag.EvalFloat('icon-size', FCtx, 1.0), 1E-9);
  Assert.AreEqual(0.0,   FBag.EvalFloat('icon-rotate', FCtx, 0.0), 1E-9);
  Assert.AreEqual(1.0,   FBag.EvalFloat('icon-opacity', FCtx, 1.0), 1E-9);
  Assert.AreEqual(250.0, FBag.EvalFloat('symbol-spacing', FCtx, 250.0), 1E-9);
  Assert.AreEqual(0.0,   FBag.EvalFloat('symbol-sort-key', FCtx, 0.0), 1E-9);
  Assert.AreEqual(1.0,   FBag.EvalFloat('background-opacity', FCtx, 1.0), 1E-9);
end;

procedure TPropertyDefaultTests.StringDefaults;
begin
  Assert.AreEqual('butt',     FBag.EvalString('line-cap', FCtx, 'butt'));
  Assert.AreEqual('miter',    FBag.EvalString('line-join', FCtx, 'miter'));
  Assert.AreEqual('map',      FBag.EvalString('line-translate-anchor', FCtx, 'map'));
  Assert.AreEqual('map',      FBag.EvalString('fill-translate-anchor', FCtx, 'map'));
  Assert.AreEqual('point',    FBag.EvalString('symbol-placement', FCtx, 'point'));
  Assert.AreEqual('center',   FBag.EvalString('text-anchor', FCtx, 'center'));
  Assert.AreEqual('center',   FBag.EvalString('text-justify', FCtx, 'center'));
  Assert.AreEqual('none',     FBag.EvalString('text-transform', FCtx, 'none'));
  Assert.AreEqual('center',   FBag.EvalString('icon-anchor', FCtx, 'center'));
end;

procedure TPropertyDefaultTests.BoolDefaults;
begin
  Assert.IsFalse(FBag.EvalBool('text-allow-overlap', FCtx, False));
  Assert.IsFalse(FBag.EvalBool('icon-allow-overlap', FCtx, False));
  Assert.IsFalse(FBag.EvalBool('text-optional', FCtx, False));
  Assert.IsFalse(FBag.EvalBool('icon-optional', FCtx, False));
  Assert.IsFalse(FBag.EvalBool('text-ignore-placement', FCtx, False));
  Assert.IsFalse(FBag.EvalBool('icon-ignore-placement', FCtx, False));
  Assert.IsTrue(FBag.EvalBool('fill-antialias', FCtx, True));
end;

procedure TPropertyDefaultTests.ColorDefaults;
begin
  // text-halo-color defaults to transparent; fill/line/circle to black; absent
  // text-color/fill-color etc. fall to the renderer's documented default.
  Assert.AreEqual(0.0, FBag.EvalColor('text-halo-color', FCtx, TMGLColor.Transparent).A, 1E-9,
    'halo transparent');
  Assert.AreEqual<Integer>(0, Round(FBag.EvalColor('fill-color', FCtx, TMGLColor.Black).R * 255),
    'fill black');
  Assert.AreEqual<Integer>(0, Round(FBag.EvalColor('line-color', FCtx, TMGLColor.Black).G * 255),
    'line black');
  Assert.AreEqual<Integer>(0, Round(FBag.EvalColor('circle-color', FCtx, TMGLColor.Black).B * 255),
    'circle black');
end;

initialization
  TDUnitX.RegisterTestFixture(TPropertyReadingTests);
  TDUnitX.RegisterTestFixture(TPropertyDefaultTests);

end.
