unit PBFMap.Types;

{
  PBFMapRenderer - Common types and constants
  
  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils;

type
  /// <summary>Tile coordinate in zoom/x/y format</summary>
  TPBFTileCoord = record
    Zoom: Integer;
    X: Integer;
    Y: Integer;
    constructor Create(AZoom, AX, AY: Integer);
    function ToString: string;
  end;

  /// <summary>Geometry type enumeration</summary>
  TPBFGeometryType = (
    gtUnknown,      // Unknown or unsupported geometry
    gtPoint,        // Point geometry
    gtLineString,   // Line string (polyline)
    gtPolygon       // Polygon
  );

  /// <summary>Base exception for PBFMapRenderer</summary>
  EPBFMapError = class(Exception);
  
  /// <summary>MBTiles specific exception</summary>
  EPBFMBTilesError = class(EPBFMapError);
  
  /// <summary>PBF decoder exception</summary>
  EPBFDecoderError = class(EPBFMapError);
  
  /// <summary>Rendering exception</summary>
  EPBFRendererError = class(EPBFMapError);

  /// <summary>MVT vector tile parsing exception</summary>
  EMVTParseError = class(EPBFMapError);

  /// <summary>Mapbox GL style parsing exception</summary>
  EMGLStyleError = class(EPBFMapError);

  /// <summary>Mapbox GL expression parsing/evaluation exception</summary>
  EMGLExpressionError = class(EPBFMapError);

const
  /// <summary>Standard tile extent in PBF format (default: 4096)</summary>
  PBF_TILE_EXTENT = 4096;
  
  /// <summary>Default tile size in pixels</summary>
  PBF_DEFAULT_TILE_SIZE = 256;

implementation

{ TPBFTileCoord }

constructor TPBFTileCoord.Create(AZoom, AX, AY: Integer);
begin
  Zoom := AZoom;
  X := AX;
  Y := AY;
end;

function TPBFTileCoord.ToString: string;
begin
  Result := Format('%d/%d/%d', [Zoom, X, Y]);
end;

end.