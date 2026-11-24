<#
.SYNOPSIS
    Summarize system information on a Windows host in the format of
    Percona Toolkit's pt-summary.

.DESCRIPTION
    pt-summary.ps1 collects hardware, operating system, storage, network and
    process information from a Windows host and prints a report with the same
    sections and layout as pt-summary from Percona Toolkit. Sections that only
    exist on Linux are replaced by their Windows equivalents:

      SELinux                    -> Windows Defender and installed antivirus
      Disk schedulers            -> Physical disks, sector sizes and write cache
      fdisk partitioning         -> Partitions with offset alignment
      LVM volumes / groups       -> Storage Spaces virtual disks / pools
      vmstat                     -> Raw performance counters sampled every second
      Transparent huge pages     -> Memory compression, Lock Pages in Memory

    The tool is read-only. It uses CIM classes and raw performance counters,
    which are not localized, so it works on non-English Windows.

    Run it as Administrator for the complete report. As a standard user, the
    write cache state, Defender exclusions, memory compression and Lock Pages in
    Memory are reported as unknown.

.PARAMETER Sleep
    How many seconds to sample performance counters for the vmstat section.
    Default 5. Use 0 to skip the samples.

.PARAMETER SaveSamples
    Save the collected data in this directory, as pt-summary-samples.json.

.PARAMETER ReadSamples
    Create a report from the pt-summary-samples.json file in this directory,
    without collecting anything. Works on any OS with PowerShell 5.1 or 7+.

.PARAMETER OutFile
    Also write the report to this file, UTF-8 encoded.

.PARAMETER NoSummarizeMounts
    Do not report on mounted filesystems and disk usage.

.PARAMETER NoSummarizeNetwork
    Do not report on network controllers and configuration.

.PARAMETER NoSummarizeProcesses
    Do not report on top processes and the vmstat samples.

.PARAMETER Version
    Print the tool's version and exit.

.PARAMETER Help
    Print help and exit.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\pt-summary.ps1

.EXAMPLE
    .\pt-summary.ps1 -SaveSamples C:\temp\pts -OutFile C:\temp\pts\pt-summary.txt

.EXAMPLE
    pwsh ./pt-summary.ps1 -ReadSamples ./pts
#>
[CmdletBinding()]
param(
    [int]$Sleep = 5,
    [string]$SaveSamples,
    [string]$ReadSamples,
    [string]$OutFile,
    [switch]$NoSummarizeMounts,
    [switch]$NoSummarizeNetwork,
    [switch]$NoSummarizeProcesses,
    [switch]$Version,
    [switch]$Help
)

$ToolVersion  = '0.1.0'
$SamplesFile  = 'pt-summary-samples.json'
$script:Inv   = [Globalization.CultureInfo]::InvariantCulture
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Out   = New-Object System.Collections.Generic.List[string]
$script:NVLen = 12

if ($Help)    { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }
if ($Version) { "pt-summary.ps1 $ToolVersion"; exit 0 }

# ###########################################################################
# Formatting helpers, ported from pt-summary's report_formatting package.
# ###########################################################################

# Culture-invariant String.Format, so decimals use "." on every locale.
function Fmt {
    $f = [string]$args[0]
    $rest = New-Object 'object[]' ($args.Count - 1)
    for ($i = 1; $i -lt $args.Count; $i++) { $rest[$i - 1] = $args[$i] }
    [string]::Format($script:Inv, $f, $rest)
}

function Say([string]$s) { $script:Out.Add($s) }

function Section([string]$name) {
    $line = "# $name "
    if ($line.Length -lt 62) { $line += '#' * (62 - $line.Length) } else { $line += '#' }
    Say $line
}

function NameVal($name, $value) {
    Say (Fmt ('{0,' + $script:NVLen + '} | {1}') $name $value)
}

function Shorten($num, [int]$prec = 2, [double]$div = 1024) {
    if ($null -eq $num -or "$num" -eq '') { return '' }
    $n = [double]$num
    $unit = if     ($n -ge 1125899906842624) { 'P' }
            elseif ($n -ge 1099511627776)    { 'T' }
            elseif ($n -ge 1073741824)       { 'G' }
            elseif ($n -ge 1048576)          { 'M' }
            elseif ($n -ge 1024)             { 'k' }
            else                             { '' }
    while ($n -ge $div) { $n /= $div }
    Fmt ('{0:F' + $prec + '}{1}') $n $unit
}

# Same rounding as pt-summary's fuzzy_formula: keeps the shape of a number
# while hiding exact values.
function Fuzz($v) {
    if ($null -eq $v) { return 0 }
    $v = [double]$v
    if ($v -le 10) { return [math]::Round($v) }
    $factor = 1.0
    while ($true) {
        if ($v -le 50 * $factor)  { return [math]::Round($v / (5 * $factor)) * 5 * $factor }
        if ($v -le 100 * $factor) { return [math]::Round($v / (10 * $factor)) * 10 * $factor }
        if ($v -le 250 * $factor) { return [math]::Round($v / (25 * $factor)) * 25 * $factor }
        $factor *= 10
    }
}

function FuzzyPct($one, $two) {
    if ($null -eq $two -or [double]$two -le 0) { return '0%' }
    $pct = [math]::Truncate([double]$one / [double]$two * 100)
    "$(Fuzz $pct)%"
}

# "8x2200, 4x1800" from a list of values, like pt-summary's group_concat.
function GroupConcat($values) {
    $groups = @($values | Where-Object { "$_" -ne '' } | Group-Object | Sort-Object Name)
    ($groups | ForEach-Object { "$($_.Count)x$($_.Name)" }) -join ', '
}

# Lookup by numeric code. The Storage module rewrites some codes as strings
# ("SSD", "GPT") once loaded, so non-numeric keys are returned unchanged.
function Map($table, $key, $default = $null) {
    $n = 0
    if ($null -ne $key -and -not [int]::TryParse("$key", [ref]$n)) { return "$key" }
    if ($null -ne $key -and $table.ContainsKey($n)) { return $table[$n] }
    if ($null -ne $default) { return $default }
    return "$key"
}

function Bps($bits) {
    if ($null -eq $bits -or [double]$bits -le 0 -or [double]$bits -ge 9e18) { return '-' }
    $b = [double]$bits
    if ($b -ge 1e9) { return (Fmt '{0:0.#} Gbps' ($b / 1e9)) }
    if ($b -ge 1e6) { return (Fmt '{0:0.#} Mbps' ($b / 1e6)) }
    Fmt '{0:0.#} Kbps' ($b / 1e3)
}

# ###########################################################################
# Lookup tables (SMBIOS, Storage Management API, TCP stack).
# ###########################################################################

$ChassisTypes = @{ 1='Other'; 2='Unknown'; 3='Desktop'; 4='Low Profile Desktop'; 5='Pizza Box';
    6='Mini Tower'; 7='Tower'; 8='Portable'; 9='Laptop'; 10='Notebook'; 11='Hand Held';
    12='Docking Station'; 13='All in One'; 14='Sub Notebook'; 15='Space-Saving'; 16='Lunch Box';
    17='Main System Chassis'; 18='Expansion Chassis'; 19='SubChassis'; 20='Bus Expansion Chassis';
    21='Peripheral Chassis'; 22='Storage Chassis'; 23='Rack Mount Chassis'; 24='Sealed-Case PC';
    25='Multi-system chassis'; 28='Blade'; 29='Blade Enclosure'; 30='Tablet'; 31='Convertible';
    32='Detachable'; 33='IoT Gateway'; 34='Embedded PC'; 35='Mini PC'; 36='Stick PC' }
$DomainRoles = @{ 0='Standalone Workstation'; 1='Member Workstation'; 2='Standalone Server';
    3='Member Server'; 4='Backup Domain Controller'; 5='Primary Domain Controller' }
$FormFactors = @{ 0='Unknown'; 1='Other'; 2='SIP'; 3='DIP'; 4='ZIP'; 5='SOJ'; 6='Proprietary';
    7='SIMM'; 8='DIMM'; 9='TSOP'; 10='PGA'; 11='RIMM'; 12='SODIMM'; 13='SRIMM'; 14='SMD';
    15='SSMP'; 16='QFP'; 17='TQFP'; 18='SOIC'; 19='LCC'; 20='PLCC'; 21='BGA'; 22='FPBGA'; 23='LGA' }
