REPORT zbwt_snx_snapshot.

"----------------------------------------------------------------------
" Snapshot Extended: deletion records for partial full loads
" Author:     Oliver Luette
" Created on: 07.10.2026
"----------------------------------------------------------------------
" After partial full loads the report compares the active table of a standard aDSO
" with the inbound table. Every load request in the inbound table is processed
" separately, limited to its scope: the DTP filter plus the constants that its
" transformation writes into the aDSO. For every key that is missing in its load
" request the report writes a deletion record (record mode D); all deletion records
" go into one separate request in the inbound table.
" Use it for a test run, for the manual release when the deletion rate is exceeded,
" or as process step (ABAP program) between load DTPs and activation.

PARAMETERS: p_adso  TYPE c LENGTH 9 OBLIGATORY,
            p_maxpc TYPE zcl_bwt_snx_snapshot=>ty_pct DEFAULT '5.00',
            p_test  AS CHECKBOX DEFAULT 'X'.

START-OF-SELECTION.

  DATA(gs_result) = NEW zcl_bwt_snx_snapshot( iv_adso    = p_adso
                                              iv_max_pct = p_maxpc )->run( iv_test = p_test ).

  WRITE: / 'aDSO:                      ', gs_result-adso.
  WRITE: / 'Inbound table:             ', gs_result-inbound_table.
  WRITE: / 'Active table:              ', gs_result-active_table.
  WRITE: / 'Key fields:                ', gs_result-key_fields.
  WRITE: / 'Transformations into aDSO: ', gs_result-trfn_count.
  WRITE: / 'Load requests:             ', lines( gs_result-requests ).
  WRITE: / 'Limit in percent:          ', p_maxpc.

  LOOP AT gs_result-requests INTO DATA(gs_req).
    SKIP.
    WRITE: / 'Load request (TSN):        ', gs_req-request_tsn.
    WRITE: / 'Filter of the request:     ', gs_req-filter_text.
    WRITE: / 'Transformation:            ', gs_req-transformation.
    WRITE: / 'Constants in scope:        ', gs_req-constant_text.
    WRITE: / 'Condition in SQL:          ', gs_req-where_clause.
    WRITE: / 'Rows in the load request:  ', gs_req-inbound_rows.
    WRITE: / 'Active records in scope:   ', gs_req-active_in_scope.
    WRITE: / 'Deletion candidates:       ', gs_req-delete_cands.
    WRITE: / 'Deletion rate in percent:  ', gs_req-delete_pct.
  ENDLOOP.

  SKIP.
  WRITE: / 'Deletion candidates total: ', gs_result-delete_cands.
  SKIP.

  IF gs_result-error IS NOT INITIAL.
    " The message is wrapped at word boundaries, so it can be read completely
    DATA(gt_lines) = zcl_bwt_snx_snapshot=>wrap_text( iv_text = gs_result-error iv_width = 100 ).
    WRITE: / 'Terminated:'.
    LOOP AT gt_lines INTO DATA(gv_line).
      WRITE: /3 gv_line.
    ENDLOOP.
    IF sy-batch = abap_true.
      " In background every line goes to the job log, then the error message cancels the job
      " and the process step turns red
      LOOP AT gt_lines INTO gv_line.
        MESSAGE gv_line TYPE 'S'.
      ENDLOOP.
      MESSAGE 'Snapshot Extended terminated, see the messages above.' TYPE 'E'.
    ELSE.
      MESSAGE 'Snapshot Extended terminated, see the list for details.' TYPE 'S' DISPLAY LIKE 'E'.
    ENDIF.
  ELSEIF p_test = abap_true.
    IF gs_result-quota_exceeded = abap_true.
      WRITE: / 'Test run: deletion rate above the limit for at least one request, a real run would terminate.'.
    ELSE.
      WRITE: / 'Test run: deletion rates within the limit, nothing was written.'.
    ENDIF.
  ELSEIF gs_result-delete_cands = 0.
    WRITE: / 'No deletion candidates, nothing was written.'.
  ELSE.
    WRITE: / 'Deletion records written:  ', gs_result-written_rows.
    WRITE: / 'Deletion request (TSN):    ', gs_result-delete_tsn.
  ENDIF.
