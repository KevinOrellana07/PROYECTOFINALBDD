@echo off
REM =====================================================================
REM  AutoAudit - Instalador para Windows (usa el PostgreSQL ya instalado)
REM  Doble clic sobre este archivo, o desde CMD:  instalar_windows.bat
REM =====================================================================
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set PGCLIENTENCODING=UTF8
set PGOPTIONS=-c client_min_messages=warning

echo.
echo ============ AutoAudit - Instalacion en Windows ============
echo.

REM ---- 1. Buscar psql.exe de PostgreSQL ------------------------------
set "PGBIN="
for /d %%D in ("%ProgramFiles%\PostgreSQL\*") do if exist "%%D\bin\psql.exe" set "PGBIN=%%D\bin"
if not defined PGBIN (
    echo [ERROR] No se encontro PostgreSQL en "%ProgramFiles%\PostgreSQL".
    echo         Instale PostgreSQL 18 desde https://www.postgresql.org/download/windows/
    goto :fin_error
)
echo [OK] PostgreSQL encontrado en: %PGBIN%

REM ---- 2. Buscar Python ----------------------------------------------
set "PY="
where py >nul 2>&1 && set "PY=py -3"
if not defined PY ( where python >nul 2>&1 && set "PY=python" )
if not defined PY (
    echo [ERROR] No se encontro Python. Instalelo desde https://www.python.org/downloads/
    echo         IMPORTANTE: marque la casilla "Add python.exe to PATH" al instalar.
    goto :fin_error
)
echo [OK] Python encontrado: %PY%

REM ---- 3. Contrasena del superusuario postgres -----------------------
echo.
echo Escriba la contrasena del usuario "postgres"
echo (es la que definio al instalar PostgreSQL; la misma que pide pgAdmin):
set /p "PGPASSWORD=Contrasena: "
set PSQL="%PGBIN%\psql.exe" -h localhost -p 5432 -U postgres -v ON_ERROR_STOP=1 -q -X

%PSQL% -d postgres -c "select 1" >nul
if errorlevel 1 (
    echo [ERROR] No se pudo conectar como postgres. Revise la contrasena
    echo         y que el servicio de PostgreSQL este iniciado.
    goto :fin_error
)
echo [OK] Conexion a PostgreSQL correcta

REM ---- 4. Base de datos -----------------------------------------------
echo.
echo == Creando base de datos, generador de triggers y seguridad ==
call :ejecutar sql\00_roles_y_bd.sql postgres          || goto :fin_error
call :ejecutar sql\01_esquema.sql autoaudit_db         || goto :fin_error
call :ejecutar sql\02_diccionario.sql autoaudit_db     || goto :fin_error
call :ejecutar sql\03_funciones_config.sql autoaudit_db || goto :fin_error
call :ejecutar sql\04_generador_triggers.sql autoaudit_db || goto :fin_error
call :ejecutar sql\05_consultas.sql autoaudit_db       || goto :fin_error
call :ejecutar sql\06_seguridad.sql autoaudit_db       || goto :fin_error
call :ejecutar sql\07_eventos_ddl.sql autoaudit_db     || goto :fin_error
call :ejecutar sql\08_datos_demo.sql autoaudit_db      || goto :fin_error
call :ejecutar sql\09_comentarios.sql autoaudit_db     || goto :fin_error

if /i "%~1"=="--sin-demo" goto :python
echo.
echo == Configuracion y actividad de demostracion ==
call :ejecutar ejemplos\01_configurar_demo.sql autoaudit_db  || goto :fin_error
call :ejecutar ejemplos\02_generar_actividad.sql autoaudit_db || goto :fin_error

:python
REM ---- 5. Entorno Python ---------------------------------------------
echo.
echo == Instalando dependencias de Python (puede tardar un par de minutos) ==
if not exist app\.venv\Scripts\python.exe (
    %PY% -m venv app\.venv
    if errorlevel 1 goto :fin_error
)
app\.venv\Scripts\python.exe -m pip install -q --upgrade pip
app\.venv\Scripts\python.exe -m pip install -q -r app\requirements.txt
if errorlevel 1 goto :fin_error
if not exist app\.env copy app\.env.example app\.env >nul

REM ---- 6. Verificacion -----------------------------------------------
echo.
%PSQL% -d autoaudit_db -c "SELECT esquema||'.'||tabla AS tabla, estado, eventos, sincronizado FROM auditoria.v_estado_auditoria WHERE estado <> 'HUERFANA' ORDER BY 1"

echo.
echo ============================================================
echo  Instalacion completada.
echo  Para iniciar la aplicacion: doble clic en iniciar_windows.bat
echo  Luego abra http://localhost:8000
echo.
echo  Usuarios: admin_auditoria / Admin123!   auditor / Auditor123!
echo            vendedor / Vendedor123!       bodeguero / Bodega123!
echo ============================================================
pause
exit /b 0

:ejecutar
echo   -^> %~1
%PSQL% -d %2 -f "%~1" >nul
if errorlevel 1 (
    echo [ERROR] Fallo el script %~1
    exit /b 1
)
exit /b 0

:fin_error
echo.
echo La instalacion no termino. Revise el mensaje de arriba.
pause
exit /b 1