$MemTypes = @{ 0='Unknown'; 1='Other'; 2='Unknown'; 3='DRAM'; 4='EDRAM'; 5='VRAM'; 6='SRAM'; 7='RAM';
    8='ROM'; 9='FLASH'; 10='EEPROM'; 11='FEPROM'; 12='EPROM'; 13='CDRAM'; 14='3DRAM'; 15='SDRAM';
    16='SGRAM'; 17='RDRAM'; 18='DDR'; 19='DDR2'; 20='DDR2 FB-DIMM'; 24='DDR3'; 25='FBD2'; 26='DDR4';
    27='LPDDR'; 28='LPDDR2'; 29='LPDDR3'; 30='LPDDR4'; 31='Logical NV'; 32='HBM'; 33='HBM2';
    34='DDR5'; 35='LPDDR5'; 36='HBM3' }
$TypeDetailBits = @{ 8='Fast-paged'; 16='Static column'; 32='Pseudo-static'; 64='RAMBUS';
    128='Synchronous'; 256='CMOS'; 512='EDO'; 1024='Window DRAM'; 2048='Cache DRAM';
    4096='Non-volatile'; 8192='Registered'; 16384='Unbuffered'; 32768='LRDIMM' }
$CacheAssoc = @{ 1='Other'; 2='Unknown'; 3='Direct Mapped'; 4='2-way Set-associative';
    5='4-way Set-associative'; 6='Fully Associative'; 7='8-way Set-associative';
    8='16-way Set-associative'; 9='12-way Set-associative'; 10='24-way Set-associative';
    11='32-way Set-associative'; 12='48-way Set-associative'; 13='64-way Set-associative';
    14='20-way Set-associative' }
$CacheLevels  = @{ 3='Level 1'; 4='Level 2'; 5='Level 3' }
$CacheTypes   = @{ 3='Instruction'; 4='Data'; 5='Unified' }
$CacheWrite   = @{ 3='Write Back'; 4='Write Through'; 5='Varies' }
$BusTypes = @{ 0='Unknown'; 1='SCSI'; 2='ATAPI'; 3='ATA'; 4='1394'; 5='SSA'; 6='FibreChannel';
    7='USB'; 8='RAID'; 9='iSCSI'; 10='SAS'; 11='SATA'; 12='SD'; 13='MMC'; 14='Virtual';
    15='FileBackedVirtual'; 16='StorageSpaces'; 17='NVMe'; 18='SCM'; 19='UFS' }
$MediaTypes   = @{ 0='Unspecified'; 3='HDD'; 4='SSD'; 5='SCM' }
$HealthStatus = @{ 0='Healthy'; 1='Warning'; 2='Unhealthy'; 5='Unknown' }
$PartStyles   = @{ 0='RAW'; 1='MBR'; 2='GPT' }
$ProvTypes    = @{ 0='Unknown'; 1='Thin'; 2='Fixed' }
$GptTypes = @{
    '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' = 'EFI System'
    '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' = 'MS Reserved'
    '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' = 'Basic Data'
    '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' = 'Recovery'
    '{5808c8aa-7e8f-42e0-85d2-e1e90434cfb3}' = 'LDM Metadata'
    '{af9b60a0-1431-4f62-bc68-3311714a69ad}' = 'LDM Data'
    '{e75caf8f-f680-4cee-afa3-b001e56efc2d}' = 'Storage Spaces'
}
$MbrTypes = @{ 1='FAT12'; 4='FAT16'; 5='Extended'; 6='Huge'; 7='IFS (NTFS)'; 12='FAT32'; 39='Recovery' }
$PowerPlans = @{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Ultimate Performance'
}

# Processes worth calling out on a database host. Name without ".exe".
$NotableRegex = '^(mysqld|mariadbd|mongod|mongos|postgres|pg_ctl|sqlservr|redis-server|valkey-server|memcached|pmm-agent|vmagent|node_exporter|mysqld_exporter|mongodb_exporter|postgres_exporter|sshd)$'

# ###########################################################################
# Collection. Every collector is isolated: a failure becomes a warning in the
# report instead of stopping the tool.
# ###########################################################################

$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:ShowSteps = $VerbosePreference -ne 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
function Step([string]$what) {
    Write-Progress -Activity 'pt-summary' -Status $what
    if ($script:ShowSteps) {
        [Console]::Error.WriteLine((Fmt 'VERBOSE: {0,6:0.0}s {1}' $script:Clock.Elapsed.TotalSeconds $what))
    }
}

# A collector that outputs nothing returns $null, never an empty
# AutomationNull (which serializes to {} and reads back as a truthy object).
function Safe([string]$what, [scriptblock]$sb) {
    try {
        $r = & $sb
        if ($null -eq $r) { return $null }
        return ,$r
    }
    catch {
        $msg = ($_.Exception.Message -split "`r?`n")[0].Trim()
        $script:Warnings.Add("${what}: $msg")
        $null
    }
}

