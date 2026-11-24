# pt-summary.ps1

When a customer runs MySQL, PostgreSQL or MongoDB on Windows, the first questions are the usual ones: how much memory, what disks, is the write cache on, what is the power plan, is antivirus scanning the data directory. On Linux you get all of that from one `pt-summary` run. On Windows you collect it by hand from `systeminfo`, Task Manager, Disk Management and a few PowerShell one-liners, and something is always missing.

`pt-summary.ps1` is a port of [pt-summary](https://docs.percona.com/percona-toolkit/pt-summary.html) from Percona Toolkit to Windows. It prints the same sections in the same layout, so you read it the way you read a Linux report.

## Requirements

- Windows Server 2016 or later, or Windows 10 or later.
- Windows PowerShell 5.1 (built in). PowerShell 7 also works.
- No modules to install. The script is read-only.

Run it as **Administrator** for the complete report. As a standard user, it still runs, and it marks the values it cannot read (write cache, Defender exclusions, memory compression, Lock Pages in Memory) as unknown.

## Usage

Run it from an elevated PowerShell prompt:

```
PS C:\> powershell -ExecutionPolicy Bypass -File .\pt-summary.ps1
```

To send the data to Support, save the samples and the report in one directory:

```
PS C:\> .\pt-summary.ps1 -SaveSamples C:\temp\pts -OutFile C:\temp\pts\pt-summary.txt
```

Use `-OutFile` instead of `>`. In Windows PowerShell 5.1, `>` writes UTF-16, and `grep` and `less` do not handle it well. `-OutFile` writes UTF-8.

To rebuild the report later from the saved samples, without touching the server:

```
PS C:\> .\pt-summary.ps1 -ReadSamples C:\temp\pts
```

`-ReadSamples` does not collect anything, so it also runs with `pwsh` on Linux or macOS.

### Options

| Option | pt-summary equivalent | Description |
|---|---|---|
| `-Sleep <n>` | `--sleep` | Seconds of performance counter samples for the vmstat section. Default 5. `0` skips it. |
| `-SaveSamples <dir>` | `--save-samples` | Save the collected data as `pt-summary-samples.json`. |
| `-ReadSamples <dir>` | `--read-samples` | Create the report from saved samples. |
| `-OutFile <file>` | | Also write the report to a UTF-8 file. |
| `-NoSummarizeMounts` | `--no-summarize-mounts` | Skip mounted filesystems. |
| `-NoSummarizeNetwork` | `--no-summarize-network` | Skip network configuration, statistics and connections. |
| `-NoSummarizeProcesses` | `--no-summarize-processes` | Skip top processes and the vmstat samples. |
| `-Verbose` | | Print how long each collection step takes, on stderr. |
| `-Version`, `-Help` | `--version`, `--help` | |

A run takes about 25 seconds with the default `-Sleep 5`, and about 13 seconds with `-Sleep 0 -NoSummarizeProcesses`.

## What the report contains

Sections that exist on both platforms keep their pt-summary name and format. Sections that only make sense on Linux are replaced by the Windows setting that answers the same question.

| pt-summary (Linux) | pt-summary.ps1 (Windows) | Source |
|---|---|---|
| Header: Date, Hostname, Uptime, System, Release, Kernel | Same, plus BIOS, domain role and power plan | `Win32_OperatingSystem`, `Win32_ComputerSystem`, `Win32_BIOS`, `powercfg` |
| SELinux | Defender real-time protection, exclusions, installed antivirus | `Get-MpComputerStatus`, `Get-MpPreference`, `SecurityCenter2` |
| Virtualized | VMware, Hyper-V, Azure, KVM, Xen, EC2, GCE, VirtualBox, or the Hyper-V root partition | SMBIOS strings, Azure asset tag, `HypervisorPresent` |
| Processor (`/proc/cpuinfo`, dmidecode caches) | Same fields and cache table | `Win32_Processor`, `Win32_CacheMemory` |
| Memory (`free`, NUMA, dmidecode DIMMs) | Free, standby (file cache), modified (dirty), commit charge, kernel pools, page files, NUMA nodes, DIMMs | Raw `PerfOS_Memory` counters, `Win32_PageFileUsage`, `Win32_PhysicalMemory` |
| Mounted Filesystems | Volumes, including mount folders and network drives, with cluster size (`bs=`) | `Win32_Volume`, `Win32_LogicalDisk` |
| Disk Schedulers And Queue Size | Disks And Write Cache: bus, media type, sector sizes, write cache, power protection, health | `MSFT_PhysicalDisk`, `Get-StorageAdvancedProperty` |
| Disk Partitioning (`fdisk`) | Partitions with offset alignment (1M, 64K, 4K or NO) | `MSFT_Disk`, `MSFT_Partition` |
| LVM Volumes / Volume Groups | Storage Spaces Virtual Disks / Pools | `MSFT_VirtualDisk`, `MSFT_StoragePool` |
| RAID Controller | Storage controllers, plus raw output of `storcli`, `perccli`, `ssacli` or `arcconf` when found in `PATH` | `Win32_SCSIController`, `Win32_IDEController` |
| Network Config (FIN timeout, port range) | TIME_WAIT, dynamic port range, auto-tuning, congestion provider | `Tcpip\Parameters` registry, `Get-NetTCPSetting` |
| Interface Statistics, Network Devices | Same, fuzzy rounded, plus MTU and link status | `Get-NetAdapterStatistics`, `Get-NetAdapter` |
| Network Connections (`netstat`) | Same four tables, and the owning process for listening ports | `Get-NetTCPConnection` |
| Top Processes (`top`) | %CPU over the sampling window, working set, private bytes, handles, threads | Raw `PerfProc_Process` counters |
| Notable Processes (sshd, OOM -17) | Database and exporter processes (mysqld, mariadbd, mongod, postgres, sqlservr, pmm-agent and others), and their services with start mode and account | `Win32_Process`, `Win32_Service` |
| vmstat | Processor queue, disk queue, available memory, paging, disk kB/s, interrupts, context switches, CPU | Raw `PerfOS_*` and `PerfDisk_PhysicalDisk` counters |
| Memory management (THP) | Memory compression, page combining, `LargeSystemCache`, Lock Pages in Memory holders | `Get-MMAgent`, registry, `secedit` |

Anything that fails to collect is listed under **Collection Warnings** at the end of the report, instead of stopping the run.

### Why raw performance counters

`Get-Counter` takes counter paths such as `\Processor(_Total)\% Idle Time`, and those paths are translated on non-English Windows. A script that uses them fails on a Spanish or German server. The `Win32_PerfRawData_*` CIM classes have the same names in every language, so the script reads two raw samples and computes rates itself. Numbers are also formatted with the invariant culture, so a `es-ES` server prints `31.5G`, not `31,5G`.

## Privacy

Like pt-summary, the report includes the hostname, serial number, process names and remote IP addresses of open connections. Command lines are not collected, because they can contain passwords. Review the report and `pt-summary-samples.json` before you attach them to a ticket.

## Limitations

- Testing so far covers Windows 11 Pro 26H2, as a standard user. The Administrator-only paths (write cache, Defender exclusions, `Get-MMAgent`, `secedit`) and Windows Server are not tested yet.
- Windows reports `CurrentClockSpeed` from SMBIOS, which is often the base clock, not the current frequency.
- `UsedRSS` is the sum of working sets, so shared pages are counted more than once, as on Linux.

## Feedback

Reports from real servers are the most useful input, especially from Windows Server, hosts with a RAID controller, and multi-socket NUMA machines. If a section is wrong or missing, open an issue with the report attached.

Reference: [pt-summary documentation](https://docs.percona.com/percona-toolkit/pt-summary.html).
