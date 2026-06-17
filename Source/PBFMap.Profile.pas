unit PBFMap.Profile;

{
  PBFMapRenderer - exhaustive per-function profiler

  A global, opt-in scope timer used to measure EVERY instrumented function across
  all units (not just the renderer). Usage at the top of a function:

      var LP := ProfScope('PBFMap.MVT.Parser.DecodeGeometry'); // one line

  The returned IProfScope records the elapsed ticks in its destructor (i.e. at
  function exit). When profiling is OFF (GProfEnabled = False, the default),
  ProfScope returns nil immediately: no allocation, no timestamp, just a single
  boolean test — so instrumentation left in shipping code costs ~nothing.

  Aggregation is per name: call count + total ticks. ProfReport renders the full
  table sorted by total time. Not thread-safe (the engine is single-threaded;
  parallel hosts use one engine/instance per thread and profile one at a time).

  MIT License
  Copyright (c) 2025 amancini
}

interface

type
  IProfScope = interface
    ['{6E0B6F2A-7C41-4E2E-9E2B-2B7E0F1A9C55}']
  end;

var
  { Master switch. Off by default -> ProfScope is a no-op (near-zero overhead). }
  GProfEnabled: Boolean = False;

{ Returns a scope object that times until it goes out of scope, or nil when
  profiling is disabled. }
function ProfScope(const AName: string): IProfScope;

{ Clears all accumulated counters. }
procedure ProfReset;

{ Full table sorted by total ms desc: name, calls, total ms, ms/call, % of the
  largest. ATopN <= 0 = all. }
function ProfReport(ATopN: Integer = 0): string;

implementation

uses
  System.SysUtils, System.Diagnostics, System.Classes, System.Math,
  System.Generics.Collections, System.Generics.Defaults;

type
  TProfRec = record
    Calls: Int64;
    Ticks: Int64;
  end;

  TProfScope = class(TInterfacedObject, IProfScope)
  private
    FName: string;
    FStart: Int64;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
  end;

var
  GMap: TDictionary<string, TProfRec>;

function ProfScope(const AName: string): IProfScope;
begin
  if GProfEnabled then
    Result := TProfScope.Create(AName)
  else
    Result := nil;
end;

procedure ProfReset;
begin
  if Assigned(GMap) then
    GMap.Clear;
end;

{ TProfScope }

constructor TProfScope.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FStart := TStopwatch.GetTimeStamp;
end;

destructor TProfScope.Destroy;
var
  R: TProfRec;
  Elapsed: Int64;
begin
  Elapsed := TStopwatch.GetTimeStamp - FStart;
  if Assigned(GMap) then
  begin
    if not GMap.TryGetValue(FName, R) then
    begin
      R.Calls := 0;
      R.Ticks := 0;
    end;
    Inc(R.Calls);
    Inc(R.Ticks, Elapsed);
    GMap.AddOrSetValue(FName, R);
  end;
  inherited;
end;

function ProfReport(ATopN: Integer): string;
var
  Pair: TPair<string, TProfRec>;
  Items: TList<TPair<string, TProfRec>>;
  SB: TStringBuilder;
  Freq, MaxMs, Ms: Double;
  I, N: Integer;
begin
  if not Assigned(GMap) or (GMap.Count = 0) then
    Exit('(no profile data)');
  Freq := TStopwatch.Frequency;
  Items := TList<TPair<string, TProfRec>>.Create;
  SB := TStringBuilder.Create;
  try
    for Pair in GMap do
      Items.Add(Pair);
    Items.Sort(TComparer<TPair<string, TProfRec>>.Construct(
      function(const L, R: TPair<string, TProfRec>): Integer
      begin
        Result := CompareValue(R.Value.Ticks, L.Value.Ticks);  // desc
      end));
    MaxMs := Items[0].Value.Ticks / Freq * 1000;
    if MaxMs <= 0 then MaxMs := 1;

    SB.AppendLine(Format('%-44s %10s %12s %10s %7s',
      ['function', 'calls', 'total ms', 'ms/call', '%max']));
    SB.AppendLine(StringOfChar('-', 88));
    N := Items.Count;
    if (ATopN > 0) and (ATopN < N) then
      N := ATopN;
    for I := 0 to N - 1 do
    begin
      Ms := Items[I].Value.Ticks / Freq * 1000;
      SB.AppendLine(Format('%-44s %10d %12.1f %10.4f %6.1f%%',
        [Items[I].Key, Items[I].Value.Calls, Ms,
         Ms / Max(1, Items[I].Value.Calls), Ms / MaxMs * 100]));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
    Items.Free;
  end;
end;

initialization
  GMap := TDictionary<string, TProfRec>.Create;

finalization
  GMap.Free;

end.
