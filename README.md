# bw-tools

Small, self-contained tools for SAP BW/4HANA.

| Tool | What it does | Package | Documentation |
| --- | --- | --- | --- |
| <img src="docs/snapshot-extended/images/icon.svg" alt="" width="20"> Snapshot Extended | Detects deletions in the source for filtered full loads into standard aDSOs and passes them on as deltas | `ZBWT_SNX` | [docs/snapshot-extended](docs/snapshot-extended/README.md) |

## Installation

The ABAP objects are managed with [abapGit](https://abapgit.org).

1. Create a package for the repository, for example `ZBWT`.
2. In abapGit, choose **New Online**, enter `https://github.com/oliverluette/bw-tools` and the package, then pull.
3. abapGit creates one sub-package per tool, for example `ZBWT_SNX`, and activates the objects.
4. Follow the tool-specific steps in its documentation, for example registering a process type.

Without a connection from the SAP system to GitHub, download the repository as ZIP and use **New Offline** with **Import ZIP** instead.

Installing the repository installs all tools. They are independent of each other.

## Repository layout

```
src/     ABAP objects, managed by abapGit
docs/    documentation, one folder per tool
```

Everything outside `src/` is ignored by abapGit.

## Naming

All objects start with `ZBWT_` (classes with `ZCL_BWT_`), followed by a short code for the tool, for example `SNX` for Snapshot Extended. abapGit installs the objects under these names.

## Disclaimer

The tools are provided as they are, without warranty. Test them in a development or test system before using them in production. They are not an SAP product and are not supported by SAP.

## AI assistance

The code and documentation were developed with the help of an AI assistant (Claude by Anthropic). The author checked them and tested them in an SAP BW/4HANA system.

## License

[MIT](LICENSE)
