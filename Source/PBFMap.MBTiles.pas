unit PBFMap.MBTiles;

{
  PBFMapRenderer - MBTiles database reader
  
  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Classes,
  FireDAC.Comp.Client, FireDAC.Stan.Def, FireDAC.Phys.SQLite, Db,
  FireDAC.Phys.SQLiteDef, FireDAC.Phys.SQLiteWrapper.Stat,
  FireDAC.Stan.Async, FireDAC.Stan.Param, FireDAC.DApt,
  PBFMap.Types;

type
  /// <summary>MBTiles database reader for PBF tiles</summary>
  TPBFMBTilesReader = class
  private
    FConnection : TFDConnection;
    FQuery      : TFDQuery;
    FFileName   : string;
    FOnLog      : TPBFLogEvent;
    { Fires OnLog if assigned (info/warning). Never raises. }
    procedure DoLog(const aFunction, aDescription: String; aLevel: TPBFLogLevel;
      aIsDebug: Boolean = False);
    { Logs via OnLog when assigned; otherwise raises EPBFMBTilesError. }
    procedure LogOrRaise(const aFunction, aDescription: String; aLevel: TPBFLogLevel);
  public
    constructor Create;
    destructor Destroy; override;
    
    /// <summary>Open MBTiles database file</summary>
    /// <param name="AFileName">Path to . mbtiles file</param>
    procedure Open(const AFileName: string);
    
    /// <summary>Close database connection</summary>
    procedure Close;
    
    /// <summary>Check if database is currently open</summary>
    function IsOpen: Boolean;
    
    /// <summary>Get tile data as byte array (PBF format)</summary>
    /// <param name="ATile">Tile coordinates</param>
    /// <returns>Raw PBF tile data</returns>
    function GetTileData(const ATile: TPBFTileCoord): TBytes; overload;
    
    /// <summary>Get tile data as byte array (PBF format)</summary>
    /// <param name="AZoom">Zoom level</param>
    /// <param name="X">Tile X coordinate</param>
    /// <param name="Y">Tile Y coordinate</param>
    /// <returns>Raw PBF tile data</returns>
    function GetTileData(AZoom, X, Y: Integer): TBytes; overload;
    
    /// <summary>Check if a specific tile exists</summary>
    function TileExists(AZoom, X, Y: Integer): Boolean;
    
    /// <summary>Get metadata value by name</summary>
    /// <param name="AName">Metadata key (e.g., 'name', 'format', 'bounds')</param>
    /// <returns>Metadata value or empty string if not found</returns>
    function GetMetadata(const AName: string): string;
    
    /// <summary>Get tile format from metadata</summary>
    /// <returns>Format string (e.g., 'pbf', 'png', 'jpg')</returns>
    function GetFormat: string;
    
    /// <summary>Current database filename</summary>
    property FileName: string read FFileName;

    /// <summary>Optional log event fired on open/read failures.</summary>
    property OnLog: TPBFLogEvent read FOnLog write FOnLog;
  end;

implementation

{ TPBFMBTilesReader }

procedure TPBFMBTilesReader.DoLog(const aFunction, aDescription: String;
  aLevel: TPBFLogLevel; aIsDebug: Boolean);
begin
  if not Assigned(FOnLog) then
    Exit;
{$REGION 'Log'}
{TSI:IGNORE ON}
  FOnLog(aFunction, aDescription, aLevel, aIsDebug);
{TSI:IGNORE OFF}
{$ENDREGION}
end;

procedure TPBFMBTilesReader.LogOrRaise(const aFunction, aDescription: String;
  aLevel: TPBFLogLevel);
begin
  if Assigned(FOnLog) then
    DoLog(aFunction, aDescription, aLevel)
  else
    raise EPBFMBTilesError.Create(aDescription);
end;

constructor TPBFMBTilesReader.Create;
begin
  inherited Create;
  FConnection := TFDConnection.Create(nil);
  FConnection.DriverName := 'SQLite';
  
  FQuery := TFDQuery.Create(nil);
  FQuery.Connection := FConnection;
end;

destructor TPBFMBTilesReader.Destroy;
begin
  Close;
  FQuery.Free;
  FConnection.Free;
  inherited;
end;

procedure TPBFMBTilesReader.Open(const AFileName: string);
begin
  if not FileExists(AFileName) then
  begin
    LogOrRaise(Format('%s.Open', [Self.ClassName]),
      Format('MBTiles file not found: %s', [AFileName]), tplivException);
    Exit;
  end;

  Close;

  try
    FFileName := AFileName;
    FConnection.Params.Clear;
    // Params.Clear also drops DriverID, so restore it before connecting,
    // otherwise FireDAC raises -340 "Driver ID is not defined".
    FConnection.DriverName := 'SQLite';
    FConnection.Params.Add('Database=' + AFileName);
    FConnection.Params.Add('LockingMode=Normal');
    FConnection.Connected := True;
    DoLog(Format('%s.Open', [Self.ClassName]),
      Format('Opened MBTiles: %s', [AFileName]), tplivInfo);
  except
    on E: Exception do
      LogOrRaise(Format('%s.Open', [Self.ClassName]),
        Format('Failed to open MBTiles "%s": %s', [AFileName, E.Message]), tplivException);
  end;
end;

procedure TPBFMBTilesReader.Close;
begin
  if FQuery.Active then
    FQuery.Close;
  FConnection.Connected := False;
  FFileName := '';
end;

function TPBFMBTilesReader.IsOpen: Boolean;
begin
  Result := FConnection.Connected;
end;

function TPBFMBTilesReader.GetTileData(const ATile: TPBFTileCoord): TBytes;
begin
  Result := GetTileData(ATile. Zoom, ATile.X, ATile.Y);
end;

function TPBFMBTilesReader.GetTileData(AZoom, X, Y: Integer): TBytes;
var
  Stream: TMemoryStream;
  TileRow: Integer;
begin
  SetLength(Result, 0);
  
  if not IsOpen then
  begin
    LogOrRaise(Format('%s.GetTileData', [Self.ClassName]),
      'MBTiles database is not open', tplivError);
    Exit;
  end;

  // MBTiles uses TMS scheme: Y coordinate is flipped
  // TMS: Y = (2^zoom - 1) - Y_xyz
  TileRow := (1 shl AZoom) - 1 - Y;
  
  try
    FQuery.SQL.Text := 
      'SELECT tile_data FROM tiles ' +
      'WHERE zoom_level = :zoom AND tile_column = :x AND tile_row = :y';
    FQuery.ParamByName('zoom').AsInteger := AZoom;
    FQuery.ParamByName('x').AsInteger := X;
    FQuery.ParamByName('y').AsInteger := TileRow;
    FQuery.Open;
    
    try
      if FQuery.IsEmpty then
      begin
        DoLog(Format('%s.GetTileData', [Self.ClassName]),
          Format('Tile not found: %d/%d/%d', [AZoom, X, Y]), tplivWarning);
        Exit;
      end;

      Stream := TMemoryStream.Create;
      try
        TBlobField(FQuery.FieldByName('tile_data')).SaveToStream(Stream);
        SetLength(Result, Stream.Size);
        if Stream.Size > 0 then
        begin
          Stream.Position := 0;
          Stream.ReadBuffer(Result[0], Stream. Size);
        end;
      finally
        Stream.Free;
      end;
    finally
      FQuery.Close;
    end;
  except
    on E: Exception do
      LogOrRaise(Format('%s.GetTileData', [Self.ClassName]),
        Format('Error reading tile %d/%d/%d: %s', [AZoom, X, Y, E.Message]), tplivError);
  end;
end;

function TPBFMBTilesReader. TileExists(AZoom, X, Y: Integer): Boolean;
var
  TileRow: Integer;
begin
  Result := False;
  
  if not IsOpen then
    Exit;
    
  TileRow := (1 shl AZoom) - 1 - Y;
  
  try
    FQuery.SQL.Text := 
      'SELECT 1 FROM tiles ' +
      'WHERE zoom_level = :zoom AND tile_column = :x AND tile_row = :y ' +
      'LIMIT 1';
    FQuery.ParamByName('zoom').AsInteger := AZoom;
    FQuery.ParamByName('x'). AsInteger := X;
    FQuery.ParamByName('y').AsInteger := TileRow;
    FQuery.Open;
    
    try
      Result := not FQuery.IsEmpty;
    finally
      FQuery.Close;
    end;
  except
    on E: Exception do
    begin
      DoLog(Format('%s.TileExists', [Self.ClassName]),
        Format('TileExists %d/%d/%d failed: %s', [AZoom, X, Y, E.Message]), tplivError);
      Result := False;
    end;
  end;
end;

function TPBFMBTilesReader.GetMetadata(const AName: string): string;
begin
  Result := '';

  if not IsOpen then
  begin
    LogOrRaise(Format('%s.GetMetadata', [Self.ClassName]),
      'MBTiles database is not open', tplivError);
    Exit;
  end;

  try
    FQuery.SQL.Text := 'SELECT value FROM metadata WHERE name = :name';
    FQuery.ParamByName('name').AsString := AName;
    FQuery.Open;

    try
      if not FQuery.IsEmpty then
        Result := FQuery.Fields[0].AsString;
    finally
      FQuery.Close;
    end;
  except
    on E: Exception do
      LogOrRaise(Format('%s.GetMetadata', [Self.ClassName]),
        Format('Error reading metadata "%s": %s', [AName, E.Message]), tplivError);
  end;
end;

function TPBFMBTilesReader.GetFormat: string;
begin
  Result := GetMetadata('format');
  if Result = '' then
    Result := 'unknown';
end;

end.