@echo off
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
cd /d "%~dp0"
dcc32 -B -U"..\Source;%BDS%\lib\win32\release" -NSSystem;System.Win;Winapi;Data;Data.Win;Vcl;Vcl.Imaging;FireDAC %1 %2 %3
echo DCC_EXIT=%ERRORLEVEL%
