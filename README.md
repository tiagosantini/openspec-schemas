# OpenSpec Schemas

Custom [OpenSpec](https://github.com/Fission-AI/OpenSpec) workflow schemas.

## Schemas

### `prototype-first`

Adds a high-fidelity prototype step before design:

```text
proposal → specs → prototype → design → tasks
```

Changes with a visible interface get self-contained HTML prototypes with
fictional data, reviewed before design and implementation. Changes without
interface impact record a short exemption instead.

[Schema documentation](schemas/prototype-first/README.md)

## Install

Run inside an initialized OpenSpec project (`openspec init`).

**macOS / Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.sh | sh
```

**Windows / PowerShell**

```powershell
irm https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.ps1 | iex
```

The installer copies the schema to `openspec/schemas/prototype-first`, selects
it in `openspec/config.yaml`, and records the installed version in
`openspec/schemas/prototype-first/.install.json`. By default it installs the
latest release, not the tip of `main`.

From a clone, point the installer at the project:

```sh
./scripts/install.sh --dir /path/to/project
```

```powershell
.\scripts\install.ps1 -Dir C:\path\to\project
```

## Update

Check whether the installed schema is current:

```sh
curl -fsSL https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.sh | sh -s -- --check
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.ps1))) -Check
```

`--check` / `-Check` exits with `0` when up to date, `1` when an update is
available (or the schema is not installed), and `2` when the latest version
cannot be determined.

Apply the update:

```sh
curl -fsSL https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.sh | sh -s -- --upgrade
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.ps1))) -Upgrade
```

From a clone, use `./scripts/install.sh --upgrade` or
`.\scripts\install.ps1 -Upgrade` instead.

The upgrade refuses to run when files in the installed schema were changed
locally, listing them instead. Review the differences and re-run with `--force`
/ `-Force` to overwrite; in that case the previous installation is kept under
`openspec/.schema-backups/`. Installations without a version stamp (from before
version tracking) are backed up the same way before being replaced.

Other options:

| Option | Purpose |
| --- | --- |
| `--ref <ref>` / `-Ref <ref>` | Install a specific release tag or branch |
| `--version` / `-Version` | Print the installed version |
| `--force` / `-Force` | Overwrite local changes and reinstall |

## Usage

After installation, run `openspec status` to see the artifact sequence for the
current change.

## License

[MIT](LICENSE) © Tiago Santini
