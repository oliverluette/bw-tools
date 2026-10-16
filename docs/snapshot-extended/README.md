<img src="images/icon.svg" alt="Snapshot Extended icon" width="96">

# Snapshot Extended

Deletion detection for filtered full loads into standard aDSOs on SAP BW/4HANA.

## The problem

The snapshot support of a standard aDSO treats every record that is missing in a load request as deleted in the source. That only works for unfiltered full loads. With a filtered full load, for example the last 12 fiscal periods, the activation would remove every record outside the filter.

A partial full load therefore either runs without snapshot support and never notices deletions in the source, or the complete data set has to be loaded every time.

Snapshot Extended closes this gap. It detects deletions within the scope of each load request and passes them on as regular deltas, without a second extraction and without an additional aDSO.

## How it works

A process step between the load DTPs and the activation compares, for every load request in the inbound table, the active table with the load request:

```
Start → Load DTP(s) → Snapshot Extended → Activate aDSO → Delta DTPs to targets
```

A record becomes a deletion candidate if

- it is in the active table of the aDSO,
- it lies within the **scope** of the load request, and
- its key does not occur in the load request.

The scope of a load request is the filter of its DTP plus every constant that its transformation writes into a characteristic of the aDSO.

For every candidate the step writes a deletion record (record mode `D`). All deletion records go into one separate request in the inbound table, written with the write interface of the aDSO. The standard activation then processes all requests together: it removes the records from the active table and writes reverse images (record mode `R`) to the change log. Downstream targets receive the deletions with their next delta.

Counting and reading run directly on SAP HANA via ADBC. Key fields, filter fields and constants are read from the metadata at runtime; nothing is coded per aDSO.

### Deletion rate

The deletion rate is the share of deletion candidates among the active records in the scope of a load request. It protects against mass deletions when a partial full load arrives empty or incomplete. If one load request exceeds the limit, nothing is written at all and the process step turns red.

### Several sources

An aDSO can be loaded from several sources, for example from several extractors or from the same extractor in several source systems. The comparison for one source must then leave out the records of the other sources, otherwise they would count as deleted.

For this, the aDSO gets a source field, for example `SOURCE`, and every transformation into the aDSO sets it as a constant with its own value. Snapshot Extended reads this constant from the transformation of each load request and limits the scope to it, for example to `SOURCE = SRC1`.

A guard checks the setup: if several transformations write into the aDSO, every other transformation must set a different constant in one of the scope fields. Otherwise the run terminates without writing anything.

### Several load requests

Every load request in the inbound table is processed separately, with its own scope, deletion rate and deletion candidates. One process step after all load DTPs is enough.

The run terminates without writing anything if

- two load requests come from the same transformation, because their scopes can overlap, or
- the inbound table already contains a deletion request from an earlier run.

## Objects

| Object | Name | Purpose |
| --- | --- | --- |
| Class | `ZCL_BWT_SNX_SNAPSHOT` | Core logic: determine requests and scopes, compare, check the deletion rate, write deletion records |
| Class | `ZCL_BWT_SNX_PROCESS_TYPE` | Process type `ZBWT_SNX` for process chains |
| Report | `ZBWT_SNX_SNAPSHOT` | Same logic for manual start: test run, manual release, or ABAP program step in a chain |

## Requirements

**Release.** Tested on SAP BW/4HANA with DW4CORE 400 SP04 and SAP_BASIS 758. Other releases are untested.

The code uses these SAP objects. Check that they exist in your system (SE24, SE37, SE11):

| Object | Used for |
| --- | --- |
| Class `CL_RSPC_SIMPLE_PROCESS_TYPE`, interface `IF_RSPC_SIMPLE_PROCESS_TYPE` | Framework for the custom process type |
| Class `CL_BW4_SIMPLE_FORM_CONTROL` | Input fields of the process step in the BW/4HANA Cockpit |
| Class `CL_RSBK_REQUEST`, methods `CREATE_FROM_DB` with parameter `I_REQUEST_TSN` and `GET_TH_RANGE` | Reading the filter of a load request |
| Interface `IF_RSBK_REQUEST`, methods `GET_T_TRANSFORMATION` and `GET_DTP` | Finding the transformation of a load request |
| Tables `RSTRAN`, `RSTRANRULE`, `RSTRANFIELD`, `RSTRANSTEPCNST` | Reading constant rules of transformations |
| Function module `RSDSO_WRITE_API` | Writing the deletion records into the inbound table |

**Tools.** abapGit, standalone or developer version.

**Authorizations.** ABAP development, table maintenance of view `RSPROCESSTYPES` (SM30), BW modeling and process chains.

## Installation

### 1. Install the objects

Install the repository with abapGit as described in the [main README](../../README.md). The objects of this tool are in sub-package `ZBWT_SNX`.

For productive use, install into a transportable package and transport the objects as usual.

### 2. Register the process type

Maintain view `RSPROCESSTYPES` in SM30 and create a new entry:

