CLASS zcl_bwt_snx_snapshot DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    TYPES ty_pct TYPE p LENGTH 5 DECIMALS 2.
    TYPES:
      BEGIN OF ty_req_result,
        request_tsn     TYPE rspm_request_tsn,
        filter_text     TYPE string,
        transformation  TYPE string,
        constant_text   TYPE string,
        where_clause    TYPE string,
        inbound_rows    TYPE int8,
        active_in_scope TYPE int8,
        delete_cands    TYPE int8,
        delete_pct      TYPE ty_pct,
        quota_exceeded  TYPE abap_bool,
      END OF ty_req_result,
      ty_t_req_result TYPE STANDARD TABLE OF ty_req_result WITH EMPTY KEY.
    TYPES:
      BEGIN OF ty_result,
        adso           TYPE string,
        inbound_table  TYPE string,
        active_table   TYPE string,
        key_fields     TYPE string,
        trfn_count     TYPE i,
        requests       TYPE ty_t_req_result,
        delete_cands   TYPE int8,
        quota_exceeded TYPE abap_bool,
        written_rows   TYPE i,
        delete_tsn     TYPE rspm_request_tsn,
        error          TYPE string,
      END OF ty_result.

    "! @parameter iv_adso    | Standard aDSO whose partial full loads are checked
    "! @parameter iv_max_pct | Maximum deletion rate per load request, in percent
    METHODS constructor
      IMPORTING iv_adso    TYPE csequence
                iv_max_pct TYPE ty_pct DEFAULT '5.00'.

    "! Processes every load request in the inbound table separately. The scope of a
    "! request is its DTP filter plus every constant that its transformation writes into
    "! a characteristic of the aDSO. Active records within the scope that are missing in
    "! the request become deletion candidates.
    "! A test run only counts. Otherwise, if every request stays within the limit, the
    "! method writes all deletion records (record mode D) as one separate request into
    "! the inbound table. If one request exceeds the limit, nothing is written.
    METHODS run
      IMPORTING iv_test          TYPE abap_bool DEFAULT abap_true
      RETURNING VALUE(rs_result) TYPE ty_result.
    "! Splits a text at word boundaries into lines of at most iv_width characters,
    "! for list output and job log messages. A word longer than a line is cut.
    CLASS-METHODS wrap_text
      IMPORTING iv_text         TYPE csequence
                iv_width        TYPE i DEFAULT 100
      RETURNING VALUE(rt_lines) TYPE string_table.

  PRIVATE SECTION.
    TYPES ty_t_range TYPE STANDARD TABLE OF rsbk_s_range WITH EMPTY KEY.
    TYPES ty_t_tsn TYPE STANDARD TABLE OF rspm_request_tsn WITH EMPTY KEY.
    TYPES ty_t_tranid TYPE STANDARD TABLE OF rstran-tranid WITH EMPTY KEY.
    TYPES:
      BEGIN OF ty_field,
        name     TYPE string,
        datatype TYPE dd03l-datatype,
        leng     TYPE dd03l-leng,
      END OF ty_field,
      ty_t_field TYPE HASHED TABLE OF ty_field WITH UNIQUE KEY name.
    TYPES:
      BEGIN OF ty_const,
        fieldnm    TYPE rstranfield-fieldnm,
        value      TYPE string,
        column     TYPE string,
        bind_value TYPE string,
      END OF ty_const,
      ty_t_const TYPE SORTED TABLE OF ty_const WITH UNIQUE KEY fieldnm.
    TYPES:
      BEGIN OF ty_query,
        sql  TYPE string,
        bind TYPE string_table,
      END OF ty_query,
      ty_t_query TYPE STANDARD TABLE OF ty_query WITH EMPTY KEY.

    DATA mv_adso      TYPE string.
    DATA mv_max_pct   TYPE ty_pct.
    DATA mv_inbound   TYPE tabname.
    DATA mv_active    TYPE tabname.
    DATA mt_fields    TYPE string_table.
    DATA mt_fieldinfo TYPE ty_t_field.
    DATA mt_keys      TYPE string_table.
    DATA mt_trfn      TYPE ty_t_tranid.
    DATA mt_bind      TYPE string_table.
    DATA mv_error     TYPE string.
    DATA mo_request   TYPE REF TO cl_rsbk_request.

    METHODS read_metadata.
    METHODS find_requests
      RETURNING VALUE(rt_tsn) TYPE ty_t_tsn.
    METHODS build_filter
      IMPORTING iv_tsn   TYPE rspm_request_tsn
      EXPORTING ev_where TYPE string
                ev_text  TYPE string.
    METHODS add_constants
      CHANGING cs_req TYPE ty_req_result.
    METHODS find_transformation
      RETURNING VALUE(rv_tranid) TYPE rstran-tranid.
    METHODS read_constants
      IMPORTING iv_tranid       TYPE rstran-tranid
      RETURNING VALUE(rt_const) TYPE ty_t_const.
    METHODS map_column
      IMPORTING iv_fieldnm      TYPE csequence
      RETURNING VALUE(rs_field) TYPE ty_field.
    METHODS range_to_sql
      IMPORTING is_range      TYPE rsbk_s_range
      RETURNING VALUE(rv_sql) TYPE string.
    METHODS count
      IMPORTING iv_sql          TYPE string
                it_bind         TYPE string_table
      RETURNING VALUE(rv_count) TYPE int8.
    METHODS write_deletes
      IMPORTING it_query TYPE ty_t_query
      EXPORTING ev_lines TYPE i
                ev_tsn   TYPE rspm_request_tsn.
