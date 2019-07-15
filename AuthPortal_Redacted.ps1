<# 

.SYNOPSIS 

This script will log you into the following MultiFactor Auth Portals automatically:

- [Redacted]
- [Redacted]
- [Redacted]
- [Redacted]
- [Redacted]

.DESCRIPTION 

After entering a valid RSA token that will be valid for at least 50 seconds, it will use your local login as the username and the RSA token into each of the 5 sites.  Must be run from an elevated PowerShell prompt.

Prerequisites: Internet Explorer 11 or higher

Version(s) / Scripting Language:  PowerShell 3.0 or higher

Author(s) Tad Cox, Jayson Bennett, and Carl Davis 

Changes: Original Version

Notes/ Usage:  Since it takes about 45 seconds (depending on workstation resources) to complete the login process to each site, you must enter a token that will be valid for at least that long. No Parameters required.

Creation Date: 12.12.2018 

Updated 7/9/2019 Carl Davis
    - Added error handling to test if a successfull login occured.  If an unsuccessful login happened, 
        script will continue to prompt for another RSA token until a successful login happens.
    - Added error handing to determine if the user is being prompted for a second token code.
    - Added Windows 10 or higher detection.  Test-NetConnection will not work under Windows 7.


.EXAMPLE 

.\AuthPortal.ps1

.INPUTS 

User will be prompted for an RSA token.

.OUTPUTS 

None

.NOTES 

Since it takes about 45 seconds (depending on workstation resources) to complete the login process to each site, you must enter a token that will be valid for at least that long. No Parameters required.

.LINK 

[Redacted]

#> 

# Must use Windows 10 or higher
If ([environment]::OSVersion.Version.major -lt 10) {
    Write-Error "Your OS is not at least Windows 10 and this script will not work."
    Break
}

# Location of MFA Site to grab URLs from
$MFASite = #<Insert your MFA Landing page here>

#Works with Cisco AnyConnect Client only
Function VPNConnect() {
    Start-Process -WindowStyle Minimized -FilePath $vpncliAbsolutePath -ArgumentList "connect $Server"
    $counter = 0; $h = 0;
    while ($counter++ -lt 1000 -and $h -eq 0) {
        Start-sleep -m 10
        $h = (Get-Process vpncli).MainWindowHandle
    }
    #if it takes more than 10 seconds then display message
    if ($h -eq 0) { Write-Output "Could not start VPNUI it takes too long." }
    else { [void] [Win]::SetForegroundWindow($h) }
}

#check for admin/run as Admin
If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {   
    $arguments = "& '" + $myinvocation.mycommand.definition + "'"
    Start-Process powershell -Verb runAs -ArgumentList $arguments
    Break
}