| Field | Value |
| --- | --- |
| Process type | `ZBWT_SNX` |
| Description | for example "Snapshot Extended: write deletion records" |
| Object name | `ZCL_BWT_SNX_PROCESS_TYPE` |
| Object type | ABAP OO class |
| Possible events | process ends successfully or incorrectly |
| Repeatable | yes |
| Process category | 20, the category of the aDSO activation |
| Icon | any |

The entry is transportable. abapGit cannot install it, because `RSPROCESSTYPES` is an SAP table.

A subobject for application log `BW_PROCESS` is **not** needed. The process type writes its output to the job log of the process.

**Check:** in the process chain editor of the BW/4HANA Cockpit the new process type appears in the same group as the aDSO activation. The step has two input fields: "aDSO (standard, write interface enabled)" and "Maximum deletion rate in percent".

## Setting up an aDSO

### aDSO

1. Standard aDSO with change log and key fields.
2. Snapshot support **switched off**. Otherwise the standard logic still removes everything outside the filter.
3. Write interface switched on ("Write Interface-Enabled" in the general settings), then activate the aDSO.
4. No namespace in the technical name. The tables are derived as `/BIC/A<aDSO>1` (inbound table) and `/BIC/A<aDSO>2` (active table).

### Load DTPs and transformations

1. Every load DTP runs in full mode and has a filter, for example on the fiscal period.
2. Every filter field is mapped 1:1 into the aDSO and has the same name there. Filter fields are matched by name.
3. The value of a filter field must not change for a record. If a record moves out of the filter in the source, it is deleted in BW.
4. Key figures are overwritten. Summation is untested.
5. A rolling window comes from the DTP filter: fixed values, a filter routine or a variable. Only fixed values are tested.

### Additionally for several sources

1. Add a source field to the aDSO, for example `SOURCE` as CHAR 10.
2. If two sources can deliver the same document key, put the source field **into the key**. Otherwise the sources overwrite each other's records.
3. In **every** transformation into the aDSO, set the source field as a **constant** with its own value per source.
4. The constant must be in the transformation that writes directly into the aDSO. With an InfoSource in between, only the second transformation counts.

Changing a transformation deactivates its DTPs. Activate them again afterwards.

The source field is easiest to add before the first load. With data in the aDSO, a key change may require remodeling.

### Process chain

1. Start.
2. All load DTPs of the aDSO, one after another, each connected "on success".
3. Process type `ZBWT_SNX`, connected "on success" of the last DTP. Enter the aDSO and the maximum deletion rate in percent, for example 5.
4. Activation of the aDSO, connected "on success" of the process type. **Enter the aDSO in the activation variant.** Without it, the activation step ends green and activates nothing.
5. Delta DTPs to downstream targets, if any.

Save and activate the chain.

Instead of the process type, report `ZBWT_SNX_SNAPSHOT` can run as an ABAP program step with a report variant. An ABAP program step has no success or failure branch. If the report terminates, the activation does not run either.

## Operations

### Regular runs

The chain runs with the rolling filter of the load DTPs. Deletions within the scope are detected, everything outside stays untouched, including the records of other sources.

The process type writes the result of every load request to the job log of the step, for example:

```
Snapshot Extended: aDSO ZSNXCO02, transformations into the aDSO: 2, load requests: 2, limit 5.00 % per request
Load request 20261016074957000017000: transformation 00ZJHIH3FKVEECH0H2DYINFEI2WC4SNM
Filter: FISC_PER I BT 2026001 2026012; Constants: SOURCE = CODOC1
Rows: 264, active records in scope: 273, deletion candidates: 9, deletion rate 3.30 %
Load request 20261016075001000064000: transformation 0O7EJ5VS9WD336JPSZPL7QJRS6ZTVXFD
Filter: FISC_PER I BT 2026001 2026012; Constants: SOURCE = CODOC2
Rows: 303, active records in scope: 312, deletion candidates: 9, deletion rate 2.88 %
18 deletion records written, deletion request 20261016075005000069000
```

The report shows the same information as a list.

### Deletion rate exceeded

The step turns red and nothing was written. The message in the job log starts with "Deletion rate exceeds the limit of …", names the load requests concerned and the way to release them. If the deletions are justified:

1. Run report `ZBWT_SNX_SNAPSHOT` for the aDSO without "Test run (count only)" and with a higher value in "Max. deletion rate in percent". It writes the deletion request.
2. In the process chain monitor, skip the red step. The activation then processes all requests.

**Do not change the process chain in between.** Once the chain has been saved, the red run can neither be repeated nor skipped. Raising the limit in the chain therefore does not help for a run that is already red.

If the deletions are not justified, for example after an incomplete load: delete the load requests from the inbound table, fix the cause and restart the chain.

### Restart after a red run

The load requests stay in the inbound table after a red run. A restart loads the same sources again, and the run terminates because two requests come from the same transformation. Delete the old requests before the restart.

### Reloading outside the rolling window

Reloading older periods works the same way: run the DTP with a filter on those periods, then the process step or the report, then the activation. The comparison covers only the reloaded periods.

## Testing

Run these tests in a development or test system.

