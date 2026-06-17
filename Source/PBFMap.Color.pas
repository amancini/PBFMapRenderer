unit PBFMap.Color;

{
  PBFMapRenderer - Color model and CSS/Mapbox color parsing

  TMGLColor stores premultiplyable RGBA as floats (0..1). Parses the color
  syntaxes Mapbox GL accepts: #rgb #rgba #rrggbb #rrggbbaa, rgb()/rgba(),
  hsl()/hsla() and CSS named colors. Converts to a VCL TColor + alpha byte.

  MIT License
  Copyright (c) 2025 amancini
}

interface

uses
  System.SysUtils, System.Math, System.UITypes, System.Generics.Collections;

type
  /// <summary>RGBA color as floats in 0..1</summary>
  TMGLColor = record
    R, G, B, A: Double;

    class function Create(AR, AG, AB: Double; AA: Double = 1.0): TMGLColor; static;
    class function FromRGBA(AR, AG, AB, AA: Byte): TMGLColor; static;
    class function Black: TMGLColor; static;
    class function Transparent: TMGLColor; static;

    /// <summary>VCL color ($00BBGGRR), alpha discarded</summary>
    function ToColor: TColor;
    /// <summary>Alpha as 0..255</summary>
    function AlphaByte: Byte;
    /// <summary>Linear interpolate between Self and Other (t in 0..1)</summary>
    function Lerp(const Other: TMGLColor; T: Double): TMGLColor;
    /// <summary>Canonical "rgba(r,g,b,a)" token (used as expression currency)</summary>
    function ToCanonical: string;
  end;

/// <summary>Parse a color string. Returns False on unrecognized input.</summary>
function TryParseColor(const AText: string; out AColor: TMGLColor): Boolean;

/// <summary>Parse a color string, raising EConvertError on failure.</summary>
function ParseColor(const AText: string): TMGLColor;

implementation

var
  GNamedColors: TDictionary<string, Cardinal>;  // name -> $RRGGBB

function Clamp01(V: Double): Double; inline;
begin
  if V < 0 then Result := 0
  else if V > 1 then Result := 1
  else Result := V;
end;

{ TMGLColor }

class function TMGLColor.Create(AR, AG, AB, AA: Double): TMGLColor;
begin
  Result.R := Clamp01(AR);
  Result.G := Clamp01(AG);
  Result.B := Clamp01(AB);
  Result.A := Clamp01(AA);
end;

class function TMGLColor.FromRGBA(AR, AG, AB, AA: Byte): TMGLColor;
begin
  Result := TMGLColor.Create(AR / 255, AG / 255, AB / 255, AA / 255);
end;

class function TMGLColor.Black: TMGLColor;
begin
  Result := TMGLColor.Create(0, 0, 0, 1);
end;

class function TMGLColor.Transparent: TMGLColor;
begin
  Result := TMGLColor.Create(0, 0, 0, 0);
end;

function TMGLColor.ToColor: TColor;
begin
  Result := TColor(
    (Round(Clamp01(R) * 255)) or
    (Round(Clamp01(G) * 255) shl 8) or
    (Round(Clamp01(B) * 255) shl 16));
end;

function TMGLColor.AlphaByte: Byte;
begin
  Result := Round(Clamp01(A) * 255);
end;

function TMGLColor.Lerp(const Other: TMGLColor; T: Double): TMGLColor;
begin
  Result.R := R + (Other.R - R) * T;
  Result.G := G + (Other.G - G) * T;
  Result.B := B + (Other.B - B) * T;
  Result.A := A + (Other.A - A) * T;
end;

function TMGLColor.ToCanonical: string;
begin
  Result := Format('rgba(%d,%d,%d,%s)',
    [Round(Clamp01(R) * 255), Round(Clamp01(G) * 255), Round(Clamp01(B) * 255),
     FloatToStr(Clamp01(A), TFormatSettings.Invariant)]);
