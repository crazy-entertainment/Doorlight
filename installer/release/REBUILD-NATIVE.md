# Rebuilding the Windows native library

Unpack the corresponding-source archive into a writable **fresh local Windows
workspace**. Keep `source/jami-daemon/`, `source/vendor/`, `source-manifest.json`
and `qualification/` together. The scripts in `qualification/` include
`rebuild-native.ps1` and `native-provenance.py`. The manifest and retained original
archives are inputs to validation, not downloaded replacements.

This entrypoint compiles contrib dependencies, static `jami-core`, and the
`ut_audio_transmission_gate` target, then runs precisely the audio gate CTest. It
does not build an installer, sign anything, install the app or access identities.
The source already contains the Windows tooling fixes: **do not reapply** the
historical `windows-tools.patch` or pywinmake overlay.

## Tool prerequisites

Install tools separately under their respective terms. The source archive does
not contain Microsoft's compiler, SDK or standard MSBuild targets. Use x64 Windows,
PowerShell 7, Git for Windows on PATH, the built-in Windows
`%SystemRoot%/System32/tar.exe` (bsdtar), and these producer inputs recorded in
`qualification/toolchain-and-downloads.original.json` and `source-manifest.json`:

| Tool | Recorded input |
| --- | --- |
| Python | 3.12.10 |
| Vendored pywinmake | 0.5.11, with retained local source changes |
| CMake and adjacent CTest | 3.31.6-msvc6 |
| Visual Studio Build Tools | 2022 17.14.40; MSVC 14.44.35207 |
| Windows SDK | 10.0.26100.0 |
| Perl | Strawberry `5.42.3.1` portable archive; executable reports v5.42.3 |
| NASM | 2.16.03 |
| YASM | 1.3.0 |
| MSYS2 | base `20260611`; recorded make 4.4.1-3 and runtime 3.6.9-2 |
| MSBuild assembly customizations | VSNASM 2.0 and VSYASM 1.0 |

The historical toolchain JSON's Perl version field is `V`, a failed capture;
the retained download reference and producer executable identify the version
above. Download references carry original archive hashes. Matching a tool filename
or passing this script's executable-format check does not authenticate its vendor;
verify your acquisition against those references. Different compatible tools may
work but do not establish the recorded producer environment.

## Private MSBuild overlay

Create a project-owned directory outside the installed Visual Studio tree. Copy
the complete installed `MSBuild/Microsoft/VC/v170/` directory there. This is a local
working copy of your licensed installation, **not a redistributable source-archive
payload**. Preserve its relative layout and SDK/tool references.

