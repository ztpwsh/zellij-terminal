<#
    Manifest - is the module publishable, and does it tell the truth?

    A manifest is the only part of the module that is read before anything
    runs, so a lie in it fails in ways that do not point at it. Two of those
    have bitten this repo already:

      Wildcards in FunctionsToExport. `zt` autoloads only because the command
      is named in the manifest; with '*' PowerShell has to import every module
      on the path to find out who owns the name, so the alias simply does not
      exist until you import by hand.

      Drift between the manifest's FunctionsToExport and the psm1's
      Export-ModuleMember. The manifest filters the module's exports, it cannot
      add to them, so a name listed in one and not the other is a command that
      documents itself as public and is not there. Nothing warns. Import-Module
      succeeds, Get-Command comes back empty, and the caller assumes a typo.
      That is what the two "in the manifest but not exported" / "exported but
      not in the manifest" tests below exist to catch, in both directions.

    Everything here is static: read the psd1, import the module, compare. No
    Zellij, no session, no config on disk. The suite is green on a machine with
    none of the rig installed.

    Pester 5/6.
#>

# Discovery-time, because -Skip is evaluated before BeforeAll has run. The
# committer's name is never written into this repo (anonymised on purpose), so
# it has to be discovered at run time to be asserted against at all.
$script:GitIdentity = @()
try {
    $raw = @()
    $raw += (& git -C $PSScriptRoot config user.name  2>$null)
    $email = (& git -C $PSScriptRoot config user.email 2>$null)
    if ($email) { $raw += ($email -split '@')[0] }

    $script:GitIdentity = @(
        $raw |
            Where-Object { $_ } |
            ForEach-Object { $_ -split '[^A-Za-z]+' } |
            Where-Object { $_.Length -ge 4 } |
            ForEach-Object { $_.ToLowerInvariant() } |
            Sort-Object -Unique
    )
}
catch {
    # No git, or no identity configured. The test that uses this skips.
    $script:GitIdentity = @()
}

BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..\module\ZellijTerminal\ZellijTerminal.psd1'

    # The literal contents, before PowerShell expands anything. Test-ModuleManifest
    # resolves '*' into the real function list, so it is no use for proving a
    # wildcard is absent - only the raw data file can do that.
    $script:Raw = Import-PowerShellDataFile -LiteralPath $script:ManifestPath

    $script:Module   = Import-Module $script:ManifestPath -Force -PassThru -ErrorAction Stop
    $script:Declared = @($script:Raw.FunctionsToExport)
    $script:Actual   = @($script:Module.ExportedFunctions.Keys)
}

AfterAll {
    Remove-Module ZellijTerminal -Force -ErrorAction SilentlyContinue
}

Describe 'Manifest loads' {

    It 'passes Test-ModuleManifest' {
        # The gate PowerShellGet applies at publish time. Failing it means the
        # module cannot be shipped, whatever else works locally.
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } |
            Should -Not -Throw
    }

    It 'points RootModule at a file that is actually there' {
        $root = Join-Path (Split-Path -Parent $script:ManifestPath) $script:Raw.RootModule
        Test-Path -LiteralPath $root | Should -BeTrue
    }

    It 'carries a GUID and a version that parse' {
        { [guid]$script:Raw.GUID }       | Should -Not -Throw
        { [version]$script:Raw.ModuleVersion } | Should -Not -Throw
    }
}

Describe 'Export lists are explicit' {

    It 'lists functions by name, never a wildcard' {
        $script:Raw.FunctionsToExport | Should -BeOfType ([string])
        $script:Raw.FunctionsToExport | Should -Not -Contain '*'
        @($script:Raw.FunctionsToExport).Count | Should -BeGreaterThan 0
    }

    It 'lists aliases by name, never a wildcard' {
        # zt and zac are the whole point of the module. A wildcard here costs
        # them their autoload.
        $script:Raw.AliasesToExport | Should -Not -Contain '*'
        @($script:Raw.AliasesToExport).Count | Should -BeGreaterThan 0
    }

    It 'declares empty cmdlet and variable lists rather than leaving them wild' {
        # Omitting these entirely means '*', which is the same autoload problem
        # with none of the visibility.
        @($script:Raw.CmdletsToExport)   | Should -Not -Contain '*'
        @($script:Raw.VariablesToExport) | Should -Not -Contain '*'
        @($script:Raw.CmdletsToExport).Count   | Should -Be 0
        @($script:Raw.VariablesToExport).Count | Should -Be 0
    }
}

Describe 'Declared exports match real exports' {

    It 'exports every function the manifest names' {
        # Fails when a function is added to FunctionsToExport but not to
        # Export-ModuleMember in the psm1. The name is then public on paper and
        # missing in the shell, with no error to say so.
        $missing = @($script:Declared | Where-Object { $_ -notin $script:Actual })
        ($missing -join ', ') | Should -Be '' -Because 'these are in FunctionsToExport but Export-ModuleMember in the psm1 does not list them, so Import-Module does not produce them'
    }

    It 'names every function it exports' {
        # The other direction: a command that works but is undocumented and
        # unautoloadable, because the manifest never mentions it.
        $extra = @($script:Actual | Where-Object { $_ -notin $script:Declared })
        ($extra -join ', ') | Should -Be '' -Because 'these are exported by the module but absent from FunctionsToExport'
    }

    It 'exports every alias the manifest names' {
        $aliases = @($script:Module.ExportedAliases.Keys)
        foreach ($a in @($script:Raw.AliasesToExport)) {
            $aliases | Should -Contain $a
        }
    }

    It 'points each alias at a function the manifest also exports' {
        # An alias to an unexported function resolves to nothing at the prompt.
        foreach ($a in @($script:Raw.AliasesToExport)) {
            $target = $script:Module.ExportedAliases[$a].ResolvedCommandName
            $script:Declared | Should -Contain $target -Because "alias $a resolves to $target"
        }
    }
}