end;

{ Parsing helpers }

function HexNibble(C: Char; out V: Integer): Boolean;
begin
  Result := True;
  case C of
    '0'..'9': V := Ord(C) - Ord('0');
    'a'..'f': V := Ord(C) - Ord('a') + 10;
    'A'..'F': V := Ord(C) - Ord('A') + 10;
  else
    Result := False;
    V := 0;
  end;
end;

function ParseHex(const S: string; out AColor: TMGLColor): Boolean;
var
  Body: string;

  function Byte2(I: Integer): Integer;
  var
    H, L: Integer;
  begin
    HexNibble(Body[I], H);
    HexNibble(Body[I + 1], L);
    Result := H * 16 + L;
  end;

  function Nib1(I: Integer): Integer;
  var
    H: Integer;
  begin
    HexNibble(Body[I], H);
    Result := H * 16 + H;
  end;

var
  I: Integer;
  Ok: Boolean;
  Dummy: Integer;
begin
  Body := S.Substring(1);  // strip '#'
  Ok := True;
  for I := 1 to Length(Body) do
    if not HexNibble(Body[I], Dummy) then
      Ok := False;
  if not Ok then
    Exit(False);

  case Length(Body) of
    3: AColor := TMGLColor.Create(Nib1(1) / 255, Nib1(2) / 255, Nib1(3) / 255, 1);
    4: AColor := TMGLColor.Create(Nib1(1) / 255, Nib1(2) / 255, Nib1(3) / 255, Nib1(4) / 255);
    6: AColor := TMGLColor.Create(Byte2(1) / 255, Byte2(3) / 255, Byte2(5) / 255, 1);
    8: AColor := TMGLColor.Create(Byte2(1) / 255, Byte2(3) / 255, Byte2(5) / 255, Byte2(7) / 255);
  else
    Exit(False);
  end;
  Result := True;
end;

function SplitArgs(const S: string): TArray<string>;
var
  Inner: string;
  P1, P2: Integer;
begin
  P1 := S.IndexOf('(');
  P2 := S.LastIndexOf(')');
  if (P1 < 0) or (P2 <= P1) then
    Exit(nil);
  Inner := S.Substring(P1 + 1, P2 - P1 - 1);
  Result := Inner.Split([',']);
end;

function ParseNum(const S: string; out V: Double): Boolean;
var
  T: string;
  Pct: Boolean;
begin
  T := S.Trim;
  Pct := T.EndsWith('%');
  if Pct then
    T := T.Substring(0, T.Length - 1).Trim;
  Result := TryStrToFloat(T, V, TFormatSettings.Invariant);
  if Result and Pct then
    V := V / 100;
end;

// HSL (h in degrees, s/l in 0..1) -> RGB 0..1
procedure HSLToRGB(H, S, L: Double; out R, G, B: Double);
var
  C, X, M: Double;
  HP: Double;
begin
  H := H - Floor(H / 360) * 360;  // normalize to 0..360
  C := (1 - Abs(2 * L - 1)) * S;
  HP := H / 60;
  // X = C * (1 - |HP mod 2 - 1|)
  X := C * (1 - Abs(HP - 2 * Floor(HP / 2) - 1));
  M := L - C / 2;
  if HP < 1 then begin R := C; G := X; B := 0; end
  else if HP < 2 then begin R := X; G := C; B := 0; end
  else if HP < 3 then begin R := 0; G := C; B := X; end
  else if HP < 4 then begin R := 0; G := X; B := C; end
  else if HP < 5 then begin R := X; G := 0; B := C; end
  else begin R := C; G := 0; B := X; end;
  R := R + M;
  G := G + M;
  B := B + M;
end;

function ParseFunctional(const S: string; out AColor: TMGLColor): Boolean;
var
  Args: TArray<string>;
  IsHsl: Boolean;
  V0, V1, V2, A: Double;
  R, G, B: Double;
