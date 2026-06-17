unit PBFMap.Compression;

{
  PBFMapRenderer - Tile data decompression

  MVT/PBF tiles stored in MBTiles are usually gzip-compressed, occasionally
  zlib-compressed, and sometimes stored raw. This unit detects the encoding
  from the leading magic bytes and inflates accordingly.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Classes, System.ZLib,
  PBFMap.Types, PBFMap.Profile;

type
  /// <summary>Detected compression of a tile blob</summary>
  TPBFCompression = (pcNone, pcGzip, pcZlib);

/// <summary>Detect the compression scheme from leading magic bytes</summary>
function DetectCompression(const AData: TBytes): TPBFCompression;

/// <summary>
///   Decompress tile data. Detects gzip (1F 8B), zlib (78 xx) or raw.
///   Returns the decoded PBF bytes. Empty input returns an empty array.
/// </summary>
function DecompressTile(const AData: TBytes): TBytes;

implementation

const
  // zlib WindowBits selectors (see zlib.h):
  //   15      -> zlib (RFC 1950) header
  //   15 + 16 -> gzip (RFC 1952) header
  WINDOWBITS_ZLIB = 15;
  WINDOWBITS_GZIP = 15 + 16;

function DetectCompression(const AData: TBytes): TPBFCompression;
begin
  if Length(AData) < 2 then
    Exit(pcNone);

  // gzip magic
  if (AData[0] = $1F) and (AData[1] = $8B) then
    Exit(pcGzip);

  // zlib magic: first byte $78 (CMF for 32K window, deflate) is the common
  // case; validate the (CMF*256 + FLG) checksum being a multiple of 31.
  if (AData[0] = $78) and (((AData[0] shl 8) or AData[1]) mod 31 = 0) then
    Exit(pcZlib);

  Result := pcNone;
end;

function Inflate(const AData: TBytes; AWindowBits: Integer): TBytes;
var
  Source: TBytesStream;
  Decomp: TZDecompressionStream;
  Dest: TBytesStream;
begin
  Source := TBytesStream.Create(AData);
  try
    Decomp := TZDecompressionStream.Create(Source, AWindowBits);
    try
      Dest := TBytesStream.Create;
      try
        Dest.CopyFrom(Decomp, 0);  // read to end
        Result := Copy(Dest.Bytes, 0, Dest.Size);
      finally
        Dest.Free;
      end;
    finally
      Decomp.Free;
    end;
  finally
    Source.Free;
  end;
end;

function DecompressTile(const AData: TBytes): TBytes;
var
  LProf: IProfScope;
begin
  LProf := ProfScope('Compression.DecompressTile');
  if Length(AData) = 0 then
    Exit(nil);

  try
    case DetectCompression(AData) of
      pcGzip:
        Result := Inflate(AData, WINDOWBITS_GZIP);
      pcZlib:
        Result := Inflate(AData, WINDOWBITS_ZLIB);
    else
      // Raw / already-decoded PBF
      Result := AData;
    end;
  except
    on E: EPBFMapError do
      raise;
    on E: Exception do
      // Wrap low-level zlib (EZDecompressionError) errors into the library
      // exception hierarchy so callers always see an EPBFMapError.
      raise EPBFDecoderError.CreateFmt('Tile decompression failed: %s',
        [E.Message]);
  end;
end;

end.
