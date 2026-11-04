@echo off
setlocal
title Workshop preflight
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0preflight_windows.ps1" %*
set "RC=%ERRORLEVEL%"
if %RC% GEQ 2 (
  echo.
  echo The preflight script could not finish. Exit code: %RC%
  echo If you see a message about scripts being disabled or signed, a company policy is
  echo blocking it. Please send a screenshot of this window to your instructor.
)
echo.
pause
exit /b %RC%
