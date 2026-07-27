@ECHO OFF

REM Public Patchwing entrypoint. Keep the upstream bootstrap implementation
REM unchanged and delegate to it.
SET CurrentDirectory=%~dp0
CALL "%CurrentDirectory%shorebird.bat" %*
