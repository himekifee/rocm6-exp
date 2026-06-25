## ROCm 6 Windows inspection

This repository uses GitHub Actions on `windows-2022` to inspect AMD `HIP SDK 6.4.2` on a hosted Windows runner.

The workflow does all of the following:

- downloads the official AMD HIP SDK installer entry URL for Windows Server 2022, with a Windows 10/11 fallback
- attempts a silent install using AMD's documented `-install` and `-log` flags
- inventories likely install roots, commands, headers, libraries, DLLs, and CMake config files
- captures environment variables, uninstall registry entries, and command lookups
- uploads all evidence as GitHub Actions artifacts

This repository intentionally does **not** attempt any interactive remote access to the runner.

## Workflow

- Workflow file: `.github/workflows/inspect-hip-sdk-642.yml`
- Collection script: `scripts/inspect-hip-sdk.ps1`

## Expected artifacts

The workflow uploads an `artifacts/` directory containing:

- installer download attempts and logs
- machine and environment metadata
- AMD/HIP uninstall registry entries
- command lookups for `clang`, `hipcc`, and related tools
- file inventories for headers, libs, DLLs, and CMake files
- shallow directory trees for candidate install roots