1. **Test run with the report.** Run a load DTP manually and do not activate the request. Start `ZBWT_SNX_SNAPSHOT` for the aDSO with "Test run (count only)". The list shows filter, transformation, constants, rows in the request and active records in the scope of every request. Without deletions in the source there are 0 deletion candidates.
2. **Chain without deletions.** Activate or delete the request from test 1, then start the chain. It runs green.
3. **Chain with deletions.** Delete some records in the source within the filter, below the deletion rate. The chain runs green, the records are gone from the active table, and the change log contains one reverse image per record.
4. **Deletion rate exceeded.** Delete more records than the limit allows. The step turns red and the activation does not run. Then try the manual release: report without test run and with a higher limit, skip the red step. Do not change the chain in between.

Additionally for several sources:

5. **Deletions in one source only.** The chain runs green. The unchanged source has 0 deletion candidates, and the change log contains reverse images only for the changed source.
6. **Guard (optional).** Temporarily set the constant of a second transformation to the same value as the first one, load a DTP of the first source and run the report. It must terminate. Then reset the constant and activate the deactivated DTP again.

## Troubleshooting

Messages are in English and appear in the report list or in the job log of the process step. Long messages are wrapped over several lines.

| Message or symptom | Cause | Solution |
| --- | --- | --- |
| Active table … not found | Wrong aDSO name, not a standard aDSO, or aDSO with namespace | Check the name, see "Setting up an aDSO" |
| Inbound table … contains no request that is not yet activated | The DTP loaded nothing, or the request is already activated | Check the order in the chain: DTPs before the process type, activation after it |
| Inbound table … already contains deletion request … | An earlier run, for example a manual release, already wrote deletion records | Activate the requests if everything is correct, otherwise delete the deletion request |
| Load requests … and … come from the same transformation … | The same source was loaded twice, for example on a restart after a red run | Delete the older request |
| aDSO … is loaded by n transformations. Transformation … is not separated by a constant … | A transformation into the aDSO does not set the source field, or sets the same value | Set a different constant in every transformation, see "Additionally for several sources" |
| aDSO … is loaded by n transformations, but the transformation of load request … could not be determined | The request does not come from a DTP into the aDSO, or the DTP path is unusual | Check what writes into the aDSO |
| Filter field … does not exist in aDSO … | The DTP filter field has another name in the aDSO or is missing there | Filter on a field with the same name that is mapped 1:1 |
| Filter option … on field … is not supported | The DTP filter uses an option other than EQ, NE, GT, GE, LT, LE, BT, NB, CP, NP | Change the filter |
| Filter of request … cannot be read | The request in the inbound table does not come from a DTP | Check what writes into the aDSO |
| Load request … is empty | The DTP wrote a request without rows | Check source and filter of the DTP |
| Deletion rate exceeds the limit of … % for load request … | More deletions than allowed | Clarify the cause, then manual release or restart |
| RSDSO_WRITE_API failed | Usually the write interface of the aDSO is not switched on | Switch it on and activate the aDSO |
| SQL error: … | Error in a statement on SAP HANA; the message contains the statement | Analyze the statement |
| ERROR: The aDSO is missing in the process variant | The aDSO field of the process step is empty | Enter the aDSO in the process step |
| Process type missing in the chain editor | Entry in `RSPROCESSTYPES` missing or with the wrong class | Check "Register the process type" |
| Activation ends green, the requests stay in the inbound table | No aDSO in the activation variant | Enter the aDSO in the variant, activate the chain |
| A DTP does not start, no request is created | Locks left over, for example after changing the DTP | Check and release the locks in SM12 |
| Repeating or skipping a red step has no effect | The chain was saved after the red run | Clean up as described in "Restart after a red run" |

## Limitations

- aDSOs with namespace are not supported.
- Filter fields must have the same name in the source and in the aDSO.
- Two load requests from the same transformation are not processed together, even if their filters do not overlap.
- Several sources must be separated by a constant in the transformation that writes directly into the aDSO. A separation only by a DTP filter on a source field is not detected by the guard.
- The keys of the deletion candidates are read per request in one go, not in packages. Large volumes are untested.
- The output goes to the job log only, not to the process log in the monitor.
- Untested: key figures with summation, variables in the DTP filter, a data flow through an InfoSource.

## Renaming the objects

abapGit installs the objects under their original names. If your naming conventions require other names, rename them after installation and adjust these places:

| Object | Adjust |
| --- | --- |
| `ZCL_BWT_SNX_SNAPSHOT` | References in the report and in the process type class |
| `ZBWT_SNX_SNAPSHOT` | Report name in the error text in method `RUN` of the core class |
| `ZCL_BWT_SNX_PROCESS_TYPE` | Literal for `c_class` in `CLASS_CONSTRUCTOR`, entry in `RSPROCESSTYPES` |
| Process type `ZBWT_SNX` (at most 10 characters) | Constant `gc_type` of the process type class, entry in `RSPROCESSTYPES` |

Renamed objects can no longer be updated with abapGit.

## AI assistance

The code and this documentation were developed with the help of an AI assistant (Claude by Anthropic). The author checked them and tested them in an SAP BW/4HANA system.
