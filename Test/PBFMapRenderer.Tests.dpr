program PBFMapRenderer.Tests;

{$APPTYPE CONSOLE}

{
  PBFMapRenderer - DUnitX console test runner

  Build:  dcc32 -U"..\Source" PBFMapRenderer.Tests.dpr
  Run:    PBFMapRenderer.Tests.exe

  MIT License
  Copyright (c) 2025 amancini
}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.TestFramework,
  PBFMap.Types in '..\Source\PBFMap.Types.pas',
  PBFMap.Decoder in '..\Source\PBFMap.Decoder.pas',
  PBFMap.Geometry in '..\Source\PBFMap.Geometry.pas',
  PBFMap.Compression in '..\Source\PBFMap.Compression.pas',
  PBFMap.MVT.Types in '..\Source\PBFMap.MVT.Types.pas',
  PBFMap.MVT.Parser in '..\Source\PBFMap.MVT.Parser.pas',
  PBFMap.Color in '..\Source\PBFMap.Color.pas',
  PBFMap.Expressions in '..\Source\PBFMap.Expressions.pas',
  PBFMap.MBTiles in '..\Source\PBFMap.MBTiles.pas',
  PBFMap.Style.Model in '..\Source\PBFMap.Style.Model.pas',
  PBFMap.Style.Parser in '..\Source\PBFMap.Style.Parser.pas',
  PBFMap.Sprite in '..\Source\PBFMap.Sprite.pas',
  PBFMap.Collision in '..\Source\PBFMap.Collision.pas',
  PBFMap.Renderer.GL in '..\Source\PBFMap.Renderer.GL.pas',
  PBFMap.Engine in '..\Source\PBFMap.Engine.pas',
  PBFMap.TestUtils in 'PBFMap.TestUtils.pas',
  PBFMap.Tests in 'PBFMap.Tests.pas',
  PBFMap.PropertyTests in 'PBFMap.PropertyTests.pas',
  PBFMap.IntegrationTests in 'PBFMap.IntegrationTests.pas';

var
  Runner: ITestRunner;
  Results: IRunResults;
begin
  try
    Runner := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;
    Runner.AddLogger(TDUnitXConsoleLogger.Create(True));
    Results := Runner.Execute;
    if not Results.AllPassed then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
