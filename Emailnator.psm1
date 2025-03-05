#!/usr/bin/env pwsh
using namespace System.Net.Http
using namespace System.Collections.Generic
using namespace Microsoft.PowerShell.Commands

#region    Classes
<#
.SYNOPSIS
  Main class
.DESCRIPTION
  Provides an interface for interacting with the EmailNator temporary email service
.EXAMPLE
  #You need to install the Newtonsoft.Json NuGet Package
  # Install-Package Newtonsoft.Json -Scope CurrentUser

  # 1.  Create Instance (with options)
  $EmailNator = [EmailNator]::new($null, $null, $true, $true, $true, $true) # Example with all options enabled

  # 2.  Get the generated email address
  Write-Host "Generated Email: $($EmailNator.Email)"

  # 3.  Reload messages (without waiting)
  $newMessages = $EmailNator.Reload()
  Write-Host "New messages (immediate): $($newMessages.Count)"
  Write-Host ($newMessages | Format-Table | Out-String) # Display new messages


  # 4. Reload, waiting for a specific message (example: subject contains "Verification")
  $verificationMessages = $EmailNator.Reload($true, 5, 60, { param($msg) $msg.subject -like "*Verification*" })
  Write-Host "Verification messages found: $($verificationMessages.Count)"
  Write-Host ($verificationMessages | Format-Table |Out-String)

  #5. Open a message
  if($verificationMessages.Count -gt 0){
    $messageContent = $EmailNator.Open($verificationMessages[0].messageID)
    Write-Host "Message Content:`n$messageContent"
  }

  #6 Get a specific email, using the filter from the reload example
  $firstVerificationMessage = $EmailNator.Get({param($msg) $msg.subject -like "*Verification*"})
  if($firstVerificationMessage){
    Write-Host "Got First Verification Message by filter"
  }

  # 7.  Clean up (important!)
  $EmailNator.Dispose()
.LINK
  Official_api : https://rapidapi.com/johndevz/api/gmailnator
#>
class EmailNator {
  hidden [HttpClient] $_client
  hidden [string] $_email
  hidden [List[string]] $_inboxAds = [List[string]]::new()
  hidden [List[Dictionary[string, string]]] $_inbox = [List[Dictionary[string, string]]]::new()
  hidden [List[Dictionary[string, string]]] $_newMsgs
  hidden [string] $_token
  hidden [WebRequestSession] $_webSession

  EmailNator() {
    $this.Initialize($null, $null, $true, $true, $true, $true)
  }
  EmailNator([hashtable]$Cookies, [hashtable]$Headers, [bool]$Domain, [bool]$Plus, [bool]$Dot, [bool]$GoogleMail) {
    $this.Initialize($Cookies, $Headers, $Domain, $Plus, $Dot, $GoogleMail)
  }

