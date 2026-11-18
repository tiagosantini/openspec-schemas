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

The installer copies the schema to `openspec/schemas/prototype-first` and
selects it in `openspec/config.yaml`.

From a clone, point the installer at the project:

```sh
./scripts/install.sh --dir /path/to/project
```

```powershell
.\scripts\install.ps1 -Dir C:\path\to\project
```

## Usage

After installation, run `openspec status` to see the artifact sequence for the
current change.

## License

[MIT](LICENSE) © Tiago Santini
