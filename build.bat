@echo off
if not exist build mkdir build
tools\pasmo.exe --tapbas src\main.asm build\demo.tap
if %errorlevel% == 0 (
    echo Build OK: build\demo.tap
) else (
    echo Build FAILED
)
