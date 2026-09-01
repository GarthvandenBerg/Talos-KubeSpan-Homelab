# Quick points

.\Add-Path.ps1 -New-Path "C:\Tools" -Style Append -Target System

# Detailed Information

#### create file Add-Path.ps1
```
function Add-Path {

  

    param (

        [string]$NewPath,

        [ValidateSet('Prepend','Append')]$Style = 'Prepend',

        [ValidateSet('User', 'System')]$Target = 'User'

    )

  

    try {

        # we need to do this to make sure not to expand the environment variables already inside the PATH

        if ($Target -eq 'User') {

            $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)

        } elseif ($Target -eq 'System') {

            $Key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)

        }

  

        $Path = $Key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames')

  

        # note that system path can only expand system environment variables and vice versa for user environment variables

        # in order to make sure this method is idempotent, we need to check if the new path already exists, this requires having a semicolon at the very end

        if ($Style -eq 'Prepend') {

            $key.SetValue('Path', (Prepend-Idempotent ("$NewPath".TrimEnd(';') + ';') ("$Path".TrimEnd(';') + ';') ';' $false), 'ExpandString')

        } elseif ($Style -eq 'Append') {

            $key.SetValue('Path', (Append-Idempotent ("$NewPath".TrimEnd(';') + ';') ("$Path".TrimEnd(';') + ';') ';' $false), 'ExpandString')

        }

  

        # update the path for the current process as well

        $Env:Path = $key.GetValue('Path', $null)

  

    } finally {

        $key.Dispose()

    }

  

}
```
## Links:
[[Windows]] [[Windows Version No longer supported]]
[[Kuberenetes]] [[]]

2026-05-08 20-27
Year-Month-Date Hour-Minute