function Cim([string]$class, [string]$ns = 'root/cimv2', [string]$filter) {
    $p = @{ ClassName = $class; Namespace = $ns; ErrorAction = 'Stop' }
    if ($filter) { $p.Filter = $filter }
    Get-CimInstance @p
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function Get-ProcessSnapshot {
    @(Cim Win32_PerfRawData_PerfProc_Process |
        Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
        Select-Object @{n='Name';e={$_.Name -replace '#\d+$',''}}, @{n='Pid';e={[int]$_.IDProcess}},
            @{n='Ppid';e={[int]$_.CreatingProcessID}}, @{n='Cpu';e={[uint64]$_.PercentProcessorTime}},
            @{n='Ts';e={[uint64]$_.Timestamp_Sys100NS}}, @{n='WS';e={[uint64]$_.WorkingSet}},
            @{n='Private';e={[uint64]$_.PrivateBytes}}, @{n='Handles';e={[int]$_.HandleCount}},
            @{n='Threads';e={[int]$_.ThreadCount}}, @{n='Pri';e={[int]$_.PriorityBase}})
}

function Get-PerfSnapshot {
    $sys  = Cim Win32_PerfRawData_PerfOS_System
    $mem  = Cim Win32_PerfRawData_PerfOS_Memory
    $cpu  = Cim Win32_PerfRawData_PerfOS_Processor -filter "Name='_Total'"
    $disk = Cim Win32_PerfRawData_PerfDisk_PhysicalDisk -filter "Name='_Total'"
    [pscustomobject]@{ Sys = $sys; Mem = $mem; Cpu = $cpu; Disk = $disk }
}

# One vmstat-like row from two raw counter snapshots.
function Get-PerfDelta($a, $b) {
    $rate = {
        param($x, $y, $prop)
        $dt = ([double]$y.Timestamp_PerfTime - [double]$x.Timestamp_PerfTime) / [double]$y.Frequency_PerfTime
        if ($dt -le 0) { return 0 }
        ([double]$y.$prop - [double]$x.$prop) / $dt
    }
    $dt100 = [double]$b.Cpu.Timestamp_Sys100NS - [double]$a.Cpu.Timestamp_Sys100NS
    $pct = { param($prop) if ($dt100 -le 0) { 0 } else { [math]::Max(0, [math]::Min(100,
        100 * ([double]$b.Cpu.$prop - [double]$a.Cpu.$prop) / $dt100)) } }
    [pscustomobject]@{
        r     = [int]$b.Sys.ProcessorQueueLength
        dq    = [int]$b.Disk.CurrentDiskQueueLength
        avail = [math]::Round([double]$b.Mem.AvailableBytes / 1MB)
        pi    = & $rate $a.Mem $b.Mem 'PagesInputPersec'
        po    = & $rate $a.Mem $b.Mem 'PagesOutputPersec'
        rd    = (& $rate $a.Disk $b.Disk 'DiskReadBytesPersec') / 1KB
        wr    = (& $rate $a.Disk $b.Disk 'DiskWriteBytesPersec') / 1KB
        int   = & $rate $a.Cpu $b.Cpu 'InterruptsPersec'
        cs    = & $rate $a.Sys $b.Sys 'ContextSwitchesPersec'
        us    = & $pct 'PercentUserTime'
        sy    = & $pct 'PercentPrivilegedTime'
        id    = & $pct 'PercentIdleTime'
    }
}

function Get-Owner($wp) {
    if (-not $wp) { return '?' }
    try {
        $o = Invoke-CimMethod -InputObject $wp -MethodName GetOwner -ErrorAction Stop -Verbose:$false
        if ($o.ReturnValue -eq 0) { return $o.User }
    } catch { }
    '?'
}

function Invoke-Collect {
    $D = [ordered]@{}
    $now = Get-Date
    $off = [TimeZoneInfo]::Local.GetUtcOffset($now)
    $sign = if ($off.Ticks -lt 0) { '-' } else { '+' }
    $isAdmin = Test-Admin

    $D.Meta = [ordered]@{
        ToolVersion  = $ToolVersion
        CollectedUtc = $now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', $script:Inv)
        TzId         = [TimeZoneInfo]::Local.Id
        TzOffset     = (Fmt '{0}{1:00}{2:00}' $sign ([math]::Abs($off.Hours)) ([math]::Abs($off.Minutes)))
        IsAdmin      = $isAdmin
        Mounts       = -not $NoSummarizeMounts
        Network      = -not $NoSummarizeNetwork
        Processes    = -not $NoSummarizeProcesses
        Sleep        = $Sleep
    }

    Step 'System'
    $D.System = Safe 'System' {
        $os   = Cim Win32_OperatingSystem
        $cs   = Cim Win32_ComputerSystem
        $bios = Safe 'BIOS' { Cim Win32_BIOS }
        $csp  = Safe 'Product' { Cim Win32_ComputerSystemProduct }
        $enc  = Safe 'Enclosure' { @(Cim Win32_SystemEnclosure)[0] }
        $cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $cpu  = @(Cim Win32_Processor)[0]
        $hn = $cs.DNSHostName
        if ($cs.PartOfDomain) { $hn = "$hn.$($cs.Domain)" }
        $chassis = $null
        if ($enc -and $enc.ChassisTypes) { $chassis = [int]@($enc.ChassisTypes)[0] }
        [ordered]@{
            Hostname          = $hn
            DomainRole        = [int]$cs.DomainRole
            LastBootLocal     = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv)
            UptimeSeconds     = [math]::Round(($now - $os.LastBootUpTime).TotalSeconds)
            Manufacturer      = "$($cs.Manufacturer)".Trim()
            Model             = "$($cs.Model)".Trim()
            ProductVersion    = if ($csp) { "$($csp.Version)".Trim() } else { $null }
            Chassis           = $chassis
            AssetTag          = if ($enc) { "$($enc.SMBIOSAssetTag)".Trim() } else { $null }
            Serial            = if ($bios) { "$($bios.SerialNumber)".Trim() } else { $null }
            Bios              = if ($bios) { ("$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)" -replace '\s+', ' ' -replace ' \)', ')').Trim() } else { $null }
            Caption           = "$($os.Caption)".Trim()
            Version           = $os.Version
            DisplayVersion    = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
            UBR               = $cv.UBR
            InstallationType  = $cv.InstallationType
            OSArchitecture    = $os.OSArchitecture
            CpuDataWidth      = $cpu.DataWidth
            HypervisorPresent = [bool]$cs.HypervisorPresent
            TotalPhysical     = [uint64]$cs.TotalPhysicalMemory
            AutoPagefile      = [bool]$cs.AutomaticManagedPagefile
        }
    }

    $D.Security = [ordered]@{
        Defender = Safe 'Defender status' {
            if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
                $s = Get-MpComputerStatus -ErrorAction Stop
                [ordered]@{ RealTime = [bool]$s.RealTimeProtectionEnabled; Mode = "$($s.AMRunningMode)" }
            }
        }
        Exclusions = Safe 'Defender exclusions' {
            if (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) {
                $p = Get-MpPreference -ErrorAction Stop
                $all = @($p.ExclusionPath) + @($p.ExclusionProcess) + @($p.ExclusionExtension) | Where-Object { $_ }
                if (@($all | Where-Object { "$_" -like 'N/A*' }).Count -gt 0) { 'NOACCESS' }
                else { @($all | ForEach-Object { "$_" }) }
            }
        }
        AntiVirus = Safe 'SecurityCenter2' {
            @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
                ForEach-Object { "$($_.displayName)" })
        }
    }
    # SecurityCenter2 only exists on client SKUs. Not a real failure on Server.
    $script:Warnings.RemoveAll({ param($w) $w -like 'SecurityCenter2:*' }) | Out-Null

    $D.PowerPlan = Safe 'Power plan' {
        $txt = (& powercfg.exe /getactivescheme 2>$null) -join ' '
        if ($txt -match '([0-9a-fA-F-]{36})\s*\((.+?)\)') {
            [ordered]@{ Guid = $Matches[1].ToLower(); Name = $Matches[2] }
        }
    }

    Step 'Processor and memory'
    $D.Cpu = [ordered]@{
        Processors = Safe 'Processor' {
            @(Cim Win32_Processor | Select-Object Name, Manufacturer, SocketDesignation, NumberOfCores,
                NumberOfLogicalProcessors, CurrentClockSpeed, MaxClockSpeed, L2CacheSize, L3CacheSize)
        }
        Caches = Safe 'CPU caches' {
            @(Cim Win32_CacheMemory | Select-Object Purpose, InstalledSize, Level, CacheType, WritePolicy, Associativity)
        }
    }

    $D.Memory = [ordered]@{
        Perf = Safe 'Memory counters' {
            Cim Win32_PerfRawData_PerfOS_Memory | Select-Object AvailableBytes, FreeAndZeroPageListBytes,
                StandbyCacheCoreBytes, StandbyCacheNormalPriorityBytes, StandbyCacheReserveBytes,
                ModifiedPageListBytes, CommittedBytes, CommitLimit, PoolPagedBytes, PoolNonpagedBytes, CacheBytes
        }
        PageFiles = Safe 'Page files' {
            @(Cim Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage)
        }
        Numa = Safe 'NUMA memory' {
            @(Cim Win32_PerfRawData_PerfOS_NUMANodeMemory | Where-Object { $_.Name -ne '_Total' } |
                Select-Object Name, TotalMBytes, AvailableMBytes, FreeAndZeroPageListMBytes)
        }
        NumaCpus = Safe 'NUMA processors' {
            @(Cim Win32_PerfRawData_Counters_ProcessorInformation |
                Where-Object { $_.Name -notmatch '_Total' } | ForEach-Object { $_.Name })
        }
        Devices = Safe 'Memory devices' {
            @(Cim Win32_PhysicalMemory | Select-Object DeviceLocator, BankLabel, Capacity, Speed,
                ConfiguredClockSpeed, FormFactor, SMBIOSMemoryType, MemoryType, TypeDetail, Manufacturer, PartNumber)
        }
        Slots = Safe 'Memory arrays' {
            (@(Cim Win32_PhysicalMemoryArray) | Measure-Object -Property MemoryDevices -Sum).Sum
        }
    }

    if (-not $NoSummarizeMounts) {
        Step 'Filesystems'
        $D.Filesystems = Safe 'Volumes' {
            $vols = @(Cim Win32_Volume | Where-Object {
                    $_.Capacity -and ($_.DriveLetter -or $_.Name -notlike '\\?\*') } |
                Select-Object Name, Label, FileSystem, Capacity, FreeSpace, BlockSize, Compressed, DriveType)
            $net = @(Safe 'Network drives' { Cim Win32_LogicalDisk -filter 'DriveType=4' } |
                Where-Object { $_ } | Select-Object @{n='Name';e={"$($_.DeviceID)\"}},
                    @{n='Label';e={$_.ProviderName}}, FileSystem, @{n='Capacity';e={$_.Size}}, FreeSpace,
                    @{n='BlockSize';e={$null}}, Compressed, DriveType)
            @($vols + $net)
        }
    }

    Step 'Disks'
    $storNs = 'root/Microsoft/Windows/Storage'
    $D.Disks = Safe 'Physical disks' {
        $pds = @(Cim MSFT_PhysicalDisk $storNs)
        $adv = @{}
        if (Get-Command Get-StorageAdvancedProperty -ErrorAction SilentlyContinue) {
            foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
                $a = Get-StorageAdvancedProperty -PhysicalDisk $pd -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                if ($a) { $adv["$($pd.DeviceId)"] = $a }
            }
        }
        @($pds | Sort-Object { [int]$_.DeviceId } | ForEach-Object {
            $a = $adv["$($_.DeviceId)"]
            [pscustomobject]@{
                DeviceId = "$($_.DeviceId)"; Model = "$($_.FriendlyName)".Trim(); Firmware = "$($_.FirmwareVersion)".Trim()
                MediaType = $_.MediaType; BusType = $_.BusType; Size = [uint64]$_.Size
                LogicalSector = [int]$_.LogicalSectorSize; PhysicalSector = [int]$_.PhysicalSectorSize
                Health = $_.HealthStatus
                WriteCache = if ($a) { $a.IsDeviceCacheEnabled } else { $null }
                PowerProtected = if ($a) { $a.IsPowerProtected } else { $null }
            }
        })
    }

    Step 'Partitions'
    $D.Partitions = Safe 'Partitions' {
        [ordered]@{
            Disks = @(Cim MSFT_Disk $storNs | Sort-Object Number | Select-Object Number, FriendlyName,
                PartitionStyle, Size, IsBoot, IsSystem, IsOffline, IsReadOnly)
            Parts = @(Cim MSFT_Partition $storNs | Sort-Object DiskNumber, PartitionNumber | ForEach-Object {
                [pscustomobject]@{
                    Disk = [int]$_.DiskNumber; Part = [int]$_.PartitionNumber
                    Offset = [uint64]$_.Offset; Size = [uint64]$_.Size
                    Letter = if ([int][char]$_.DriveLetter -ne 0) { "$($_.DriveLetter):" } else { '' }
                    Paths = @($_.AccessPaths | Where-Object { $_ -notlike '\\?\*' })
                    GptType = "$($_.GptType)".ToLower(); MbrType = $_.MbrType
                }
            })
        }
    }

    Step 'Storage Spaces'
    $D.Spaces = Safe 'Storage Spaces' {
        [ordered]@{
            Pools = @(Cim MSFT_StoragePool $storNs | Where-Object { -not $_.IsPrimordial } |
                Select-Object FriendlyName, Size, AllocatedSize, HealthStatus, IsReadOnly)
            VDisks = @(Cim MSFT_VirtualDisk $storNs | Select-Object FriendlyName, ResiliencySettingName,
                Size, FootprintOnPool, NumberOfColumns, Interleave, ProvisioningType, WriteCacheSize, HealthStatus)
        }
    }

    Step 'Storage controllers'
    $D.Raid = Safe 'Storage controllers' {
        $ctl = @(Cim Win32_SCSIController | ForEach-Object { "$($_.Name)" })
        $ctl += @(Safe 'IDE controllers' { Cim Win32_IDEController } | Where-Object { $_ } |
            ForEach-Object { "$($_.Name)" })
        $tool = $null; $toolOut = $null
        $tools = [ordered]@{
            'storcli64.exe' = '/call show'; 'storcli.exe' = '/call show'
            'perccli64.exe' = '/call show'; 'perccli.exe' = '/call show'
            'ssacli.exe' = 'ctrl all show config'; 'hpssacli.exe' = 'ctrl all show config'
            'arcconf.exe' = 'getconfig 1 AD'
        }
        foreach ($t in $tools.Keys) {
            $c = Get-Command $t -ErrorAction SilentlyContinue
            if ($c) {
                $tool = $t
                $toolOut = @(& $c.Source ($tools[$t] -split ' ') 2>&1 | ForEach-Object { "$_" })
                break
            }
        }
        [ordered]@{ Controllers = @($ctl | Sort-Object -Unique); Tool = $tool; ToolOutput = $toolOut }
    }

    if (-not $NoSummarizeNetwork) {
        Step 'Network'
        $D.Network = [ordered]@{
            Tcp = Safe 'TCP settings' {
                $reg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -ErrorAction SilentlyContinue
                $set = @(Get-NetTCPSetting -ErrorAction Stop)
                $pick = $set | Where-Object { $_.SettingName -eq 'InternetCustom' } | Select-Object -First 1
                if (-not $pick) { $pick = $set | Where-Object { $_.DynamicPortRangeStartPort } | Select-Object -First 1 }
                [ordered]@{
                    TimedWaitDelay = $reg.TcpTimedWaitDelay
                    MaxUserPort    = $reg.MaxUserPort
                    PortStart      = $pick.DynamicPortRangeStartPort
                    PortCount      = $pick.DynamicPortRangeNumberOfPorts
                    AutoTuning     = "$($pick.AutoTuningLevelLocal)"
                    Congestion     = "$($pick.CongestionProvider)"
                    SettingName    = $pick.SettingName
                }
            }
            Adapters = Safe 'Network adapters' {
                @(Get-NetAdapter -ErrorAction Stop | Sort-Object Name | ForEach-Object {
                    [pscustomobject]@{ Name = $_.Name; Description = $_.InterfaceDescription; Speed = [uint64]$_.Speed
                        FullDuplex = $_.FullDuplex; Mtu = $_.MtuSize; Status = "$($_.Status)"
                        Hardware = [bool]$_.HardwareInterface }
                })
            }
            Stats = Safe 'Interface statistics' {
                @(Get-NetAdapterStatistics -ErrorAction Stop | Sort-Object Name | ForEach-Object {
                    [pscustomobject]@{ Name = $_.Name
                        RxBytes = [uint64]$_.ReceivedBytes
                        RxPackets = [uint64]$_.ReceivedUnicastPackets + [uint64]$_.ReceivedMulticastPackets + [uint64]$_.ReceivedBroadcastPackets
                        RxErrors = [uint64]$_.ReceivedPacketErrors
                        TxBytes = [uint64]$_.SentBytes
                        TxPackets = [uint64]$_.SentUnicastPackets + [uint64]$_.SentMulticastPackets + [uint64]$_.SentBroadcastPackets
                        TxErrors = [uint64]$_.OutboundPacketErrors }
                })
            }
            Connections = Safe 'TCP connections' {
                @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { "$($_.State)" -ne 'Bound' } |
                    ForEach-Object { [pscustomobject]@{ L = $_.LocalAddress; LP = [int]$_.LocalPort; R = $_.RemoteAddress
                        S = "$($_.State)"; P = [int]$_.OwningProcess } })
            }
        }
    }

    Step 'Memory management'
    $D.MemMgmt = [ordered]@{
        MMAgent = Safe 'Memory compression' {
            if ($isAdmin -and (Get-Command Get-MMAgent -ErrorAction SilentlyContinue)) {
                $m = Get-MMAgent -ErrorAction Stop
                [ordered]@{ MemoryCompression = [bool]$m.MemoryCompression; PageCombining = [bool]$m.PageCombining }
            }
        }
        LargeSystemCache = Safe 'LargeSystemCache' {
            (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -ErrorAction Stop).LargeSystemCache
        }
        LockPages = Safe 'Lock Pages in Memory' {
            if ($isAdmin) {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) ("pt-summary-secedit-{0}.inf" -f [guid]::NewGuid())
                try {
                    & secedit.exe /export /areas USER_RIGHTS /cfg $tmp /quiet | Out-Null
                    $line = Select-String -Path $tmp -Pattern '^SeLockMemoryPrivilege\s*=' | Select-Object -First 1
                    if (-not $line) { ,@() }
                    else {
                        @(($line.Line -split '=', 2)[1].Split(',') | ForEach-Object {
                            $e = $_.Trim()
                            if ($e.StartsWith('*')) {
                                try { (New-Object Security.Principal.SecurityIdentifier $e.Substring(1)).Translate(
                                        [Security.Principal.NTAccount]).Value } catch { $e.Substring(1) }
                            } else { $e }
                        })
                    }
                } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
            }
        }
    }

    # Processes and vmstat go last. The first process snapshot and the last
    # counter snapshot bracket the sampling window, so %CPU covers all of it.
    Step 'Processes'
    $snap1 = Safe 'Processes' { Get-ProcessSnapshot }
    $wproc = @{}
    Safe 'Win32_Process' { Cim Win32_Process | ForEach-Object { $wproc[[int]$_.ProcessId] = $_ } } | Out-Null

    $D.Vmstat = @()
    if (-not $NoSummarizeProcesses -and $Sleep -gt 0) {
        $rows = New-Object System.Collections.Generic.List[object]
        $prev = Safe 'Performance counters' { Get-PerfSnapshot }
        $tick = [Diagnostics.Stopwatch]::StartNew()
        if ($prev) {
            for ($i = 1; $i -le $Sleep; $i++) {
                Step "Sampling performance counters ($i of $Sleep)"
                $wait = [int](1000 * $i - $tick.ElapsedMilliseconds)
                if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
                $cur = Safe 'Performance counters' { Get-PerfSnapshot }
                if (-not $cur) { break }
                $rows.Add((Get-PerfDelta $prev $cur))
                $prev = $cur
            }
        }
        $D.Vmstat = $rows.ToArray()
    } elseif (-not $NoSummarizeProcesses) {
        Start-Sleep -Seconds 1
    }
    Step 'Processes (second sample)'
    $snap2 = Safe 'Processes' { Get-ProcessSnapshot }

    $procs = @()
    if ($snap2) {
        $before = @{}
        foreach ($p in @($snap1)) { if ($p) { $before["$($p.Pid)|$($p.Name)"] = $p } }
        $procs = @($snap2 | ForEach-Object {
            $b = $before["$($_.Pid)|$($_.Name)"]
            $pct = 0.0
            if ($b -and $_.Ts -gt $b.Ts -and $_.Cpu -ge $b.Cpu) {
                $pct = 100.0 * ([double]$_.Cpu - [double]$b.Cpu) / ([double]$_.Ts - [double]$b.Ts)
            }
            $w = $wproc[$_.Pid]
            [pscustomobject]@{ Pid = $_.Pid; Ppid = $_.Ppid
                Name = if ($w) { "$($w.Name)" } else { "$($_.Name).exe" }
                Base = $_.Name; Pct = [math]::Round($pct, 1); CpuSec = [math]::Round([double]$_.Cpu / 1e7, 2)
                WS = $_.WS; Private = $_.Private; Handles = $_.Handles; Threads = $_.Threads; Pri = $_.Pri }
        })
    }

    $D.Processes = [ordered]@{ RssTotal = ($procs | Measure-Object -Property WS -Sum).Sum
        MemCompression = [bool](@($procs | Where-Object { $_.Base -eq 'Memory Compression' }).Count) }
    if (-not $NoSummarizeProcesses) {
        $top = @($procs | Sort-Object @{e='Pct';Descending=$true}, @{e='WS';Descending=$true} | Select-Object -First 15)
        $notable = @($procs | Where-Object { $_.Base -match $NotableRegex } | Sort-Object Base, Pid)
        Step 'Process owners'
        foreach ($p in @($top) + @($notable)) {
            if ($p -and -not $p.PSObject.Properties['User']) {
                $p | Add-Member -NotePropertyName User -NotePropertyValue (Get-Owner $wproc[$p.Pid])
            }
        }
        foreach ($p in $notable) {
            $w = $wproc[$p.Pid]
            $p | Add-Member -NotePropertyName Path -NotePropertyValue $(if ($w) { $w.ExecutablePath } else { $null }) -Force
        }
        $D.Processes.Top = @($top)
        $D.Processes.Notable = @($notable)
        Step 'Services'
        $D.Processes.Services = Safe 'Services' {
            @(Cim Win32_Service | Where-Object {
                    $exe = [IO.Path]::GetFileNameWithoutExtension((("$($_.PathName)" -replace '^"([^"]+)".*$', '$1') -split ' ')[0])
                    $exe -match $NotableRegex } |
                Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = $_.State
                    StartMode = $_.StartMode; Account = $_.StartName; Pid = [int]$_.ProcessId } })
        }
        # Total connections per owning process name, for the local ports table.
        $D.Processes.PidNames = @{}
        foreach ($p in $procs) { $D.Processes.PidNames["$($p.Pid)"] = $p.Name }
    }

    Step 'Done'
    Write-Progress -Activity 'pt-summary' -Completed
    $D.Warnings = @($script:Warnings)
    $D
}

