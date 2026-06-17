unit PBFMap.Renderer;

{
  PBFMapRenderer - Canvas renderer
  
  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  Vcl.Graphics,
  PBFMap.Types, PBFMap.Geometry;

type
  /// <summary>Rendering style options</summary>
  TPBFRenderStyle = record
    PointColor: TColor;
    PointSize: Integer;
    LineColor: TColor;
    LineWidth: Integer;
    PolygonFillColor: TColor;
    PolygonBorderColor: TColor;
    PolygonBorderWidth: Integer;
    BackgroundColor: TColor;
    
    class function Default: TPBFRenderStyle; static;
  end;

  /// <summary>PBF tile renderer for TCanvas</summary>
  TPBFRenderer = class
  private
    FCanvas: TCanvas;
    FTileSize: Integer;
    FExtent: Integer;
    FStyle: TPBFRenderStyle;
  public
    constructor Create(ACanvas: TCanvas; ATileSize: Integer = PBF_DEFAULT_TILE_SIZE);
    
    /// <summary>Convert tile coordinate to pixel coordinate</summary>
    /// <param name="APoint">Point in tile coordinate space (0.. Extent)</param>
    /// <returns>Point in pixel coordinate space (0..TileSize)</returns>
    function TileToPixel(const APoint: TPBFPoint): TPoint;
    
    /// <summary>Render single geometry</summary>
    procedure RenderGeometry(AGeometry: TPBFGeometry);
    
    /// <summary>Render complete feature</summary>
    procedure RenderFeature(AFeature: TPBFFeature);
    
    /// <summary>Render complete layer</summary>
    procedure RenderLayer(ALayer: TPBFLayer);
    
    /// <summary>Clear canvas with background color</summary>
    procedure Clear;
    
    /// <summary>Target canvas for rendering</summary>
    property Canvas: TCanvas read FCanvas write FCanvas;
    
    /// <summary>Output tile size in pixels</summary>
    property TileSize: Integer read FTileSize write FTileSize;
    
    /// <summary>Tile extent (coordinate space, usually 4096)</summary>
    property Extent: Integer read FExtent write FExtent;
    
    /// <summary>Rendering style</summary>
    property Style: TPBFRenderStyle read FStyle write FStyle;
  end;

implementation

{ TPBFRenderStyle }

class function TPBFRenderStyle.Default: TPBFRenderStyle;
begin
  Result. PointColor := clRed;
  Result.PointSize := 3;
  Result.LineColor := clBlue;
  Result.LineWidth := 2;
  Result.PolygonFillColor := clLtGray;
  Result. PolygonBorderColor := clBlack;
  Result. PolygonBorderWidth := 1;
  Result.BackgroundColor := clWhite;
end;

{ TPBFRenderer }

constructor TPBFRenderer.Create(ACanvas: TCanvas; ATileSize: Integer);
begin
  inherited Create;
  FCanvas := ACanvas;
  FTileSize := ATileSize;
  FExtent := PBF_TILE_EXTENT;
  FStyle := TPBFRenderStyle.Default;
end;

function TPBFRenderer.TileToPixel(const APoint: TPBFPoint): TPoint;
begin
  // Scale from tile extent (e.g., 4096) to pixel size (e.g., 256)
  // Result = (Point * TileSize) / Extent
  Result.X := (APoint.X * FTileSize) div FExtent;
  Result. Y := (APoint.Y * FTileSize) div FExtent;
  
end;

procedure TPBFRenderer.RenderGeometry(AGeometry: TPBFGeometry);
var
  I: Integer;
  Pt: TPoint;
  Points: array of TPoint;
begin
  if not Assigned(FCanvas) then
    raise EPBFRendererError.Create('Canvas is not assigned');
    
  if not Assigned(AGeometry) then
    Exit;
    
  if AGeometry.Count = 0 then
    Exit;
    
  case AGeometry.GeometryType of
    gtPoint:
      begin
        // Render points as small circles
        FCanvas.Pen.Color := FStyle.PointColor;
        FCanvas.Brush.Color := FStyle.PointColor;
        FCanvas. Brush.Style := bsSolid;
        
        for I := 0 to AGeometry.Points.Count - 1 do
        begin
          Pt := TileToPixel(AGeometry.Points[I]);
          FCanvas. Ellipse(
            Pt.X - FStyle.PointSize, 
            Pt.Y - FStyle.PointSize,
            Pt.X + FStyle. PointSize, 
            Pt.Y + FStyle. PointSize
          );
        end;
      end;
      
    gtLineString:
      begin
        // Render line string (polyline)
        FCanvas. Pen.Color := FStyle. LineColor;
        FCanvas. Pen.Width := FStyle.LineWidth;
        FCanvas.Pen.Style := psSolid;
        
        if AGeometry.Points.Count > 0 then
        begin
          Pt := TileToPixel(AGeometry.Points[0]);
          FCanvas.MoveTo(Pt.X, Pt.Y);
          
          for I := 1 to AGeometry.Points.Count - 1 do
          begin
            Pt := TileToPixel(AGeometry.Points[I]);
            FCanvas.LineTo(Pt.X, Pt.Y);
          end;
        end;
      end;
      
    gtPolygon:
      begin
        // Render polygon with fill and border
        FCanvas.Brush.Color := FStyle.PolygonFillColor;
        FCanvas.Brush.Style := bsSolid;
        FCanvas.Pen.Color := FStyle.PolygonBorderColor;
        FCanvas. Pen.Width := FStyle. PolygonBorderWidth;
        FCanvas.Pen.Style := psSolid;
        
        // Convert points to array
        SetLength(Points, AGeometry.Points.Count);
        for I := 0 to AGeometry.Points.Count - 1 do
          Points[I] := TileToPixel(AGeometry.Points[I]);
          
        // Draw polygon
        if Length(Points) > 0 then
          FCanvas.Polygon(Points);
      end;
  end;
end;

procedure TPBFRenderer.RenderFeature(AFeature: TPBFFeature);
begin
  if not Assigned(AFeature) then
    Exit;
    
  if Assigned(AFeature.Geometry) then
    RenderGeometry(AFeature.Geometry);
end;

procedure TPBFRenderer.RenderLayer(ALayer: TPBFLayer);
var
  I: Integer;
begin
  if not Assigned(ALayer) then
    Exit;
    
  // Update extent from layer
  FExtent := ALayer.Extent;
  
  // Render all features
  for I := 0 to ALayer.Features.Count - 1 do
    RenderFeature(ALayer. Features[I]);
end;

procedure TPBFRenderer.Clear;
begin
  if Assigned(FCanvas) then
  begin
    FCanvas. Brush.Color := FStyle.BackgroundColor;
    FCanvas.Brush.Style := bsSolid;
    FCanvas.FillRect(Rect(0, 0, FTileSize, FTileSize));
  end;
end;

end.