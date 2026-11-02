@echo off
REM =====================================================================
REM  AutoAudit - Inicia la aplicacion web en Windows
REM  Deje esta ventana abierta mientras usa la aplicacion.
REM  Para detenerla: cierre la ventana o presione Ctrl+C.
REM =====================================================================
chcp 65001 >nul
cd /d "%~dp0app"
if not exist .venv\Scripts\python.exe (
    echo Primero ejecute instalar_windows.bat
    pause
    exit /b 1
)
echo.
echo  AutoAudit se esta iniciando en http://localhost:8000
echo  NO CIERRE ESTA VENTANA mientras use la aplicacion.
echo.
start "" cmd /c "timeout /t 3 >nul & start http://localhost:8000"
.venv\Scripts\python.exe -m uvicorn main:app --host 127.0.0.1 --port 8000
pause