# ###########################################################################
# Report. Uses only the collected data, so it also runs from saved samples.
# ###########################################################################

function Format-Uptime($sec) {
    $ts = [TimeSpan]::FromSeconds([double]$sec)
    $hm = Fmt '{0}:{1:00}' $ts.Hours $ts.Minutes
    if ($ts.Days -eq 1) { return "1 day, $hm" }
    if ($ts.Days -gt 1) { return "$($ts.Days) days, $hm" }
    $hm
}

function Get-Virtualization($S) {
    $hw = "$($S.Manufacturer) $($S.Model) $($S.Bios) $($S.ProductVersion)"
    if ($S.AssetTag -eq '7783-7084-3265-9085-8269-3286-77') { return 'Microsoft Azure (Hyper-V)' }
    switch -Regex ($hw) {
        'VMware'                   { return 'VMWare' }
        'VirtualBox|innotek'       { return 'VirtualBox' }
        'Amazon EC2|amazon'        { return 'Amazon EC2' }
        'Google Compute|Google'    { return 'Google Compute Engine' }
        'QEMU|KVM|Bochs'           { return 'KVM/QEMU' }
        'Xen'                      { return 'Xen' }
        'Parallels'                { return 'Parallels' }
        'Nutanix|AHV'              { return 'Nutanix AHV' }
        'Microsoft Corporation.*Virtual Machine' { return 'Hyper-V' }
    }
    if ($S.HypervisorPresent) {
        return 'No virtualization detected (Hyper-V/VBS hypervisor running, this OS is the root partition)'
    }
    'No virtualization detected'
}

