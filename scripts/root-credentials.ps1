<#
.SYNOPSIS
    Audit or delete the root user credentials of member accounts
    (roadmap step 3, ADR 0007).

.DESCRIPTION
    Runs from the management account. For each member account it opens a
    short sts:AssumeRoot session, scoped by an AWS-managed task policy, and
    works on that account's root user only:

      Audit   IAMAuditRootUserCredentials. Read-only: shows whether the root
              user has a password, access keys, signing certificates or MFA.
      Delete  IAMDeleteRootUserCredentials. Shows the same, asks for
              confirmation, deletes what exists, then checks again.

    A task policy is a set of Deny statements on top of a root session: deny
    every action except the listed ones, and deny those on anything but the
    root user. So the session can't do anything else, even by mistake.

    Requires centralized root access to be enabled (00-bootstrap,
    root-access.tf) and a valid SSO session for the management profile.

.PARAMETER AccountId
    Member account IDs to work on. Default: every active account in the
    organization except the management account.

.EXAMPLE
    ./scripts/root-credentials.ps1 -Action Audit

.EXAMPLE
    ./scripts/root-credentials.ps1 -Action Delete -AccountId 111122223333
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Audit', 'Delete')]
    [string]$Action,

    [ValidatePattern('^\d{12}$')]
    [string[]]$AccountId,

    # Not $Profile: that name is a PowerShell automatic variable.
    [string]$ManagementProfile = 'management-admin',

    # AssumeRoot has no global endpoint; it must go to a regional STS endpoint.
    [string]$Region = 'eu-west-3'
)

$ErrorActionPreference = 'Stop'

# Runs the AWS CLI and returns parsed JSON. NoSuchEntity means "the root user
# has no such credential", which is an answer, not a failure, so it returns
# $null instead of throwing.
function Invoke-Aws([string[]]$Arguments) {
    $out = & aws @Arguments --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ("$out" -match 'NoSuchEntity') { return $null }
        throw "aws $($Arguments[0..1] -join ' ') failed: $out"
    }
    if ($out) { $out | Out-String | ConvertFrom-Json }
}

function Start-RootSession([string]$Id, [string]$TaskPolicy) {
    (Invoke-Aws @(
        'sts', 'assume-root',
        '--target-principal', $Id,
        '--task-policy-arn', "arn=arn:aws:iam::aws:policy/root-task/$TaskPolicy",
        '--duration-seconds', '900',
        '--region', $Region,
        '--profile', $ManagementProfile
    )).Credentials
}

# Runs one CLI call as the root session. The credentials go in environment
# variables for the duration of the call only, and AWS_PROFILE is cleared so it
# can't pull the call back to the management account. Everything is restored
# afterwards, also when the call fails.
#
# Removal goes through the Env: drive, not [Environment]::SetEnvironmentVariable
# with $null: PowerShell passes $null to a .NET string parameter as "", which
# leaves AWS_PROFILE set to an empty profile name instead of removing it.
function Set-EnvVar([string]$Name, [string]$Value) {
    if ($Value) { Set-Item "Env:$Name" $Value } else { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
}

function Invoke-AsRoot($Credentials, [string[]]$Arguments) {
    $names = 'AWS_PROFILE', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN'
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        Set-EnvVar 'AWS_PROFILE' $null
        Set-EnvVar 'AWS_ACCESS_KEY_ID' $Credentials.AccessKeyId
        Set-EnvVar 'AWS_SECRET_ACCESS_KEY' $Credentials.SecretAccessKey
        Set-EnvVar 'AWS_SESSION_TOKEN' $Credentials.SessionToken
        Invoke-Aws ($Arguments + @('--region', $Region))
    }
    finally {
        foreach ($n in $names) { Set-EnvVar $n $saved[$n] }
    }
}