# Load assembly to display GUI prompts
[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic') | Out-Null

# Validate if user can get to MFA Site.  If not, then prompts to connect to Cisco AnyConnect.
While (!(Test-NetConnection $MFASite.split("/")[2]).PingSucceeded ) {
    VPNConnect
    #Start vpnui
    Start-Process -WindowStyle Minimized -FilePath $vpnuiAbsolutePath
    [Microsoft.VisualBasic.Interaction]::MsgBox("Log into VPN and click OK", 0, "Network Check") | Out-Null 
}

#prompt for RSA key
$key = [Microsoft.VisualBasic.Interaction]::InputBox("Enter RSA key that will be valid for at least 50 seconds")
$user = $env:USERNAME

If ($key) {
    #Pull content from MFA Site
    $MFASubsites = @()
    $MFASubsites = (Invoke-WebRequest -Uri $MFASite)

    #Based on info pulled from above, populate the 4 sites that we want to authenticate to and sory in desc order so [Redacted] is last. 
    $Portal = @()
    $Portal = $MFASubsites.InputFields.Formaction # Grabs [Redacted]
    $Portal += ( $MFASubsites.links | Where-Object { $_.innerHTML -like <#[Redacted]#> }).href # Grabs <#[Redacted]#>
    # $Portal += ( $MFASubsites.links | Where-Object { $_.innerHTML -like '<#[Redacted]#>' }).href
    # $Portal += ( $MFASubsites.links | Where-Object { $_.innerHTML -like '<#[Redacted]#>' }).href
    # $Portal += ( $MFASubsites.links | Where-Object { $_.innerHTML -like '<#[Redacted]#>' }).href
    # $Portal += ( $MFASubsites.links | Where-Object { $_.innerHTML -like '<#[Redacted]#>' }).href
    # $Portal += ( $MFASubsites.links | Where-Object { $_.innerHTML -like '<#[Redacted]#>' }).href
    # $Portal += ( $MFASubsites.links | Where-Object { $_.innerHTML -like '<#[Redacted]#>' }).href
    $Portal = $Portal | Sort-Object -Descending

    #open IE, navigate to auth site, enter user/key variables
    $ie = New-Object -com InternetExplorer.Application
    $ie.visible = $true 

    foreach ($Site in $Portal) {
        $ie.Navigate($Site)
        while ($ie.busy) { start-sleep -Milliseconds 200 } 
        # Case for handling <#[Redacted]#> MFA Site since it is different
        If ($Site -ilike <#[Redacted]#>) {
            Write-Verbose "<#[Redacted]#> MFA Site: $Site"
            ($ie.Document.IHTMLDocument3_getElementsByTagName('input') | Where-Object -property type -eq 'password').value = $key
            ($ie.Document.IHTMLDocument3_getElementsByName('user'))[0].value = $user
            #click submit, wait 200 milliseconds, click Submit again
            $Submit = $ie.Document.IHTMLDocument3_getElementsByTagName('Input') | Where-Object { $_.Type -eq 'Submit' }
            $Submit.click()
            while ($ie.busy) { start-sleep -Milliseconds 200 } 
            # Check for text "You have been successfully authenticated" on screen.  If not, prompt for another RSA token and try again
            $i = $null
            While ($ie.Document.IHTMLDocument3_documentElement.innerText -inotlike '*You have been successfully authenticated*') {
                # Since <#[Redacted]#> MFA site just sends you back to teh first logon screen, only do it three times before bail out.
                $i++
                If ($i -gt 3)
                { 
                    Write-Error "Something is wrong with your RSA login"
                    Break
                }
                #prompt for RSA key
                Write-Verbose "<#[Redacted]#> MFA Site bad login"
                $key = [Microsoft.VisualBasic.Interaction]::InputBox("Wait for RSA Key to change and enter the new one", "RSA Key", $null)
                ($ie.Document.IHTMLDocument3_getElementsByTagName('input') | Where-Object -property type -eq 'password').value = $key
                ($ie.Document.IHTMLDocument3_getElementsByName('user'))[0].value = $user
                $Submit = $ie.Document.IHTMLDocument3_getElementsByTagName('Input') | Where-Object { $_.Type -eq 'Submit' }
                $Submit.click()    
                Start-Sleep -Seconds 5
            }
            Write-Verbose "<#[Redacted]#> MFA Site good login"
        }Else {
            # Case to handle everythin other than <#[Redacted]#>
            Write-Verbose "<#[Redacted]#> MFA Site: $Site"
            # Enter username and password on the first screen and hit submit
            ($ie.Document.IHTMLDocument3_getElementsByTagName('input') | Where-Object -property type -eq 'password').value = $key
            ($ie.Document.IHTMLDocument3_getElementsByName('DATA'))[0].value = $user
            #click submit, wait 200 milliseconds, click Submit again
            $Submit = $ie.Document.IHTMLDocument3_getElementsByTagName('Input') | Where-Object { $_.Type -eq 'Submit' }
            $Submit.click()
            while ($ie.busy) { start-sleep -Milliseconds 300 } 
            # Check for text "authenticated by Radius authentication" on screen.  If not, prompt for another RSA token and try again
            while ($ie.Document.IHTMLDocument3_documentElement.innerText -inotlike '*authenticated by Radius authentication*') {   
                
                # Check for second token code prompt.
                If ($ie.Document.IHTMLDocument3_documentElement.innerText -ilike '*Enter the Next Code from Your Token*') {
                    Write-Verbose "<#[Redacted]#> MFA Site: Prompt for second token"
                    $key = [Microsoft.VisualBasic.Interaction]::InputBox("Wait for RSA Key to expire and enter the next token code", "RSA Key", $null)
                    ($ie.Document.IHTMLDocument3_getElementsByTagName('input') | Where-Object -property Name -eq 'Data').value = $key
                    $Submit = $ie.Document.IHTMLDocument3_getElementsByTagName('Input') | Where-Object { $_.Type -eq 'Submit' }
                    $Submit.click()
                    Start-Sleep -Seconds 5
                }Else {
                    # Bad login track.  Get new RSA token code and resubmit.
                    Write-Verbose "<#[Redacted]#> MFA Site: bad login"
                    $Submit = ($ie.Document.IHTMLDocument3_getElementsByTagName('input') | Where-Object -property type -eq 'submit')
                    $Submit.click()
                    $key = [Microsoft.VisualBasic.Interaction]::InputBox("Wait for RSA Key to expire and enter the new one", "RSA Key", $null)
                    ($ie.Document.IHTMLDocument3_getElementsByTagName('input') | Where-Object -property type -eq 'password').value = $key
                    ($ie.Document.IHTMLDocument3_getElementsByName('DATA'))[0].value = $user
                    $Submit = $ie.Document.IHTMLDocument3_getElementsByTagName('Input') | Where-Object { $_.Type -eq 'Submit' }
                    $Submit.click()
                    Write-Verbose "Clicking Submit and waiting 2 seconds"
                    Start-Sleep -Seconds 5
                    Write-Verbose "End wait"
                }
            }
            # Correctly authenticated to <#[Redacted]#> MFA Site.  Click on next submit button
            Write-Verbose "<#[Redacted]#> MFA Site: good login"
            while ($ie.busy) { start-sleep -Milliseconds 300 } 
            $Submit = $ie.Document.IHTMLDocument3_getElementsByTagName('input') | Where-Object { $_.Type -eq 'Submit' }
            $Submit.click()
        
        }
        while ($ie.busy) { start-sleep -Milliseconds 300 } 
    }
}Else { 
    # Case for no RSA Key entered in prompt.
    Write-host "No RSA Key Entered" -ForegroundColor Yellow 
}

# Close Internet Explorer
$ie.quit()

#end