begin
  IsHsl := S.StartsWith('hsl');
  Args := SplitArgs(S);
  if (Length(Args) < 3) or (Length(Args) > 4) then
    Exit(False);

  A := 1;
  if Length(Args) = 4 then
    if not ParseNum(Args[3], A) then
      Exit(False);

  if not (ParseNum(Args[0], V0) and ParseNum(Args[1], V1) and ParseNum(Args[2], V2)) then
    Exit(False);

  if IsHsl then
  begin
    HSLToRGB(V0, Clamp01(V1), Clamp01(V2), R, G, B);
    AColor := TMGLColor.Create(R, G, B, A);
  end
  else
  begin
    // rgb()/rgba(): channels 0..255 (or % handled in ParseNum -> 0..1)
    if V0 > 1 then V0 := V0 / 255;
    if V1 > 1 then V1 := V1 / 255;
    if V2 > 1 then V2 := V2 / 255;
    AColor := TMGLColor.Create(V0, V1, V2, A);
  end;
  Result := True;
end;

function TryParseColor(const AText: string; out AColor: TMGLColor): Boolean;
var
  S: string;
  RGB: Cardinal;
begin
  S := AText.Trim;
  if S = '' then
    Exit(False);

  if S.StartsWith('#') then
    Exit(ParseHex(S, AColor));

  if S.StartsWith('rgb') or S.StartsWith('hsl') then
    Exit(ParseFunctional(S.ToLower, AColor));

  // named color
  if GNamedColors.TryGetValue(S.ToLower, RGB) then
  begin
    AColor := TMGLColor.FromRGBA((RGB shr 16) and $FF, (RGB shr 8) and $FF, RGB and $FF, 255);
    Exit(True);
  end;

  Result := False;
end;

function ParseColor(const AText: string): TMGLColor;
begin
  if not TryParseColor(AText, Result) then
    raise EConvertError.CreateFmt('Invalid color: "%s"', [AText]);
end;

procedure RegisterNamedColors;
  procedure C(const N: string; V: Cardinal);
  begin
    GNamedColors.Add(N, V);
  end;
