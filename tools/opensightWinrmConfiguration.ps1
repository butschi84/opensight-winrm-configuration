# basic logging function
function log($text) {
    $logfile = join-path $env:temp "opensightWinrmConfiguration.log"
    $timestamp = (get-date).toString("dd.mm.yyyy hh:mm:ss")
    write-host $timestamp - $text
    echo ($timestamp + " - " + $text) | out-file $logfile -append -ErrorAction SilentlyContinue
}

# Get Fully Qualified Domain Name of current computer
function getFQDN() {
    $fqdn = [System.Net.Dns]::GetHostByName($env:computerName)
    return $fqdn.HostName.toLower()
}

# Check if there is a machine certificate
# - usable for "server authentication (1.3.6.1.5.5.7.3.1)"
# - subject should contain hostname
# - should be issued by a cert that is in trustedRootCerts
function findHostCertificate() {
    # get all trusted certs store - subjects
    log ("listener: cert: gettings list of all root certs")
    $trustedRootCerts = (get-childitem -Path Cert:\localmachine\root) | ForEach-Object { $_.Subject }
    log ("listener: cert: found " + ($trustedRootCerts | measure).count + " certs")
    
    log ("listener: cert: resolving fqdn hostname")
    [String] $HostName = getFQDN
    log ("listener: cert: " + $HostName)
    [String] $Thumbprint = (get-childitem -Path Cert:\localmachine\my | Where-Object { 
                    ($_.Issuer -in $trustedRootCerts) -and
                    ($_.Extensions.EnhancedKeyUsages.value -eq '1.3.6.1.5.5.7.3.1') -and
                    ($HostName -in $_.DNSNameList.Unicode.toLower()) -and
                    ($_.Subject.ToLower() -like "cn=$HostName") } | Select-Object -First 1
    ).Thumbprint

    if(!$Thumbprint) {
        # Generieren eines Self Signed Zertifikats
        log ("listener: cert: cert could not find an existing host certificate.")
        log ("listener: cert: check if there is already a selfsigned host certificate")
        $Thumbprint = (get-childitem Cert:\LocalMachine\My  | Where-Object { 
            ($_.FriendlyName -eq 'OpensightWinRMHostCert')
        }).Thumbprint
        if(!$Thumbprint) {
            log ("listener: cert: there is no self signed cert yet. creating a self signed certificate")
            $cert = New-SelfSignedCertificate -Subject ("CN=$HostName") -TextExtension '2.5.29.37={text}1.3.6.1.5.5.7.3.1' -CertStoreLocation Cert:\LocalMachine\My -FriendlyName OpensightWinRMHostCert
            log ("listener: cert: thumbprint of generated certificate is: " + $cert.Thumbprint)
            return $cert.Thumbprint
        }else{
            log ("listener: cert: found a self signed certificate")
            log ("listener: cert: thumbprint is: " + $Thumbprint)
            return $Thumbprint
        }
    }else{
        log ("listener: cert: found a host certificate that seems to be issued from CA")
        log ("listener: cert: thumbprint is: " + $Thumbprint)
        return $Thumbprint
    }
}

# configure winrm service startup
function configureWinRMService() {
    log "service: configuring winrm service startup => automatic"
    Set-Service -Name WinRM -StartupType Automatic

    log "service: starting winrm service"
    Set-Service -Name WinRM -Status Running
}

# function to check wheter there is a http listener
function httpListenerExisting() {
    try {
        Get-WSManInstance winrm/config/listener -SelectorSet @{Address="*";Transport="HTTP"} -ErrorAction SilentlyContinue
        return $true
    }catch{
        return $false
    }
}

# function to check wheter there is a https listener
function httpsListenerExisting() {
    try {
        Get-WSManInstance winrm/config/listener -SelectorSet @{Address="*";Transport="HTTPS"} -ErrorAction SilentlyContinue
        return $true
    }catch{
        return $false
    }
}

function configureWinRMListener() {
    # deactive unencrypted winrm endpoint (http)
    if(httpListenerExisting) {
        log ("listener: removing previous http listener config")
        Remove-WSManInstance winrm/config/Listener -SelectorSet @{Address='*';Transport="HTTP"} -ErrorAction SilentlyContinue
    }

    # WinRM HTTPS Listener konfigurieren
    # - find correct ssl certificate to use (see function findHostCertificate)
    # - configure ssl certificate accordingly
    log ("listener: trying to find correct host certificate to use")
    $certificateThumbprint = findHostCertificate

    if(httpsListenerExisting) {
        log "listener: removing previous https listeners"
        Remove-WSManInstance winrm/config/listener -SelectorSet @{Address="*";Transport="HTTPS"} -ErrorAction SilentlyContinue
    }

    log ("listener: getting host fqdn")
    $fqdn = getFQDN

    log ("listener: configuring https listener")
    New-WSManInstance winrm/config/listener -SelectorSet @{Address="*";Transport="HTTPS"} -ValueSet @{Hostname=$fqdn;CertificateThumbprint=$certificateThumbprint} | out-null
}

function configureWinRMAuthentication() {
    log "authentication: configuring winrm authentication"
    # basic auth desctivate / credssp activate
    log "authentication: deactivating basic auth"
    set-item -Path WSMan:\localhost\Service\Auth\Basic -Value false
    log "authentication: activating credssp"
    set-item -Path WSMan:\localhost\Service\Auth\CredSSP -Value true
    log "authentication: restarting winrm service"
    restart-service -ServiceName WinRM
}

# configure windows firewall
# - allow inbound traffic on 5986
function configureFirewall() {
    log ("firewall: configuring firewall")

    $existingRule = (Get-NetFirewallRule | Where-Object { $_.DisplayName -eq "Windows Remote Management (HTTPS)"} | measure).Count -gt 0

    if(!$existingRule) {
        log ("firewall: allow inbound traffic on 5986")
        $FirewallParam = @{
            DisplayName = 'Windows Remote Management (HTTPS)'
            Direction = 'Inbound'
            LocalPort = 5986
            Protocol = 'TCP'
            Action = 'Allow'
            Program = 'System'
        }
        New-NetFirewallRule @FirewallParam
    }else{
        log ("firewall skipping, the rule 'Windows Remote Management (HTTPS)' is already existing")
    }
}

log "----------------------------------"
log "opensight.ch - winrm configuration"
log "----------------------------------"
configureWinRMService
configureWinRMListener
configureWinRMAuthentication
configureFirewall