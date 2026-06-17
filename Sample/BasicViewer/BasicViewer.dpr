program BasicViewer;

{
  PBFMapRenderer - Basic single-tile viewer (VCL)

  Open an .mbtiles, load a Mapbox GL / MapTiler style.json, type a z/x/y tile
  and render it with the style applied.

  MIT License
  Copyright (c) 2025 amancini
}

uses
  Vcl.Forms,
  BasicViewer.MainForm in 'BasicViewer.MainForm.pas' {MainForm},
  PBFMap.Color in '..\..\Source\PBFMap.Color.pas',
  PBFMap.Compression in '..\..\Source\PBFMap.Compression.pas',
  PBFMap.Decoder in '..\..\Source\PBFMap.Decoder.pas',
  PBFMap.Engine in '..\..\Source\PBFMap.Engine.pas',
  PBFMap.Expressions in '..\..\Source\PBFMap.Expressions.pas',
  PBFMap.Geometry in '..\..\Source\PBFMap.Geometry.pas',
  PBFMap.MBTiles in '..\..\Source\PBFMap.MBTiles.pas',
  PBFMap.MVT.Parser in '..\..\Source\PBFMap.MVT.Parser.pas',
  PBFMap.MVT.Types in '..\..\Source\PBFMap.MVT.Types.pas',
  PBFMap.Renderer.GL in '..\..\Source\PBFMap.Renderer.GL.pas',
  PBFMap.Renderer in '..\..\Source\PBFMap.Renderer.pas',
  PBFMap.Sprite in '..\..\Source\PBFMap.Sprite.pas',
  PBFMap.Style.Model in '..\..\Source\PBFMap.Style.Model.pas',
  PBFMap.Style.Parser in '..\..\Source\PBFMap.Style.Parser.pas',
  PBFMap.Types in '..\..\Source\PBFMap.Types.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
