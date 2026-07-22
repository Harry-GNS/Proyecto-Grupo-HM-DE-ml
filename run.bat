@echo off
echo =========================================
echo Iniciando Motor de Graficos Financieros...
echo =========================================

:: Intentar correr con perl local en el PATH
where perl >nul 2>nul
if %errorlevel% equ 0 (
    echo Usando Perl desde el PATH del sistema...
    perl market.pl
    pause
    exit /b
)

:: Intentar con la ruta tipica de Strawberry Perl
if exist "C:\Strawberry\perl\bin\perl.exe" (
    echo Usando Strawberry Perl detectado en C:\Strawberry...
    "C:\Strawberry\perl\bin\perl.exe" market.pl
    pause
    exit /b
)

:: Intentar con la ruta tipica en C:\Perl
if exist "C:\Perl\bin\perl.exe" (
    echo Usando Perl detectado en C:\Perl...
    "C:\Perl\bin\perl.exe" market.pl
    pause
    exit /b
)

echo ERROR: No se pudo encontrar un interprete de Perl instalado.
echo Por favor asegurese de tener instalado Strawberry Perl (https://strawberryperl.com/)
echo o agregarlo a las variables de entorno del sistema.
echo.
pause
