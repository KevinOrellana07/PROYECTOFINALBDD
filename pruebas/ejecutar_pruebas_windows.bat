@echo off
REM =====================================================================
REM  AutoAudit - Pruebas de validacion en Windows
REM    ejecutar_pruebas_windows.bat           (todas)
REM    ejecutar_pruebas_windows.bat --rapido  (sin rendimiento)
REM =====================================================================
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set PGCLIENTENCODING=UTF8
set "PGBIN="
for /d %%D in ("%ProgramFiles%\PostgreSQL\*") do if exist "%%D\bin\psql.exe" set "PGBIN=%%D\bin"
if not defined PGBIN ( echo No se encontro PostgreSQL & pause & exit /b 1 )

set /p "PGPASSWORD=Contrasena del usuario postgres: "
set PSQL="%PGBIN%\psql.exe" -h localhost -p 5432 -U postgres -d autoaudit_db -v ON_ERROR_STOP=1 -q -X

for %%F in (00_preparar 01_prueba_insert 02_prueba_update 03_prueba_delete 04_prueba_seguridad) do (
    %PSQL% -f %%F.sql
    if errorlevel 1 goto :error
)
if /i not "%~1"=="--rapido" (
    %PSQL% -f 05_prueba_rendimiento.sql
    if errorlevel 1 goto :error
)

echo.
echo ================ RESUMEN ================
%PSQL% -P footer=off -c "SELECT count(*) FILTER (WHERE exito) AS pasaron, count(*) FILTER (WHERE NOT exito) AS fallaron, count(*) AS total FROM pruebas.resultado"
%PSQL% -c "SELECT prueba, detalle FROM pruebas.resultado WHERE NOT exito"
pause
exit /b 0

:error
echo Una prueba se detuvo con error (ver mensaje arriba).
pause
exit /b 1
