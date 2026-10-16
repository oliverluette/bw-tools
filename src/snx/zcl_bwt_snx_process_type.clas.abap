CLASS zcl_bwt_snx_process_type DEFINITION
  PUBLIC
  INHERITING FROM cl_rspc_simple_process_type
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    " Custom process type for process chains (simple process type framework).
    " Wraps ZCL_BWT_SNX_SNAPSHOT: after partial full loads it compares the active table
    " of a standard aDSO with the inbound table within the scope of each load request
    " and writes the missing keys as deletion records.
    " The process ends green or red. Red on error or when the deletion rate is exceeded.
    "
    " In a chain the process always runs for real. A test run exists only in
    " report ZBWT_SNX_SNAPSHOT.
    "
    " Log: the method deliberately returns no messages via ET_MESSAGE.
    " The framework would write them to application log BW_PROCESS with the process type
    " as subobject. BW_PROCESS is an SAP object, a custom subobject would be a
    " modification, and without the subobject the framework sets the step to red.
    " The output therefore goes to the job log of the process as messages.
    INTERFACES if_rspc_simple_process_type.

    CONSTANTS gc_type TYPE rspc_type VALUE 'ZBWT_SNX'.

    CLASS-METHODS class_constructor.

  PRIVATE SECTION.
    CLASS-METHODS log
      IMPORTING iv_text TYPE string.
ENDCLASS.


CLASS zcl_bwt_snx_process_type IMPLEMENTATION.

  METHOD class_constructor.
    "----------------------------------------------------------------------
    " Snapshot Extended: process type ZBWT_SNX for process chains
    " Author:     Oliver Luette
    " Created on: 08.10.2026
    "----------------------------------------------------------------------
    " Tells the simple process type framework which process type this class
    " implements. View RSPROCESSTYPES must contain the same type with this class.
    c_type  = gc_type.
    c_class = 'ZCL_BWT_SNX_PROCESS_TYPE'.
  ENDMETHOD.


  METHOD if_rspc_simple_process_type~get_user_interface.
    " Input fields of the process variant in the process chain editor
    cr_simple_form_control->add_input_char(
      i_name       = `ADSO`
      i_text       = `aDSO (standard, write interface enabled)`
      i_upper_case = abap_true
      i_max_length = 9 ).
    cr_simple_form_control->add_input_number(
      i_name      = `MAXPCT`
      i_text      = `Maximum deletion rate in percent`
      i_min_value = 0
      i_max_value = 100 ).
  ENDMETHOD.


  METHOD if_rspc_simple_process_type~get_variant_reuse.
    " E_VARIANT_REUSE stays initial: the variant is not offered for reuse in other
    " chains. aDSO and limit are maintained directly in the process step of each chain.
  ENDMETHOD.


  METHOD if_rspc_simple_process_type~execute.
    " Runs Snapshot Extended as a step of a process chain: reads aDSO and limit from the
    " process variant, calls ZCL_BWT_SNX_SNAPSHOT as a real run, writes the result of
    " every load request to the job log and sets E_FAILED on any error, so the step
    " turns red.
    DATA lv_adso    TYPE string.
    DATA lv_max_pct TYPE zcl_bwt_snx_snapshot=>ty_pct VALUE '5.00'.

    " ET_MESSAGE stays empty, see the comment in the definition
    CLEAR: e_failed, et_message.

    " Read the values of the process variant
    LOOP AT it_variant ASSIGNING FIELD-SYMBOL(<ls_variant>).
      CASE <ls_variant>-fnam.
        WHEN 'ADSO'.
          lv_adso = <ls_variant>-low.
        WHEN 'MAXPCT'.
          IF <ls_variant>-low IS NOT INITIAL.
            TRY.
                lv_max_pct = <ls_variant>-low.
              CATCH cx_sy_conversion_error.
                log( |ERROR: Maximum deletion rate "{ <ls_variant>-low }" is not a number.| ).
                e_failed = abap_true.
                RETURN.
            ENDTRY.
          ENDIF.
      ENDCASE.
    ENDLOOP.

    IF lv_adso IS INITIAL.
      log( `ERROR: The aDSO is missing in the process variant.` ).
      e_failed = abap_true.
      RETURN.
    ENDIF.

    " Compare and write the deletion records, in a chain always as a real run
    DATA(ls_result) = NEW zcl_bwt_snx_snapshot( iv_adso    = lv_adso
                                                iv_max_pct = lv_max_pct )->run( iv_test = abap_false ).

    log( |Snapshot Extended: aDSO { ls_result-adso }, transformations into the aDSO: { ls_result-trfn_count }, | &&
         |load requests: { lines( ls_result-requests ) }, limit { lv_max_pct } % per request| ).

    LOOP AT ls_result-requests INTO DATA(ls_req).
      log( |Load request { ls_req-request_tsn }: transformation { ls_req-transformation }| ).
      log( |  Filter: { ls_req-filter_text } Constants: { COND #( WHEN ls_req-constant_text IS INITIAL THEN `none` ELSE ls_req-constant_text ) }| ).
      log( |  Rows: { ls_req-inbound_rows }, active records in scope: { ls_req-active_in_scope }, | &&
           |deletion candidates: { ls_req-delete_cands }, deletion rate { ls_req-delete_pct } %| ).
    ENDLOOP.

    IF ls_result-error IS NOT INITIAL.
      log( |ERROR: { ls_result-error }| ).
      e_failed = abap_true.
    ELSEIF ls_result-delete_cands = 0.
      log( `No deletion candidates, nothing was written.` ).
    ELSE.
      log( |{ ls_result-written_rows } deletion records written, deletion request { ls_result-delete_tsn }| ).
    ENDIF.
  ENDMETHOD.


  METHOD log.
    " Success message: in background it appears in the job log and never cancels the job.
    " Long texts are wrapped at word boundaries, so every line can be read completely.
    DATA(lt_lines) = zcl_bwt_snx_snapshot=>wrap_text( iv_text = iv_text iv_width = 120 ).
    LOOP AT lt_lines INTO DATA(lv_line).
      MESSAGE lv_line TYPE 'S'.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.

