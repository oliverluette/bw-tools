# bw-tools

Small, self-contained tools for SAP BW/4HANA.

| Tool | What it does | Package | Documentation |
| --- | --- | --- | --- |
| <img src="docs/snapshot-extended/images/icon.svg" alt="" width="20"> Snapshot Extended | Enhanced Snapshot functionality: detects deletions in the source for filtered full loads into standard aDSOs and passes them on as deltas | `ZBWT_SNX` | [docs/snapshot-extended](docs/snapshot-extended/README.md) |

## Related projects

Separate repositories, not part of the abapGit installation below.

| Project | What it does | Repository |
| --- | --- | --- |
| coBWeb | MCP server for modeling in SAP BW/4HANA: lets a language model search, read, write and activate BW objects, read data, monitor loads and run DTPs and process chains via the REST interface of the BW Modeling Tools. | [oliverluette/coBWeb-mcp](https://github.com/oliverluette/coBWeb-mcp) |
| abap2sqlscript | Claude skill that migrates the ABAP logic of BW transformations (start, end, expert and field routines, lookups) to SQLScript (AMDP) for HANA execution, with approval steps, lookup analysis and a comparison of old and new results. Documentation in German. | [oliverluette/abap2sqlscript](https://github.com/oliverluette/abap2sqlscript) |

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