  # Initialization method (called by the constructor)
  [void] Initialize([hashtable]$Cookies, [hashtable]$Headers, [bool]$Domain, [bool]$Plus, [bool]$Dot, [bool]$GoogleMail) {
    # --- Token and Cookie Acquisition (like TempEmail.py) ---
    $initialHeaders = @{
      "User-Agent" = [Microsoft.PowerShell.Commands.PSUserAgent].GetMembers('Static, NonPublic').Where{ $_.Name -eq 'UserAgent' }.GetValue($null, $null) #Get default user agent ie (Net.WebClient).Headers['User-Agent']
      "Accept"     = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"
    }
    try {
      $initialResponse = Invoke-WebRequest -Uri "https://www.EmailNator.com/" -Headers $initialHeaders -UseBasicParsing -SkipHttpErrorCheck
      $initialResponse | Select-Object @{l = 'Status'; e = { $_.StatusDescription } }, @{l = 'Code'; e = { $_.StatusCode } } | Format-List | Out-String | Write-Host -f Yellow
      $this._token = ($initialResponse.Headers.'Set-Cookie' | Select-String -Pattern "XSRF-TOKEN=([^;]+)").Matches.Groups[1].Value.SubString(0, 339) + "="

      # Update cookies with the ones from the initial request.
      if (-not $Cookies) { $Cookies = @{} }
      $initialResponse.Cookies.GetCookies([uri]"https://www.EmailNator.com") | ForEach-Object {
        $Cookies[$_.Name] = $_.Value
      }
    } catch {
      Write-Warning "Failed to get initial token and cookies: $_"
      # Consider retrying here, similar to the Python code
      #  For simplicity, we'll throw for now, but a retry loop would be better.
      throw "Failed to get initial token and cookies"
    }

    # --- End Token and Cookie Acquisition ---

    # Default headers (if none provided)
    if (!$Headers) {
      $Headers = @{
        'accept'                      = 'application/json, text/plain, */*'
        'accept-language'             = 'en-US,en;q=0.9'
        'content-type'                = 'application/json'
        'dnt'                         = '1'
        'origin'                      = 'https://www.EmailNator.com'
        'priority'                    = 'u=1, i'
        'referer'                     = 'https://www.EmailNator.com/'
        'sec-ch-ua'                   = '"Not;A=Brand";v="24", "Chromium";v="128"'
        'sec-ch-ua-arch'              = '"x86"'
        'sec-ch-ua-bitness'           = '"64"'
        'sec-ch-ua-full-version'      = '"128.0.6613.120"'
        'sec-ch-ua-full-version-list' = '"Not;A=Brand";v="24.0.0.0", "Chromium";v="128.0.6613.120"'
        'sec-ch-ua-mobile'            = '?0'
        'sec-ch-ua-model'             = '""'
        'sec-ch-ua-platform'          = '"Windows"'
        'sec-ch-ua-platform-version'  = '"19.0.0"'
        'sec-fetch-dest'              = 'empty'
        'sec-fetch-mode'              = 'cors'
        'sec-fetch-site'              = 'same-origin'
        'user-agent'                  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
        'x-requested-with'            = 'XMLHttpRequest'
      }
    }
    if ($Cookies -and $Cookies['XSRF-TOKEN']) {
      $Headers['x-xsrf-token'] = [System.Web.HttpUtility]::UrlDecode($Cookies['XSRF-TOKEN'])
    }

    # Create HttpClient
    $handler = [HttpClientHandler]::new()
    # If Cookies are not null or empty
    if ($Cookies) {
      $cookieContainer = [System.Net.CookieContainer]::new()
      foreach ($key in $Cookies.Keys) {
        $cookie = [System.Net.Cookie]::new($key, $Cookies[$key], "/", ".EmailNator.com")  # Setting the path and domain is crucial
        $cookieContainer.Add($cookie)
      }
      $handler.CookieContainer = $cookieContainer
    }

    $this._client = [HttpClient]::new($handler)
    foreach ($header in $Headers.Keys) {
      $this._client.DefaultRequestHeaders.Add($header, $Headers[$header])
    }
    # Prepare data for email generation
    $data = @{ email = @() }

    #Simplified domain/gmail selection based on TempEmail.py
    if ($Domain) { $data.email += 'domain' }
    elseif ($Dot) { $data.email += 'dotGmail' } # Prioritize dotGmail if both dot and plus are true
    elseif ($Plus) { $data.email += 'plusGmail' }
    if ($GoogleMail) { $data.email += 'googleMail' }  #googleMail is independent

    # Generate email address
    $retries = 0
    while ($retries -lt 5) {
      # Added a retry loop.
      try {
        $response = $this.PostAsync('https://www.EmailNator.com/generate-email', $data).Result | ConvertFrom-Json
        if ($response.email) {
          $this._email = $response.email[0]
          break
        }
      } catch {
        Write-Warning "Failed to generate email. Retrying... ($_)"
        Start-Sleep -Seconds 2
        $retries++
      }
    }
    if (!$this._email) {
      throw "Failed to get email address after multiple retries."
    }

    # Get initial message list (for ads)
    $response = $this.PostAsync('https://www.EmailNator.com/message-list', @{ email = $this._email }).Result | ConvertFrom-Json
    if ($response.messageData) {
      foreach ($msg in $response.messageData) {
        $this._inboxAds.Add($msg.messageID)
      }
    }
  }

  # Helper method for POST requests (using Invoke-RestMethod)
  [string] PostAsync([string]$Url, [object]$Body) {
    $jsonBody = $Body | ConvertTo-Json -Depth 10 # Important: Increase -Depth if nested objects are truncated
    $response = Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Body $jsonBody -WebSession $this.GetWebSession()
    return $response
  }

  # Public Properties (Get-only for read-only access)
  [string] get_Email() { return $this._email }
  [List[Dictionary[string, string]]] get_Inbox() { return $this._inbox }
  [List[Dictionary[string, string]]] get_NewMessages() { return $this._newMsgs }

