unit PBFMap.Decoder;

{
  PBFMapRenderer - Protocol Buffer decoder
  
  Lightweight Protocol Buffers decoder for PBF tiles. 
  Supports varint, zigzag encoding, and basic wire types.
  
  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System. SysUtils, System.Classes,
  PBFMap.Types;

type
  /// <summary>Protocol Buffer wire types</summary>
  TPBFWireType = (
    wtVarint = 0,           // int32, int64, uint32, uint64, sint32, sint64, bool, enum
    wt64Bit = 1,            // fixed64, sfixed64, double
    wtLengthDelimited = 2,  // string, bytes, embedded messages, packed repeated fields
    wtStartGroup = 3,       // deprecated (not supported)
    wtEndGroup = 4,         // deprecated (not supported)
    wt32Bit = 5             // fixed32, sfixed32, float
  );

  /// <summary>Protocol Buffer decoder for PBF tile data</summary>
  TPBFDecoder = class
  private
    FData: TBytes;
    FPosition: Integer;
    function GetRemaining: Integer;
    function GetDataSize: Integer;
  public
    /// <summary>Create decoder with byte data</summary>
    /// <param name="AData">Raw PBF data</param>
    constructor Create(const AData: TBytes);
    
    /// <summary>Check if there's more data to read</summary>
    function HasMore: Boolean;
    
    /// <summary>Read variable-length integer (varint)</summary>
    /// <returns>Unsigned 64-bit integer</returns>
    function ReadVarint: UInt64;
    
    /// <summary>Read signed varint with ZigZag decoding</summary>
    /// <returns>Signed 64-bit integer</returns>
    function ReadSignedVarint: Int64;
    
    /// <summary>Read 32-bit fixed value (little-endian)</summary>
    function ReadFixed32: UInt32;
    
    /// <summary>Read 64-bit fixed value (little-endian)</summary>
    function ReadFixed64: UInt64;
    
    /// <summary>Read length-delimited byte array</summary>
    /// <returns>Byte array</returns>
    function ReadBytes: TBytes;
    
    /// <summary>Read string (length-delimited UTF-8)</summary>
    function ReadString: string;
    
    /// <summary>Read field tag (field number + wire type)</summary>
    /// <param name="AFieldNumber">Output: field number</param>
    /// <param name="AWireType">Output: wire type</param>
    /// <returns>True if tag was read, False if end of data</returns>
    function ReadTag(out AFieldNumber: Integer; out AWireType: TPBFWireType): Boolean;
    
    /// <summary>Skip field data based on wire type</summary>
    /// <param name="AWireType">Wire type to skip</param>
    procedure SkipField(AWireType: TPBFWireType);
    
    /// <summary>Read packed repeated varint array</summary>
    function ReadPackedVarint: TArray<UInt64>;
    
    /// <summary>Read packed repeated signed varint array (ZigZag)</summary>
    function ReadPackedSignedVarint: TArray<Int64>;
    
    /// <summary>Current position in data buffer</summary>
    property Position: Integer read FPosition write FPosition;
    
    /// <summary>Remaining bytes to read</summary>
    property Remaining: Integer read GetRemaining;
    
    /// <summary>Total data size</summary>
    property DataSize: Integer read GetDataSize;
  end;

implementation

{ TPBFDecoder }

constructor TPBFDecoder.Create(const AData: TBytes);
begin
  inherited Create;
  FData := AData;
  FPosition := 0;
end;

function TPBFDecoder.GetRemaining: Integer;
begin
  Result := Length(FData) - FPosition;
end;

function TPBFDecoder.GetDataSize: Integer;
begin
  Result := Length(FData);
end;

function TPBFDecoder.HasMore: Boolean;
begin
  Result := FPosition < Length(FData);
end;

function TPBFDecoder.ReadVarint: UInt64;
var
  B: Byte;
  Shift: Integer;
begin
  Result := 0;
  Shift := 0;
  
  repeat
    if FPosition >= Length(FData) then
      raise EPBFDecoderError. Create('Unexpected end of data while reading varint');
      
    B := FData[FPosition];
    Inc(FPosition);
    
    // Take lower 7 bits and shift into position
    Result := Result or (UInt64(B and $7F) shl Shift);
    Inc(Shift, 7);
    
    if Shift > 63 then
      raise EPBFDecoderError.Create('Varint is too long (> 64 bits)');
      
  until (B and $80) = 0;  // Continue while MSB is set
end;

function TPBFDecoder.ReadSignedVarint: Int64;
var
  Value: UInt64;
begin
  Value := ReadVarint;
  // ZigZag decoding: (n >>> 1) XOR (-(n & 1))
  // Converts: 0,1,2,3,4...  to 0,-1,1,-2,2... 
  Result := Int64(Value shr 1) xor (-Int64(Value and 1));
end;

function TPBFDecoder.ReadFixed32: UInt32;
begin
  if Remaining < 4 then
    raise EPBFDecoderError.Create('Unexpected end of data while reading fixed32');
    
  Result := PUInt32(@FData[FPosition])^;
  Inc(FPosition, 4);
end;

function TPBFDecoder.ReadFixed64: UInt64;
begin
  if Remaining < 8 then
    raise EPBFDecoderError.Create('Unexpected end of data while reading fixed64');
    
  Result := PUInt64(@FData[FPosition])^;
  Inc(FPosition, 8);
end;

function TPBFDecoder.ReadBytes: TBytes;
var
  Len: Integer;
begin
  Len := Integer(ReadVarint);
  
  if Len < 0 then
    raise EPBFDecoderError.Create('Invalid byte array length (negative)');
    
  if Remaining < Len then
    raise EPBFDecoderError.CreateFmt('Unexpected end of data while reading bytes (need %d, have %d)', 
      [Len, Remaining]);
    
  SetLength(Result, Len);
  if Len > 0 then
  begin
    Move(FData[FPosition], Result[0], Len);
    Inc(FPosition, Len);
  end;
end;

function TPBFDecoder.ReadString: string;
var
  Bytes: TBytes;
begin
  Bytes := ReadBytes;
  if Length(Bytes) > 0 then
    Result := TEncoding.UTF8.GetString(Bytes)
  else
    Result := '';
end;

function TPBFDecoder.ReadTag(out AFieldNumber: Integer; out AWireType: TPBFWireType): Boolean;
var
  Tag: UInt64;
  WireTypeValue: Integer;
begin
  Result := HasMore;
  if not Result then
  begin
    AFieldNumber := 0;
    AWireType := wtVarint;
    Exit;
  end;
    
  Tag := ReadVarint;
  
  // Tag = (field_number << 3) | wire_type
  AFieldNumber := Integer(Tag shr 3);
  WireTypeValue := Integer(Tag and 7);
  
  if (WireTypeValue < 0) or (WireTypeValue > 5) then
    raise EPBFDecoderError.CreateFmt('Invalid wire type: %d', [WireTypeValue]);
    
  AWireType := TPBFWireType(WireTypeValue);
end;

procedure TPBFDecoder.SkipField(AWireType: TPBFWireType);
var
  Len: Integer;
begin
  case AWireType of
    wtVarint:
      ReadVarint;  // Read and discard
      
    wt64Bit:
      begin
        if Remaining < 8 then
          raise EPBFDecoderError.Create('Unexpected end of data while skipping 64-bit field');
        Inc(FPosition, 8);
      end;
      
    wtLengthDelimited:
      begin
        Len := Integer(ReadVarint);
        if Remaining < Len then
          raise EPBFDecoderError.Create('Unexpected end of data while skipping length-delimited field');
        Inc(FPosition, Len);
      end;
      
    wt32Bit:
      begin
        if Remaining < 4 then
          raise EPBFDecoderError.Create('Unexpected end of data while skipping 32-bit field');
        Inc(FPosition, 4);
      end;
      
    wtStartGroup, wtEndGroup:
      raise EPBFDecoderError. Create('Group wire types are deprecated and not supported');
  else
    raise EPBFDecoderError.CreateFmt('Unknown wire type: %d', [Ord(AWireType)]);
  end;
end;

function TPBFDecoder.ReadPackedVarint: TArray<UInt64>;
var
  Data: TBytes;
  SubDecoder: TPBFDecoder;
  List: TArray<UInt64>;
  Count: Integer;
begin
  Data := ReadBytes;
  SubDecoder := TPBFDecoder. Create(Data);
  try
    SetLength(List, 16);  // Initial capacity
    Count := 0;
    
    while SubDecoder.HasMore do
    begin
      if Count >= Length(List) then
        SetLength(List, Length(List) * 2);  // Grow array
        
      List[Count] := SubDecoder.ReadVarint;
      Inc(Count);
    end;
    
    SetLength(List, Count);  // Trim to actual size
    Result := List;
  finally
    SubDecoder.Free;
  end;
end;

function TPBFDecoder.ReadPackedSignedVarint: TArray<Int64>;
var
  Data: TBytes;
  SubDecoder: TPBFDecoder;
  List: TArray<Int64>;
  Count: Integer;
begin
  Data := ReadBytes;
  SubDecoder := TPBFDecoder.Create(Data);
  try
    SetLength(List, 16);  // Initial capacity
    Count := 0;
    
    while SubDecoder.HasMore do
    begin
      if Count >= Length(List) then
        SetLength(List, Length(List) * 2);  // Grow array
        
      List[Count] := SubDecoder.ReadSignedVarint;
      Inc(Count);
    end;
    
    SetLength(List, Count);  // Trim to actual size
    Result := List;
  finally
    SubDecoder.Free;
  end;
end;

end.