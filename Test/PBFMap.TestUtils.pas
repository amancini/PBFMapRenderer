unit PBFMap.TestUtils;

{
  PBFMapRenderer - Test helpers

  A minimal protobuf writer and a TMVTTileBuilder that hand-encodes synthetic
  vector tiles (vector_tile.proto) for parser/renderer tests, plus a gzip
  helper for the compression tests.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Classes, System.ZLib, System.Generics.Collections;

type
  /// <summary>Lightweight protobuf encoder</summary>
  TPBWriter = class
  private
    FStream: TBytesStream;
  public
    constructor Create;
    destructor Destroy; override;

    procedure WriteVarint(V: UInt64);
    procedure WriteTag(AField: Integer; AWireType: Integer);
    procedure WriteVarintField(AField: Integer; V: UInt64);
    procedure WriteStringField(AField: Integer; const S: string);
    procedure WriteBytesField(AField: Integer; const B: TBytes);
    procedure WritePackedVarints(AField: Integer; const Vals: TArray<UInt64>);

    function ToBytes: TBytes;
  end;

  /// <summary>Encode a MoveTo/LineTo/ClosePath geometry command stream</summary>
  TGeomBuilder = class
  private
    FCmds: TList<UInt64>;
    FCX, FCY: Int64;
    function ZZ(V: Int64): UInt64;
  public
    constructor Create;
    destructor Destroy; override;
    procedure MoveTo(X, Y: Integer);
    procedure LineTo(X, Y: Integer);   // absolute coords; deltas computed
    procedure ClosePath;
    function Commands: TArray<UInt64>;
  end;

/// <summary>gzip-compress bytes (for compression tests)</summary>
function GzipBytes(const AData: TBytes): TBytes;

implementation

{ TPBWriter }

constructor TPBWriter.Create;
begin
  inherited Create;
  FStream := TBytesStream.Create;
end;

destructor TPBWriter.Destroy;
begin
  FStream.Free;
  inherited;
end;

procedure TPBWriter.WriteVarint(V: UInt64);
var
  B: Byte;
begin
  repeat
    B := V and $7F;
    V := V shr 7;
    if V <> 0 then
      B := B or $80;
    FStream.Write(B, 1);
  until V = 0;
end;

procedure TPBWriter.WriteTag(AField: Integer; AWireType: Integer);
begin
  WriteVarint((UInt64(AField) shl 3) or UInt64(AWireType));
end;

procedure TPBWriter.WriteVarintField(AField: Integer; V: UInt64);
begin
  WriteTag(AField, 0);
  WriteVarint(V);
end;

procedure TPBWriter.WriteStringField(AField: Integer; const S: string);
begin
  WriteBytesField(AField, TEncoding.UTF8.GetBytes(S));
end;

procedure TPBWriter.WriteBytesField(AField: Integer; const B: TBytes);
begin
  WriteTag(AField, 2);
  WriteVarint(Length(B));
  if Length(B) > 0 then
    FStream.Write(B[0], Length(B));
end;

procedure TPBWriter.WritePackedVarints(AField: Integer; const Vals: TArray<UInt64>);
var
  Inner: TPBWriter;
  V: UInt64;
begin
  Inner := TPBWriter.Create;
  try
    for V in Vals do
      Inner.WriteVarint(V);
    WriteBytesField(AField, Inner.ToBytes);
  finally
    Inner.Free;
  end;
end;

function TPBWriter.ToBytes: TBytes;
begin
  Result := Copy(FStream.Bytes, 0, FStream.Size);
end;

{ TGeomBuilder }

constructor TGeomBuilder.Create;
begin
  inherited Create;
  FCmds := TList<UInt64>.Create;
end;

destructor TGeomBuilder.Destroy;
begin
  FCmds.Free;
  inherited;
end;

function TGeomBuilder.ZZ(V: Int64): UInt64;
begin
  // standard protobuf zigzag encode (Delphi 'shr' is logical, so branch)
  if V >= 0 then
    Result := UInt64(V) shl 1
  else
    Result := (UInt64(-V) shl 1) - 1;
end;

procedure TGeomBuilder.MoveTo(X, Y: Integer);
begin
  FCmds.Add((UInt64(1) shl 3) or 1);  // MoveTo, count 1
  FCmds.Add(ZZ(X - FCX));
  FCmds.Add(ZZ(Y - FCY));
  FCX := X;
  FCY := Y;
end;

procedure TGeomBuilder.LineTo(X, Y: Integer);
begin
  // single LineTo with count 1 (tests don't need run-length packing)
  FCmds.Add((UInt64(1) shl 3) or 2);  // LineTo, count 1
  FCmds.Add(ZZ(X - FCX));
  FCmds.Add(ZZ(Y - FCY));
  FCX := X;
  FCY := Y;
end;

procedure TGeomBuilder.ClosePath;
begin
  FCmds.Add((UInt64(1) shl 3) or 7);  // ClosePath, count 1
end;

function TGeomBuilder.Commands: TArray<UInt64>;
begin
  Result := FCmds.ToArray;
end;

{ gzip }

function GzipBytes(const AData: TBytes): TBytes;
var
  Dest: TBytesStream;
  Comp: TZCompressionStream;
begin
  Dest := TBytesStream.Create;
  try
    Comp := TZCompressionStream.Create(Dest, zcDefault, 15 + 16);
    try
      if Length(AData) > 0 then
        Comp.Write(AData[0], Length(AData));
    finally
      Comp.Free;  // flushes
    end;
    Result := Copy(Dest.Bytes, 0, Dest.Size);
  finally
    Dest.Free;
  end;
end;

end.
