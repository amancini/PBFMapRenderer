unit PBFMap.Collision;

{
  PBFMapRenderer - Spatial collision index for label/icon placement

  A uniform grid (spatial hash) of axis-aligned boxes. Placement tests only the
  cells a candidate touches instead of every placed box, so symbol placement
  scales to busy tiles. This is the renderer-side equivalent of MapLibre's
  CollisionIndex (simplified to AABBs, single tile / viewport).

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.Types, System.Math, System.Generics.Collections,
  PBFMap.Profile;

type
  /// <summary>Uniform-grid index of axis-aligned collision boxes</summary>
  TGridIndex = class
  private
    FCell: Integer;
    FGrid: TObjectDictionary<Int64, TList<TRect>>;
    function CellKey(ACX, ACY: Integer): Int64;
    procedure CellSpan(const ARect: TRect; out AX0, AY0, AX1, AY1: Integer);
    function BoxCollides(const ARect: TRect): Boolean;
  public
    constructor Create(ACellSize: Integer = 64);
    destructor Destroy; override;

    /// <summary>Drop all placed boxes (call once per render).</summary>
    procedure Clear;
    /// <summary>True if none of ABoxes intersects an already-placed box.</summary>
    function CanPlace(const ABoxes: TArray<TRect>): Boolean;
    /// <summary>Record ABoxes as occupied.</summary>
    procedure Insert(const ABoxes: TArray<TRect>);
  end;

implementation

function FloorDiv(A, B: Integer): Integer;
begin
  Result := Floor(A / B);
end;

{ TGridIndex }

constructor TGridIndex.Create(ACellSize: Integer);
begin
  inherited Create;
  if ACellSize < 1 then
    ACellSize := 1;
  FCell := ACellSize;
  FGrid := TObjectDictionary<Int64, TList<TRect>>.Create([doOwnsValues]);
end;

destructor TGridIndex.Destroy;
begin
  FGrid.Free;
  inherited;
end;

procedure TGridIndex.Clear;
begin
  FGrid.Clear;
end;

function TGridIndex.CellKey(ACX, ACY: Integer): Int64;
begin
  // pack two 32-bit cell coords into one key
  Result := (Int64(ACX) shl 32) or Int64(Cardinal(ACY));
end;

procedure TGridIndex.CellSpan(const ARect: TRect; out AX0, AY0, AX1, AY1: Integer);
begin
  AX0 := FloorDiv(ARect.Left, FCell);
  AY0 := FloorDiv(ARect.Top, FCell);
  AX1 := FloorDiv(ARect.Right, FCell);
  AY1 := FloorDiv(ARect.Bottom, FCell);
end;

function TGridIndex.BoxCollides(const ARect: TRect): Boolean;
var
  X0, Y0, X1, Y1, CX, CY: Integer;
  List: TList<TRect>;
  Other: TRect;
begin
  Result := False;
  CellSpan(ARect, X0, Y0, X1, Y1);
  for CY := Y0 to Y1 do
    for CX := X0 to X1 do
      if FGrid.TryGetValue(CellKey(CX, CY), List) then
        for Other in List do
          if Other.IntersectsWith(ARect) then
            Exit(True);
end;

function TGridIndex.CanPlace(const ABoxes: TArray<TRect>): Boolean;
var
  Box: TRect;
  LP: IProfScope;
begin
  LP := ProfScope('Collision.CanPlace');
  for Box in ABoxes do
    if BoxCollides(Box) then
      Exit(False);
  Result := True;
end;

procedure TGridIndex.Insert(const ABoxes: TArray<TRect>);
var
  Box: TRect;
  X0, Y0, X1, Y1, CX, CY: Integer;
  Key: Int64;
  List: TList<TRect>;
  LP: IProfScope;
begin
  LP := ProfScope('Collision.Insert');
  for Box in ABoxes do
  begin
    CellSpan(Box, X0, Y0, X1, Y1);
    for CY := Y0 to Y1 do
      for CX := X0 to X1 do
      begin
        Key := CellKey(CX, CY);
        if not FGrid.TryGetValue(Key, List) then
        begin
          List := TList<TRect>.Create;
          FGrid.Add(Key, List);
        end;
        List.Add(Box);
      end;
  end;
end;

end.