ENDCLASS.


CLASS zcl_bwt_snx_snapshot IMPLEMENTATION.

  METHOD constructor.
    "----------------------------------------------------------------------
    " Snapshot Extended: deletion records for partial full loads
    " Author:     Oliver Luette
    " Created on: 07.10.2026
    "----------------------------------------------------------------------
    " Takes the aDSO and the limit and derives the names of the generated tables.
    " An aDSO without namespace has the inbound table /BIC/A<aDSO>1 and the active
    " table /BIC/A<aDSO>2. aDSOs with namespace are not supported.
    mv_adso    = to_upper( condense( CONV string( iv_adso ) ) ).
    mv_max_pct = iv_max_pct.
    mv_inbound = |/BIC/A{ mv_adso }1|.
    mv_active  = |/BIC/A{ mv_adso }2|.
  ENDMETHOD.


  METHOD run.
    " Phase 1 determines scope, counts and deletion rate of every load request and stops
    " at the first error. Phase 2 writes the deletion records of all requests, but only
    " in a real run and only if no request exceeds the limit.
    DATA lt_tsn     TYPE ty_t_tsn.
    DATA lt_query   TYPE ty_t_query.
    DATA ls_req     TYPE ty_req_result.
    DATA lv_keyjoin TYPE string.
    DATA lv_keylist TYPE string.

    CLEAR mv_error.
    rs_result-adso          = mv_adso.
    rs_result-inbound_table = mv_inbound.
    rs_result-active_table  = mv_active.

    read_metadata( ).

    IF mv_error IS INITIAL.
      rs_result-key_fields = concat_lines_of( table = mt_keys sep = `, ` ).

      SELECT tranid
        FROM rstran
        WHERE objvers    = 'A'
          AND targettype = 'ADSO'
          AND targetname = @mv_adso
          AND is_shadow  = @abap_false
        INTO TABLE @mt_trfn.
      rs_result-trfn_count = lines( mt_trfn ).

      lt_tsn = find_requests( ).
    ENDIF.

    " Phase 1: scope and counts per load request. Nothing is written here.
    IF mv_error IS INITIAL.
      lv_keyjoin = concat_lines_of(
                     table = VALUE string_table( FOR lv_key IN mt_keys ( |n."{ lv_key }" = a."{ lv_key }"| ) )
                     sep   = ` AND ` ).
      lv_keylist = concat_lines_of(
                     table = VALUE string_table( FOR lv_key IN mt_keys ( |a."{ lv_key }"| ) )
                     sep   = `, ` ).

      LOOP AT lt_tsn INTO DATA(lv_tsn).
        CLEAR ls_req.
        ls_req-request_tsn = lv_tsn.

        build_filter( EXPORTING iv_tsn   = lv_tsn
                      IMPORTING ev_where = ls_req-where_clause
                                ev_text  = ls_req-filter_text ).

        " Constants of the transformation narrow the scope to the records this source can deliver
        IF mv_error IS INITIAL.
          add_constants( CHANGING cs_req = ls_req ).
        ENDIF.

        " Two requests from the same transformation can overlap in scope
        IF mv_error IS INITIAL.
          LOOP AT rs_result-requests INTO DATA(ls_prev) WHERE transformation = ls_req-transformation.
            mv_error = |Load requests { ls_prev-request_tsn } and { lv_tsn } come from the same | &&
                       |transformation { ls_req-transformation }, their scopes can overlap. | &&
                       |Activate or delete one of them first. Nothing was written.|.
            EXIT.
          ENDLOOP.
        ENDIF.

        IF mv_error IS INITIAL.
          DATA(lv_tsn_text) = CONV string( lv_tsn ).
          DATA(lt_bind_all) = mt_bind.
          APPEND lv_tsn_text TO lt_bind_all.

          " Active records within the scope that are missing in this load request
          DATA(lv_from) = |FROM "{ mv_active }" AS a WHERE { ls_req-where_clause }| &&
                          | AND NOT EXISTS ( SELECT 1 FROM "{ mv_inbound }" AS n| &&
                          | WHERE n."REQTSN" = ? AND { lv_keyjoin } )|.

          ls_req-inbound_rows = count(
            iv_sql  = |SELECT COUNT(*) FROM "{ mv_inbound }" AS n WHERE n."REQTSN" = ?|
            it_bind = VALUE #( ( lv_tsn_text ) ) ).
        ENDIF.

        IF mv_error IS INITIAL.
          ls_req-active_in_scope = count(
            iv_sql  = |SELECT COUNT(*) FROM "{ mv_active }" AS a WHERE { ls_req-where_clause }|
            it_bind = mt_bind ).
        ENDIF.

        IF mv_error IS INITIAL.
          ls_req-delete_cands = count( iv_sql  = |SELECT COUNT(*) { lv_from }|
                                       it_bind = lt_bind_all ).
        ENDIF.

        IF mv_error IS INITIAL AND ls_req-inbound_rows = 0.
          mv_error = |Load request { lv_tsn } is empty.|.
        ENDIF.

        IF mv_error IS INITIAL.
          IF ls_req-active_in_scope > 0.
            ls_req-delete_pct = ls_req-delete_cands * 100 / ls_req-active_in_scope.
          ENDIF.
          ls_req-quota_exceeded = xsdbool( ls_req-delete_pct > mv_max_pct ).
          IF ls_req-delete_cands > 0.
            APPEND VALUE #( sql  = |SELECT { lv_keylist } { lv_from }|
                            bind = lt_bind_all ) TO lt_query.
          ENDIF.
          rs_result-delete_cands = rs_result-delete_cands + ls_req-delete_cands.
          IF ls_req-quota_exceeded = abap_true.
            rs_result-quota_exceeded = abap_true.
          ENDIF.
        ENDIF.

        APPEND ls_req TO rs_result-requests.
        IF mv_error IS NOT INITIAL.
          EXIT.
        ENDIF.
      ENDLOOP.
    ENDIF.

    " Phase 2: write all deletion records, only if every request stays within the limit
    IF mv_error IS INITIAL AND iv_test = abap_false.
      IF rs_result-quota_exceeded = abap_true.
        " The text names the way to release manually: run the report by hand, then skip
        " the red step. The chain must not be changed in between, because the run can
        " no longer be continued once the chain has been saved.
        DATA(lt_over) = VALUE string_table( FOR ls_r IN rs_result-requests WHERE ( quota_exceeded = abap_true )
                                            ( |{ ls_r-request_tsn } ({ ls_r-delete_pct } %)| ) ).
        mv_error = |Deletion rate exceeds the limit of { mv_max_pct } % for load request | &&
                   |{ concat_lines_of( table = lt_over sep = `, ` ) }. Nothing was written. | &&
                   |Manual release: run report ZBWT_SNX_SNAPSHOT for aDSO { mv_adso } | &&
                   |without test run and with a higher maximum deletion rate, | &&
                   |then skip the red step in the process chain. | &&
                   |Do not change the process chain in between.|.
      ELSEIF rs_result-delete_cands > 0.
        write_deletes( EXPORTING it_query = lt_query
                       IMPORTING ev_lines = rs_result-written_rows
                                 ev_tsn   = rs_result-delete_tsn ).
      ENDIF.
    ENDIF.

    rs_result-error = mv_error.
  ENDMETHOD.


  METHOD read_metadata.
    " Reads the fields of the active table from the ABAP Dictionary: all field names
    " (to check the filter fields), their data types (to map constants) and the key
    " fields (to compare active table and load request). Also checks that the inbound
    " table exists.
    CLEAR: mt_fields, mt_fieldinfo, mt_keys.

    SELECT fieldname, keyflag, datatype, leng
      FROM dd03l
      WHERE tabname   = @mv_active
        AND as4local  = 'A'
        AND fieldname NOT LIKE '.%'
      ORDER BY position
      INTO TABLE @DATA(lt_dd03l).
    IF sy-subrc <> 0.
      mv_error = |Active table { mv_active } not found. Is { mv_adso } a standard aDSO?|.
      RETURN.
    ENDIF.

    LOOP AT lt_dd03l INTO DATA(ls_field).
      APPEND CONV string( ls_field-fieldname ) TO mt_fields.
      INSERT VALUE #( name     = ls_field-fieldname
                      datatype = ls_field-datatype
                      leng     = ls_field-leng ) INTO TABLE mt_fieldinfo.
      IF ls_field-keyflag = abap_true.
        APPEND CONV string( ls_field-fieldname ) TO mt_keys.
      ENDIF.
    ENDLOOP.
    IF mt_keys IS INITIAL.
      mv_error = |Active table { mv_active } has no key fields.|.
      RETURN.
    ENDIF.

    SELECT SINGLE tabname
      FROM dd02l
      WHERE tabname  = @mv_inbound
        AND as4local = 'A'
      INTO @DATA(lv_inbound).
    IF sy-subrc <> 0.
      mv_error = |Inbound table { mv_inbound } not found.|.
    ENDIF.
  ENDMETHOD.


  METHOD find_requests.
    " Load requests are all requests in the inbound table. A request that holds only
    " deletion records (record mode D) was written by an earlier run; processing the
    " table again would write the deletions twice.
    TYPES:
      BEGIN OF ty_mode,
        reqtsn     TYPE rspm_request_tsn,
        recordmode TYPE c LENGTH 1,
        cnt        TYPE int8,
      END OF ty_mode.
    DATA lt_mode TYPE STANDARD TABLE OF ty_mode WITH EMPTY KEY.
    DATA lt_all  TYPE SORTED TABLE OF rspm_request_tsn WITH UNIQUE KEY table_line.
    DATA lt_load TYPE SORTED TABLE OF rspm_request_tsn WITH UNIQUE KEY table_line.

    TRY.
        SELECT reqtsn, recordmode, COUNT(*) AS cnt
          FROM (mv_inbound)
          GROUP BY reqtsn, recordmode
          INTO TABLE @lt_mode.
      CATCH cx_sy_dynamic_osql_error INTO DATA(lx_osql).
        mv_error = |Inbound table { mv_inbound } cannot be read: { lx_osql->get_text( ) }|.
        RETURN.
    ENDTRY.

    LOOP AT lt_mode INTO DATA(ls_mode).
      INSERT ls_mode-reqtsn INTO TABLE lt_all.
      IF ls_mode-recordmode <> 'D'.
        INSERT ls_mode-reqtsn INTO TABLE lt_load.
      ENDIF.
    ENDLOOP.

    LOOP AT lt_all INTO DATA(lv_req).
      IF NOT line_exists( lt_load[ table_line = lv_req ] ).
        mv_error = |Inbound table { mv_inbound } already contains deletion request { lv_req }. | &&
                   |Activate or delete it first. Nothing was written.|.
        RETURN.
      ENDIF.
    ENDLOOP.

    IF lt_load IS INITIAL.
      mv_error = |Inbound table { mv_inbound } contains no request that is not yet activated.|.
      RETURN.
    ENDIF.

    rt_tsn = VALUE #( FOR lv_load IN lt_load ( lv_load ) ).
  ENDMETHOD.


  METHOD build_filter.
    " Reads the DTP filter of a load request and translates it into a condition on the
    " active table (alias a). Selections of one field are combined with OR, excluding
    " selections with AND NOT, and the fields with AND. The values go into mt_bind as
    " parameters. The request object is kept for find_transformation.
    DATA lt_range     TYPE ty_t_range.
    DATA lt_fieldcond TYPE string_table.
    DATA lv_incl      TYPE string.
    DATA lv_excl      TYPE string.
    DATA lv_fieldcond TYPE string.
    DATA lv_cond      TYPE string.

    CLEAR: ev_where, ev_text, mt_bind, mo_request.

    TRY.
        mo_request = cl_rsbk_request=>create_from_db( i_request_tsn = iv_tsn ).
        DATA(lth_range) = mo_request->get_th_range( i_for_ui = rs_c_false ).
      CATCH cx_root INTO DATA(lx_root).
        mv_error = |Filter of request { iv_tsn } cannot be read: { lx_root->get_text( ) }|.
        RETURN.
    ENDTRY.

    lt_range = VALUE #( FOR ls_line IN lth_range ( ls_line ) ).
    SORT lt_range BY fieldnm ASCENDING sign DESCENDING posit ASCENDING.

    LOOP AT lt_range INTO DATA(ls_range).
      ev_text = ev_text && |{ ls_range-fieldnm } { ls_range-sign } { ls_range-option } { ls_range-low } { ls_range-high }; |.
    ENDLOOP.

    LOOP AT lt_range INTO ls_range GROUP BY ( fieldnm = ls_range-fieldnm ) INTO DATA(ls_group).
      IF NOT line_exists( mt_fields[ table_line = ls_group-fieldnm ] ).
        mv_error = |Filter field { ls_group-fieldnm } does not exist in aDSO { mv_adso }.|.
        RETURN.
      ENDIF.

      CLEAR: lv_incl, lv_excl, lv_fieldcond.
      LOOP AT GROUP ls_group INTO DATA(ls_member).
        lv_cond = range_to_sql( ls_member ).
        IF mv_error IS NOT INITIAL.
          RETURN.
        ENDIF.
        IF ls_member-sign = 'E'.
          lv_excl = COND #( WHEN lv_excl IS INITIAL THEN lv_cond ELSE |{ lv_excl } OR { lv_cond }| ).
        ELSE.
          lv_incl = COND #( WHEN lv_incl IS INITIAL THEN lv_cond ELSE |{ lv_incl } OR { lv_cond }| ).
        ENDIF.
      ENDLOOP.

      IF lv_incl IS NOT INITIAL.
        lv_fieldcond = |( { lv_incl } )|.
      ENDIF.
      IF lv_excl IS NOT INITIAL.
        lv_fieldcond = COND #( WHEN lv_fieldcond IS INITIAL
                               THEN |NOT ( { lv_excl } )|
                               ELSE |{ lv_fieldcond } AND NOT ( { lv_excl } )| ).
      ENDIF.
      APPEND lv_fieldcond TO lt_fieldcond.
    ENDLOOP.

    " A request without filter means comparison across the whole aDSO
    ev_where = COND #( WHEN lt_fieldcond IS INITIAL
                       THEN `1 = 1`
                       ELSE concat_lines_of( table = lt_fieldcond sep = ` AND ` ) ).
  ENDMETHOD.


  METHOD add_constants.
    " Case 1: one transformation into the aDSO. Constants of that transformation
    " (if any) only narrow the scope further; without constants nothing changes.
    " Case 2: several transformations into the aDSO, for example one per source.
    " Every record of the load request carries the constants of its transformation,
    " so the scope is limited to those values. A guard makes sure that every other
    " transformation into the aDSO writes a different constant into one of these
    " fields; otherwise the records of the other source would count as deleted.
    DATA lt_scope TYPE ty_t_const.
    DATA lt_cond  TYPE string_table.
    DATA lt_text  TYPE string_table.

    DATA(lv_tranid) = find_transformation( ).
    cs_req-transformation = lv_tranid.

    " Constants of the request's transformation that restrict a characteristic of the aDSO
    IF lv_tranid IS NOT INITIAL.
      DATA(lt_mine) = read_constants( lv_tranid ).
      LOOP AT lt_mine INTO DATA(ls_mine).
        DATA(ls_field) = map_column( ls_mine-fieldnm ).
        IF ls_field-name IS INITIAL.
          CONTINUE.
        ENDIF.
        ls_mine-column     = ls_field-name.
        ls_mine-bind_value = ls_mine-value.
        IF ls_field-datatype = 'NUMC'.
          DATA(lv_width) = CONV i( ls_field-leng ).
          ls_mine-bind_value = |{ condense( ls_mine-value ) ALIGN = RIGHT WIDTH = lv_width PAD = '0' }|.
        ENDIF.
        INSERT ls_mine INTO TABLE lt_scope.
      ENDLOOP.
    ENDIF.

    " The constants are shown in the output even if the guard below terminates the run
    LOOP AT lt_scope INTO DATA(ls_scope).
      APPEND |{ ls_scope-column } = { ls_scope-bind_value }| TO lt_text.
    ENDLOOP.
    cs_req-constant_text = concat_lines_of( table = lt_text sep = `, ` ).

    " Guard for case 2
    IF lines( mt_trfn ) > 1.
      IF lv_tranid IS INITIAL.
        mv_error = |aDSO { mv_adso } is loaded by { lines( mt_trfn ) } transformations, | &&
                   |but the transformation of load request { cs_req-request_tsn } could not be determined. | &&
                   |Nothing was written.|.
        RETURN.
      ENDIF.
      LOOP AT mt_trfn INTO DATA(lv_other_tranid) WHERE table_line <> lv_tranid.
        DATA(lt_other)     = read_constants( lv_other_tranid ).
        DATA(lv_separated) = abap_false.
        LOOP AT lt_scope INTO ls_scope.
          READ TABLE lt_other WITH TABLE KEY fieldnm = ls_scope-fieldnm INTO DATA(ls_other).
          IF sy-subrc = 0 AND ls_other-value <> ls_scope-value.
            lv_separated = abap_true.
            EXIT.
          ENDIF.
        ENDLOOP.
        IF lv_separated = abap_false.
          mv_error = |aDSO { mv_adso } is loaded by { lines( mt_trfn ) } transformations. | &&
                     |Transformation { lv_other_tranid } is not separated by a constant | &&
                     |from transformation { lv_tranid } of load request { cs_req-request_tsn }. | &&
                     |Set a source field (for example SOURCE) to a different constant | &&
                     |in each transformation into the aDSO. Nothing was written.|.
          RETURN.
        ENDIF.
      ENDLOOP.
    ENDIF.

    " Append the constants to the scope; the values are bound after the filter values
    LOOP AT lt_scope INTO ls_scope.
      APPEND |a."{ ls_scope-column }" = ?| TO lt_cond.
      APPEND ls_scope-bind_value TO mt_bind.
    ENDLOOP.
    IF lt_cond IS NOT INITIAL.
      cs_req-where_clause = |{ cs_req-where_clause } AND { concat_lines_of( table = lt_cond sep = ` AND ` ) }|.
    ENDIF.
  ENDMETHOD.


  METHOD find_transformation.
    " Determines the transformation of the load request that writes into the aDSO.
    " The request lists the transformations of its DTP path; the one with the aDSO as
    " target is used. If that fails, the direct transformation between source and
    " target of the DTP is used. Without a result the returned ID stays initial.
    DATA lt_tf     TYPE rsbk_t_transformation.
    DATA lv_tranid TYPE rstran-tranid.

    TRY.
        lt_tf = mo_request->if_rsbk_request~get_t_transformation( ).
      CATCH cx_root.
        CLEAR lt_tf.
    ENDTRY.

    LOOP AT lt_tf INTO DATA(ls_tf).
      lv_tranid = ls_tf-tf.
      SELECT SINGLE tranid
        FROM rstran
        WHERE tranid     = @lv_tranid
          AND objvers    = 'A'
          AND targettype = 'ADSO'
          AND targetname = @mv_adso
        INTO @rv_tranid.
      IF sy-subrc = 0.
        RETURN.
      ENDIF.
    ENDLOOP.

    " Fallback: direct transformation between source and target of the DTP
    TRY.
        DATA(lv_dtp) = mo_request->if_rsbk_request~get_dtp( ).
      CATCH cx_root.
        RETURN.
    ENDTRY.
    SELECT SINGLE src
      FROM rsbkdtp
      WHERE dtp     = @lv_dtp
        AND objvers = 'A'
      INTO @DATA(lv_src).
    IF sy-subrc = 0.
      SELECT SINGLE tranid
        FROM rstran
        WHERE objvers    = 'A'
          AND sourcename = @lv_src
          AND targettype = 'ADSO'
          AND targetname = @mv_adso
        INTO @rv_tranid.
    ENDIF.
  ENDMETHOD.


  METHOD read_constants.
    " A target field counts as constant only if every rule on it outside the technical
    " group is a constant rule with the same value (several rule groups are possible).
    DATA lt_bad TYPE SORTED TABLE OF rstranfield-fieldnm WITH UNIQUE KEY table_line.

    SELECT r~ruletype, r~grouptype, f~fieldnm, c~value
      FROM rstranrule AS r
        INNER JOIN rstranfield AS f
          ON  f~tranid  = r~tranid
          AND f~objvers = r~objvers
          AND f~ruleid  = r~ruleid
        LEFT OUTER JOIN rstranstepcnst AS c
          ON  c~tranid  = r~tranid
          AND c~objvers = r~objvers
          AND c~ruleid  = r~ruleid
      WHERE r~tranid    = @iv_tranid
        AND r~objvers   = 'A'
        AND f~paramtype = '1'
      INTO TABLE @DATA(lt_rule).

    LOOP AT lt_rule INTO DATA(ls_rule) WHERE grouptype <> 'T'.
      IF ls_rule-ruletype <> 'CONSTANT'.
        INSERT ls_rule-fieldnm INTO TABLE lt_bad.
        CONTINUE.
      ENDIF.
      DATA(lv_value) = CONV string( ls_rule-value ).
      READ TABLE rt_const WITH TABLE KEY fieldnm = ls_rule-fieldnm INTO DATA(ls_const).
      IF sy-subrc <> 0.
        INSERT VALUE #( fieldnm = ls_rule-fieldnm value = lv_value ) INTO TABLE rt_const.
      ELSEIF ls_const-value <> lv_value.
        INSERT ls_rule-fieldnm INTO TABLE lt_bad.
      ENDIF.
    ENDLOOP.

    LOOP AT lt_bad INTO DATA(lv_bad).
      DELETE TABLE rt_const WITH TABLE KEY fieldnm = lv_bad.
    ENDLOOP.
  ENDMETHOD.


  METHOD map_column.
    " Field name in the transformation -> column of the active table.
    " Pure fields keep their name, InfoObjects appear as FISCPER (0FISCPER) or /BIC/<name>.
    " Only characteristic-like columns restrict the scope; key figures never do.
    DATA lt_try TYPE string_table.
    DATA(lv_name) = condense( CONV string( iv_fieldnm ) ).

    APPEND lv_name TO lt_try.
    IF strlen( lv_name ) > 1 AND substring( val = lv_name len = 1 ) = '0'.
      APPEND substring( val = lv_name off = 1 ) TO lt_try.
    ENDIF.
    APPEND |/BIC/{ lv_name }| TO lt_try.

    LOOP AT lt_try INTO DATA(lv_try).
      READ TABLE mt_fieldinfo WITH TABLE KEY name = lv_try INTO rs_field.
      IF sy-subrc = 0.
        IF NOT (    rs_field-datatype = 'CHAR' OR rs_field-datatype = 'NUMC'
                 OR rs_field-datatype = 'DATS' OR rs_field-datatype = 'TIMS'
                 OR rs_field-datatype = 'CUKY' OR rs_field-datatype = 'UNIT'
                 OR rs_field-datatype = 'LANG' OR rs_field-datatype = 'SSTR' ).
          CLEAR rs_field.
        ENDIF.
        RETURN.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD range_to_sql.
    " Translates one line of the DTP filter into an SQL predicate on the active table.
    " Values are bound as parameters (appended to mt_bind), never written into the SQL
    " text. Patterns use * and + as in ABAP and are converted to % and _ for LIKE.
    " An unsupported option sets an error.
    DATA(lv_col)  = |a."{ is_range-fieldnm }"|.
    DATA(lv_low)  = CONV string( is_range-low ).
    DATA(lv_high) = CONV string( is_range-high ).

    CASE is_range-option.
      WHEN 'EQ'.
        rv_sql = |{ lv_col } = ?|.
        APPEND lv_low TO mt_bind.
      WHEN 'NE'.
        rv_sql = |{ lv_col } <> ?|.
        APPEND lv_low TO mt_bind.
      WHEN 'GT'.
        rv_sql = |{ lv_col } > ?|.
        APPEND lv_low TO mt_bind.
      WHEN 'GE'.
        rv_sql = |{ lv_col } >= ?|.
        APPEND lv_low TO mt_bind.
      WHEN 'LT'.
        rv_sql = |{ lv_col } < ?|.
        APPEND lv_low TO mt_bind.
      WHEN 'LE'.
        rv_sql = |{ lv_col } <= ?|.
        APPEND lv_low TO mt_bind.
      WHEN 'BT'.
        rv_sql = |{ lv_col } BETWEEN ? AND ?|.
        APPEND lv_low  TO mt_bind.
        APPEND lv_high TO mt_bind.
      WHEN 'NB'.
        rv_sql = |{ lv_col } NOT BETWEEN ? AND ?|.
        APPEND lv_low  TO mt_bind.
        APPEND lv_high TO mt_bind.
      WHEN 'CP' OR 'NP'.
        REPLACE ALL OCCURRENCES OF '*' IN lv_low WITH '%'.
        REPLACE ALL OCCURRENCES OF '+' IN lv_low WITH '_'.
        rv_sql = COND #( WHEN is_range-option = 'CP'
                         THEN |{ lv_col } LIKE ?|
                         ELSE |{ lv_col } NOT LIKE ?| ).
        APPEND lv_low TO mt_bind.
      WHEN OTHERS.
        mv_error = |Filter option { is_range-option } on field { is_range-fieldnm } is not supported.|.
    ENDCASE.
  ENDMETHOD.


  METHOD count.
    " Runs a COUNT query directly on HANA via ADBC. The parameters are bound in the
    " order of the question marks in the statement. An SQL error is stored in mv_error
    " together with the statement.
    DATA lv_count TYPE int8.
    DATA(lt_bind) = it_bind.

    TRY.
        DATA(lo_statement) = NEW cl_sql_statement( ).
        LOOP AT lt_bind REFERENCE INTO DATA(lr_value).
          lo_statement->set_param( lr_value ).
        ENDLOOP.
        DATA(lo_result) = lo_statement->execute_query( iv_sql ).
        lo_result->set_param( REF #( lv_count ) ).
        lo_result->next( ).
        lo_result->close( ).
        rv_count = lv_count.
      CATCH cx_sql_exception INTO DATA(lx_sql).
        mv_error = |SQL error: { lx_sql->get_text( ) } { lx_sql->sql_message } Statement: { iv_sql }|.
    ENDTRY.
  ENDMETHOD.


  METHOD write_deletes.
    " Writes the deletion records of all load requests as one request into the inbound
    " table: reads the keys of the deletion candidates per request via ADBC, builds one
    " record per key with record mode D and calls the write interface of the aDSO
    " without activation. Each request is read in one go; the deletion rate limits
    " the volume.
    DATA lr_keys    TYPE REF TO data.
    DATA lr_part    TYPE REF TO data.
    DATA lr_data    TYPE REF TO data.
    DATA lt_keycomp TYPE cl_abap_structdescr=>component_table.
    DATA lt_msg     TYPE rs_t_msg.
    DATA lv_msgtext TYPE string.
    DATA lv_adsonm  TYPE rsoadsonm.
    FIELD-SYMBOLS <lt_keys> TYPE STANDARD TABLE.
    FIELD-SYMBOLS <lt_part> TYPE STANDARD TABLE.
    FIELD-SYMBOLS <lt_data> TYPE STANDARD TABLE.

    CLEAR: ev_lines, ev_tsn.

    " Derive the line type of the key list from the inbound table
    DATA(lo_inbound) = CAST cl_abap_structdescr( cl_abap_typedescr=>describe_by_name( mv_inbound ) ).
    DATA(lt_comp)    = lo_inbound->get_components( ).
    LOOP AT mt_keys INTO DATA(lv_key).
      APPEND lt_comp[ name = lv_key ] TO lt_keycomp.
    ENDLOOP.
    DATA(lo_keytab) = cl_abap_tabledescr=>create( cl_abap_structdescr=>create( lt_keycomp ) ).
    CREATE DATA lr_keys TYPE HANDLE lo_keytab.
    ASSIGN lr_keys->* TO <lt_keys>.

    " Read the keys of the deletion candidates of every load request from HANA
    LOOP AT it_query INTO DATA(ls_query).
      CREATE DATA lr_part TYPE HANDLE lo_keytab.
      ASSIGN lr_part->* TO <lt_part>.
      DATA(lt_bind) = ls_query-bind.
      TRY.
          DATA(lo_statement) = NEW cl_sql_statement( ).
          LOOP AT lt_bind REFERENCE INTO DATA(lr_value).
            lo_statement->set_param( lr_value ).
          ENDLOOP.
          DATA(lo_result) = lo_statement->execute_query( ls_query-sql ).
          lo_result->set_param_table( lr_part ).
          lo_result->next_package( ).
          lo_result->close( ).
        CATCH cx_sql_exception INTO DATA(lx_sql).
          mv_error = |SQL error: { lx_sql->get_text( ) } { lx_sql->sql_message } Statement: { ls_query-sql }|.
          RETURN.
      ENDTRY.
      APPEND LINES OF <lt_part> TO <lt_keys>.
    ENDLOOP.

    " Build the deletion records in the structure of the inbound table: key plus record mode D
    CREATE DATA lr_data TYPE STANDARD TABLE OF (mv_inbound).
    ASSIGN lr_data->* TO <lt_data>.
    LOOP AT <lt_keys> ASSIGNING FIELD-SYMBOL(<ls_key>).
      APPEND INITIAL LINE TO <lt_data> ASSIGNING FIELD-SYMBOL(<ls_data>).
      MOVE-CORRESPONDING <ls_key> TO <ls_data>.
      ASSIGN COMPONENT 'RECORDMODE' OF STRUCTURE <ls_data> TO FIELD-SYMBOL(<lv_recordmode>).
      IF sy-subrc <> 0.
        mv_error = |Inbound table { mv_inbound } has no field RECORDMODE.|.
        RETURN.
      ENDIF.
      <lv_recordmode> = 'D'.
    ENDLOOP.

    " Write as one separate request via the write interface, without activation
    lv_adsonm = mv_adso.
    CALL FUNCTION 'RSDSO_WRITE_API'
      EXPORTING
        i_adsonm            = lv_adsonm
        i_activate_data     = rs_c_false
        it_data             = <lt_data>
      IMPORTING
        e_lines_inserted    = ev_lines
        et_msg              = lt_msg
        e_upd_req_tsn       = ev_tsn
      EXCEPTIONS
        write_failed        = 1
        activation_failed   = 2
        datastore_not_found = 3
        OTHERS              = 4.
    IF sy-subrc <> 0.
      DATA(lv_subrc) = sy-subrc.
      LOOP AT lt_msg INTO DATA(ls_msg) WHERE msgty CA 'EAX'.
        MESSAGE ID ls_msg-msgid TYPE 'S' NUMBER ls_msg-msgno
                WITH ls_msg-msgv1 ls_msg-msgv2 ls_msg-msgv3 ls_msg-msgv4
                INTO DATA(lv_line).
        lv_msgtext = |{ lv_msgtext } { lv_line }|.
      ENDLOOP.
      mv_error = |RSDSO_WRITE_API failed (return code { lv_subrc }):{ lv_msgtext }|.
    ENDIF.
  ENDMETHOD.

  METHOD wrap_text.
    " Builds the lines word by word: a word goes onto the current line if it still
    " fits, otherwise it starts a new line. Multiple blanks are reduced to one.
    DATA lt_words TYPE string_table.
    DATA lv_line  TYPE string.
    DATA lv_word  TYPE string.
    DATA(lv_width) = nmax( val1 = iv_width val2 = 10 ).

    SPLIT condense( CONV string( iv_text ) ) AT space INTO TABLE lt_words.

    LOOP AT lt_words INTO lv_word.
      " A word longer than a line is cut into pieces of full line width
      WHILE strlen( lv_word ) > lv_width.
        IF lv_line IS NOT INITIAL.
          APPEND lv_line TO rt_lines.
          CLEAR lv_line.
        ENDIF.
        APPEND substring( val = lv_word len = lv_width ) TO rt_lines.
        lv_word = substring( val = lv_word off = lv_width ).
      ENDWHILE.

      IF lv_word IS INITIAL.
        CONTINUE.
      ELSEIF lv_line IS INITIAL.
        lv_line = lv_word.
      ELSEIF strlen( lv_line ) + 1 + strlen( lv_word ) <= lv_width.
        lv_line = |{ lv_line } { lv_word }|.
      ELSE.
        APPEND lv_line TO rt_lines.
        lv_line = lv_word.
      ENDIF.
    ENDLOOP.

    IF lv_line IS NOT INITIAL.
      APPEND lv_line TO rt_lines.
    ENDIF.
  ENDMETHOD.
ENDCLASS.