  #Reload
  [List[Dictionary[string, string]]] Reload([bool]$Wait, [int]$Retry = 5, [int]$Timeout = 30, [scriptblock]$WaitFor) {
    $this._newMsgs = [List[Dictionary[string, string]]]::new()
    $start = Get-Date
    $wait_for_found = $false
    while ($true) {
      try {
        $response = $this.PostAsync('https://www.EmailNator.com/message-list', @{ email = $this._email }) | ConvertFrom-Json
        if ($response -and $response.messageData) {
          foreach ($msg in $response.messageData) {
            $msgDict = @{}
            foreach ($prop in $msg.PSObject.Properties) {
              $msgDict[$prop.Name] = $prop.Value
            }

            if ($this._inboxAds -notcontains $msgDict.messageID -and ($this._inbox | ForEach-Object { $_.messageID }) -notcontains $msgDict.messageID) {
              $this._newMsgs.Add($msgDict)

              if ($WaitFor) {
                if (& $WaitFor $msgDict) {
                  $wait_for_found = $true
                }
              }
            }
          }
        }
        if (($Wait -and $this._newMsgs.Count -eq 0) -or $WaitFor) {
          if ($wait_for_found) {
            break
          }

          if (((Get-Date) - $start).TotalSeconds -gt $Timeout) {
            return  $this._newMsgs # Return what we found, even if timed out.
          }
          Start-Sleep -Seconds $Retry
        } else {
          break
        }
      } catch {
        Write-Warning "An error occurred during reload: $_"
        # Consider adding retry logic here as well.
      }
      $this._inbox.AddRange($this._newMsgs)
    }
    return $this._newMsgs
  }

  # Open a specific message
  [string] Open([string]$MessageId) {
    try {
      # --- Check for invalid Message ID (like TempEmail.py) ---
      if (![string]::IsNullOrEmpty($MessageId)) {
        # Attempt to get the message list and find the corresponding messageID
        $messageList = $this.PostAsync('https://www.EmailNator.com/message-list', @{ email = $this._email }) | ConvertFrom-Json
        if ($messageList -and $messageList.messageData) {
          $message = $messageList.messageData | Where-Object { $_.messageID -eq $MessageId }
          if (-not $message) {
            Write-Warning "Invalid message ID: $MessageId"
            return $null # Or throw an exception: throw "Invalid message ID"
          }
          # --- Get Mail Content ---
          $response = $this.PostAsync('https://www.EmailNator.com/message-list', @{ email = $this._email; messageID = $MessageId })
          # Check for server error (like TempEmail.py)
          if ($response -and ($response -match "Server Error")) {
            Write-Warning "Server Error.  You may need to wait and retry."
            # In a real application, you might want to implement a retry mechanism here.
            return $null
          }
          return $response
        } else {
          Write-Warning "Could not retrieve Message List"
          return $null
        }
      } else {
        Write-Warning "Message ID cannot be null or empty."
        return $null  # Or throw an exception
      }
    } catch {
      Write-Warning "An error occurred when opening the message: $_"
      return $null  # Return null on error.  Or throw.
    }
  }

  # Get messages based on a filter function
  [Dictionary[string, string]] Get([scriptblock]$Func, [List[Dictionary[string, string]]]$Messages = $null) {
    $targetMessages = if ($Messages) { $Messages } else { $this._inbox }
    foreach ($msg in $targetMessages) {
      if (& $Func $msg) {
        return $msg
      }
    }
    return $null # if no match found
  }

  # WebSession creation method to reuse the session.
  [WebRequestSession] GetWebSession() {
    if (!$this._webSession) {
      $this._webSession = [WebRequestSession]::new()
    }
    # Transfer cookies from HttpClientHandler to WebRequestSession
    $cookieContainer = $this._client.Handler.CookieContainer
    if ($cookieContainer) {
      $allCookies = $cookieContainer.GetCookies([uri]"https://www.EmailNator.com")
      foreach ($cookie in $allCookies) {
        $this._webSession.Cookies.Add($cookie)
      }
    }
    return $this._webSession
  }

  # Dispose method to clean up HttpClient (important for long-running scripts)
  [void] Dispose() {
    if ($this._client) {
      $this._client.Dispose()
      $this._client = $null
    }
  }
}

#endregion Classes

# Types that will be available to users when they import the module.
$typestoExport = @(
  [EmailNator]
)
$TypeAcceleratorsClass = [PsObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
foreach ($Type in $typestoExport) {
  if ($Type.FullName -in $TypeAcceleratorsClass::Get.Keys) {
    $Message = @(
      "Unable to register type accelerator '$($Type.FullName)'"
      'Accelerator already exists.'
    ) -join ' - '
    "TypeAcceleratorAlreadyExists $Message" | Write-Debug
  }
}
# Add type accelerators for every exportable type.
foreach ($Type in $typestoExport) {
  $TypeAcceleratorsClass::Add($Type.FullName, $Type)
}
# Remove type accelerators when the module is removed.
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
  foreach ($Type in $typestoExport) {
    $TypeAcceleratorsClass::Remove($Type.FullName)
  }
}.GetNewClosure();

$scripts = @();
$Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += $Public

foreach ($file in $scripts) {
  Try {
    if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
    . "$($file.fullname)"
  } Catch {
    Write-Warning "Failed to import function $($file.BaseName): $_"
    $host.UI.WriteErrorLine($_)
  }
}

$Param = @{
  Function = $Public.BaseName
  Cmdlet   = '*'
  Alias    = '*'
  Verbose  = $false
}
Export-ModuleMember @Param