Obtain the official
[VSYASM 1.0](https://github.com/ShiftMediaProject/VSYASM/releases/tag/1.0) and
[VSNASM 2.0](https://github.com/ShiftMediaProject/VSNASM/releases/tag/2.0) archives.
Check their hashes against the retained download references. Copy only each
archive's `yasm.props`, `yasm.targets`, `yasm.xml` or `nasm.props`, `nasm.targets`,
`nasm.xml` into the overlay's `BuildCustomizations/`. Preserve the upstream COPYING
texts beside locally retained plugin files. Do not run their global installer
scripts. Supply the separately installed assembler executables via `-Yasm` and
`-Nasm`; MSBuild receives their **parent directories with a trailing backslash**.

## Invocation

All paths below are placeholders for your own installation; none of the original
producer's drive letters is required. Pass executable files, except
`-MSBuildTargets`, which is the private overlay directory:

```powershell
$tools = @{
  Workspace = 'D:\native-source'
  Python = 'D:\tools\python\python.exe'
  CMake = 'D:\VS2022\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
  VsDevCmd = 'D:\VS2022\Common7\Tools\VsDevCmd.bat'
  MsysBash = 'D:\tools\msys64\usr\bin\bash.exe'
  Perl = 'D:\tools\strawberry\perl\bin\perl.exe'
  Yasm = 'D:\tools\yasm\yasm.exe'
  Nasm = 'D:\tools\nasm\nasm.exe'
  MSBuildTargets = 'D:\native-tools\msbuild-v170-overlay'
  Jobs = 4
}
& 'D:\native-source\qualification\rebuild-native.ps1' @tools -ValidateOnly
& 'D:\native-source\qualification\rebuild-native.ps1' @tools
```

`-Jobs` accepts 1–16, default 4. `-ValidateOnly` checks tool paths, source hashes,
vendored pywinmake, the 32 retained dependency originals, three retained GnuTLS
submodule source archives, and expected-lite header/licence pins. It checks the
built-in Windows tar executable as well. It does not write outputs, call VsDevCmd, compile, or require
10 GiB free. It may inspect an existing build workspace without treating its
generated outputs as source evidence. Neither mode follows linked/reparse input
paths. Paths containing `%`, `!`, quotes or control characters are rejected
because build commands use cmd.exe.

A real build requires at least 10 GiB free and no existing `build-core/`,
`source/jami-daemon/contrib/build/` or `contrib/msvc/`. The script never deletes or
repairs previous output. Keep failed attempts and unpack a new source workspace
before rebuilding. It creates `tmp/`, an exclusive process lock, and fresh
`logs/rebuild-<timestamp>-<unique-id>/` containing the exact command, stdout,
stderr and exit code. Command output is retained there while the build runs.

VsDevCmd initializes x64 host/target tools in a child process. The child sets
`PYTHONPATH` to `source/vendor`, the two job caps, `TEMP`/`TMP` to workspace `tmp`,
`MSYS2_BIN` to the full bash executable, and `VCTargetsPath` to the private overlay.
Tool directories are prepended to the child PATH. Parent environment and global
tool installations are unchanged. The maintained commands are:

```text
python extras/scripts/winmake.py --base-dir <workspace>/source/jami-daemon -l 4 resolve
cmake -S <source> -B <workspace>/build-core -G "Visual Studio 17 2022" -A x64 -DCMAKE_GENERATOR_INSTANCE=<selected VS installation> -DBUILD_CONTRIB=OFF -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=ON
cmake --build <workspace>/build-core --config Release --target jami-core ut_audio_transmission_gate --parallel <jobs>
ctest --test-dir <workspace>/build-core -C Release -R "^audio_transmission_gate$" --output-on-failure --no-tests=error
```

Restinio's expected-lite 0.10.0 header is vendored and pinned to commit
`3583e95bad46f5af7d8a826632bc68a6f7281551`; its recipe copies that header rather
than downloading a mutable branch. The source retains all 32 original dependency
archives **plus three exact GnuTLS Git source archives** under
`contrib/src/gnutls/source/`: gnulib `3639c57a`, libtasn1 `2b7ee166`, and that
libtasn1's gnulib `aa52cadc`. Their `UPSTREAM.json` binds full commits, trees,
archive hashes, lengths and destinations. The GnuTLS prebuild extracts these local
archives with built-in Windows tar; it performs no GnuTLS/submodule Git fetch.
It excludes the three known source symlinks (`libtasn1/README` and nested gnulib
`etc/license-notices/GPL` and `LGPL`), then creates ordinary byte-for-byte copies
of `README.md`, `GPLv3+` and `LGPLv3+` at those names. Administrator privileges or
Windows Developer Mode are not needed to materialize these source aliases.
Git for Windows is still needed for local patch application.

Original native notice texts and their index ship separately from the
pywinmake build-tool source/notice material; keep both in corresponding-source
delivery, and keep runtime notices with any distributed native binary.

The source archive's recorded provenance associates particular source inputs,
commands and outputs. This rebuild script does not promise bitwise-identical
artifacts, full test acceptance, security approval, licensing clearance or a
successful build on an untested toolchain. Preserve actual output and test evidence
for the environment you use.

For focused script checks, run `rebuild-native-test.ps1`. Supply
`-ValidationArguments $tools` to additionally check real ValidateOnly behavior.
