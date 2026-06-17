unit PBFMap.Geometry;

{
  PBFMapRenderer - Geometry structures
  
  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System. SysUtils, System.Types, System. Generics.Collections,
  PBFMap.Types;

type
  /// <summary>Point in tile coordinate space (0.. 4096)</summary>
  TPBFPoint = record
    X: Integer;
    Y: Integer;
    constructor Create(AX, AY: Integer);
    function ToString: string;
  end;

  /// <summary>Geometry collection with type</summary>
  TPBFGeometry = class
  private
    FGeometryType: TPBFGeometryType;
    FPoints: TList<TPBFPoint>;
  public
    constructor Create(AGeometryType: TPBFGeometryType);
    destructor Destroy; override;
    
    /// <summary>Add point by coordinates</summary>
    procedure AddPoint(X, Y: Integer); overload;
    
    /// <summary>Add point record</summary>
    procedure AddPoint(const APoint: TPBFPoint); overload;
    
    /// <summary>Clear all points</summary>
    procedure Clear;
    
    /// <summary>Get point count</summary>
    function Count: Integer;
    
    /// <summary>Geometry type (point, line, polygon)</summary>
    property GeometryType: TPBFGeometryType read FGeometryType write FGeometryType;
    
    /// <summary>Point list</summary>
    property Points: TList<TPBFPoint> read FPoints;
  end;

  /// <summary>Map feature with geometry and properties</summary>
  TPBFFeature = class
  private
    FID: Int64;
    FGeometry: TPBFGeometry;
    FProperties: TDictionary<string, string>;
  public
    constructor Create;
    destructor Destroy; override;
    
    /// <summary>Set property value</summary>
    procedure SetProperty(const AKey, AValue: string);
    
    /// <summary>Get property value (returns empty string if not found)</summary>
    function GetProperty(const AKey: string): string;
    
    /// <summary>Check if property exists</summary>
    function HasProperty(const AKey: string): Boolean;
    
    /// <summary>Feature ID</summary>
    property ID: Int64 read FID write FID;
    
    /// <summary>Feature geometry</summary>
    property Geometry: TPBFGeometry read FGeometry write FGeometry;
    
    /// <summary>Feature properties (tags)</summary>
    property Properties: TDictionary<string, string> read FProperties;
  end;

  /// <summary>Layer containing multiple features</summary>
  TPBFLayer = class
  private
    FName: string;
    FExtent: Integer;
    FFeatures: TObjectList<TPBFFeature>;
  public
    constructor Create(const AName: string; AExtent: Integer = PBF_TILE_EXTENT);
    destructor Destroy; override;
    
    /// <summary>Add feature to layer</summary>
    procedure AddFeature(AFeature: TPBFFeature);
    
    /// <summary>Clear all features</summary>
    procedure Clear;
    
    /// <summary>Layer name</summary>
    property Name: string read FName write FName;
    
    /// <summary>Tile extent (usually 4096)</summary>
    property Extent: Integer read FExtent write FExtent;
    
    /// <summary>Features in this layer</summary>
    property Features: TObjectList<TPBFFeature> read FFeatures;
  end;

implementation

{ TPBFPoint }

constructor TPBFPoint. Create(AX, AY: Integer);
begin
  X := AX;
  Y := AY;
end;

function TPBFPoint.ToString: string;
begin
  Result := Format('(%d, %d)', [X, Y]);
end;

{ TPBFGeometry }

constructor TPBFGeometry.Create(AGeometryType: TPBFGeometryType);
begin
  inherited Create;
  FGeometryType := AGeometryType;
  FPoints := TList<TPBFPoint>.Create;
end;

destructor TPBFGeometry.Destroy;
begin
  FPoints.Free;
  inherited;
end;

procedure TPBFGeometry.AddPoint(X, Y: Integer);
begin
  FPoints.Add(TPBFPoint.Create(X, Y));
end;

procedure TPBFGeometry.AddPoint(const APoint: TPBFPoint);
begin
  FPoints.Add(APoint);
end;

procedure TPBFGeometry.Clear;
begin
  FPoints.Clear;
end;

function TPBFGeometry.Count: Integer;
begin
  Result := FPoints.Count;
end;

{ TPBFFeature }

constructor TPBFFeature.Create;
begin
  inherited;
  FID := 0;
  FGeometry := nil;
  FProperties := TDictionary<string, string>.Create;
end;

destructor TPBFFeature.Destroy;
begin
  FGeometry.Free;
  FProperties.Free;
  inherited;
end;

procedure TPBFFeature.SetProperty(const AKey, AValue: string);
begin
  FProperties.AddOrSetValue(AKey, AValue);
end;

function TPBFFeature.GetProperty(const AKey: string): string;
begin
  if not FProperties.TryGetValue(AKey, Result) then
    Result := '';
end;

function TPBFFeature.HasProperty(const AKey: string): Boolean;
begin
  Result := FProperties.ContainsKey(AKey);
end;

{ TPBFLayer }

constructor TPBFLayer.Create(const AName: string; AExtent: Integer);
begin
  inherited Create;
  FName := AName;
  FExtent := AExtent;
  FFeatures := TObjectList<TPBFFeature>.Create(True);  // Owns objects
end;

destructor TPBFLayer.Destroy;
begin
  FFeatures.Free;
  inherited;
end;

procedure TPBFLayer.AddFeature(AFeature: TPBFFeature);
begin
  FFeatures.Add(AFeature);
end;

procedure TPBFLayer.Clear;
begin
  FFeatures.Clear;
end;

end.