function Write-Header($D) {
    $S = $D.System
    $M = $D.Meta
    NameVal 'Date' "$($M.CollectedUtc) UTC (local TZ: $($M.TzId) $($M.TzOffset))"
    if (-not $S) { return }
    NameVal 'Hostname' $S.Hostname
    NameVal 'Uptime' "$(Format-Uptime $S.UptimeSeconds), booted $($S.LastBootLocal)"
    if ($S.Manufacturer) {
        $sys = "$($S.Manufacturer); $($S.Model)"
        if ($S.ProductVersion) { $sys += "; v$($S.ProductVersion)" }
        if ($null -ne $S.Chassis) { $sys += " ($(Map $ChassisTypes $S.Chassis))" }
        NameVal 'System' $sys
        NameVal 'Service Tag' $S.Serial
        if ($S.Bios) { NameVal 'BIOS' $S.Bios }
    }
    NameVal 'Platform' 'Windows'
    $rel = $S.Caption
    $extra = @()
    if ($S.DisplayVersion) { $extra += $S.DisplayVersion }
    $extra += "build $(($S.Version -split '\.')[2]).$($S.UBR)"
    if ($S.InstallationType -eq 'Server Core') { $extra += 'Server Core' }
    NameVal 'Release' "$rel ($($extra -join ', '))"
    NameVal 'Kernel' "$($S.Version).$($S.UBR)"
    NameVal 'Architecture' "CPU = $($S.CpuDataWidth)-bit, OS = $($S.OSArchitecture)"
    NameVal 'Role' (Map $DomainRoles $S.DomainRole)

    $sec = $D.Security
    if ($sec.Defender) {
        $rt = if ($sec.Defender.RealTime) { 'on' } else { 'off' }
        NameVal 'Defender' "real-time protection = $rt, mode = $($sec.Defender.Mode)"
        if ($sec.Exclusions -eq 'NOACCESS') { NameVal 'Exclusions' 'unknown (run as Administrator to read them)' }
        elseif (@($sec.Exclusions).Count -gt 0) { NameVal 'Exclusions' (@($sec.Exclusions) -join '; ') }
        else { NameVal 'Exclusions' 'none' }
    }
    if (@($sec.AntiVirus).Count -gt 0) { NameVal 'Antivirus' (@($sec.AntiVirus) -join ', ') }

    if ($D.PowerPlan) {
        $pp = $D.PowerPlan
        $name = if ($PowerPlans.ContainsKey($pp.Guid)) { $PowerPlans[$pp.Guid] } else { $pp.Name }
        NameVal 'Power Plan' $name
    }
    NameVal 'Virtualized' (Get-Virtualization $S)
    if (-not $M.IsAdmin) { NameVal 'Privileges' 'standard user, some values are unknown (run as Administrator)' }
}

function Write-Processor($D) {
    Section 'Processor'
    $cpus = @($D.Cpu.Processors | Where-Object { $_ })
    if ($cpus.Count -eq 0) { return }
    $physical = $cpus.Count
    $cores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
    $virtual = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $htt = if ($cores -gt 0 -and $cores -lt $virtual) { 'yes' } else { 'no' }
    NameVal 'Processors' "physical = $physical, cores = $cores, virtual = $virtual, hyperthreading = $htt"
    $speeds = @(); $models = @()
    foreach ($c in $cpus) {
        for ($i = 0; $i -lt [int]$c.NumberOfLogicalProcessors; $i++) {
            $speeds += "$($c.CurrentClockSpeed)"; $models += "$($c.Name)".Trim()
        }
    }
    $max = ($cpus | Measure-Object -Property MaxClockSpeed -Maximum).Maximum
    NameVal 'Speeds' "$(GroupConcat $speeds) (MHz, max $max)"
    NameVal 'Models' (GroupConcat $models)
    NameVal 'Caches' (GroupConcat @($cpus | ForEach-Object { " L2 $($_.L2CacheSize) KB, L3 $($_.L3CacheSize) KB" }))

    $caches = @($D.Cpu.Caches | Where-Object { $_ })
    if ($caches.Count -gt 0) {
        Say '  Designation               Configuration                    Size     Associativity'
        Say '  ========================= ================================ ======== ======================'
        foreach ($c in ($caches | Sort-Object Level, Purpose)) {
            $cfg = @((Map $CacheLevels $c.Level ''), (Map $CacheTypes $c.CacheType ''), (Map $CacheWrite $c.WritePolicy '')) |
                Where-Object { $_ }
            Say (Fmt '  {0,-25} {1,-32} {2,-8} {3}' $c.Purpose ($cfg -join ', ') "$($c.InstalledSize) kB" (Map $CacheAssoc $c.Associativity))
        }
    }
}