begin
  C('black', $000000); C('silver', $C0C0C0); C('gray', $808080); C('grey', $808080);
  C('white', $FFFFFF); C('maroon', $800000); C('red', $FF0000); C('purple', $800080);
  C('fuchsia', $FF00FF); C('magenta', $FF00FF); C('green', $008000); C('lime', $00FF00);
  C('olive', $808000); C('yellow', $FFFF00); C('navy', $000080); C('blue', $0000FF);
  C('teal', $008080); C('aqua', $00FFFF); C('cyan', $00FFFF); C('orange', $FFA500);
  C('aliceblue', $F0F8FF); C('antiquewhite', $FAEBD7); C('aquamarine', $7FFFD4);
  C('azure', $F0FFFF); C('beige', $F5F5DC); C('bisque', $FFE4C4); C('blanchedalmond', $FFEBCD);
  C('blueviolet', $8A2BE2); C('brown', $A52A2A); C('burlywood', $DEB887); C('cadetblue', $5F9EA0);
  C('chartreuse', $7FFF00); C('chocolate', $D2691E); C('coral', $FF7F50);
  C('cornflowerblue', $6495ED); C('cornsilk', $FFF8DC); C('crimson', $DC143C);
  C('darkblue', $00008B); C('darkcyan', $008B8B); C('darkgoldenrod', $B8860B);
  C('darkgray', $A9A9A9); C('darkgrey', $A9A9A9); C('darkgreen', $006400);
  C('darkkhaki', $BDB76B); C('darkmagenta', $8B008B); C('darkolivegreen', $556B2F);
  C('darkorange', $FF8C00); C('darkorchid', $9932CC); C('darkred', $8B0000);
  C('darksalmon', $E9967A); C('darkseagreen', $8FBC8F); C('darkslateblue', $483D8B);
  C('darkslategray', $2F4F4F); C('darkslategrey', $2F4F4F); C('darkturquoise', $00CED1);
  C('darkviolet', $9400D3); C('deeppink', $FF1493); C('deepskyblue', $00BFFF);
  C('dimgray', $696969); C('dimgrey', $696969); C('dodgerblue', $1E90FF);
  C('firebrick', $B22222); C('floralwhite', $FFFAF0); C('forestgreen', $228B22);
  C('gainsboro', $DCDCDC); C('ghostwhite', $F8F8FF); C('gold', $FFD700);
  C('goldenrod', $DAA520); C('greenyellow', $ADFF2F); C('honeydew', $F0FFF0);
  C('hotpink', $FF69B4); C('indianred', $CD5C5C); C('indigo', $4B0082);
  C('ivory', $FFFFF0); C('khaki', $F0E68C); C('lavender', $E6E6FA);
  C('lavenderblush', $FFF0F5); C('lawngreen', $7CFC00); C('lemonchiffon', $FFFACD);
  C('lightblue', $ADD8E6); C('lightcoral', $F08080); C('lightcyan', $E0FFFF);
  C('lightgoldenrodyellow', $FAFAD2); C('lightgray', $D3D3D3); C('lightgrey', $D3D3D3);
  C('lightgreen', $90EE90); C('lightpink', $FFB6C1); C('lightsalmon', $FFA07A);
  C('lightseagreen', $20B2AA); C('lightskyblue', $87CEFA); C('lightslategray', $778899);
  C('lightslategrey', $778899); C('lightsteelblue', $B0C4DE); C('lightyellow', $FFFFE0);
  C('limegreen', $32CD32); C('linen', $FAF0E6); C('mediumaquamarine', $66CDAA);
  C('mediumblue', $0000CD); C('mediumorchid', $BA55D3); C('mediumpurple', $9370DB);
  C('mediumseagreen', $3CB371); C('mediumslateblue', $7B68EE); C('mediumspringgreen', $00FA9A);
  C('mediumturquoise', $48D1CC); C('mediumvioletred', $C71585); C('midnightblue', $191970);
  C('mintcream', $F5FFFA); C('mistyrose', $FFE4E1); C('moccasin', $FFE4B5);
  C('navajowhite', $FFDEAD); C('oldlace', $FDF5E6); C('olivedrab', $6B8E23);
  C('orangered', $FF4500); C('orchid', $DA70D6); C('palegoldenrod', $EEE8AA);
  C('palegreen', $98FB98); C('paleturquoise', $AFEEEE); C('palevioletred', $DB7093);
  C('papayawhip', $FFEFD5); C('peachpuff', $FFDAB9); C('peru', $CD853F);
  C('pink', $FFC0CB); C('plum', $DDA0DD); C('powderblue', $B0E0E6);
  C('rosybrown', $BC8F8F); C('royalblue', $4169E1); C('saddlebrown', $8B4513);
  C('salmon', $FA8072); C('sandybrown', $F4A460); C('seagreen', $2E8B57);
  C('seashell', $FFF5EE); C('sienna', $A0522D); C('skyblue', $87CEEB);
  C('slateblue', $6A5ACD); C('slategray', $708090); C('slategrey', $708090);
  C('snow', $FFFAFA); C('springgreen', $00FF7F); C('steelblue', $4682B4);
  C('tan', $D2B48C); C('thistle', $D8BFD8); C('tomato', $FF6347);
  C('turquoise', $40E0D0); C('violet', $EE82EE); C('wheat', $F5DEB3);
  C('whitesmoke', $F5F5F5); C('yellowgreen', $9ACD32); C('rebeccapurple', $663399);
end;

initialization
  GNamedColors := TDictionary<string, Cardinal>.Create;
  RegisterNamedColors;

finalization
  GNamedColors.Free;

end.
