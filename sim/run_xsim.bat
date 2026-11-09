@echo off
rem ============================================================
rem  RISC-V CPU simulation runner (ASCII only, no Chinese here)
rem  Usage: double click this file, or run from cmd.
rem ============================================================
setlocal

rem ---- 1. locate Vivado bin directory -------------------------
set VIVADO_BIN=D:\vivado\2025.2\Vivado\bin
if not exist "%VIVADO_BIN%\xvlog.bat" (
    echo [ERROR] Cannot find xvlog.bat under: %VIVADO_BIN%
    echo         Please edit line 9 of this file and set VIVADO_BIN
    echo         to your own Vivado bin directory, for example:
    echo             set VIVADO_BIN=C:\Xilinx\Vivado\2023.2\bin
    pause
    exit /b 1
)
set PATH=%VIVADO_BIN%;%PATH%

cd /d "%~dp0"

echo.
echo === Step 1/3 : compile (xvlog) ===
if exist xvlog.log del /q xvlog.log
call xvlog -sv ../rtl/cpu_add.sv ../rtl/cpu_ALU.sv ../rtl/cpu_Control.sv ^
    ../rtl/cpu_CSR.sv ../rtl/cpu_Data_hazard.sv ../rtl/cpu_EXU.sv ^
    ../rtl/cpu_EX_LSWB_Reg.sv ../rtl/cpu_IDU.sv ../rtl/cpu_IFID_EX_Reg.sv ^
    ../rtl/cpu_IFU.sv ../rtl/cpu_LSU.sv ../rtl/cpu_myCPU.sv ^
    ../rtl/cpu_para.sv ../rtl/cpu_Reg.sv ../rtl/cpu_RegisterFile.sv ^
    ../rtl/cpu_Reg_Stack.sv ../rtl/cpu_sext.sv ../rtl/cpu_WBU.sv ^
    ../rtl/top.v ../rtl/DRAM.v ../rtl/IROM.v ../rtl/dram_driver.sv ^
    ../rtl/perip_bridge.sv ../rtl/counter.sv ../rtl/display_seg.sv ^
    ../rtl/seg7.sv ../rtl/uart.sv tb.sv
if errorlevel 1 goto :fail

echo.
echo === Step 2/3 : elaborate (xelab) ===
if exist xelab.log del /q xelab.log
call xelab tb -s tb
if errorlevel 1 goto :fail

echo.
echo === Step 3/3 : simulate (xsim) ===
call xsim tb -R

echo.
echo ============================================================
echo  Expected output (this CPU, prog.s test):
echo      RESULT_CYCLES=1604 DONEVAL=00004e84
echo      TOTAL_CYCLES=1605 DRAM0=00004e84
echo  DONEVAL = 0x4e84 = 20100  (result of the test program)
echo ============================================================
pause
exit /b 0

:fail
echo.
echo [FAILED] see the log above (xvlog.log / xelab.log)
pause
exit /b 1