function Write-Memory($D) {
    Section 'Memory'
    $script:NVLen = 14
    $P = $D.Memory.Perf
    $S = $D.System
    if ($P) {
        $total = if ($S -and $S.TotalPhysical) { [double]$S.TotalPhysical } else { $null }
        $standby = [double]$P.StandbyCacheCoreBytes + [double]$P.StandbyCacheNormalPriorityBytes + [double]$P.StandbyCacheReserveBytes
        $pfAlloc = 0.0; $pfUsed = 0.0
        foreach ($pf in @($D.Memory.PageFiles | Where-Object { $_ })) {
            $pfAlloc += [double]$pf.AllocatedBaseSize * 1MB; $pfUsed += [double]$pf.CurrentUsage * 1MB
        }
        $used = if ($total) { $total - [double]$P.AvailableBytes } else { 0 }
        if ($total) { NameVal 'Total' (Shorten $total 1) }
        NameVal 'Free' (Shorten $P.FreeAndZeroPageListBytes 1)
        NameVal 'Used' "physical = $(Shorten $used 1), swap allocated = $(Shorten $pfAlloc 1), swap used = $(Shorten $pfUsed 1), virtual = $(Shorten ($used + $pfUsed) 1)"
        NameVal 'Available' (Shorten $P.AvailableBytes 1)
        NameVal 'Standby' "$(Shorten $standby 1) (file cache, reclaimable)"
        NameVal 'Modified' "$(Shorten $P.ModifiedPageListBytes 1) (dirty, waiting to be written)"
        NameVal 'Commit' "$(Shorten $P.CommittedBytes 1) of $(Shorten $P.CommitLimit 1) limit ($(FuzzyPct $P.CommittedBytes $P.CommitLimit))"
        NameVal 'Kernel Pools' "paged = $(Shorten $P.PoolPagedBytes 1), nonpaged = $(Shorten $P.PoolNonpagedBytes 1)"
    }
    foreach ($pf in @($D.Memory.PageFiles | Where-Object { $_ })) {
        NameVal 'Page File' "$($pf.Name) = $(Shorten ([double]$pf.AllocatedBaseSize * 1MB) 1) allocated, $(Shorten ([double]$pf.CurrentUsage * 1MB) 1) used, $(Shorten ([double]$pf.PeakUsage * 1MB) 1) peak"
    }
    if ($S) { NameVal 'Page File Mgmt' $(if ($S.AutoPagefile) { 'system managed' } else { 'manual' }) }
    if ($null -ne $D.Processes.RssTotal) { NameVal 'UsedRSS' (Shorten $D.Processes.RssTotal 1) }

    $numa = @($D.Memory.Numa | Where-Object { $_ })
    if ($numa.Count -gt 0) {
        NameVal 'Numa Nodes' $numa.Count
        $script:NVLen = 12
        $cpusByNode = @{}
        foreach ($n in @($D.Memory.NumaCpus)) {
            $parts = "$n" -split ','
            if ($parts.Count -eq 2) { $cpusByNode[$parts[0]] = @($cpusByNode[$parts[0]]) + [int]$parts[1] | Where-Object { $null -ne $_ } }
        }
        Say '   Node    Size        Free        CPUs'
        Say '   ====    ====        ====        ===='
        foreach ($n in ($numa | Sort-Object { [int]$_.Name })) {
            $list = (@($cpusByNode["$($n.Name)"]) | Sort-Object) -join ' '
            Say (Fmt '   {0,-8}{1,-12}{2,-12}{3}' "node$($n.Name)" "$($n.TotalMBytes) MB" "$($n.AvailableMBytes) MB" $list)
        }
    }
    $script:NVLen = 12

    $devs = @($D.Memory.Devices | Where-Object { $_ })
    if ($devs.Count -gt 0) {
        Say '  Locator              Size     Speed             Form Factor   Type          Type Detail'
        Say '  ==================== ======== ================= ============= ============= ==========='
        foreach ($m in ($devs | Sort-Object DeviceLocator)) {
            $type = Map $MemTypes $m.SMBIOSMemoryType
            if ([int]$m.SMBIOSMemoryType -le 2) { $type = Map $MemTypes $m.MemoryType }
            $det = @(); foreach ($bit in ($TypeDetailBits.Keys | Sort-Object)) { if (([int]$m.TypeDetail -band $bit) -ne 0) { $det += $TypeDetailBits[$bit] } }
            $spd = if ($m.ConfiguredClockSpeed) { $m.ConfiguredClockSpeed } else { $m.Speed }
            Say (Fmt '  {0,-20} {1,-8} {2,-17} {3,-13} {4,-13} {5}' $m.DeviceLocator (Shorten $m.Capacity 0) "$spd MT/s" (Map $FormFactors $m.FormFactor) $type ($det -join ' '))
        }
        if ($D.Memory.Slots) { Say "  Slots used: $($devs.Count) of $($D.Memory.Slots)" }
    }
}

function Write-Filesystems($D) {
    $fs = @($D.Filesystems | Where-Object { $_ })
    if ($fs.Count -eq 0) { return }
    Section 'Mounted Filesystems'
    $rows = foreach ($v in ($fs | Sort-Object Name)) {
        $opts = @()
        if ($v.BlockSize) { $opts += "bs=$(Shorten $v.BlockSize 0)" }
        if ($v.Compressed) { $opts += 'compressed' }
        if ([int]$v.DriveType -eq 4) { $opts += 'network' }
        if ([int]$v.DriveType -eq 2) { $opts += 'removable' }
        $label = if ("$($v.Label)" -ne '') { "$($v.Label)" } else { '-' }
        [pscustomobject]@{ Fs = $label; Size = (Shorten $v.Capacity 1)
            Used = FuzzyPct ([double]$v.Capacity - [double]$v.FreeSpace) $v.Capacity
            Type = "$($v.FileSystem)"; Opts = ($opts -join ','); Mount = $v.Name }
    }
    $w1 = [math]::Max(10, ($rows | ForEach-Object { $_.Fs.Length } | Measure-Object -Maximum).Maximum)
    $w4 = [math]::Max(4, ($rows | ForEach-Object { $_.Type.Length } | Measure-Object -Maximum).Maximum)
    $w5 = [math]::Max(4, ($rows | ForEach-Object { $_.Opts.Length } | Measure-Object -Maximum).Maximum)
    $f = '  {0,-' + $w1 + '} {1,6} {2,4} {3,-' + $w4 + '} {4,-' + $w5 + '} {5}'
    Say (Fmt $f 'Filesystem' 'Size' 'Used' 'Type' 'Opts' 'Mountpoint')
    foreach ($r in $rows) { Say (Fmt $f $r.Fs $r.Size $r.Used $r.Type $r.Opts $r.Mount) }
}

function Write-Disks($D) {
    Section 'Disks And Write Cache'
    $disks = @($D.Disks | Where-Object { $_ })
    if ($disks.Count -eq 0) { Say '  Unable to collect information'; return }
    $wm = [math]::Max(5, ($disks | ForEach-Object { $_.Model.Length } | Measure-Object -Maximum).Maximum)
    $f = '  {0,-4} {1,-' + $wm + '} {2,-6} {3,-5} {4,7} {5,-9} {6,-10} {7,-9} {8}'
    Say (Fmt $f 'Disk' 'Model' 'Bus' 'Media' 'Size' 'Sector' 'WriteCache' 'PowerProt' 'Health')
    foreach ($d in $disks) {
        $wc = if ($null -eq $d.WriteCache) { 'unknown' } elseif ($d.WriteCache) { 'enabled' } else { 'disabled' }
        $pp = if ($null -eq $d.PowerProtected) { 'unknown' } elseif ($d.PowerProtected) { 'yes' } else { 'no' }
        Say (Fmt $f $d.DeviceId $d.Model (Map $BusTypes $d.BusType) (Map $MediaTypes $d.MediaType) (Shorten $d.Size 1) "$($d.LogicalSector)/$($d.PhysicalSector)" $wc $pp (Map $HealthStatus $d.Health))
    }
}

