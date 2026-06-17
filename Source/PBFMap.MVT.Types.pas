unit PBFMap.MVT.Types;

{
  PBFMapRenderer - Mapbox Vector Tile object model

  Typed value, multi-part/multi-ring geometry, feature, layer and tile.
  This model is produced by PBFMap.MVT.Parser and consumed by the renderer
  and the expression engine. TMVTValue is also the currency type used as the
  result of every Mapbox GL style expression.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  PBFMap.Types, PBFMap.Geometry;

type
  /// <summary>Discriminator for the value held in a TMVTValue</summary>
  TMVTValueKind = (vkNull, vkString, vkBool, vkInt, vkUInt, vkDouble);

  /// <summary>
  ///   Typed, value-semantics MVT property value. Also the result type of
  ///   every style expression. Lightweight record - no heap allocation beyond
  ///   the managed string field.
  /// </summary>
  TMVTValue = record
  strict private
    FKind: TMVTValueKind;
    FStr: string;
    FNum: Double;
    FInt: Int64;
    FBool: Boolean;
  public
    class function Null: TMVTValue; static;
    class function FromString(const S: string): TMVTValue; static;
    class function FromBool(B: Boolean): TMVTValue; static;
    class function FromInt(I: Int64): TMVTValue; static;
    class function FromUInt(U: UInt64): TMVTValue; static;
    class function FromDouble(D: Double): TMVTValue; static;

    property Kind: TMVTValueKind read FKind;
    function IsNull: Boolean;

    /// <summary>String representation (invariant, integers without ".0")</summary>
    function AsString: string;
    /// <summary>Numeric value; Ok=False if not coercible</summary>
    function AsDouble(out Ok: Boolean): Double; overload;
    /// <summary>Numeric value, returns ADefault when not coercible</summary>
    function AsDouble(ADefault: Double = 0): Double; overload;
    /// <summary>Mapbox truthiness: false for false/0/""/null/NaN</summary>
    function AsBool: Boolean;

    /// <summary>Equality per Mapbox semantics (numeric across int/uint/double)</summary>
    function Equals(const Other: TMVTValue): Boolean;
    /// <summary>Ordering for &lt; &gt;; Ok=False when not comparable</summary>
    function Compare(const Other: TMVTValue; out Ok: Boolean): Integer;
  end;

  /// <summary>Role of a polygon ring</summary>
  TMVTRingRole = (rrUnknown, rrExterior, rrInterior);

  /// <summary>One part of a geometry: a line part, a point group, or a ring</summary>
  TMVTPart = record
    Points: TArray<TPBFPoint>;
    Role: TMVTRingRole;     // meaningful for polygons
    SignedArea: Double;     // shoelace area (polygons); 0 otherwise
  end;

  /// <summary>Multi-part / multi-ring geometry</summary>
  TMVTGeometry = class
  private
    FGeometryType: TPBFGeometryType;
    FParts: TList<TMVTPart>;
  public
    constructor Create(AGeometryType: TPBFGeometryType);
    destructor Destroy; override;

    procedure AddPart(const APart: TMVTPart);

    /// <summary>
    ///   For polygons: group interior rings (holes) under their containing
    ///   exterior ring, in encounter order. Each result entry is
    ///   [exterior, hole1, hole2, ...].
    /// </summary>
    function ExteriorWithHoles: TArray<TArray<TArray<TPBFPoint>>>;

    property GeometryType: TPBFGeometryType read FGeometryType write FGeometryType;
    property Parts: TList<TMVTPart> read FParts;
  end;

  /// <summary>Feature with typed properties</summary>
  TMVTFeature = class
  private
    FID: UInt64;
    FGeometry: TMVTGeometry;
    // Parallel key/value arrays instead of a per-feature TDictionary: features
    // carry only a handful of props, so a linear scan beats a dict and avoids
    // ~14k dictionary allocations per tile (cuts MVT parse time).
    FKeys: TArray<string>;
    FVals: TArray<TMVTValue>;
    FHashes: TArray<Cardinal>;   // FNV-1a hash of each key, for fast lookup compare
    FCount: Integer;
    procedure Grow;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetProp(const AKey: string; const AValue: TMVTValue);
    /// <summary>Append a property WITHOUT the dedup scan SetProp does. For the MVT
    /// parser only, where tag keys are guaranteed unique by the spec: avoids the
    /// O(n^2) build cost of SetProp across a feature's tags.</summary>
    procedure AddProp(const AKey: string; const AValue: TMVTValue);
    function GetProp(const AKey: string; out AValue: TMVTValue): Boolean;
    function HasProp(const AKey: string): Boolean;
    /// <summary>GetProp with a precomputed key hash (from MVTKeyHash): compares the
    /// integer hash first and the string only on a hash hit. The expression engine
    /// caches the hash of a constant get-key, so per-feature filter eval avoids the
    /// per-char string scan over the feature's keys.</summary>
    function GetPropH(const AKey: string; AHash: Cardinal; out AValue: TMVTValue): Boolean;
    function HasPropH(const AKey: string; AHash: Cardinal): Boolean;

    property ID: UInt64 read FID write FID;
    property Geometry: TMVTGeometry read FGeometry write FGeometry;
    property PropCount: Integer read FCount;
  end;

  /// <summary>Layer with its own extent</summary>
  TMVTLayer = class
  private
    FName: string;
    FExtent: Integer;
    FVersion: Integer;
    FFeatures: TObjectList<TMVTFeature>;
  public
    constructor Create(const AName: string; AExtent: Integer = PBF_TILE_EXTENT);
    destructor Destroy; override;

    procedure AddFeature(AFeature: TMVTFeature);

    property Name: string read FName write FName;
    property Extent: Integer read FExtent write FExtent;
    property Version: Integer read FVersion write FVersion;
    property Features: TObjectList<TMVTFeature> read FFeatures;
  end;

  /// <summary>Decoded vector tile</summary>
  TMVTTile = class
  private
    FLayers: TObjectList<TMVTLayer>;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddLayer(ALayer: TMVTLayer);
    function LayerByName(const AName: string): TMVTLayer;

    property Layers: TObjectList<TMVTLayer> read FLayers;
  end;

/// <summary>Invariant-culture format settings shared across the library</summary>
function PBFInvariant: TFormatSettings;

/// <summary>FNV-1a 32-bit hash of a property key (shared by feature lookup and the
/// expression engine's cached get-keys so the hashes match).</summary>
function MVTKeyHash(const S: string): Cardinal;

implementation

var
  GInvariant: TFormatSettings;

function MVTKeyHash(const S: string): Cardinal;
var
  I: Integer;
begin
  Result := 2166136261;  // FNV offset basis
  for I := 1 to Length(S) do
    Result := (Result xor Ord(S[I])) * 16777619;  // FNV prime
end;

function PBFInvariant: TFormatSettings;
begin
  Result := GInvariant;
end;

{ TMVTValue }

class function TMVTValue.Null: TMVTValue;
begin
  Result.FKind := vkNull;
end;

class function TMVTValue.FromString(const S: string): TMVTValue;
begin
  Result.FKind := vkString;
  Result.FStr := S;
end;

class function TMVTValue.FromBool(B: Boolean): TMVTValue;
begin
  Result.FKind := vkBool;
  Result.FBool := B;
end;

class function TMVTValue.FromInt(I: Int64): TMVTValue;
begin
  Result.FKind := vkInt;
  Result.FInt := I;
end;

class function TMVTValue.FromUInt(U: UInt64): TMVTValue;
begin
  Result.FKind := vkUInt;
  Result.FInt := Int64(U);
end;

class function TMVTValue.FromDouble(D: Double): TMVTValue;
begin
  Result.FKind := vkDouble;
  Result.FNum := D;
end;

function TMVTValue.IsNull: Boolean;
begin
  Result := FKind = vkNull;
end;

function TMVTValue.AsString: string;
begin
  case FKind of
    vkNull:   Result := '';
    vkString: Result := FStr;
    vkBool:   if FBool then Result := 'true' else Result := 'false';
    vkInt:    Result := IntToStr(FInt);
    vkUInt:   Result := UIntToStr(UInt64(FInt));
    vkDouble:
      if IsNan(FNum) or IsInfinite(FNum) then
        Result := ''
      else
        Result := FloatToStr(FNum, GInvariant);
  else
    Result := '';
  end;
end;

function TMVTValue.AsDouble(out Ok: Boolean): Double;
begin
  Ok := True;
  case FKind of
    vkInt:    Result := FInt;
    vkUInt:   Result := UInt64(FInt);
    vkDouble:
      begin
        Result := FNum;
        Ok := not (IsNan(FNum) or IsInfinite(FNum));
      end;
    vkBool:   if FBool then Result := 1 else Result := 0;
    vkString: Ok := TryStrToFloat(FStr, Result, GInvariant);
  else
    Ok := False;
    Result := 0;
  end;
  if not Ok then
    Result := 0;
end;

function TMVTValue.AsDouble(ADefault: Double): Double;
var
  Ok: Boolean;
begin
  Result := AsDouble(Ok);
  if not Ok then
    Result := ADefault;
end;

function TMVTValue.AsBool: Boolean;
begin
  case FKind of
    vkNull:   Result := False;
    vkBool:   Result := FBool;
    vkInt:    Result := FInt <> 0;
    vkUInt:   Result := FInt <> 0;
    vkDouble: Result := (FNum <> 0) and not IsNan(FNum);
    vkString: Result := FStr <> '';
  else
    Result := False;
  end;
end;

function TMVTValue.Equals(const Other: TMVTValue): Boolean;
var
  A, B: Double;
  OkA, OkB: Boolean;
begin
  // null only equals null
  if (FKind = vkNull) or (Other.FKind = vkNull) then
    Exit((FKind = vkNull) and (Other.FKind = vkNull));

  // both strings -> string equality
  if (FKind = vkString) and (Other.FKind = vkString) then
    Exit(FStr = Other.FStr);

  // string vs non-string never equal (Mapbox does not coerce here)
  if (FKind = vkString) or (Other.FKind = vkString) then
    Exit(False);

  // bool vs bool
  if (FKind = vkBool) and (Other.FKind = vkBool) then
    Exit(FBool = Other.FBool);

  // remaining: numeric comparison
  A := AsDouble(OkA);
  B := Other.AsDouble(OkB);
  Result := OkA and OkB and (A = B);
end;

function TMVTValue.Compare(const Other: TMVTValue; out Ok: Boolean): Integer;
var
  A, B: Double;
  OkA, OkB: Boolean;
begin
  Ok := True;
  Result := 0;

  // string vs string
  if (FKind = vkString) and (Other.FKind = vkString) then
  begin
    Result := CompareStr(FStr, Other.FStr);
    Exit;
  end;

  // numeric vs numeric
  if (FKind in [vkInt, vkUInt, vkDouble, vkBool]) and
     (Other.FKind in [vkInt, vkUInt, vkDouble, vkBool]) then
  begin
    A := AsDouble(OkA);
    B := Other.AsDouble(OkB);
    if OkA and OkB then
    begin
      if A < B then Result := -1
      else if A > B then Result := 1
      else Result := 0;
      Exit;
    end;
  end;

  Ok := False;
end;

{ TMVTGeometry }

constructor TMVTGeometry.Create(AGeometryType: TPBFGeometryType);
begin
  inherited Create;
  FGeometryType := AGeometryType;
  FParts := TList<TMVTPart>.Create;
end;

destructor TMVTGeometry.Destroy;
begin
  FParts.Free;
  inherited;
end;

procedure TMVTGeometry.AddPart(const APart: TMVTPart);
begin
  FParts.Add(APart);
end;

function TMVTGeometry.ExteriorWithHoles: TArray<TArray<TArray<TPBFPoint>>>;
var
  Groups: TList<TArray<TArray<TPBFPoint>>>;
  Current: TList<TArray<TPBFPoint>>;
  I: Integer;
  Part: TMVTPart;

  procedure Flush;
  begin
    if Assigned(Current) then
    begin
      Groups.Add(Current.ToArray);
      FreeAndNil(Current);
    end;
  end;

begin
  Groups := TList<TArray<TArray<TPBFPoint>>>.Create;
  try
    Current := nil;
    try
      for I := 0 to FParts.Count - 1 do
      begin
        Part := FParts[I];
        if Part.Role = rrInterior then
        begin
          // hole of the open exterior; ignore stray holes with no exterior
          if Assigned(Current) then
            Current.Add(Part.Points);
        end
        else
        begin
          // exterior (or unknown treated as exterior) starts a new group
          Flush;
          Current := TList<TArray<TPBFPoint>>.Create;
          Current.Add(Part.Points);
        end;
      end;
      Flush;
    finally
      Current.Free;  // no-op if Flush already freed it
    end;
    Result := Groups.ToArray;
  finally
    Groups.Free;
  end;
end;

{ TMVTFeature }

constructor TMVTFeature.Create;
begin
  inherited Create;
  FCount := 0;
end;

destructor TMVTFeature.Destroy;
begin
  FGeometry.Free;
  inherited;
end;

procedure TMVTFeature.Grow;
begin
  SetLength(FKeys, Length(FKeys) * 2 + 8);  // amortised growth
  SetLength(FVals, Length(FKeys));
  SetLength(FHashes, Length(FKeys));
end;

procedure TMVTFeature.SetProp(const AKey: string; const AValue: TMVTValue);
var
  I: Integer;
begin
  // overwrite if the key already exists (matches the old AddOrSetValue)
  for I := 0 to FCount - 1 do
    if FKeys[I] = AKey then
    begin
      FVals[I] := AValue;
      Exit;
    end;
  if FCount >= Length(FKeys) then
    Grow;
  FKeys[FCount] := AKey;
  FVals[FCount] := AValue;
  FHashes[FCount] := MVTKeyHash(AKey);
  Inc(FCount);
end;

procedure TMVTFeature.AddProp(const AKey: string; const AValue: TMVTValue);
begin
  if FCount >= Length(FKeys) then
    Grow;
  FKeys[FCount] := AKey;
  FVals[FCount] := AValue;
  FHashes[FCount] := MVTKeyHash(AKey);
  Inc(FCount);
end;

function TMVTFeature.GetProp(const AKey: string; out AValue: TMVTValue): Boolean;
begin
  Result := GetPropH(AKey, MVTKeyHash(AKey), AValue);
end;

function TMVTFeature.GetPropH(const AKey: string; AHash: Cardinal;
  out AValue: TMVTValue): Boolean;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if (FHashes[I] = AHash) and (FKeys[I] = AKey) then
    begin
      AValue := FVals[I];
      Exit(True);
    end;
  Result := False;
end;

function TMVTFeature.HasProp(const AKey: string): Boolean;
begin
  Result := HasPropH(AKey, MVTKeyHash(AKey));
end;

function TMVTFeature.HasPropH(const AKey: string; AHash: Cardinal): Boolean;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if (FHashes[I] = AHash) and (FKeys[I] = AKey) then
      Exit(True);
  Result := False;
end;

{ TMVTLayer }

constructor TMVTLayer.Create(const AName: string; AExtent: Integer);
begin
  inherited Create;
  FName := AName;
  FExtent := AExtent;
  FVersion := 2;
  FFeatures := TObjectList<TMVTFeature>.Create(True);
end;

destructor TMVTLayer.Destroy;
begin
  FFeatures.Free;
  inherited;
end;

procedure TMVTLayer.AddFeature(AFeature: TMVTFeature);
begin
  FFeatures.Add(AFeature);
end;

{ TMVTTile }

constructor TMVTTile.Create;
begin
  inherited Create;
  FLayers := TObjectList<TMVTLayer>.Create(True);
end;

destructor TMVTTile.Destroy;
begin
  FLayers.Free;
  inherited;
end;

procedure TMVTTile.AddLayer(ALayer: TMVTLayer);
begin
  FLayers.Add(ALayer);
end;

function TMVTTile.LayerByName(const AName: string): TMVTLayer;
var
  L: TMVTLayer;
begin
  for L in FLayers do
    if L.Name = AName then
      Exit(L);
  Result := nil;
end;

initialization
  GInvariant := TFormatSettings.Invariant;

end.
