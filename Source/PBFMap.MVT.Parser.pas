unit PBFMap.MVT.Parser;

{
  PBFMapRenderer - Mapbox Vector Tile parser

  Parses a decompressed PBF tile (vector_tile.proto) into the TMVT* object
  model: layers, features, typed values and decoded multi-part/multi-ring
  geometry (delta + zigzag command stream).

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  PBFMap.Types, PBFMap.Geometry, PBFMap.Decoder, PBFMap.MVT.Types;

type
  /// <summary>Parser turning raw PBF bytes into a TMVTTile</summary>
  TMVTTileParser = class
  private
    procedure ParseLayer(const AData: TBytes; ATile: TMVTTile);
    procedure ParseFeature(const AData: TBytes; ALayer: TMVTLayer;
      const AKeys: TArray<string>; const AValues: TArray<TMVTValue>);
    function ParseValue(const AData: TBytes): TMVTValue;
    procedure DecodeGeometry(const ACommands: TArray<UInt64>;
      AType: TPBFGeometryType; AGeometry: TMVTGeometry);
    procedure ClassifyRings(AGeometry: TMVTGeometry);
  public
    /// <summary>Parse decompressed PBF data. Caller owns the result.</summary>
    function Parse(const AData: TBytes): TMVTTile;
  end;

implementation

const
  // Geometry command ids
  CMD_MOVE_TO    = 1;
  CMD_LINE_TO    = 2;
  CMD_CLOSE_PATH = 7;

  // vector_tile.proto GeomType
  GEOM_UNKNOWN    = 0;
  GEOM_POINT      = 1;
  GEOM_LINESTRING = 2;
  GEOM_POLYGON    = 3;

function ZigZag(N: UInt64): Int64; inline;
begin
  Result := Int64(N shr 1) xor (-Int64(N and 1));
end;

function ShoelaceArea(const APoints: TArray<TPBFPoint>): Double;
var
  I, N: Integer;
  Sum: Double;
begin
  N := Length(APoints);
  if N < 3 then
    Exit(0);
  Sum := 0;
  for I := 0 to N - 1 do
    Sum := Sum + (APoints[I].X * APoints[(I + 1) mod N].Y)
                - (APoints[(I + 1) mod N].X * APoints[I].Y);
  Result := Sum / 2.0;
end;

{ TMVTTileParser }

function TMVTTileParser.Parse(const AData: TBytes): TMVTTile;
var
  Decoder: TPBFDecoder;
  Field: Integer;
  Wire: TPBFWireType;
begin
  Result := TMVTTile.Create;
  if Length(AData) = 0 then
    Exit;
  try
    Decoder := TPBFDecoder.Create(AData);
    try
      while Decoder.ReadTag(Field, Wire) do
      begin
        if (Field = 3) and (Wire = wtLengthDelimited) then
          ParseLayer(Decoder.ReadBytes, Result)
        else
          Decoder.SkipField(Wire);
      end;
    finally
      Decoder.Free;
    end;
  except
    on E: EPBFMapError do
    begin
      Result.Free;
      raise;
    end;
    on E: Exception do
    begin
      Result.Free;
      raise EMVTParseError.CreateFmt('Failed to parse tile: %s', [E.Message]);
    end;
  end;
end;

procedure TMVTTileParser.ParseLayer(const AData: TBytes; ATile: TMVTTile);
var
  Decoder: TPBFDecoder;
  Field: Integer;
  Wire: TPBFWireType;
  Name: string;
  Extent, Version: Integer;
  Keys: TList<string>;
  Values: TList<TMVTValue>;
  FeatureBlobs: TList<TBytes>;
  Layer: TMVTLayer;
  Blob: TBytes;
  KeysArr: TArray<string>;
  ValuesArr: TArray<TMVTValue>;
begin
  Name := '';
  Extent := PBF_TILE_EXTENT;
  Version := 2;
  Keys := TList<string>.Create;
  Values := TList<TMVTValue>.Create;
  FeatureBlobs := TList<TBytes>.Create;
  try
    Decoder := TPBFDecoder.Create(AData);
    try
      // First pass: read everything; defer features until keys/values known.
      while Decoder.ReadTag(Field, Wire) do
      begin
        case Field of
          15: Version := Integer(Decoder.ReadVarint);          // version
          1:  Name := Decoder.ReadString;                      // name
          2:  FeatureBlobs.Add(Decoder.ReadBytes);             // features
          3:  Keys.Add(Decoder.ReadString);                    // keys
          4:  Values.Add(ParseValue(Decoder.ReadBytes));       // values
          5:  Extent := Integer(Decoder.ReadVarint);           // extent
        else
          Decoder.SkipField(Wire);
        end;
      end;
    finally
      Decoder.Free;
    end;

    Layer := TMVTLayer.Create(Name, Extent);
    Layer.Version := Version;
    ATile.AddLayer(Layer);

    // keys/values pools are per-layer constants: snapshot once, not per feature
    // (Keys.ToArray/Values.ToArray per feature copied the whole pool each time).
    KeysArr := Keys.ToArray;
    ValuesArr := Values.ToArray;
    for Blob in FeatureBlobs do
      ParseFeature(Blob, Layer, KeysArr, ValuesArr);
  finally
    Keys.Free;
    Values.Free;
    FeatureBlobs.Free;
  end;
end;

function TMVTTileParser.ParseValue(const AData: TBytes): TMVTValue;
var
  Decoder: TPBFDecoder;
  Field: Integer;
  Wire: TPBFWireType;
  U32: UInt32;
  U64: UInt64;
  SingleVal: Single;
  DoubleVal: Double;
begin
  Result := TMVTValue.Null;
  Decoder := TPBFDecoder.Create(AData);
  try
    while Decoder.ReadTag(Field, Wire) do
    begin
      case Field of
        1: Result := TMVTValue.FromString(Decoder.ReadString);        // string_value
        2: begin                                                      // float_value
             U32 := Decoder.ReadFixed32;
             SingleVal := PSingle(@U32)^;
             Result := TMVTValue.FromDouble(SingleVal);
           end;
        3: begin                                                      // double_value
             U64 := Decoder.ReadFixed64;
             DoubleVal := PDouble(@U64)^;
             Result := TMVTValue.FromDouble(DoubleVal);
           end;
        4: Result := TMVTValue.FromInt(Int64(Decoder.ReadVarint));    // int_value
        5: Result := TMVTValue.FromUInt(Decoder.ReadVarint);          // uint_value
        6: Result := TMVTValue.FromInt(Decoder.ReadSignedVarint);     // sint_value
        7: Result := TMVTValue.FromBool(Decoder.ReadVarint <> 0);     // bool_value
      else
        Decoder.SkipField(Wire);
      end;
    end;
  finally
    Decoder.Free;
  end;
end;

procedure TMVTTileParser.ParseFeature(const AData: TBytes; ALayer: TMVTLayer;
  const AKeys: TArray<string>; const AValues: TArray<TMVTValue>);
var
  Decoder: TPBFDecoder;
  Field: Integer;
  Wire: TPBFWireType;
  ID: UInt64;
  GeomType: Integer;
  Tags: TArray<UInt64>;
  Commands: TArray<UInt64>;
  Feature: TMVTFeature;
  PbfGeomType: TPBFGeometryType;
  I, KeyIdx, ValIdx: Integer;
begin
  ID := 0;
  GeomType := GEOM_UNKNOWN;
  Tags := nil;
  Commands := nil;

  Decoder := TPBFDecoder.Create(AData);
  try
    while Decoder.ReadTag(Field, Wire) do
    begin
      case Field of
        1: ID := Decoder.ReadVarint;                  // id
        2: Tags := Decoder.ReadPackedVarint;          // tags (packed)
        3: GeomType := Integer(Decoder.ReadVarint);   // type
        4: Commands := Decoder.ReadPackedVarint;      // geometry (packed)
      else
        Decoder.SkipField(Wire);
      end;
    end;
  finally
    Decoder.Free;
  end;

  case GeomType of
    GEOM_POINT:      PbfGeomType := gtPoint;
    GEOM_LINESTRING: PbfGeomType := gtLineString;
    GEOM_POLYGON:    PbfGeomType := gtPolygon;
  else
    PbfGeomType := gtUnknown;
  end;

  Feature := TMVTFeature.Create;
  try
    Feature.ID := ID;
    Feature.Geometry := TMVTGeometry.Create(PbfGeomType);

    // Decode tags into typed properties (pairs of key/value indices)
    I := 0;
    while I + 1 < Length(Tags) do
    begin
      KeyIdx := Integer(Tags[I]);
      ValIdx := Integer(Tags[I + 1]);
      if (KeyIdx >= 0) and (KeyIdx < Length(AKeys)) and
         (ValIdx >= 0) and (ValIdx < Length(AValues)) then
        Feature.SetProp(AKeys[KeyIdx], AValues[ValIdx]);
      Inc(I, 2);
    end;

    DecodeGeometry(Commands, PbfGeomType, Feature.Geometry);
    if PbfGeomType = gtPolygon then
      ClassifyRings(Feature.Geometry);

    ALayer.AddFeature(Feature);
    Feature := nil;
  finally
    Feature.Free;  // only runs if an exception occurred before AddFeature
  end;
end;

procedure TMVTTileParser.DecodeGeometry(const ACommands: TArray<UInt64>;
  AType: TPBFGeometryType; AGeometry: TMVTGeometry);
var
  I, Count, CmdId, J: Integer;
  CmdInt: UInt64;
  CX, CY: Int64;
  Current: TList<TPBFPoint>;
  Part: TMVTPart;

  procedure FlushPart;
  begin
    if Assigned(Current) and (Current.Count > 0) then
    begin
      Part := Default(TMVTPart);
      Part.Points := Current.ToArray;
      AGeometry.AddPart(Part);
    end;
    Current.Clear;
  end;

begin
  CX := 0;
  CY := 0;
  I := 0;
  Current := TList<TPBFPoint>.Create;
  try
    while I < Length(ACommands) do
    begin
      CmdInt := ACommands[I];
      Inc(I);
      CmdId := Integer(CmdInt and 7);
      Count := Integer(CmdInt shr 3);

      case CmdId of
        CMD_MOVE_TO:
          begin
            for J := 0 to Count - 1 do
            begin
              if I + 1 >= Length(ACommands) then
                Break;
              Inc(CX, ZigZag(ACommands[I]));
              Inc(CY, ZigZag(ACommands[I + 1]));
              Inc(I, 2);

              // For points, accumulate in a single part; for lines/polygons a
              // MoveTo starts a new part/ring.
              if AType = gtPoint then
                Current.Add(TPBFPoint.Create(Integer(CX), Integer(CY)))
              else
              begin
                FlushPart;
                Current.Add(TPBFPoint.Create(Integer(CX), Integer(CY)));
              end;
            end;
          end;

        CMD_LINE_TO:
          begin
            for J := 0 to Count - 1 do
            begin
              if I + 1 >= Length(ACommands) then
                Break;
              Inc(CX, ZigZag(ACommands[I]));
              Inc(CY, ZigZag(ACommands[I + 1]));
              Inc(I, 2);
              Current.Add(TPBFPoint.Create(Integer(CX), Integer(CY)));
            end;
          end;

        CMD_CLOSE_PATH:
          begin
            // Close current ring (polygons). No parameters, no point dup.
            FlushPart;
          end;
      else
        Break;  // unknown command - stop to avoid runaway
      end;
    end;

    FlushPart;
  finally
    Current.Free;
  end;
end;

procedure TMVTTileParser.ClassifyRings(AGeometry: TMVTGeometry);
var
  I: Integer;
  Part: TMVTPart;
  Area, FirstSign: Double;
begin
  FirstSign := 0;
  for I := 0 to AGeometry.Parts.Count - 1 do
  begin
    Part := AGeometry.Parts[I];
    Area := ShoelaceArea(Part.Points);
    Part.SignedArea := Area;

    if SameValue(Area, 0) then
      Part.Role := rrUnknown
    else
    begin
      if FirstSign = 0 then
      begin
        FirstSign := Area;
        Part.Role := rrExterior;
      end
      else if (Area > 0) = (FirstSign > 0) then
        Part.Role := rrExterior   // same winding as first -> new exterior
      else
        Part.Role := rrInterior;  // opposite winding -> hole
    end;

    AGeometry.Parts[I] := Part;
  end;
end;

end.