Describe 'Command naming' {

    It 'uses an approved verb for every exported function' {
        # Unapproved verbs make Import-Module print a warning on every load,
        # and the warning is the first thing a new user sees.
        $approved = (Get-Verb).Verb
        $bad = @(
            $script:Declared |
                Where-Object { ($_ -split '-')[0] -notin $approved }
        )
        ($bad -join ', ') | Should -Be ''
    }

    It 'prefixes every exported function with the module noun' {
        # One noun, so tab completion after `Get-Zellij` shows the whole surface
        # and nothing else claims a bare name in the global scope.
        $bad = @($script:Declared | Where-Object { $_ -notmatch '^[A-Z][a-z]+-ZellijTerminal' })
        ($bad -join ', ') | Should -Be ''
    }
}

Describe 'Platform contract' {

    It 'sets the floor at PowerShell 7.0' {
        # Not 5.1. install.ps1 junctions the module onto the pwsh 7 module path,
        # which Windows PowerShell does not scan, so a 5.1 user can satisfy a
        # 5.1 manifest and still have nothing autoload. The header on the psd1
        # records why that was changed.
        [version]$script:Raw.PowerShellVersion | Should -Be ([version]'7.0')
    }

    It 'declares Core, and only Core' {
        @($script:Raw.CompatiblePSEditions) | Should -Contain 'Core'
        @($script:Raw.CompatiblePSEditions) | Should -Not -Contain 'Desktop'
    }
}

Describe 'Publishable metadata' {

    BeforeAll {
        $script:PSData = $script:Raw.PrivateData.PSData
    }

    It 'gives an absolute https LicenseUri' {
        $uri = [uri]$script:PSData.LicenseUri
        $uri.IsAbsoluteUri | Should -BeTrue
        $uri.Scheme        | Should -Be 'https'
    }

    It 'gives an absolute https ProjectUri' {
        # Relative or http URIs are rejected by the gallery, and the rejection
        # arrives at publish time rather than here.
        $uri = [uri]$script:PSData.ProjectUri
        $uri.IsAbsoluteUri | Should -BeTrue
        $uri.Scheme        | Should -Be 'https'
    }

    It 'has a description and at least one tag' {
        $script:Raw.Description | Should -Not -BeNullOrEmpty
        @($script:PSData.Tags).Count | Should -BeGreaterThan 0
    }
}

Describe 'Attribution stays anonymous' {

    BeforeAll {
        # CompanyName is '' in this manifest, which is legal and deliberate.
        # Joined so a name is caught wherever it was pasted.
        $script:Attribution = @(
            $script:Raw.Author
            $script:Raw.CompanyName
            $script:Raw.Copyright
        ) -join ' '
    }

    It 'credits the project rather than a person' {
        $script:Raw.Author | Should -Be 'zt contributors'
        $script:Raw.Copyright | Should -Match 'zt contributors'
    }

    It 'does not carry the name of whoever is logged in' -Skip:([Environment]::UserName.Length -lt 4) {
        # The usual way a real name gets in: a template, or a tool that fills
        # Author from the account. The repo is anonymised as a hard rule, so
        # the check has to compare against something discovered rather than
        # written down here.
        $script:Attribution | Should -Not -Match ([regex]::Escape([Environment]::UserName))
    }

    It 'does not carry the committer identity from git' -Skip:($script:GitIdentity.Count -eq 0) {
        foreach ($token in $script:GitIdentity) {
            $script:Attribution | Should -Not -Match ([regex]::Escape($token)) -Because "'$token' comes from git config on this machine and must not appear in the manifest"
        }
    }
}

Describe 'Help' {

    It 'gives every exported function a SYNOPSIS' {
        # Get-Help invents a synopsis from the syntax line when comment-based
        # help is absent, so "has help" is not the same as "returned something".
        # A synopsis that starts with the function's own name is that fallback.
        #
        # Run inside the module's scope so the check covers everything the
        # manifest declares, including any name that is not currently exported -
        # otherwise a missing export would hide a missing synopsis behind it.
        $bad = & $script:Module {
            param($names)
            foreach ($n in $names) {
                $help = Get-Help -Name $n -ErrorAction SilentlyContinue
                $synopsis = ''
                if ($help) { $synopsis = [string]$help.Synopsis }
                if ([string]::IsNullOrWhiteSpace($synopsis)) { $n; continue }
                if ($synopsis -match ('^\s*' + [regex]::Escape($n) + '\b')) { $n }
            }
        } $script:Declared

        (@($bad) -join ', ') | Should -Be ''
    }
}
