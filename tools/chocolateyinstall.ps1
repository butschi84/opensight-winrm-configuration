$toolsDir   = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"

# 1. Run Installer Script
#    will create logfile in c:\windows\temp\opensightWinrmConfiguration.log
$installScript = join-path $toolsDir "opensightWinrmConfiguration.ps1"
. $installScript