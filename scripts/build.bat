@echo off
rem =============================================================================
rem  Проверка и выпуск проекта «Пульсоксиметр» (KiCad 9/10, kicad-cli) — Windows
rem    1. ERC схемы            -> output\reports\erc.rpt
rem    2. DRC платы            -> output\reports\drc.rpt   (+ сверка со схемой)
rem    3. Gerber + сверловка   -> output\gerber\*, output\pulse_oximeter_gerber.zip
rem    4. BOM (перечень)       -> output\pulse_oximeter_BOM.csv
rem    5. PDF схемы            -> output\pulse_oximeter_schematic.pdf (+ ч/б)
rem    6. 3D-модель платы      -> output\pulse_oximeter.step
rem
rem  Запуск:  scripts\build.bat        (двойной щелчок тоже работает)
rem  Другой kicad-cli:  set KICAD_CLI=C:\путь\kicad-cli.exe
rem  Коды возврата: 0 — ERC и DRC без ошибок (предупреждения допустимы); 1 — есть ошибки;
rem                 2 — нет kicad-cli/сабмодуля
rem =============================================================================
chcp 65001 >nul
setlocal EnableExtensions

set "PROJECT=pulse_oximeter"
cd /d "%~dp0.."
set "SCH=%PROJECT%.kicad_sch"
set "PCB=%PROJECT%.kicad_pcb"
set "OUT=output"
set "REP=%OUT%\reports"
set "GBR=%OUT%\gerber"
set "STATUS=0"

rem --- поиск kicad-cli ----------------------------------------------------------
set "CLI="
if defined KICAD_CLI set "CLI=%KICAD_CLI%"
if not defined CLI for %%P in (kicad-cli.exe) do if not "%%~$PATH:P"=="" set "CLI=%%~$PATH:P"
if not defined CLI if exist "%ProgramFiles%\KiCad\10.0\bin\kicad-cli.exe" set "CLI=%ProgramFiles%\KiCad\10.0\bin\kicad-cli.exe"
if not defined CLI if exist "%ProgramFiles%\KiCad\9.0\bin\kicad-cli.exe" set "CLI=%ProgramFiles%\KiCad\9.0\bin\kicad-cli.exe"
if not defined CLI (
    echo ОШИБКА: kicad-cli не найден. Установите KiCad 9/10 или задайте KICAD_CLI.
    exit /b 2
)

rem --- библиотека (git-сабмодуль) -----------------------------------------------
if not exist "lib\kicad-gost-lib\symbols\GOST_UGO.kicad_sym" (
    echo Сабмодуль lib\kicad-gost-lib не загружен — выполняю git submodule update --init
    git submodule update --init --recursive
    if errorlevel 1 (
        echo ОШИБКА: не удалось загрузить сабмодуль lib\kicad-gost-lib
        exit /b 2
    )
)

if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%REP%" "%GBR%"
echo kicad-cli: "%CLI%"

rem --- 1. ERC ---------------------------------------------------------------------
echo.
echo === 1/6 ERC — проверка электрических правил схемы ===
"%CLI%" sch erc --severity-all --format report -o "%REP%\erc.rpt" "%SCH%"
if errorlevel 1 (set "STATUS=1" & echo   !! ERC не выполнен)
call :summary "%REP%\erc.rpt" ERC

rem --- 2. DRC ---------------------------------------------------------------------
echo.
echo === 2/6 DRC — проверка правил проектирования платы ===
"%CLI%" pcb drc --schematic-parity --severity-all --format report -o "%REP%\drc.rpt" "%PCB%"
if errorlevel 1 (set "STATUS=1" & echo   !! DRC не выполнен)
call :summary "%REP%\drc.rpt" DRC

rem --- 3. Gerber + сверловка ------------------------------------------------------
echo.
echo === 3/6 Gerber и файлы сверловки ===
"%CLI%" pcb export gerbers --layers "F.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts" --subtract-soldermask --no-x2 -o "%GBR%\\" "%PCB%"
if errorlevel 1 (set "STATUS=1" & echo   !! Gerber)
"%CLI%" pcb export drill --format excellon --excellon-units mm --excellon-separate-th --generate-map --map-format pdf -o "%GBR%\\" "%PCB%"
if errorlevel 1 (set "STATUS=1" & echo   !! сверловка)
powershell -NoProfile -Command "Compress-Archive -Path '%GBR%\*' -DestinationPath '%OUT%\%PROJECT%_gerber.zip' -Force"
if exist "%OUT%\%PROJECT%_gerber.zip" echo   архив: %OUT%\%PROJECT%_gerber.zip

rem --- 4. BOM ---------------------------------------------------------------------
echo.
echo === 4/6 BOM — перечень элементов ===
"%CLI%" sch export bom --fields "Reference,Value,Footprint,${QUANTITY},Manufacturer,Manufacturer_Part_Number" --labels "Поз. обозначение,Номинал/тип,Корпус,Кол.,Производитель,Партномер" --group-by "Value,Footprint,Manufacturer_Part_Number" --sort-field "Reference" --ref-range-delimiter "-" --exclude-dnp -o "%OUT%\%PROJECT%_BOM.csv" "%SCH%"
if errorlevel 1 (set "STATUS=1" & echo   !! BOM)

rem --- 5. PDF схемы ---------------------------------------------------------------
echo.
echo === 5/6 PDF схемы ===
"%CLI%" sch export pdf -o "%OUT%\%PROJECT%_schematic.pdf" "%SCH%"
if errorlevel 1 (set "STATUS=1" & echo   !! PDF цвет)
"%CLI%" sch export pdf --black-and-white -o "%OUT%\%PROJECT%_schematic_bw.pdf" "%SCH%"
if errorlevel 1 (set "STATUS=1" & echo   !! PDF ч/б)

rem --- 6. STEP ---------------------------------------------------------------------
echo.
echo === 6/6 3D-модель платы (STEP) ===
"%CLI%" pcb export step --subst-models -f -o "%OUT%\%PROJECT%.step" "%PCB%" >nul 2>&1
if exist "%OUT%\%PROJECT%.step" (echo   %OUT%\%PROJECT%.step) else (echo   STEP не выгружен — на результат не влияет)

rem --- итог -----------------------------------------------------------------------
echo.
echo === Итог ===
dir /b "%OUT%"
if "%STATUS%"=="0" (echo   ERC и DRC без ошибок, файлы выпущены.) else (echo   Есть замечания — см. отчёты в %REP%\)
endlocal & exit /b %STATUS%

rem --- подпрограмма: число ошибок/предупреждений в отчёте --------------------------
:summary
set "ERRS=0" & set "WARNS=0"
for /f %%N in ('type "%~1" ^| find /c "; error"') do set "ERRS=%%N"
for /f %%N in ('type "%~1" ^| find /c "; warning"') do set "WARNS=%%N"
echo   %~2: ошибок %ERRS%, предупреждений %WARNS%  -^>  %~1
if not "%ERRS%"=="0" set "STATUS=1"
exit /b 0
