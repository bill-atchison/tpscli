param([string]$Proj = "tpscli.cwproj")
$msb = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe"
& $msb $Proj /t:Rebuild /p:Configuration=Release /p:ClarionBinPath="C:\Clarion12\bin" `
      /p:clarion_version="Clarion 12.0.14000" /v:minimal
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }
$exe = [IO.Path]::ChangeExtension($Proj, ".exe")
$b = [IO.File]::ReadAllBytes($exe); $pe = [BitConverter]::ToInt32($b, 0x3C)
$sub = [BitConverter]::ToUInt16($b, $pe + 4 + 20 + 68)
if ($sub -ne 3) { throw "$exe is not a console-subsystem image (subsystem=$sub); check tpscli.exp" }
"subsystem=3 (console)"
