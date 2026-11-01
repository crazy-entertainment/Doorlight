set MSYS2_PATH_TYPE=inherit
IF NOT DEFINED MSYS2_BIN (
    IF EXIST C:\msys64\usr\bin\bash.exe (
        SET "MSYS2_BIN=C:\msys64\usr\bin\bash.exe"
    ) ELSE (
        SET "MSYS2_BIN=C:\tools\msys64\usr\bin\bash.exe"
    )
)
IF NOT EXIST "%MSYS2_BIN%" (
    ECHO MSYS2 bash not found at "%MSYS2_BIN%" 1>&2
    EXIT /B 1
)
"%MSYS2_BIN%" --login -x %CONTRIB_SRC_DIR%\ffmpeg\windows-configure-make.sh win32 x64
