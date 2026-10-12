@echo off
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0pi-model-manager.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
popd
if not "%EXIT_CODE%"=="0" (
  echo.
  echo Pi model manager exited with code %EXIT_CODE%.
  pause
)
exit /b %EXIT_CODE%
