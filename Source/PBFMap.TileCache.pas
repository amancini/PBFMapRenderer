unit PBFMap.TileCache;

{
  PBFMapRenderer - Shared decoded-tile cache

  A thread-safe LRU cache of decoded MVT tiles, shared by the worker engines of a
  render pool. Each engine keeps its own (thread-affine) FireDAC connection and
  decodes a tile only on a miss; the PARSED result is shared, so the same data tile
  is not re-decompressed + re-parsed once per engine (and per buffer-ring neighbour).

  A decoded TMVTTile is READ-ONLY during rendering (the renderer keeps every computed
  index in renderer-local state, never on the tile), so several threads may read the
  same tile concurrently. Lifetime is pin-based: Acquire/Add pin a tile for the
  CALLING thread; the engine calls ReleaseThread at the end of each top-level render,
  and eviction never frees a tile that is still pinned by some thread.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  System.Generics.Collections, System.SyncObjs,
  PBFMap.MVT.Types;

type
  /// <summary>
  ///   Thread-safe, pin-based LRU cache of decoded MVT tiles shared across the
  ///   per-thread engines of a render pool. Owns the tiles it stores.
  /// </summary>
  TPBFSharedTileCache = class
  private
    type
      TEntry = class
        Tile : TMVTTile;   // nil = cached no-data marker (avoids re-probing the DB)
        Pins : Integer;    // >0 while some thread is rendering from this tile
        destructor Destroy; override;
      end;
  private
    FLock       : TCriticalSection;
    FItems      : TObjectDictionary<string, TEntry>;   // owns entries (and their tiles)
    FOrder      : TStringList;                          // LRU: index 0 = oldest
    FThreadPins : TObjectDictionary<Cardinal, TStringList>;  // thread id -> keys it pinned
    FCap        : Integer;
    FHits       : Int64;   // Acquire found a shared tile (decode avoided)
    FMisses     : Int64;   // Acquire missed -> caller decoded
    function KeyOf(AZoom, X, Y: Integer): string; inline;
    procedure TouchLocked(const AKey: string);
    procedure PinLocked(const AKey: string; AEntry: TEntry);
    procedure EvictLocked;
  public
    constructor Create(ACapacity: Integer);
    destructor Destroy; override;

    /// <summary>
    ///   If the tile is cached, pin it for the calling thread and return True
    ///   (ATile may be nil = cached no-data). On a miss returns False: the caller
    ///   must decode the tile and hand it to Add.
    /// </summary>
    function Acquire(AZoom, X, Y: Integer; out ATile: TMVTTile): Boolean;

    /// <summary>
    ///   Publish a freshly decoded tile (the cache takes ownership) and pin it for
    ///   the calling thread. If another thread already inserted the same key while
    ///   this thread was decoding, the duplicate ATile is freed and ATile is set to
    ///   the already-cached tile (pinned), so the caller always renders the shared
    ///   instance. ATile may be nil (no-data); it is stored as a no-data marker.
    /// </summary>
    procedure Add(AZoom, X, Y: Integer; var ATile: TMVTTile);

    /// <summary>Release every pin held by the calling thread. Call once at the end
    ///   of each top-level render pass (RenderTile / RenderBlock).</summary>
    procedure ReleaseThread;

    /// <summary>Decode-avoided / total ratio as text (e.g. "1234/1800 (68.6%)").</summary>
    function StatsText: string;

    property Capacity : Integer read FCap;
    property Hits     : Int64 read FHits;
    property Misses   : Int64 read FMisses;
  end;

implementation

{ TPBFSharedTileCache.TEntry }

destructor TPBFSharedTileCache.TEntry.Destroy;
begin
  Tile.Free;  // nil-safe; the entry owns the decoded tile
  inherited;
end;

{ TPBFSharedTileCache }

constructor TPBFSharedTileCache.Create(ACapacity: Integer);
begin
  inherited Create;
  if ACapacity < 1 then
    ACapacity := 1;
  FCap        := ACapacity;
  FLock       := TCriticalSection.Create;
  FItems      := TObjectDictionary<string, TEntry>.Create([doOwnsValues]);
  FOrder      := TStringList.Create;
  FThreadPins := TObjectDictionary<Cardinal, TStringList>.Create([doOwnsValues]);
end;

destructor TPBFSharedTileCache.Destroy;
begin
  // All worker threads must be stopped before the cache is freed.
  FThreadPins.Free;
  FItems.Free;       // frees every entry -> frees every cached tile
  FOrder.Free;
  FLock.Free;
  inherited;
end;

function TPBFSharedTileCache.KeyOf(AZoom, X, Y: Integer): string;
begin
  Result := Format('%d/%d/%d', [AZoom, X, Y]);
end;

procedure TPBFSharedTileCache.TouchLocked(const AKey: string);
var
  LIdx: Integer;
begin
  LIdx := FOrder.IndexOf(AKey);
  if LIdx >= 0 then
    FOrder.Delete(LIdx);
  FOrder.Add(AKey);  // most-recently-used at the back
end;

procedure TPBFSharedTileCache.PinLocked(const AKey: string; AEntry: TEntry);
var
  LList: TStringList;
  LTid : Cardinal;
begin
  Inc(AEntry.Pins);
  LTid := GetCurrentThreadId;
  if not FThreadPins.TryGetValue(LTid, LList) then
  begin
    LList := TStringList.Create;
    FThreadPins.Add(LTid, LList);
  end;
  LList.Add(AKey);  // duplicates allowed: one entry per Acquire/Add
end;

procedure TPBFSharedTileCache.EvictLocked;
var
  I: Integer;
  LKey: string;
  LEntry: TEntry;
begin
  // Drop oldest UNPINNED entries until within capacity. If the oldest entries are
  // all pinned (every thread's working set), eviction is deferred until a later
  // ReleaseThread frees them - the cache just runs slightly over capacity.
  while FOrder.Count > FCap do
  begin
    I := 0;
    while (I < FOrder.Count) do
    begin
      LKey := FOrder[I];
      if FItems.TryGetValue(LKey, LEntry) and (LEntry.Pins = 0) then
      begin
        FOrder.Delete(I);
        FItems.Remove(LKey);  // frees entry + tile
        Break;
      end;
      Inc(I);
    end;
    if I >= FOrder.Count then
      Break;  // nothing evictable right now
  end;
end;

function TPBFSharedTileCache.Acquire(AZoom, X, Y: Integer; out ATile: TMVTTile): Boolean;
var
  LKey: string;
  LEntry: TEntry;
begin
  ATile := nil;
  LKey  := KeyOf(AZoom, X, Y);
  FLock.Enter;
  try
    Result := FItems.TryGetValue(LKey, LEntry);
    if Result then
    begin
      ATile := LEntry.Tile;
      TouchLocked(LKey);
      PinLocked(LKey, LEntry);
      Inc(FHits);
    end
    else
      Inc(FMisses);
  finally
    FLock.Leave;
  end;
end;

procedure TPBFSharedTileCache.Add(AZoom, X, Y: Integer; var ATile: TMVTTile);
var
  LKey: string;
  LEntry: TEntry;
begin
  LKey := KeyOf(AZoom, X, Y);
  FLock.Enter;
  try
    if FItems.TryGetValue(LKey, LEntry) then
    begin
      // Another thread won the race: keep the shared instance, drop the duplicate.
      if (ATile <> nil) and (ATile <> LEntry.Tile) then
        FreeAndNil(ATile);
      ATile := LEntry.Tile;
      TouchLocked(LKey);
      PinLocked(LKey, LEntry);
      Exit;
    end;
    LEntry := TEntry.Create;
    LEntry.Tile := ATile;   // cache takes ownership (may be nil = no-data marker)
    LEntry.Pins := 0;
    FItems.Add(LKey, LEntry);
    FOrder.Add(LKey);
    PinLocked(LKey, LEntry);
    EvictLocked;
  finally
    FLock.Leave;
  end;
end;

function TPBFSharedTileCache.StatsText: string;
var
  LTotal: Int64;
begin
  FLock.Enter;
  try
    LTotal := FHits + FMisses;
    if LTotal = 0 then
      Result := '0/0 (n/a)'
    else
      Result := Format('%d/%d (%.1f%%)', [FHits, LTotal, FHits * 100.0 / LTotal]);
  finally
    FLock.Leave;
  end;
end;

procedure TPBFSharedTileCache.ReleaseThread;
var
  LList: TStringList;
  LTid : Cardinal;
  I: Integer;
  LEntry: TEntry;
begin
  LTid := GetCurrentThreadId;
  FLock.Enter;
  try
    if not FThreadPins.TryGetValue(LTid, LList) then
      Exit;
    for I := 0 to LList.Count - 1 do
      if FItems.TryGetValue(LList[I], LEntry) and (LEntry.Pins > 0) then
        Dec(LEntry.Pins);
    LList.Clear;
    EvictLocked;  // entries this thread just unpinned may now be evictable
  finally
    FLock.Leave;
  end;
end;

end.