function Write-Partitions($D) {
    Section 'Disk Partitioning'
    $P = $D.Partitions
    if (-not $P) { Say '  Unable to collect information'; return }
    foreach ($d in @($P.Disks | Where-Object { $_ })) {
        $flags = @((Map $PartStyles $d.PartitionStyle))
        if ($d.IsBoot) { $flags += 'boot' }
        if ($d.IsSystem) { $flags += 'system' }
        if ($d.IsOffline) { $flags += 'OFFLINE' }
        if ($d.IsReadOnly) { $flags += 'read-only' }
        $size = if ([double]$d.Size -gt 0) { Shorten $d.Size 1 } else { 'no media' }
        Say "Disk $($d.Number): $("$($d.FriendlyName)".Trim()), $size, $($flags -join ', ')"
        $parts = @($P.Parts | Where-Object { $_ -and [int]$_.Disk -eq [int]$d.Number })
        if ($parts.Count -eq 0) { continue }
        Say (Fmt '  {0,-4} {1,14} {2,8} {3,-8} {4,-15} {5}' 'Part' 'Offset' 'Size' 'Aligned' 'Type' 'Mount')
        foreach ($p in $parts) {
            $off = [uint64]$p.Offset
            $al = if ($off % 1MB -eq 0) { '1M' } elseif ($off % 64KB -eq 0) { '64K' } elseif ($off % 4KB -eq 0) { '4K' } else { 'NO' }
            $type = if ($p.GptType -and $GptTypes.ContainsKey($p.GptType)) { $GptTypes[$p.GptType] }
                    elseif ($p.GptType) { 'GPT other' } else { Map $MbrTypes $p.MbrType 'MBR other' }
            $mount = @($p.Paths | Where-Object { "$_" -ne '' }) -join ' '
            if (-not $mount) { $mount = $p.Letter }
            Say (Fmt '  {0,-4} {1,14} {2,8} {3,-8} {4,-15} {5}' $p.Part $off (Shorten $p.Size 1) $al $type $mount)
        }
    }
}

function Write-Spaces($D) {
    Section 'Storage Spaces Virtual Disks'
    $sp = $D.Spaces
    if (-not $sp) { Say '  Unable to collect information' }
    elseif (@($sp.VDisks | Where-Object { $_ }).Count -eq 0) { Say '  No virtual disks' }
    else {
        Say (Fmt '  {0,-20} {1,-10} {2,8} {3,9} {4,7} {5,10} {6,-6} {7}' 'Name' 'Resiliency' 'Size' 'Footprint' 'Columns' 'Interleave' 'Prov' 'Health')
        foreach ($v in @($sp.VDisks | Where-Object { $_ })) {
            Say (Fmt '  {0,-20} {1,-10} {2,8} {3,9} {4,7} {5,10} {6,-6} {7}' $v.FriendlyName $v.ResiliencySettingName (Shorten $v.Size 1) (Shorten $v.FootprintOnPool 1) $v.NumberOfColumns (Shorten $v.Interleave 0) (Map $ProvTypes $v.ProvisioningType) (Map $HealthStatus $v.HealthStatus))
        }
    }
    Section 'Storage Spaces Pools'
    if (-not $sp) { Say '  Unable to collect information' }
    elseif (@($sp.Pools | Where-Object { $_ }).Count -eq 0) { Say '  No storage pools' }
    else {
        Say (Fmt '  {0,-20} {1,8} {2,9} {3}' 'Name' 'Size' 'Allocated' 'Health')
        foreach ($p in @($sp.Pools | Where-Object { $_ })) {
            Say (Fmt '  {0,-20} {1,8} {2,9} {3}' $p.FriendlyName (Shorten $p.Size 1) (Shorten $p.AllocatedSize 1) (Map $HealthStatus $p.HealthStatus))
        }
    }
}

function Write-Raid($D) {
    Section 'RAID Controller'
    $R = $D.Raid
    $ctl = @($R.Controllers | Where-Object { $_ })
    $raid = @($ctl | Where-Object { $_ -match 'RAID|PERC|Smart Array|MegaRAID|LSI|Adaptec|Broadcom|Avago|HBA|SmartRAID|ServeRAID' })
    if ($raid.Count -gt 0) { NameVal 'Controller' ($raid -join ', ') } else { NameVal 'Controller' 'No RAID controller detected' }
    foreach ($c in ($ctl | Where-Object { $raid -notcontains $_ })) { NameVal 'Storage Ctrl' $c }
    if ($R.Tool) {
        NameVal 'Vendor Tool' $R.Tool
        foreach ($l in @($R.ToolOutput)) { Say "  $l" }
    } elseif ($raid.Count -gt 0) {
        NameVal 'Vendor Tool' 'not found in PATH (storcli, perccli, ssacli, arcconf); cache and BBU state unknown'
    }
}

function Write-Network($D) {
    $N = $D.Network
    if (-not $N) { return }
    Section 'Network Config'
    $ctl = @($N.Adapters | Where-Object { $_ -and $_.Hardware -and $_.Status -ne 'Not Present' } |
        ForEach-Object { $_.Description } | Sort-Object -Unique)
    foreach ($c in $ctl) { NameVal 'Controller' $c }
    $T = $N.Tcp
    if ($T) {
        $tw = if ($T.TimedWaitDelay) { "$($T.TimedWaitDelay)s" } else { '120s (default)' }
        NameVal 'TIME_WAIT' $tw
        if ($T.PortStart) {
            $end = [int]$T.PortStart + [int]$T.PortCount - 1
            NameVal 'Port Range' "$($T.PortStart)-$end ($($T.PortCount) ports)"
        }
        if ($T.MaxUserPort) { NameVal 'MaxUserPort' "$($T.MaxUserPort) (legacy setting, ignored since Windows Server 2008)" }
        NameVal 'Auto-Tuning' "$($T.AutoTuning) ($($T.SettingName))"
        NameVal 'Congestion' "$($T.Congestion) ($($T.SettingName))"
    }

    $stats = @($N.Stats | Where-Object { $_ })
    if ($stats.Count -gt 0) {
        Section 'Interface Statistics'
        $w = [math]::Max(9, ($stats | ForEach-Object { "$($_.Name)".Length } | Measure-Object -Maximum).Maximum)
        $f = '  {0,-' + $w + '} {1,10} {2,10} {3,10} {4,10} {5,10} {6,10}'
        Say (Fmt $f 'interface' 'rx_bytes' 'rx_packets' 'rx_errors' 'tx_bytes' 'tx_packets' 'tx_errors')
        Say (Fmt $f ('=' * $w) ('=' * 9) ('=' * 10) ('=' * 10) ('=' * 10) ('=' * 10) ('=' * 10))
        foreach ($s in $stats) {
            Say (Fmt $f $s.Name (Fuzz $s.RxBytes) (Fuzz $s.RxPackets) (Fuzz $s.RxErrors) (Fuzz $s.TxBytes) (Fuzz $s.TxPackets) (Fuzz $s.TxErrors))
        }
    }

    $ad = @($N.Adapters | Where-Object { $_ -and $_.Status -ne 'Not Present' })
    if ($ad.Count -gt 0) {
        Section 'Network Devices'
        $w = [math]::Max(9, ($ad | ForEach-Object { "$($_.Name)".Length } | Measure-Object -Maximum).Maximum)
        $f = '  {0,-' + $w + '} {1,-10} {2,-7} {3,-6} {4,-13} {5}'
        Say (Fmt $f 'Device' 'Speed' 'Duplex' 'MTU' 'Status' 'Description')
        Say (Fmt $f ('=' * $w) ('=' * 10) ('=' * 7) ('=' * 6) ('=' * 13) ('=' * 11))
        foreach ($a in $ad) {
            $dup = if ($null -eq $a.FullDuplex) { '-' } elseif ($a.FullDuplex) { 'full' } else { 'half' }
            Say (Fmt $f $a.Name (Bps $a.Speed) $dup $a.Mtu $a.Status $a.Description)
        }
    }

    $conns = @($N.Connections | Where-Object { $_ })
    if ($N.Connections -ne $null) {
        Section 'Network Connections'
        $remote = @($conns | Where-Object { $_.R -and $_.R -ne '0.0.0.0' -and $_.R -ne '::' })
        $line = { param($k, $n) Say (Fmt '    {0,-15} {1,5}' $k (Fuzz $n)) }
        $ipSort = { $a = $null; if ([Version]::TryParse("$($_.Name)", [ref]$a)) { $a } else { [Version]'255.255.255.255' } }
        Say '  Connections from remote IP addresses'
        foreach ($g in ($remote | Group-Object R | Sort-Object $ipSort, Name)) { & $line $g.Name $g.Count }
        Say '  Connections to local IP addresses'
        foreach ($g in ($remote | Group-Object L | Sort-Object $ipSort, Name)) { & $line $g.Name $g.Count }
        Say '  Connections to top 10 local ports'
        $names = $D.Processes.PidNames
        foreach ($g in ($remote | Group-Object LP | Sort-Object Count -Descending | Select-Object -First 10 | Sort-Object { [int]$_.Name })) {
            $owner = @($conns | Where-Object { $_.S -eq 'Listen' -and "$($_.LP)" -eq $g.Name } | Select-Object -First 1)
            $suffix = ''
            if ($owner.Count -gt 0 -and $names) {
                $pn = if ($names -is [hashtable]) { $names["$($owner[0].P)"] } else { $names."$($owner[0].P)" }
                if ($pn) { $suffix = "  ($pn)" }
            }
            Say ((Fmt '    {0,-15} {1,5}' $g.Name (Fuzz $g.Count)) + $suffix)
        }
        Say '  States of connections'
        foreach ($g in ($conns | Group-Object S | Sort-Object Name)) { & $line $g.Name $g.Count }
    }
}