# Without --user-name, these IAM calls act on the caller, which in a root
# session is the root user.
function Get-RootCredentialStatus($Credentials) {
    [pscustomobject]@{
        Password     = [bool](Invoke-AsRoot $Credentials @('iam', 'get-login-profile'))
        AccessKeys   = @((Invoke-AsRoot $Credentials @('iam', 'list-access-keys')).AccessKeyMetadata |
                         Where-Object { $_ } | ForEach-Object AccessKeyId)
        SigningCerts = @((Invoke-AsRoot $Credentials @('iam', 'list-signing-certificates')).Certificates |
                         Where-Object { $_ } | ForEach-Object CertificateId)
        MfaDevices   = @((Invoke-AsRoot $Credentials @('iam', 'list-mfa-devices')).MFADevices |
                         Where-Object { $_ } | ForEach-Object SerialNumber)
    }
}

function Test-HasCredentials($Status) {
    $Status.Password -or $Status.AccessKeys.Count -or $Status.SigningCerts.Count -or $Status.MfaDevices.Count
}

function Format-Status($Status) {
    "password=$($Status.Password) keys=$($Status.AccessKeys.Count) " +
    "certs=$($Status.SigningCerts.Count) mfa=$($Status.MfaDevices.Count)"
}

# --- Which accounts ---------------------------------------------------------

$managementId = (Invoke-Aws @('sts', 'get-caller-identity', '--profile', $ManagementProfile)).Account
$accounts = (Invoke-Aws @('organizations', 'list-accounts', '--profile', $ManagementProfile)).Accounts
$names = @{}
foreach ($a in $accounts) { $names[$a.Id] = $a.Name }

if (-not $AccountId) {
    # State replaces the older Status field; read whichever the CLI returns.
    $AccountId = $accounts |
        Where-Object { ($_.State ?? $_.Status) -eq 'ACTIVE' -and $_.Id -ne $managementId } |
        ForEach-Object Id
}
if ($AccountId -contains $managementId) {
    throw "Centralized root access covers member accounts only; the management account's root is protected by its own MFA."
}

# --- Do it ------------------------------------------------------------------

foreach ($id in $AccountId) {
    $label = "$($names[$id] ?? '?') ($id)"

    if ($Action -eq 'Audit') {
        $session = Start-RootSession $id 'IAMAuditRootUserCredentials'
        "{0,-28} {1}" -f $label, (Format-Status (Get-RootCredentialStatus $session))
        continue
    }

    $session = Start-RootSession $id 'IAMDeleteRootUserCredentials'
    $before = Get-RootCredentialStatus $session
    "{0,-28} before: {1}" -f $label, (Format-Status $before)

    if (-not (Test-HasCredentials $before)) {
        "{0,-28} nothing to delete" -f ''
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($label, 'Delete root user credentials')) { continue }

    if ($before.Password) { Invoke-AsRoot $session @('iam', 'delete-login-profile') | Out-Null }
    foreach ($k in $before.AccessKeys) {
        Invoke-AsRoot $session @('iam', 'delete-access-key', '--access-key-id', $k) | Out-Null
    }
    foreach ($c in $before.SigningCerts) {
        Invoke-AsRoot $session @('iam', 'delete-signing-certificate', '--certificate-id', $c) | Out-Null
    }
    foreach ($m in $before.MfaDevices) {
        Invoke-AsRoot $session @('iam', 'deactivate-mfa-device', '--serial-number', $m) | Out-Null
        # A virtual MFA device (an authenticator app) is an IAM resource of its
        # own; deactivating only unlinks it. Hardware keys have no such resource.
        if ($m -like 'arn:aws:iam::*:mfa/*') {
            Invoke-AsRoot $session @('iam', 'delete-virtual-mfa-device', '--serial-number', $m) | Out-Null
        }
    }

    $after = Get-RootCredentialStatus $session
    "{0,-28} after:  {1}" -f $label, (Format-Status $after)
    if (Test-HasCredentials $after) { Write-Warning "$label still has root credentials." }
}
