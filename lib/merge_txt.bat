@echo off
setlocal enabledelayedexpansion

REM ================================
REM PARAMETERS
REM ================================
if "%~1"=="" (
    echo Usage: merge_txt.bat ^<folderPath^> ^<outputFile^>
    exit /b 1
)

if "%~2"=="" (
    echo Usage: merge_txt.bat ^<folderPath^> ^<outputFile^>
    exit /b 1
)

set "ROOT=%~f1"
set "OUT=%~f2"

echo Merged file generated on %date% %time%> "%OUT%"
echo.>> "%OUT%"

REM ================================
REM MAIN LOOP (RECURSIVE)
REM ================================
for /r "%ROOT%" %%F in (*.*) do (
    REM Skip the output file itself
    if /I not "%%~fF"=="%OUT%" (
        set "IS_TEXT=1"

        REM Quick extension-based skip for obvious binaries
        for %%E in (
            .exe .dll .png .jpg .jpeg .gif .ico .bmp .ttf .otf
            .zip .7z .rar .gz .pdf .mp3 .mp4 .wav .avi .mov
        ) do (
            if /I "%%~xF"=="%%E" set "IS_TEXT=0"
        )

        REM Null-byte check: if found, treat as binary
        if !IS_TEXT!==1 (
            findstr /R /N "\x00" "%%F" >nul 2>&1
            if !errorlevel! equ 0 set "IS_TEXT=0"
        )

        REM If still considered text, append it
        if !IS_TEXT!==1 (
            echo // %%~fF>>"%OUT%"
            type "%%F" >>"%OUT%"
            echo.>>"%OUT%"
        )
    )
)

echo Done.
endlocal