function Write-Processes($D) {
    $P = $D.Processes
    Section 'Top Processes'
    $top = @($P.Top | Where-Object { $_ })
    $f = '{0,7} {1,-16} {2,3} {3,6} {4,5} {5,8} {6,8} {7,7} {8,4} {9,11} {10}'
    Say (Fmt $f 'PID' 'USER' 'PRI' '%CPU' '%MEM' 'WS' 'PRIVATE' 'HANDLES' 'THR' 'TIME+' 'COMMAND')
    $total = if ($D.System) { [double]$D.System.TotalPhysical } else { 0 }
    foreach ($p in $top) {
        $ts = [TimeSpan]::FromSeconds([double]$p.CpuSec)
        $time = Fmt '{0}:{1:00}:{2:00.00}' ([math]::Floor($ts.TotalHours)) $ts.Minutes ($ts.Seconds + $ts.Milliseconds / 1000.0)
        $mem = if ($total -gt 0) { Fmt '{0:0.0}' (100.0 * [double]$p.WS / $total) } else { '?' }
        $user = "$($p.User)"; if ($user.Length -gt 16) { $user = $user.Substring(0, 16) }
        Say (Fmt $f $p.Pid $user $p.Pri (Fmt '{0:0.0}' $p.Pct) $mem (Shorten $p.WS 1) (Shorten $p.Private 1) $p.Handles $p.Threads $time $p.Name)
    }

    Section 'Notable Processes'
    $notable = @($P.Notable | Where-Object { $_ })
    Say '  PID    PRI    USER             COMMAND'
    if ($notable.Count -eq 0) {
        Say (Fmt '{0,5}    {1,3}    {2,-16} {3}' '?' '?' '?' 'no database or exporter processes found')
    }
    foreach ($g in ($notable | Group-Object Base)) {
        $pids = @($g.Group | ForEach-Object { $_.Pid })
        $roots = @($g.Group | Where-Object { $pids -notcontains $_.Ppid })
        foreach ($p in $roots) {
            $cmd = if ($p.Path) { $p.Path } else { $p.Name }
            Say (Fmt '{0,5}    {1,3}    {2,-16} {3}' $p.Pid $p.Pri $p.User $cmd)
        }
        $children = $g.Group.Count - $roots.Count
        if ($children -gt 0) { Say "                         (+$children child $($g.Name) processes)" }
    }
    $svc = @($P.Services | Where-Object { $_ })
    if ($svc.Count -gt 0) {
        Say '  Services'
        foreach ($s in $svc) {
            Say (Fmt '    {0,-24} {1,-8} {2,-9} {3}' $s.Name $s.State $s.StartMode $s.Account)
        }
    }

    $rows = @($D.Vmstat | Where-Object { $_ })
    if ($rows.Count -gt 0) {
        Section 'Simplified and fuzzy rounded vmstat (wait please)'
        Say '  -queue-- -memory- ---paging--- ---disk kB/s--- ---system---- ----cpu----'
        $f = '{0,5}{1,4}{2,9}{3,7}{4,6}{5,8}{6,8}{7,7}{8,7}{9,4}{10,4}{11,4}'
        Say (Fmt $f 'r' 'dq' 'availMB' 'pi/s' 'po/s' 'read' 'write' 'in' 'cs' 'us' 'sy' 'id')
        foreach ($r in $rows) {
            Say (Fmt $f $r.r $r.dq (Fuzz $r.avail) (Fuzz $r.pi) (Fuzz $r.po) (Fuzz $r.rd) (Fuzz $r.wr) (Fuzz $r.int) (Fuzz $r.cs) ([math]::Round($r.us)) ([math]::Round($r.sy)) ([math]::Round($r.id)))
        }
        Say '  r = processor queue, dq = disk queue (_Total), pi/po = pages read/written from/to disk per second'
    }
}

function Write-MemMgmt($D) {
    Section 'Memory management'
    $M = $D.MemMgmt
    if ($M.MMAgent) {
        $mc = if ($M.MMAgent.MemoryCompression) { 'enabled' } else { 'disabled' }
        $pc = if ($M.MMAgent.PageCombining) { 'enabled' } else { 'disabled' }
        Say "Memory compression is $mc. Page combining is $pc."
    } elseif ($D.Processes.MemCompression) {
        Say 'Memory compression is enabled (the Memory Compression process is running). Page combining is unknown (run as Administrator).'
    } else {
        Say 'Memory compression appears disabled (no Memory Compression process). Page combining is unknown (run as Administrator).'
    }
    if ($null -ne $M.LargeSystemCache) {
        $lsc = if ([int]$M.LargeSystemCache -eq 1) { 'enabled (file cache favored over process working sets)' } else { 'disabled' }
        Say "LargeSystemCache is $lsc."
    }
    if ($null -eq $M.LockPages) {
        Say 'Lock Pages in Memory holders are unknown (run as Administrator).'
    } elseif (@($M.LockPages).Count -eq 0) {
        Say 'No account holds Lock Pages in Memory (SeLockMemoryPrivilege). Large pages are not available to services.'
    } else {
        Say "Lock Pages in Memory (SeLockMemoryPrivilege) is granted to: $(@($M.LockPages) -join ', ')."
    }
}

function Invoke-Report($D) {
    Section 'Percona Toolkit System Summary Report'
    Write-Header $D
    Write-Processor $D
    Write-Memory $D
    if ($D.Meta.Mounts) { Write-Filesystems $D }
    Write-Disks $D
    Write-Partitions $D
    Write-Spaces $D
    Write-Raid $D
    if ($D.Meta.Network) { Write-Network $D }
    if ($D.Meta.Processes) { Write-Processes $D }
    Write-MemMgmt $D
    $w = @($D.Warnings | Where-Object { $_ })
    if ($w.Count -gt 0) {
        Section 'Collection Warnings'
        foreach ($x in $w) { Say "  $x" }
    }
    Section 'The End'
}

# ###########################################################################
# Main
# ###########################################################################

if ($ReadSamples) {
    $file = Join-Path $ReadSamples $SamplesFile
    if (-not (Test-Path $file)) { Write-Error "The data directory doesn't have a $SamplesFile file, exiting."; exit 1 }
    $data = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        Write-Error 'Collecting data requires Windows. Use -ReadSamples to report from saved samples.'; exit 1
    }
    $data = Invoke-Collect
    if ($SaveSamples) {
        New-Item -ItemType Directory -Path $SaveSamples -Force | Out-Null
        $json = $data | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path (Resolve-Path $SaveSamples) $SamplesFile), $json, (New-Object Text.UTF8Encoding $false))
    }
}

Invoke-Report $data
$report = $script:Out -join [Environment]::NewLine
if ($OutFile) {
    $OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($OutFile, $report + [Environment]::NewLine, (New-Object Text.UTF8Encoding $false))
}
$report
