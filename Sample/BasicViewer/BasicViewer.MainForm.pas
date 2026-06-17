unit BasicViewer.MainForm;

{
  PBFMapRenderer - Basic single-tile viewer form

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Math,
  System.IOUtils, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Samples.Spin,
  PBFMap.Types, PBFMap.Engine, Vcl.ComCtrls, FireDAC.UI.Intf,
  FireDAC.VCLUI.Wait, FireDAC.Stan.Intf, FireDAC.Comp.UI;

type
  TMainForm = class(TForm)
    pnlTop: TPanel;
    btnOpenTiles: TButton;
    btnLoadStyle: TButton;
    lblZ: TLabel;
    edZ: TSpinEdit;
    lblX: TLabel;
    edX: TSpinEdit;
    lblY: TLabel;
    edY: TSpinEdit;
    btnRender: TButton;
    btnRome: TButton;
    img: TImage;
    sbStatus: TStatusBar;
    dlgOpenTiles: TOpenDialog;
    dlgOpenStyle: TOpenDialog;
    FDGUIxWaitCursor1: TFDGUIxWaitCursor;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnOpenTilesClick(Sender: TObject);
    procedure btnLoadStyleClick(Sender: TObject);
    procedure btnRenderClick(Sender: TObject);
    procedure btnRomeClick(Sender: TObject);
  private
    FEngine: TPBFMapEngine;
    FTilesOpen: Boolean;
    FStyleOpen: Boolean;
    procedure RenderCurrent;
    procedure SetStatus(const S: string);
    procedure LonLatToTile(ALon, ALat: Double; AZoom: Integer; out X, Y: Integer);
    function FindNearby(const ARelPath: string): string;
    procedure TryAutoLoad;
    procedure EngineLog(const aFunction, aDescription: String; aLevel: TPBFLogLevel;
      aIsDebug: Boolean = False);
  end;

var
  MainForm: TMainForm;

const
  RENDER_SIZE = 512;  // px

implementation

{$R *.dfm}

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FEngine := TPBFMapEngine.Create(RENDER_SIZE);
  FEngine.OnLog := EngineLog;
  img.Picture.Bitmap.SetSize(RENDER_SIZE, RENDER_SIZE);
  img.Picture.Bitmap.Canvas.Brush.Color := clWhite;
  img.Picture.Bitmap.Canvas.FillRect(Rect(0, 0, RENDER_SIZE, RENDER_SIZE));
  SetStatus('Open an .mbtiles and a style.json to begin.');
  TryAutoLoad;
end;

function TMainForm.FindNearby(const ARelPath: string): string;
var
  Base: string;
  I: Integer;
  Candidate: string;
begin
  // Search the file relative to the exe dir, walking up a few levels so it
  // works whether the exe is in the project folder or a Win32\Debug subdir.
  Base := ExtractFilePath(Application.ExeName);
  for I := 0 to 5 do
  begin
    Candidate := TPath.Combine(Base, ARelPath);
    if TFile.Exists(Candidate) then
      Exit(Candidate);
    Base := ExtractFilePath(ExcludeTrailingPathDelimiter(Base));
    if Base = '' then
      Break;
  end;
  Result := '';
end;

procedure TMainForm.TryAutoLoad;
var
  StylePath, TilesPath: string;
begin
  // OnLog is wired, so loading degrades gracefully and reports via EngineLog.
  // Success is judged from the engine state, not from the absence of an error.
  // Prefer the richer osm-bright style (real casing layers) if present.
  StylePath := FindNearby('bright\style.json');
  if StylePath <> '' then
    FEngine.SyntheticCasing := False  // bright defines its own casing layers
  else
    StylePath := FindNearby('style.json');
  if StylePath <> '' then
  begin
    FEngine.LoadStyle(StylePath);
    FStyleOpen := Assigned(FEngine.Style) and (FEngine.Style.Layers.Count > 0);
  end;

  TilesPath := FindNearby('data\roma.mbtiles');
  if TilesPath <> '' then
  begin
    FEngine.OpenTiles(TilesPath);
    FTilesOpen := FEngine.Reader.IsOpen;
  end;

  if FStyleOpen and FTilesOpen then
  begin
    SetStatus('Auto-loaded style + roma.mbtiles. Click "Goto Rome z14".');
    btnRomeClick(nil);
  end;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  FEngine.Free;
end;

procedure TMainForm.SetStatus(const S: string);
begin
  sbStatus.SimpleText := S;
end;

procedure TMainForm.EngineLog(const aFunction, aDescription: String;
  aLevel: TPBFLogLevel; aIsDebug: Boolean);
const
  LEVEL_LABELS: array[1..5] of string =
    ('EXCEPTION', 'ERROR', 'WARNING', 'INFO', 'TIMING');
var
  LLabel: string;
begin
  if (Ord(aLevel) >= 1) and (Ord(aLevel) <= 5) then
    LLabel := LEVEL_LABELS[Ord(aLevel)]
  else
    LLabel := 'LOG';
  SetStatus(Format('[%s] %s: %s', [LLabel, aFunction, aDescription]));
end;

procedure TMainForm.btnOpenTilesClick(Sender: TObject);
begin
  if not dlgOpenTiles.Execute then
    Exit;
  FEngine.OpenTiles(dlgOpenTiles.FileName);
  FTilesOpen := FEngine.Reader.IsOpen;
  if FTilesOpen then
    SetStatus(Format('Tiles: %s', [dlgOpenTiles.FileName]));
end;

procedure TMainForm.btnLoadStyleClick(Sender: TObject);
begin
  if not dlgOpenStyle.Execute then
    Exit;
  FEngine.LoadStyle(dlgOpenStyle.FileName);
  FStyleOpen := Assigned(FEngine.Style) and (FEngine.Style.Layers.Count > 0);
  if FStyleOpen then
    SetStatus(Format('Style: %s', [dlgOpenStyle.FileName]));
end;

procedure TMainForm.btnRenderClick(Sender: TObject);
begin
  // Profiled render: clear caches so it actually renders, time per layer/function.
  FEngine.ClearTileCache;
  FEngine.SetProfiling(True);
  FEngine.ResetProfile;
  RenderCurrent;
  FEngine.SetProfiling(False);
  ShowMessage(
    'Top LAYERS (ms):' + sLineBreak + FEngine.TopLayers(12) + sLineBreak +
    'Top FUNCTIONS (ms, leaf = self-time):' + sLineBreak + FEngine.TopFuncs(12));
end;

procedure TMainForm.LonLatToTile(ALon, ALat: Double; AZoom: Integer;
  out X, Y: Integer);
var
  N, LatRad: Double;
begin
  N := Power(2, AZoom);
  LatRad := DegToRad(ALat);
  X := Floor((ALon + 180.0) / 360.0 * N);
  Y := Floor((1.0 - Ln(Tan(LatRad) + 1.0 / Cos(LatRad)) / Pi) / 2.0 * N);
end;

procedure TMainForm.btnRomeClick(Sender: TObject);
var
  X, Y: Integer;
begin
  // Center of Rome (Piazza Venezia ~ 12.4828, 41.8959) at zoom 14
  edZ.Value := 14;
  LonLatToTile(12.4828, 41.8959, 14, X, Y);
  edX.Value := X;
  edY.Value := Y;
  RenderCurrent;
end;

procedure TMainForm.RenderCurrent;
begin
  if not FTilesOpen then
  begin
    SetStatus('No tiles open.');
    Exit;
  end;
  if not FStyleOpen then
  begin
    SetStatus('No style loaded.');
    Exit;
  end;

  // The style has no background layer, so clear the canvas first - otherwise
  // each render is painted on top of the previous tile.
  img.Picture.Bitmap.Canvas.Brush.Color := clWhite;
  img.Picture.Bitmap.Canvas.Brush.Style := bsSolid;
  img.Picture.Bitmap.Canvas.FillRect(Rect(0, 0, RENDER_SIZE, RENDER_SIZE));

  try
    FEngine.RenderTile(edZ.Value, edX.Value, edY.Value, img.Picture.Bitmap.Canvas);
    img.Invalidate;
    SetStatus(Format('Rendered tile %d/%d/%d', [edZ.Value, edX.Value, edY.Value]));
  except
    on E: Exception do
      SetStatus(Format('Render %d/%d/%d failed: %s',
        [edZ.Value, edX.Value, edY.Value, E.Message]));
  end;
end;

end.
