@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Integrate-PMAnalyzer-Zstd.ps1" %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" (
  echo Integration failed. Exit code: %ERR%
) else (
  echo Integration completed successfully.
)
pause
exit /b %ERR%
