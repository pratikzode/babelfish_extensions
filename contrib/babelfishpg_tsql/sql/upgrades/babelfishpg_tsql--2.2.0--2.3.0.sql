-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION ""babelfishpg_tsql"" UPDATE TO '2.3.0'" to load this file. \quit

-- add 'sys' to search path for the convenience
SELECT set_config('search_path', 'sys, '||current_setting('search_path'), false);

-- Drops a view if it does not have any dependent objects.
-- Is a temporary procedure for use by the upgrade script. Will be dropped at the end of the upgrade.
-- Please have this be one of the first statements executed in this upgrade script. 
CREATE OR REPLACE PROCEDURE babelfish_drop_deprecated_view(schema_name varchar, view_name varchar) AS
$$
DECLARE
    error_msg text;
    query1 text;
    query2 text;
BEGIN
    query1 := pg_catalog.format('alter extension babelfishpg_tsql drop view %s.%s', schema_name, view_name);
    query2 := pg_catalog.format('drop view %s.%s', schema_name, view_name);
    execute query1;
    execute query2;
EXCEPTION
    when object_not_in_prerequisite_state then --if 'alter extension' statement fails
        GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
        raise warning '%', error_msg;
    when dependent_objects_still_exist then --if 'drop view' statement fails
        GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
        raise warning '%', error_msg;
end
$$
LANGUAGE plpgsql;


-- please add your SQL here
CREATE OR REPLACE FUNCTION sys.is_table_type(object_id oid) RETURNS bool AS
$BODY$
SELECT
  EXISTS(
    SELECT 1
    FROM pg_catalog.pg_type pt
    INNER JOIN pg_catalog.pg_depend dep
    ON pt.typrelid = dep.objid AND pt.oid = dep.refobjid
    join sys.schemas sch on pt.typnamespace = sch.schema_id
    JOIN pg_catalog.pg_class pc ON pc.oid = dep.objid
    WHERE pt.typtype = 'c' AND dep.deptype = 'i' AND pt.typrelid = object_id AND pc.relkind = 'r'
    AND dep.classid = 'pg_catalog.pg_class'::regclass AND dep.refclassid = 'pg_catalog.pg_type'::regclass);
$BODY$
LANGUAGE SQL VOLATILE STRICT;

CREATE OR REPLACE PROCEDURE sys.sp_helpsrvrolemember("@srvrolename" sys.SYSNAME = NULL) AS
$$
BEGIN
	-- If server role is not specified, return info for all server roles
	IF @srvrolename IS NULL
	BEGIN
		SELECT CAST(Ext1.rolname AS sys.SYSNAME) AS 'ServerRole',
			   CAST(Ext2.rolname AS sys.SYSNAME) AS 'MemberName',
			   CAST(CAST(Base2.oid AS INT) AS sys.VARBINARY(85)) AS 'MemberSID'
		FROM pg_catalog.pg_auth_members AS Authmbr
		INNER JOIN pg_catalog.pg_roles AS Base1 ON Base1.oid = Authmbr.roleid
		INNER JOIN pg_catalog.pg_roles AS Base2 ON Base2.oid = Authmbr.member
		INNER JOIN sys.babelfish_authid_login_ext AS Ext1 ON Base1.rolname = Ext1.rolname
		INNER JOIN sys.babelfish_authid_login_ext AS Ext2 ON Base2.rolname = Ext2.rolname
		WHERE Ext1.type = 'R'
		ORDER BY ServerRole, MemberName;
	END
	-- If a valid server role is specified, return its member info
	-- If the role is a SQL server predefined role (i.e. serveradmin), 
	-- do not raise an error even if it does not exist
	ELSE IF EXISTS (SELECT 1
					FROM sys.babelfish_authid_login_ext
					WHERE (rolname = RTRIM(@srvrolename)
					OR lower(rolname) = lower(RTRIM(@srvrolename)))
					AND type = 'R')
					OR lower(RTRIM(@srvrolename)) IN (
					'serveradmin', 'setupadmin', 'securityadmin', 'processadmin',
					'dbcreator', 'diskadmin', 'bulkadmin')
	BEGIN
		SELECT CAST(Ext1.rolname AS sys.SYSNAME) AS 'ServerRole',
			   CAST(Ext2.rolname AS sys.SYSNAME) AS 'MemberName',
			   CAST(CAST(Base2.oid AS INT) AS sys.VARBINARY(85)) AS 'MemberSID'
		FROM pg_catalog.pg_auth_members AS Authmbr
		INNER JOIN pg_catalog.pg_roles AS Base1 ON Base1.oid = Authmbr.roleid
		INNER JOIN pg_catalog.pg_roles AS Base2 ON Base2.oid = Authmbr.member
		INNER JOIN sys.babelfish_authid_login_ext AS Ext1 ON Base1.rolname = Ext1.rolname
		INNER JOIN sys.babelfish_authid_login_ext AS Ext2 ON Base2.rolname = Ext2.rolname
		WHERE Ext1.type = 'R'
		AND (Ext1.rolname = RTRIM(@srvrolename) OR lower(Ext1.rolname) = lower(RTRIM(@srvrolename)))
		ORDER BY ServerRole, MemberName;
	END
	-- If the specified server role is not valid
	ELSE
		RAISERROR('%s is not a known fixed role.', 16, 1, @srvrolename);
END;
$$
LANGUAGE 'pltsql';
GRANT EXECUTE ON PROCEDURE sys.sp_helpsrvrolemember TO PUBLIC;

-- TODO: BABEL-3127
CREATE OR REPLACE VIEW sys.all_sql_modules_internal AS
SELECT
  ao.object_id AS object_id
  , CAST(
      CASE WHEN ao.type in ('P', 'FN', 'IN', 'TF', 'RF') THEN tsql_get_functiondef(ao.object_id)
      WHEN ao.type = 'V' THEN COALESCE(bvd.definition, '')
      WHEN ao.type = 'TR' THEN NULL
      ELSE NULL
      END
    AS sys.nvarchar(4000)) AS definition  -- Object definition work in progress, will update definition with BABEL-3127 Jira.
  , CAST(1 as sys.bit)  AS uses_ansi_nulls
  , CAST(1 as sys.bit)  AS uses_quoted_identifier
  , CAST(0 as sys.bit)  AS is_schema_bound
  , CAST(0 as sys.bit)  AS uses_database_collation
  , CAST(0 as sys.bit)  AS is_recompiled
  , CAST(
      CASE WHEN ao.type IN ('P', 'FN', 'IN', 'TF', 'RF') THEN
        CASE WHEN p.proisstrict THEN 1
        ELSE 0 
        END
      ELSE 0
      END
    AS sys.bit) as null_on_null_input
  , null::integer as execute_as_principal_id
  , CAST(0 as sys.bit) as uses_native_compilation
  , CAST(ao.is_ms_shipped as INT) as is_ms_shipped
FROM sys.all_objects ao
LEFT OUTER JOIN sys.pg_namespace_ext nmext on ao.schema_id = nmext.oid
LEFT OUTER JOIN sys.babelfish_namespace_ext ext ON nmext.nspname = ext.nspname
LEFT OUTER JOIN sys.babelfish_view_def bvd 
 on (
      ext.orig_name = bvd.schema_name AND 
      ext.dbid = bvd.dbid AND
      ao.name = bvd.object_name 
   )
LEFT JOIN pg_proc p ON ao.object_id = CAST(p.oid AS INT)
WHERE ao.type in ('P', 'RF', 'V', 'TR', 'FN', 'IF', 'TF', 'R');
GRANT SELECT ON sys.all_sql_modules_internal TO PUBLIC;

CREATE OR REPLACE FUNCTION sys.dateadd(IN datepart PG_CATALOG.TEXT, IN num INTEGER, IN startdate ANYELEMENT) RETURNS ANYELEMENT
AS
$body$
BEGIN
    RETURN sys.dateadd_internal(datepart, num, startdate);
END;
$body$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION sys.dateadd_internal(IN datepart PG_CATALOG.TEXT, IN num INTEGER, IN startdate ANYELEMENT) RETURNS ANYELEMENT AS $$
BEGIN
    IF pg_typeof(startdate) = 'date'::regtype AND
		datepart IN ('hour', 'minute', 'second', 'millisecond', 'microsecond', 'nanosecond') THEN
		RAISE EXCEPTION 'The datepart % is not supported by date function dateadd for data type date.', datepart;
	END IF;
    IF pg_typeof(startdate) = 'time'::regtype AND
		datepart IN ('year', 'quarter', 'month', 'doy', 'day', 'week', 'weekday') THEN
		RAISE EXCEPTION 'The datepart % is not supported by date function dateadd for data type time.', datepart;
	END IF;

	CASE datepart
	WHEN 'year' THEN
		RETURN startdate + make_interval(years => num);
	WHEN 'quarter' THEN
		RETURN startdate + make_interval(months => num * 3);
	WHEN 'month' THEN
		RETURN startdate + make_interval(months => num);
	WHEN 'dayofyear', 'y' THEN
		RETURN startdate + make_interval(days => num);
	WHEN 'day' THEN
		RETURN startdate + make_interval(days => num);
	WHEN 'week' THEN
		RETURN startdate + make_interval(weeks => num);
	WHEN 'weekday' THEN
		RETURN startdate + make_interval(days => num);
	WHEN 'hour' THEN
		RETURN startdate + make_interval(hours => num);
	WHEN 'minute' THEN
		RETURN startdate + make_interval(mins => num);
	WHEN 'second' THEN
		RETURN startdate + make_interval(secs => num);
	WHEN 'millisecond' THEN
		RETURN startdate + make_interval(secs => (num::numeric) * 0.001);
	WHEN 'microsecond' THEN
        IF pg_typeof(startdate) = 'sys.datetimeoffset'::regtype THEN
            RETURN startdate + make_interval(secs => (num::numeric) * 0.000001);
        ELSIF pg_typeof(startdate) = 'time'::regtype THEN
            RETURN startdate + make_interval(secs => (num::numeric) * 0.000001);
        ELSIF pg_typeof(startdate) = 'sys.datetime2'::regtype THEN
            RETURN startdate + make_interval(secs => (num::numeric) * 0.000001);
        ELSIF pg_typeof(startdate) = 'sys.smalldatetime'::regtype THEN
            RAISE EXCEPTION 'The datepart % is not supported by date function dateadd for data type smalldatetime.', datepart;
        ELSE
            RAISE EXCEPTION 'The datepart % is not supported by date function dateadd for data type datetime.', datepart;
        END IF;
	WHEN 'nanosecond' THEN
        IF pg_typeof(startdate) = 'sys.datetimeoffset'::regtype THEN
            RETURN startdate + make_interval(secs => TRUNC((num::numeric)* 0.000000001, 6));
        ELSIF pg_typeof(startdate) = 'time'::regtype THEN
            RETURN startdate + make_interval(secs => TRUNC((num::numeric)* 0.000000001, 6));
        ELSIF pg_typeof(startdate) = 'sys.datetime2'::regtype THEN
            RETURN startdate + make_interval(secs => TRUNC((num::numeric)* 0.000000001, 6));
        ELSIF pg_typeof(startdate) = 'sys.smalldatetime'::regtype THEN
            RAISE EXCEPTION 'The datepart % is not supported by date function dateadd for data type smalldatetime.', datepart;
        ELSE
            RAISE EXCEPTION 'The datepart % is not supported by date function dateadd for data type datetime.', datepart;
        END IF;
	ELSE
		RAISE EXCEPTION '''%'' is not a recognized dateadd option.', datepart;
	END CASE;
END;
$$
STRICT
LANGUAGE plpgsql IMMUTABLE;


CREATE OR REPLACE FUNCTION sys.format_datetime(IN value anyelement, IN format_pattern NVARCHAR,IN culture VARCHAR,  IN data_type VARCHAR DEFAULT '') RETURNS sys.nvarchar
AS 'babelfishpg_tsql', 'format_datetime' LANGUAGE C IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION sys.format_datetime(IN anyelement, IN NVARCHAR, IN VARCHAR, IN VARCHAR) TO PUBLIC;

CREATE OR REPLACE FUNCTION sys.format_numeric(IN value anyelement, IN format_pattern NVARCHAR,IN culture VARCHAR,  IN data_type VARCHAR DEFAULT '', IN e_position INT DEFAULT -1) RETURNS sys.nvarchar
AS 'babelfishpg_tsql', 'format_numeric' LANGUAGE C IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION sys.format_numeric(IN anyelement, IN NVARCHAR, IN VARCHAR, IN VARCHAR, IN INT) TO PUBLIC;

CREATE OR REPLACE FUNCTION sys.FORMAT(IN arg anyelement, IN p_format_pattern NVARCHAR, IN p_culture VARCHAR default 'en-us')
RETURNS sys.NVARCHAR
AS
$BODY$
DECLARE
    arg_type regtype;
    v_temp_integer INTEGER;
BEGIN
    arg_type := pg_typeof(arg);

    CASE
        WHEN arg_type IN ('time'::regtype ) THEN
            RETURN sys.format_datetime(arg, p_format_pattern, p_culture, 'time');

        WHEN arg_type IN ('date'::regtype, 'sys.datetime'::regtype, 'sys.smalldatetime'::regtype, 'sys.datetime2'::regtype ) THEN
            RETURN sys.format_datetime(arg::timestamp, p_format_pattern, p_culture);

        WHEN arg_type IN ('sys.tinyint'::regtype) THEN
            RETURN sys.format_numeric(arg::SMALLINT, p_format_pattern, p_culture, 'tinyint');

        WHEN arg_type IN ('smallint'::regtype) THEN
            RETURN sys.format_numeric(arg::SMALLINT, p_format_pattern, p_culture, 'smallint');

        WHEN arg_type IN ('integer'::regtype) THEN
            RETURN sys.format_numeric(arg, p_format_pattern, p_culture, 'integer');

         WHEN arg_type IN ('bigint'::regtype) THEN
            RETURN sys.format_numeric(arg, p_format_pattern, p_culture, 'bigint');

        WHEN arg_type IN ('numeric'::regtype) THEN
            RETURN sys.format_numeric(arg, p_format_pattern, p_culture, 'numeric');

        WHEN arg_type IN ('sys.decimal'::regtype) THEN
            RETURN sys.format_numeric(arg::numeric, p_format_pattern, p_culture, 'numeric');

        WHEN arg_type IN ('real'::regtype) THEN
            IF(p_format_pattern LIKE 'R%') THEN
                v_temp_integer := length(nullif((regexp_matches(arg::real::text, '(?<=\d*\.).*(?=[eE].*)')::text[])[1], ''));
            ELSE v_temp_integer:= -1;
            END IF;

            RETURN sys.format_numeric(arg, p_format_pattern, p_culture, 'real', v_temp_integer);

        WHEN arg_type IN ('float'::regtype) THEN
            RETURN sys.format_numeric(arg, p_format_pattern, p_culture, 'float');

        WHEN pg_typeof(arg) IN ('sys.smallmoney'::regtype, 'sys.money'::regtype) THEN
            RETURN sys.format_numeric(arg::numeric, p_format_pattern, p_culture, 'numeric');
        ELSE
            RAISE datatype_mismatch;
        END CASE;
EXCEPTION
	WHEN datatype_mismatch THEN
		RAISE USING MESSAGE := format('Argument data type % is invalid for argument 1 of format function.', pg_typeof(arg)),
					DETAIL := 'Invalid datatype.',
					HINT := 'Convert it to valid datatype and try again.';
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION sys.FORMAT(IN anyelement, IN NVARCHAR, IN VARCHAR) TO PUBLIC;

CREATE OR REPLACE FUNCTION sys.babelfish_try_cast_to_any(IN arg TEXT, INOUT output ANYELEMENT, IN typmod INT)
RETURNS ANYELEMENT
AS $BODY$ BEGIN
    EXECUTE pg_catalog.format('SELECT CAST(%L AS %s)', arg, format_type(pg_typeof(output), typmod)) INTO output;
    EXCEPTION
        WHEN OTHERS THEN
            -- Do nothing. Output carries NULL.
END; $BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sys.babelfish_conv_date_to_string(IN p_datatype TEXT,
                                                                 IN p_dateval DATE,
                                                                 IN p_style NUMERIC DEFAULT 20)
RETURNS TEXT
AS
$BODY$
DECLARE
    v_day VARCHAR COLLATE "C";
    v_dateval DATE;
    v_style SMALLINT;
    v_month SMALLINT;
    v_resmask VARCHAR COLLATE "C";
    v_datatype VARCHAR COLLATE "C";
    v_language VARCHAR COLLATE "C";
    v_monthname VARCHAR COLLATE "C";
    v_resstring VARCHAR COLLATE "C";
    v_lengthexpr VARCHAR COLLATE "C";
    v_maxlength SMALLINT;
    v_res_length SMALLINT;
    v_err_message VARCHAR COLLATE "C";
    v_res_datatype VARCHAR COLLATE "C";
    v_lang_metadata_json JSONB;
    VARCHAR_MAX CONSTANT SMALLINT := 8000;
    NVARCHAR_MAX CONSTANT SMALLINT := 4000;
    CONVERSION_LANG CONSTANT VARCHAR COLLATE "C" := '';
    DATATYPE_REGEXP CONSTANT VARCHAR COLLATE "C" := '^\s*(CHAR|NCHAR|VARCHAR|NVARCHAR|CHARACTER VARYING)\s*$';
    DATATYPE_MASK_REGEXP CONSTANT VARCHAR COLLATE "C" := '^\s*(?:CHAR|NCHAR|VARCHAR|NVARCHAR|CHARACTER VARYING)\s*\(\s*(\d+|MAX)\s*\)\s*$';
BEGIN
    v_datatype := upper(trim(p_datatype));
    v_style := floor(p_style)::SMALLINT;
    IF (scale(p_style) > 0) THEN
        RAISE most_specific_type_mismatch;
    ELSIF (NOT ((v_style BETWEEN 0 AND 13) OR
                (v_style BETWEEN 20 AND 25) OR
                (v_style BETWEEN 100 AND 113) OR
                v_style IN (120, 121, 126, 127, 130, 131)))
    THEN
        RAISE invalid_parameter_value;
    ELSIF (v_style IN (8, 24, 108)) THEN
        RAISE invalid_datetime_format;
    END IF;
    IF (v_datatype ~* DATATYPE_MASK_REGEXP) THEN
        v_res_datatype := rtrim(split_part(v_datatype, '(', 1));
        v_maxlength := CASE
                          WHEN (v_res_datatype IN ('CHAR', 'VARCHAR')) THEN VARCHAR_MAX
                          ELSE NVARCHAR_MAX
                       END;
        v_lengthexpr := substring(v_datatype, DATATYPE_MASK_REGEXP);
        IF (v_lengthexpr <> 'MAX' AND char_length(v_lengthexpr) > 4) THEN
            RAISE interval_field_overflow;
        END IF;
        v_res_length := CASE v_lengthexpr
                           WHEN 'MAX' THEN v_maxlength
                           ELSE v_lengthexpr::SMALLINT
                        END;
    ELSIF (v_datatype ~* DATATYPE_REGEXP) THEN
        v_res_datatype := v_datatype;
    ELSE
        RAISE datatype_mismatch;
    END IF;
    v_dateval := CASE
                    WHEN (v_style NOT IN (130, 131)) THEN p_dateval
                    ELSE sys.babelfish_conv_greg_to_hijri(p_dateval) + 1
                 END;
    v_day := ltrim(to_char(v_dateval, 'DD'), '0');
    v_month := to_char(v_dateval, 'MM')::SMALLINT;
    v_language := CASE
                     WHEN (v_style IN (130, 131)) THEN 'HIJRI'
                     ELSE CONVERSION_LANG
                  END;
 RAISE NOTICE 'v_language=[%]', v_language;		  
    BEGIN
        v_lang_metadata_json := sys.babelfish_get_lang_metadata_json(v_language);
    EXCEPTION
        WHEN OTHERS THEN
        RAISE invalid_character_value_for_cast;
    END;
    v_monthname := (v_lang_metadata_json -> 'months_shortnames') ->> v_month - 1;
    v_resmask := CASE
                    WHEN (v_style IN (1, 22)) THEN 'MM/DD/YY'
                    WHEN (v_style = 101) THEN 'MM/DD/YYYY'
                    WHEN (v_style = 2) THEN 'YY.MM.DD'
                    WHEN (v_style = 102) THEN 'YYYY.MM.DD'
                    WHEN (v_style = 3) THEN 'DD/MM/YY'
                    WHEN (v_style = 103) THEN 'DD/MM/YYYY'
                    WHEN (v_style = 4) THEN 'DD.MM.YY'
                    WHEN (v_style = 104) THEN 'DD.MM.YYYY'
                    WHEN (v_style = 5) THEN 'DD-MM-YY'
                    WHEN (v_style = 105) THEN 'DD-MM-YYYY'
                    WHEN (v_style = 6) THEN 'DD $mnme$ YY'
                    WHEN (v_style IN (13, 106, 113)) THEN 'DD $mnme$ YYYY'
                    WHEN (v_style = 7) THEN '$mnme$ DD, YY'
                    WHEN (v_style = 107) THEN '$mnme$ DD, YYYY'
                    WHEN (v_style = 10) THEN 'MM-DD-YY'
                    WHEN (v_style = 110) THEN 'MM-DD-YYYY'
                    WHEN (v_style = 11) THEN 'YY/MM/DD'
                    WHEN (v_style = 111) THEN 'YYYY/MM/DD'
                    WHEN (v_style = 12) THEN 'YYMMDD'
                    WHEN (v_style = 112) THEN 'YYYYMMDD'
                    WHEN (v_style IN (20, 21, 23, 25, 120, 121, 126, 127)) THEN 'YYYY-MM-DD'
                    WHEN (v_style = 130) THEN 'DD $mnme$ YYYY'
                    WHEN (v_style = 131) THEN pg_catalog.format('%s/MM/YYYY', lpad(v_day, 2, ' '))
                    WHEN (v_style IN (0, 9, 100, 109)) THEN pg_catalog.format('$mnme$ %s YYYY', lpad(v_day, 2, ' '))
                 END;

    v_resstring := to_char(v_dateval, v_resmask);
    v_resstring := pg_catalog.replace(v_resstring, '$mnme$', v_monthname);
    v_resstring := substring(v_resstring, 1, coalesce(v_res_length, char_length(v_resstring)));
    v_res_length := coalesce(v_res_length,
                             CASE v_res_datatype
                                WHEN 'CHAR' THEN 30
                                ELSE 60
                             END);
    RETURN CASE
              WHEN (v_res_datatype NOT IN ('CHAR', 'NCHAR')) THEN v_resstring
              ELSE rpad(v_resstring, v_res_length, ' ')
           END;
EXCEPTION
    WHEN most_specific_type_mismatch THEN
        RAISE USING MESSAGE := 'Argument data type NUMERIC is invalid for argument 3 of convert function.',
                    DETAIL := 'Use of incorrect "style" parameter value during conversion process.',
                    HINT := 'Change "style" parameter to the proper value and try again.';

    WHEN invalid_parameter_value THEN
    RAISE USING MESSAGE := pg_catalog.format('%s is not a valid style number when converting from DATE to a character string.', v_style),
                    DETAIL := 'Use of incorrect "style" parameter value during conversion process.',
                    HINT := 'Change "style" parameter to the proper value and try again.';

    WHEN invalid_datetime_format THEN
    RAISE USING MESSAGE := pg_catalog.format('Error converting data type DATE to %s.', trim(p_datatype)),
                    DETAIL := 'Incorrect using of pair of input parameters values during conversion process.',
                    HINT := 'Check the input parameters values, correct them if needed, and try again.';

   WHEN interval_field_overflow THEN
   RAISE USING MESSAGE := pg_catalog.format('The size (%s) given to the convert specification ''%s'' exceeds the maximum allowed for any data type (%s).',
                                     v_lengthexpr,
                                     lower(v_res_datatype),
                                     v_maxlength),
                   DETAIL := 'Use of incorrect size value of data type parameter during conversion process.',
                   HINT := 'Change size component of data type parameter to the allowable value and try again.';
    WHEN datatype_mismatch THEN
        RAISE USING MESSAGE := 'Data type should be one of these values: ''CHAR(n|MAX)'', ''NCHAR(n|MAX)'', ''VARCHAR(n|MAX)'', ''NVARCHAR(n|MAX)''.',
                    DETAIL := 'Use of incorrect "datatype" parameter value during conversion process.',
                    HINT := 'Change "datatype" parameter to the proper value and try again.';

    WHEN invalid_character_value_for_cast THEN
    RAISE USING MESSAGE := pg_catalog.format('Invalid CONVERSION_LANG constant value - ''%s''. Allowed values are: ''English'', ''Deutsch'', etc.',
                                      CONVERSION_LANG),
                    DETAIL := 'Compiled incorrect CONVERSION_LANG constant value in function''s body.',
                    HINT := 'Correct CONVERSION_LANG constant value in function''s body, recompile it and try again.';
    WHEN invalid_text_representation THEN
        GET STACKED DIAGNOSTICS v_err_message = MESSAGE_TEXT;
        v_err_message := substring(lower(v_err_message), 'integer\:\s\"(.*)\"');

		RAISE USING MESSAGE := pg_catalog.format('Error while trying to convert "%s" value to SMALLINT (or INTEGER) data type.',
                                      v_err_message),
                    DETAIL := 'Supplied value contains illegal characters.',
                    HINT := 'Correct supplied value, remove all illegal characters.';
END;
$BODY$
LANGUAGE plpgsql
VOLATILE
RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE FUNCTION sys.babelfish_conv_datetime_to_string(IN p_datatype TEXT,
                                                                     IN p_src_datatype TEXT,
                                                                     IN p_datetimeval TIMESTAMP(6) WITHOUT TIME ZONE,
                                                                     IN p_style NUMERIC DEFAULT -1)
RETURNS TEXT
AS
$BODY$
DECLARE
    v_day VARCHAR COLLATE "C";
    v_hour VARCHAR COLLATE "C";
    v_month SMALLINT;
    v_style SMALLINT;
    v_scale SMALLINT;
    v_resmask VARCHAR COLLATE "C";
    v_language VARCHAR COLLATE "C";
    v_datatype VARCHAR COLLATE "C";
    v_fseconds VARCHAR COLLATE "C";
    v_fractsep VARCHAR COLLATE "C";
    v_monthname VARCHAR COLLATE "C";
    v_resstring VARCHAR COLLATE "C";
    v_lengthexpr VARCHAR COLLATE "C";
    v_maxlength SMALLINT;
    v_res_length SMALLINT;
    v_err_message VARCHAR COLLATE "C";
    v_src_datatype VARCHAR COLLATE "C";
    v_res_datatype VARCHAR COLLATE "C";
    v_lang_metadata_json JSONB;
    VARCHAR_MAX CONSTANT SMALLINT := 8000;
    NVARCHAR_MAX CONSTANT SMALLINT := 4000;
    CONVERSION_LANG CONSTANT VARCHAR COLLATE "C" := '';
    DATATYPE_REGEXP CONSTANT VARCHAR COLLATE "C" := '^\s*(CHAR|NCHAR|VARCHAR|NVARCHAR|CHARACTER VARYING)\s*$';
    SRCDATATYPE_MASK_REGEXP VARCHAR COLLATE "C" := '^(?:DATETIME|SMALLDATETIME|DATETIME2)\s*(?:\s*\(\s*(\d+)\s*\)\s*)?$';
    DATATYPE_MASK_REGEXP CONSTANT VARCHAR COLLATE "C" := '^\s*(?:CHAR|NCHAR|VARCHAR|NVARCHAR|CHARACTER VARYING)\s*\(\s*(\d+|MAX)\s*\)\s*$';
    v_datetimeval TIMESTAMP(6) WITHOUT TIME ZONE;
BEGIN
    v_datatype := upper(trim(p_datatype));
    v_src_datatype := upper(trim(p_src_datatype));
    v_style := floor(p_style)::SMALLINT;
    IF (v_src_datatype ~* SRCDATATYPE_MASK_REGEXP)
    THEN
        v_scale := substring(v_src_datatype, SRCDATATYPE_MASK_REGEXP)::SMALLINT;
        v_src_datatype := rtrim(split_part(v_src_datatype, '(', 1));
        IF (v_src_datatype <> 'DATETIME2' AND v_scale IS NOT NULL) THEN
            RAISE invalid_indicator_parameter_value;
        ELSIF (v_scale NOT BETWEEN 0 AND 7) THEN
            RAISE invalid_regular_expression;
        END IF;
        v_scale := coalesce(v_scale, 7);
    ELSE
        RAISE most_specific_type_mismatch;
    END IF;
    IF (scale(p_style) > 0) THEN
        RAISE escape_character_conflict;
    ELSIF (NOT ((v_style BETWEEN 0 AND 14) OR
                (v_style BETWEEN 20 AND 25) OR
                (v_style BETWEEN 100 AND 114) OR
                v_style IN (-1, 120, 121, 126, 127, 130, 131)))
    THEN
        RAISE invalid_parameter_value;
    END IF;
    IF (v_datatype ~* DATATYPE_MASK_REGEXP) THEN
        v_res_datatype := rtrim(split_part(v_datatype, '(', 1));
        v_maxlength := CASE
                          WHEN (v_res_datatype IN ('CHAR', 'VARCHAR')) THEN VARCHAR_MAX
                          ELSE NVARCHAR_MAX
                       END;
        v_lengthexpr := substring(v_datatype, DATATYPE_MASK_REGEXP);
        IF (v_lengthexpr <> 'MAX' AND char_length(v_lengthexpr) > 4)
        THEN
            RAISE interval_field_overflow;
        END IF;
        v_res_length := CASE v_lengthexpr
                           WHEN 'MAX' THEN v_maxlength
                           ELSE v_lengthexpr::SMALLINT
                        END;
    ELSIF (v_datatype ~* DATATYPE_REGEXP) THEN
        v_res_datatype := v_datatype;
    ELSE
        RAISE datatype_mismatch;
    END IF;
    v_datetimeval := CASE
                        WHEN (v_style NOT IN (130, 131)) THEN p_datetimeval
                        ELSE sys.babelfish_conv_greg_to_hijri(p_datetimeval) + INTERVAL '1 day'
                     END;
    v_day := ltrim(to_char(v_datetimeval, 'DD'), '0');
    v_hour := ltrim(to_char(v_datetimeval, 'HH12'), '0');
    v_month := to_char(v_datetimeval, 'MM')::SMALLINT;
    v_language := CASE
                     WHEN (v_style IN (130, 131)) THEN 'HIJRI'
                     ELSE CONVERSION_LANG
                  END;
    BEGIN
        v_lang_metadata_json := sys.babelfish_get_lang_metadata_json(v_language);
    EXCEPTION
        WHEN OTHERS THEN
        RAISE invalid_character_value_for_cast;
    END;
    v_monthname := (v_lang_metadata_json -> 'months_shortnames') ->> v_month - 1;
    IF (v_src_datatype IN ('DATETIME', 'SMALLDATETIME')) THEN
        v_fseconds := sys.babelfish_round_fractseconds(to_char(v_datetimeval, 'MS'));
        IF (v_fseconds::INTEGER = 1000) THEN
            v_fseconds := '000';
            v_datetimeval := v_datetimeval + INTERVAL '1 second';
        ELSE
            v_fseconds := lpad(v_fseconds, 3, '0');
        END IF;
    ELSE
        v_fseconds := sys.babelfish_get_microsecs_from_fractsecs(to_char(v_datetimeval, 'US'), v_scale);
        IF (v_scale = 7) THEN
            v_fseconds := concat(v_fseconds, '0');
        END IF;
    END IF;
    v_fractsep := CASE v_src_datatype
                     WHEN 'DATETIME2' THEN '.'
                     ELSE ':'
                  END;
    IF ((v_style = -1 AND v_src_datatype <> 'DATETIME2') OR
        v_style IN (0, 9, 100, 109))
    THEN
    	v_resmask := pg_catalog.format('$mnme$ %s YYYY %s:MI%s',
                            lpad(v_day, 2, ' '),
                            lpad(v_hour, 2, ' '),
                            CASE
                               WHEN (v_style IN (-1, 0, 100)) THEN 'AM'
                               ELSE pg_catalog.format(':SS:%sAM', v_fseconds)
                            END);
                            ELSIF (v_style = 1) THEN
        v_resmask := 'MM/DD/YY';
    ELSIF (v_style = 101) THEN
        v_resmask := 'MM/DD/YYYY';
    ELSIF (v_style = 2) THEN
        v_resmask := 'YY.MM.DD';
    ELSIF (v_style = 102) THEN
        v_resmask := 'YYYY.MM.DD';
    ELSIF (v_style = 3) THEN
        v_resmask := 'DD/MM/YY';
    ELSIF (v_style = 103) THEN
        v_resmask := 'DD/MM/YYYY';
    ELSIF (v_style = 4) THEN
        v_resmask := 'DD.MM.YY';
    ELSIF (v_style = 104) THEN
        v_resmask := 'DD.MM.YYYY';
    ELSIF (v_style = 5) THEN
        v_resmask := 'DD-MM-YY';
    ELSIF (v_style = 105) THEN
        v_resmask := 'DD-MM-YYYY';
    ELSIF (v_style = 6) THEN
        v_resmask := 'DD $mnme$ YY';
    ELSIF (v_style = 106) THEN
        v_resmask := 'DD $mnme$ YYYY';
    ELSIF (v_style = 7) THEN
        v_resmask := '$mnme$ DD, YY';
    ELSIF (v_style = 107) THEN
        v_resmask := '$mnme$ DD, YYYY';
    ELSIF (v_style IN (8, 24, 108)) THEN
        v_resmask := 'HH24:MI:SS';
    ELSIF (v_style = 10) THEN
        v_resmask := 'MM-DD-YY';
    ELSIF (v_style = 110) THEN
        v_resmask := 'MM-DD-YYYY';
    ELSIF (v_style = 11) THEN
        v_resmask := 'YY/MM/DD';
    ELSIF (v_style = 111) THEN
        v_resmask := 'YYYY/MM/DD';
    ELSIF (v_style = 12) THEN
        v_resmask := 'YYMMDD';
    ELSIF (v_style = 112) THEN
        v_resmask := 'YYYYMMDD';
    ELSIF (v_style IN (13, 113)) THEN
	    v_resmask := pg_catalog.format('DD $mnme$ YYYY HH24:MI:SS%s%s', v_fractsep, v_fseconds);
    ELSIF (v_style IN (14, 114)) THEN
    	v_resmask := pg_catalog.format('HH24:MI:SS%s%s', v_fractsep, v_fseconds);
    ELSIF (v_style IN (20, 120)) THEN
        v_resmask := 'YYYY-MM-DD HH24:MI:SS';
    ELSIF ((v_style = -1 AND v_src_datatype = 'DATETIME2') OR
           v_style IN (21, 25, 121))
    THEN
    	v_resmask := pg_catalog.format('YYYY-MM-DD HH24:MI:SS.%s', v_fseconds);
    ELSIF (v_style = 22) THEN
    	v_resmask := pg_catalog.format('MM/DD/YY %s:MI:SS AM', lpad(v_hour, 2, ' '));
    ELSIF (v_style = 23) THEN
        v_resmask := 'YYYY-MM-DD';
    ELSIF (v_style IN (126, 127)) THEN
        v_resmask := CASE v_src_datatype
                        WHEN 'SMALLDATETIME' THEN 'YYYY-MM-DDT$rem$HH24:MI:SS'
    					ELSE pg_catalog.format('YYYY-MM-DDT$rem$HH24:MI:SS.%s', v_fseconds)
    				END;
    ELSIF (v_style IN (130, 131)) THEN
        v_resmask := concat(CASE p_style
				        		WHEN 131 THEN pg_catalog.format('%s/MM/YYYY ', lpad(v_day, 2, ' '))
                                ELSE pg_catalog.format('%s $mnme$ YYYY ', lpad(v_day, 2, ' '))
                            END,
                            pg_catalog.format('%s:MI:SS%s%sAM', lpad(v_hour, 2, ' '), v_fractsep, v_fseconds));
    END IF;

    v_resstring := to_char(v_datetimeval, v_resmask);
    v_resstring := pg_catalog.replace(v_resstring, '$mnme$', v_monthname);
    v_resstring := pg_catalog.replace(v_resstring, '$rem$', '');
    v_resstring := substring(v_resstring, 1, coalesce(v_res_length, char_length(v_resstring)));
    v_res_length := coalesce(v_res_length,
                             CASE v_res_datatype
                                WHEN 'CHAR' THEN 30
                                ELSE 60
                             END);
    RETURN CASE
              WHEN (v_res_datatype NOT IN ('CHAR', 'NCHAR')) THEN v_resstring
              ELSE rpad(v_resstring, v_res_length, ' ')
           END;
EXCEPTION
	WHEN most_specific_type_mismatch THEN
        RAISE USING MESSAGE := 'Source data type should be one of these values: ''DATETIME'', ''SMALLDATETIME'', ''DATETIME2'' or ''DATETIME2(n)''.',
                    DETAIL := 'Use of incorrect "src_datatype" parameter value during conversion process.',
                    HINT := 'Change "srcdatatype" parameter to the proper value and try again.';

	WHEN invalid_regular_expression THEN
		RAISE USING MESSAGE := pg_catalog.format('The source data type scale (%s) given to the convert specification exceeds the maximum allowable value (7).',
										v_scale),
                   DETAIL := 'Use of incorrect scale value of source data type parameter during conversion process.',
                   HINT := 'Change scale component of source data type parameter to the allowable value and try again.';

	WHEN invalid_indicator_parameter_value THEN
        RAISE USING MESSAGE := pg_catalog.format('Invalid attributes specified for data type %s.', v_src_datatype),
                    DETAIL := 'Use of incorrect scale value, which is not corresponding to specified data type.',
                    HINT := 'Change data type scale component or select different data type and try again.';

    WHEN escape_character_conflict THEN
        RAISE USING MESSAGE := 'Argument data type NUMERIC is invalid for argument 4 of convert function.',
                    DETAIL := 'Use of incorrect "style" parameter value during conversion process.',
                    HINT := 'Change "style" parameter to the proper value and try again.';

    WHEN invalid_parameter_value THEN
        RAISE USING MESSAGE := pg_catalog.format('%s is not a valid style number when converting from %s to a character string.',
                                      v_style, v_src_datatype),
                    DETAIL := 'Use of incorrect "style" parameter value during conversion process.',
                    HINT := 'Change "style" parameter to the proper value and try again.';

    WHEN interval_field_overflow THEN
            RAISE USING MESSAGE := pg_catalog.format('The size (%s) given to the convert specification ''%s'' exceeds the maximum allowed for any data type (%s).',
                                      v_lengthexpr, lower(v_res_datatype), v_maxlength),
                    DETAIL := 'Use of incorrect size value of data type parameter during conversion process.',
                    HINT := 'Change size component of data type parameter to the allowable value and try again.';
    WHEN datatype_mismatch THEN
        RAISE USING MESSAGE := 'Data type should be one of these values: ''CHAR(n|MAX)'', ''NCHAR(n|MAX)'', ''VARCHAR(n|MAX)'', ''NVARCHAR(n|MAX)''.',
                    DETAIL := 'Use of incorrect "datatype" parameter value during conversion process.',
                    HINT := 'Change "datatype" parameter to the proper value and try again.';

    WHEN invalid_character_value_for_cast THEN
        RAISE USING MESSAGE := pg_catalog.format('Invalid CONVERSION_LANG constant value - ''%s''. Allowed values are: ''English'', ''Deutsch'', etc.',
                                      CONVERSION_LANG),
                    DETAIL := 'Compiled incorrect CONVERSION_LANG constant value in function''s body.',
                    HINT := 'Correct CONVERSION_LANG constant value in function''s body, recompile it and try again.';

    WHEN invalid_text_representation THEN
        GET STACKED DIAGNOSTICS v_err_message = MESSAGE_TEXT;
        v_err_message := substring(lower(v_err_message), 'integer\:\s\"(.*)\"');

        RAISE USING MESSAGE := pg_catalog.format('Error while trying to convert "%s" value to SMALLINT data type.',

                                      v_err_message),
                    DETAIL := 'Supplied value contains illegal characters.',
                    HINT := 'Correct supplied value, remove all illegal characters.';
END;
$BODY$
LANGUAGE plpgsql
VOLATILE
RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE FUNCTION sys.babelfish_conv_greg_to_hijri(IN p_datetimeval TIMESTAMP WITHOUT TIME ZONE)
RETURNS TIMESTAMP WITHOUT TIME ZONE
AS
$BODY$
DECLARE
    v_hijri_date DATE;
BEGIN
    v_hijri_date := sys.babelfish_conv_greg_to_hijri(extract(day from p_datetimeval)::SMALLINT,
                                                         extract(month from p_datetimeval)::SMALLINT,
                                                         extract(year from p_datetimeval)::INTEGER);

    RETURN to_timestamp(pg_catalog.format('%s %s', to_char(v_hijri_date, 'DD.MM.YYYY'),
                                        to_char(p_datetimeval, ' HH24:MI:SS.US')),
                        'DD.MM.YYYY HH24:MI:SS.US');
END;
$BODY$
LANGUAGE plpgsql
VOLATILE
RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE FUNCTION sys.babelfish_conv_hijri_to_greg(IN p_datetimeval TIMESTAMP WITHOUT TIME ZONE)
RETURNS TIMESTAMP WITHOUT TIME ZONE
AS
$BODY$
DECLARE
    v_hijri_date DATE;
BEGIN
    v_hijri_date := sys.babelfish_conv_hijri_to_greg(extract(day from p_dateval)::NUMERIC,
                                                         extract(month from p_dateval)::NUMERIC,
                                                         extract(year from p_dateval)::NUMERIC);

    RETURN to_timestamp(pg_catalog.format('%s %s', to_char(v_hijri_date, 'DD.MM.YYYY'),
                                        to_char(p_datetimeval, ' HH24:MI:SS.US')),
                        'DD.MM.YYYY HH24:MI:SS.US');
END;
$BODY$
LANGUAGE plpgsql
VOLATILE
RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE FUNCTION sys.babelfish_conv_time_to_string(IN p_datatype TEXT,
                                                                 IN p_src_datatype TEXT,
                                                                 IN p_timeval TIME(6) WITHOUT TIME ZONE,
                                                                 IN p_style NUMERIC DEFAULT 25)
RETURNS TEXT
AS
$BODY$
DECLARE
    v_hours VARCHAR COLLATE "C";
    v_style SMALLINT;
    v_scale SMALLINT;
    v_resmask VARCHAR COLLATE "C";
    v_fseconds VARCHAR COLLATE "C";
    v_datatype VARCHAR COLLATE "C";
    v_resstring VARCHAR COLLATE "C";
    v_lengthexpr VARCHAR COLLATE "C";
    v_res_length SMALLINT;
    v_res_datatype VARCHAR COLLATE "C";
    v_src_datatype VARCHAR COLLATE "C";
    v_res_maxlength SMALLINT;
    VARCHAR_MAX CONSTANT SMALLINT := 8000;
    NVARCHAR_MAX CONSTANT SMALLINT := 4000;
    -- We use the regex below to make sure input p_datatype is one of them
    DATATYPE_REGEXP CONSTANT VARCHAR COLLATE "C" := '^\s*(CHAR|NCHAR|VARCHAR|NVARCHAR|CHARACTER VARYING)\s*$';
    -- We use the regex below to get the length of the datatype, if specified
    -- For example, to get the '10' out of 'varchar(10)'
    DATATYPE_MASK_REGEXP CONSTANT VARCHAR COLLATE "C" := '^\s*(?:CHAR|NCHAR|VARCHAR|NVARCHAR|CHARACTER VARYING)\s*\(\s*(\d+|MAX)\s*\)\s*$';
    SRCDATATYPE_MASK_REGEXP VARCHAR COLLATE "C" := '^\s*(?:TIME)\s*(?:\s*\(\s*(\d+)\s*\)\s*)?\s*$';
BEGIN
    v_datatype := upper(trim(p_datatype));
    v_src_datatype := upper(trim(p_src_datatype));
    v_style := floor(p_style)::SMALLINT;
    IF (v_src_datatype ~* SRCDATATYPE_MASK_REGEXP)
    THEN
        v_scale := coalesce(substring(v_src_datatype, SRCDATATYPE_MASK_REGEXP)::SMALLINT, 7);
        IF (v_scale NOT BETWEEN 0 AND 7) THEN
            RAISE invalid_regular_expression;
        END IF;
    ELSE
        RAISE most_specific_type_mismatch;
    END IF;
    IF (v_datatype ~* DATATYPE_MASK_REGEXP)
    THEN
        v_res_datatype := rtrim(split_part(v_datatype, '(', 1));
        v_res_maxlength := CASE
                              WHEN (v_res_datatype IN ('CHAR', 'VARCHAR')) THEN VARCHAR_MAX
                              ELSE NVARCHAR_MAX
                           END;
        v_lengthexpr := substring(v_datatype, DATATYPE_MASK_REGEXP);
        IF (v_lengthexpr <> 'MAX' AND char_length(v_lengthexpr) > 4) THEN
            RAISE interval_field_overflow;
        END IF;
        v_res_length := CASE v_lengthexpr
                           WHEN 'MAX' THEN v_res_maxlength
                           ELSE v_lengthexpr::SMALLINT
                        END;
    ELSIF (v_datatype ~* DATATYPE_REGEXP) THEN
        v_res_datatype := v_datatype;
    ELSE
        RAISE datatype_mismatch;
    END IF;
    IF (scale(p_style) > 0) THEN
        RAISE escape_character_conflict;
    ELSIF (NOT ((v_style BETWEEN 0 AND 14) OR
                (v_style BETWEEN 20 AND 25) OR
                (v_style BETWEEN 100 AND 114) OR
                v_style IN (120, 121, 126, 127, 130, 131)))
    THEN
        RAISE invalid_parameter_value;
    ELSIF ((v_style BETWEEN 1 AND 7) OR
           (v_style BETWEEN 10 AND 12) OR
           (v_style BETWEEN 101 AND 107) OR
           (v_style BETWEEN 110 AND 112) OR
           v_style = 23)
    THEN
        RAISE invalid_datetime_format;
    END IF;
    v_hours := ltrim(to_char(p_timeval, 'HH12'), '0');
    v_fseconds := sys.babelfish_get_microsecs_from_fractsecs(to_char(p_timeval, 'US'), v_scale);
    IF (v_scale = 7) THEN
        v_fseconds := concat(v_fseconds, '0');
    END IF;
    IF (v_style IN (0, 100))
    THEN
        v_resmask := concat(v_hours, ':MIAM');
    ELSIF (v_style IN (8, 20, 24, 108, 120))
    THEN
        v_resmask := 'HH24:MI:SS';
    ELSIF (v_style IN (9, 109))
    THEN
        v_resmask := CASE
                        WHEN (char_length(v_fseconds) = 0) THEN concat(v_hours, ':MI:SSAM')
                        ELSE pg_catalog.format('%s:MI:SS.%sAM', v_hours, v_fseconds)
                     END;
    ELSIF (v_style IN (13, 14, 21, 25, 113, 114, 121, 126, 127))
    THEN
        v_resmask := CASE
                        WHEN (char_length(v_fseconds) = 0) THEN 'HH24:MI:SS'
                        ELSE concat('HH24:MI:SS.', v_fseconds)
                     END;
    ELSIF (v_style = 22)
    THEN
    	v_resmask := pg_catalog.format('%s:MI:SS AM', lpad(v_hours, 2, ' '));
    ELSIF (v_style IN (130, 131))
    THEN
        v_resmask := CASE
                        WHEN (char_length(v_fseconds) = 0) THEN concat(lpad(v_hours, 2, ' '), ':MI:SSAM')
                        ELSE pg_catalog.format('%s:MI:SS.%sAM', lpad(v_hours, 2, ' '), v_fseconds)
                     END;
    END IF;

    v_resstring := to_char(p_timeval, v_resmask);
    v_resstring := substring(v_resstring, 1, coalesce(v_res_length, char_length(v_resstring)));
    v_res_length := coalesce(v_res_length,
                             CASE v_res_datatype
                                WHEN 'CHAR' THEN 30
                                ELSE 60
                             END);
    RETURN CASE
              WHEN (v_res_datatype NOT IN ('CHAR', 'NCHAR')) THEN v_resstring
              ELSE rpad(v_resstring, v_res_length, ' ')
           END;
EXCEPTION
    WHEN most_specific_type_mismatch THEN
        RAISE USING MESSAGE := 'Source data type should be ''TIME'' or ''TIME(n)''.',
                    DETAIL := 'Use of incorrect "src_datatype" parameter value during conversion process.',
                    HINT := 'Change "src_datatype" parameter to the proper value and try again.';

   WHEN invalid_regular_expression THEN
       RAISE USING MESSAGE := pg_catalog.format('The source data type scale (%s) given to the convert specification exceeds the maximum allowable value (7).',
                                     v_scale),
                   DETAIL := 'Use of incorrect scale value of source data type parameter during conversion process.',
                   HINT := 'Change scale component of source data type parameter to the allowable value and try again.';

   WHEN interval_field_overflow THEN
       RAISE USING MESSAGE := pg_catalog.format('The size (%s) given to the convert specification ''%s'' exceeds the maximum allowed for any data type (%s).',
                                     v_lengthexpr, lower(v_res_datatype), v_res_maxlength),
                   DETAIL := 'Use of incorrect size value of target data type parameter during conversion process.',
                   HINT := 'Change size component of data type parameter to the allowable value and try again.';
    WHEN escape_character_conflict THEN
        RAISE USING MESSAGE := 'Argument data type NUMERIC is invalid for argument 4 of convert function.',
                    DETAIL := 'Use of incorrect "style" parameter value during conversion process.',
                    HINT := 'Change "style" parameter to the proper value and try again.';

    WHEN invalid_parameter_value THEN
        RAISE USING MESSAGE := pg_catalog.format('%s is not a valid style number when converting from TIME to a character string.', v_style),
                    DETAIL := 'Use of incorrect "style" parameter value during conversion process.',
                    HINT := 'Change "style" parameter to the proper value and try again.';

    WHEN datatype_mismatch THEN
        RAISE USING MESSAGE := 'Data type should be one of these values: ''CHAR(n|MAX)'', ''NCHAR(n|MAX)'', ''VARCHAR(n|MAX)'', ''NVARCHAR(n|MAX)''.',
                    DETAIL := 'Use of incorrect "datatype" parameter value during conversion process.',
                    HINT := 'Change "datatype" parameter to the proper value and try again.';

    WHEN invalid_datetime_format THEN
        RAISE USING MESSAGE := pg_catalog.format('Error converting data type TIME to %s.',
                                      rtrim(split_part(trim(p_datatype), '(', 1))),
                    DETAIL := 'Incorrect using of pair of input parameters values during conversion process.',
                    HINT := 'Check the input parameters values, correct them if needed, and try again.';
END;
$BODY$
LANGUAGE plpgsql
VOLATILE
RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE FUNCTION sys.babelfish_sp_aws_add_jobschedule (
  par_job_id integer = NULL::integer,
  par_schedule_id integer = NULL::integer,
  out returncode integer
)
AS
$body$
DECLARE
  var_retval INT;
  proc_name_mask VARCHAR(100);
  var_owner_login_name VARCHAR(128);
  var_xml TEXT DEFAULT '';
  var_cron_expression VARCHAR(50);
  var_job_cmd VARCHAR(255);
  lambda_arn VARCHAR(255);
  return_message text;
  var_schedule_name VARCHAR(255);
  var_job_name VARCHAR(128);
  var_start_step_id INTEGER;
  var_notify_level_email INTEGER;
  var_notify_email_operator_id INTEGER;
  var_notify_email_operator_name VARCHAR(128);
  notify_email_sender VARCHAR(128);
  var_delete_level INTEGER;
BEGIN
  IF (EXISTS (
      SELECT 1
        FROM sys.sysjobschedules
       WHERE (schedule_id = par_schedule_id)
         AND (job_id = par_job_id)))
  THEN
    SELECT cron_expression
      FROM sys.babelfish_sp_schedule_to_cron (par_job_id, par_schedule_id)
      INTO var_cron_expression;
    SELECT name
      FROM sys.sysschedules
     WHERE schedule_id = par_schedule_id
      INTO var_schedule_name;
    SELECT name
         , start_step_id
         , COALESCE(notify_level_email,0)
         , COALESCE(notify_email_operator_id,0)
         , COALESCE(notify_email_operator_name,'')
         , COALESCE(delete_level,0)
      FROM sys.sysjobs
     WHERE job_id = par_job_id
      INTO var_job_name
         , var_start_step_id
         , var_notify_level_email
         , var_notify_email_operator_id
         , var_notify_email_operator_name
         , var_delete_level;

    proc_name_mask := 'sys_data.sql_agent$job_%s_step_%s';
    var_job_cmd := pg_catalog.format(proc_name_mask, par_job_id, '1');
    notify_email_sender := 'aws_test_email_sender@dbbest.com';


    var_xml := CONCAT(var_xml, '{');
    var_xml := CONCAT(var_xml, '"mode": "add_job",');
    var_xml := CONCAT(var_xml, '"parameters": {');
    var_xml := CONCAT(var_xml, '"vendor": "postgresql",');
    var_xml := CONCAT(var_xml, '"job_name": "',var_schedule_name,'",');
    var_xml := CONCAT(var_xml, '"job_frequency": "',var_cron_expression,'",');
    var_xml := CONCAT(var_xml, '"job_cmd": "',var_job_cmd,'",');
    var_xml := CONCAT(var_xml, '"notify_level_email": ',var_notify_level_email,',');
    var_xml := CONCAT(var_xml, '"delete_level": ',var_delete_level,',');
    var_xml := CONCAT(var_xml, '"uid": "',par_job_id,'",');
    var_xml := CONCAT(var_xml, '"callback": "sys.babelfish_sp_job_log",');
    var_xml := CONCAT(var_xml, '"notification": {');
    var_xml := CONCAT(var_xml, '"notify_email_sender": "',notify_email_sender,'",');
    var_xml := CONCAT(var_xml, '"notify_email_recipient": "',var_notify_email_operator_name,'"');
    var_xml := CONCAT(var_xml, '}');
    var_xml := CONCAT(var_xml, '}');
    var_xml := CONCAT(var_xml, '}');
    -- RAISE NOTICE '%', var_xml;
    SELECT sys.babelfish_get_service_setting ('JOB', 'LAMBDA_ARN')
      INTO lambda_arn;
    SELECT sys.awslambda_fn (lambda_arn, var_xml) INTO return_message;
    returncode := 0;
  ELSE
    returncode := 1;
    RAISE 'Job not fount' USING ERRCODE := '50000';
  END IF;
END;
$body$
LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION sys.babelfish_sp_aws_add_jobschedule (
  par_job_id integer = NULL::integer,
  par_schedule_id integer = NULL::integer,
  out returncode integer
)
AS
$body$
DECLARE
  var_retval INT;
  proc_name_mask VARCHAR(100);
  var_owner_login_name VARCHAR(128);
  var_xml TEXT DEFAULT '';
  var_cron_expression VARCHAR(50);
  var_job_cmd VARCHAR(255);
  lambda_arn VARCHAR(255);
  return_message text;
  var_schedule_name VARCHAR(255);
  var_job_name VARCHAR(128);
  var_start_step_id INTEGER;
  var_notify_level_email INTEGER;
  var_notify_email_operator_id INTEGER;
  var_notify_email_operator_name VARCHAR(128);
  notify_email_sender VARCHAR(128);
  var_delete_level INTEGER;
BEGIN
  IF (EXISTS (
      SELECT 1
        FROM sys.sysjobschedules
       WHERE (schedule_id = par_schedule_id)
         AND (job_id = par_job_id)))
  THEN
    SELECT cron_expression
      FROM sys.babelfish_sp_schedule_to_cron (par_job_id, par_schedule_id)
      INTO var_cron_expression;
    SELECT name
      FROM sys.sysschedules
     WHERE schedule_id = par_schedule_id
      INTO var_schedule_name;
    SELECT name
         , start_step_id
         , COALESCE(notify_level_email,0)
         , COALESCE(notify_email_operator_id,0)
         , COALESCE(notify_email_operator_name,'')
         , COALESCE(delete_level,0)
      FROM sys.sysjobs
     WHERE job_id = par_job_id
      INTO var_job_name
         , var_start_step_id
         , var_notify_level_email
         , var_notify_email_operator_id
         , var_notify_email_operator_name
         , var_delete_level;

    proc_name_mask := 'sys_data.sql_agent$job_%s_step_%s';
    var_job_cmd := pg_catalog.format(proc_name_mask, par_job_id, '1');
    notify_email_sender := 'aws_test_email_sender@dbbest.com';


    var_xml := CONCAT(var_xml, '{');
    var_xml := CONCAT(var_xml, '"mode": "add_job",');
    var_xml := CONCAT(var_xml, '"parameters": {');
    var_xml := CONCAT(var_xml, '"vendor": "postgresql",');
    var_xml := CONCAT(var_xml, '"job_name": "',var_schedule_name,'",');
    var_xml := CONCAT(var_xml, '"job_frequency": "',var_cron_expression,'",');
    var_xml := CONCAT(var_xml, '"job_cmd": "',var_job_cmd,'",');
    var_xml := CONCAT(var_xml, '"notify_level_email": ',var_notify_level_email,',');
    var_xml := CONCAT(var_xml, '"delete_level": ',var_delete_level,',');
    var_xml := CONCAT(var_xml, '"uid": "',par_job_id,'",');
    var_xml := CONCAT(var_xml, '"callback": "sys.babelfish_sp_job_log",');
    var_xml := CONCAT(var_xml, '"notification": {');
    var_xml := CONCAT(var_xml, '"notify_email_sender": "',notify_email_sender,'",');
    var_xml := CONCAT(var_xml, '"notify_email_recipient": "',var_notify_email_operator_name,'"');
    var_xml := CONCAT(var_xml, '}');
    var_xml := CONCAT(var_xml, '}');
    var_xml := CONCAT(var_xml, '}');
    -- RAISE NOTICE '%', var_xml;
    SELECT sys.babelfish_get_service_setting ('JOB', 'LAMBDA_ARN')
      INTO lambda_arn;
    SELECT sys.awslambda_fn (lambda_arn, var_xml) INTO return_message;
    returncode := 0;
  ELSE
    returncode := 1;
    RAISE 'Job not fount' USING ERRCODE := '50000';
  END IF;
END;
$body$
LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION sys.babelfish_sp_schedule_to_cron (
  par_job_id integer,
  par_schedule_id integer,
  out cron_expression varchar
)
RETURNS VARCHAR AS
$body$
DECLARE
  var_enabled INTEGER;
  var_freq_type INTEGER;
  var_freq_interval INTEGER;
  var_freq_subday_type INTEGER;
  var_freq_subday_interval INTEGER;
  var_freq_relative_interval INTEGER;
  var_freq_recurrence_factor INTEGER;
  var_active_start_date INTEGER;
  var_active_end_date INTEGER;
  var_active_start_time INTEGER;
  var_active_end_time INTEGER;
  var_next_run_date date;
  var_next_run_time time;
  var_next_run_dt timestamp;
  var_tmp_interval varchar(50);
  var_current_dt timestamp;
  var_next_dt timestamp;
BEGIN
  SELECT enabled
       , freq_type
       , freq_interval
       , freq_subday_type
       , freq_subday_interval
       , freq_relative_interval
       , freq_recurrence_factor
       , active_start_date
       , active_end_date
       , active_start_time
       , active_end_time
    FROM sys.sysschedules
    INTO var_enabled
       , var_freq_type
       , var_freq_interval
       , var_freq_subday_type
       , var_freq_subday_interval
       , var_freq_relative_interval
       , var_freq_recurrence_factor
       , var_active_start_date
       , var_active_end_date
       , var_active_start_time
       , var_active_end_time
   WHERE schedule_id = par_schedule_id;
  /* if enabled = 0 return */
  CASE var_freq_type
    WHEN 1 THEN
      NULL;
    WHEN 4 THEN
    BEGIN
        cron_expression :=
        CASE
          /* WHEN var_freq_subday_type = 1 THEN var_freq_subday_interval::character varying || ' At the specified time'  -- start time */
          /* WHEN var_freq_subday_type = 2 THEN var_freq_subday_interval::character varying || ' second'  -- ADD var_freq_subday_interval SECOND */
          WHEN var_freq_subday_type = 4 THEN pg_catalog.format('cron(*/%s * * * ? *)', var_freq_subday_interval::character varying) /* ADD var_freq_subday_interval MINUTE */
          WHEN var_freq_subday_type = 8 THEN pg_catalog.format('cron(0 */%s * * ? *)', var_freq_subday_interval::character varying) /* ADD var_freq_subday_interval HOUR */
          ELSE ''
        END;
    END;
    WHEN 8 THEN
      NULL;
    WHEN 16 THEN
      NULL;
    WHEN 32 THEN
      NULL;
    WHEN 64 THEN
      NULL;
    WHEN 128 THEN
     NULL;
  END CASE;
 -- return cron_expression;
END;
$body$
LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION sys.datetime2fromparts(IN p_year NUMERIC,
                                                                IN p_month NUMERIC,
                                                                IN p_day NUMERIC,
                                                                IN p_hour NUMERIC,
                                                                IN p_minute NUMERIC,
                                                                IN p_seconds NUMERIC,
                                                                IN p_fractions NUMERIC,
                                                                IN p_precision NUMERIC)
RETURNS TIMESTAMP WITHOUT TIME ZONE
AS
$BODY$
DECLARE
   v_fractions VARCHAR;
   v_precision SMALLINT;
   v_err_message VARCHAR;
   v_calc_seconds NUMERIC;
BEGIN
   v_fractions := floor(p_fractions)::INTEGER::VARCHAR;
   v_precision := p_precision::SMALLINT;
   IF (scale(p_precision) > 0) THEN
      RAISE most_specific_type_mismatch;
   ELSIF ((p_year::SMALLINT NOT BETWEEN 1 AND 9999) OR
       (p_month::SMALLINT NOT BETWEEN 1 AND 12) OR
       (p_day::SMALLINT NOT BETWEEN 1 AND 31) OR
       (p_hour::SMALLINT NOT BETWEEN 0 AND 23) OR
       (p_minute::SMALLINT NOT BETWEEN 0 AND 59) OR
       (p_seconds::SMALLINT NOT BETWEEN 0 AND 59) OR
       (p_fractions::SMALLINT NOT BETWEEN 0 AND 9999999) OR
       (p_fractions::SMALLINT != 0 AND char_length(v_fractions) > p_precision))
   THEN
      RAISE invalid_datetime_format;
   ELSIF (v_precision NOT BETWEEN 0 AND 7) THEN
      RAISE invalid_parameter_value;
   END IF;

   v_calc_seconds := pg_catalog.format('%s.%s',
                            floor(p_seconds)::SMALLINT,
                            substring(rpad(lpad(v_fractions, v_precision, '0'), 7, '0'), 1, 6))::NUMERIC;

   RETURN make_timestamp(floor(p_year)::SMALLINT,
                         floor(p_month)::SMALLINT,
                         floor(p_day)::SMALLINT,
                         floor(p_hour)::SMALLINT,
                         floor(p_minute)::SMALLINT,
                         v_calc_seconds);
EXCEPTION
   WHEN most_specific_type_mismatch THEN
      RAISE USING MESSAGE := 'Scale argument is not valid. Valid expressions for data type DATETIME2 scale argument are integer constants and integer constant expressions.',
                  DETAIL := 'Use of incorrect "precision" parameter value during conversion process.',
                  HINT := 'Change "precision" parameter to the proper value and try again.';

   WHEN invalid_parameter_value THEN
      RAISE USING MESSAGE := pg_catalog.format('Specified scale %s is invalid.', v_precision),
                  DETAIL := 'Use of incorrect "precision" parameter value during conversion process.',
                  HINT := 'Change "precision" parameter to the proper value and try again.';

   WHEN invalid_datetime_format THEN
      RAISE USING MESSAGE := 'Cannot construct data type DATETIME2, some of the arguments have values which are not valid.',
                  DETAIL := 'Possible use of incorrect value of date or time part (which lies outside of valid range).',
                  HINT := 'Check each input argument belongs to the valid range and try again.';
   WHEN numeric_value_out_of_range THEN
      GET STACKED DIAGNOSTICS v_err_message = MESSAGE_TEXT;
      v_err_message := upper(split_part(v_err_message, ' ', 1));

      RAISE USING MESSAGE := pg_catalog.format('Error while trying to cast to %s data type.', v_err_message),
                  DETAIL := pg_catalog.format('Source value is out of %s data type range.', v_err_message),
                  HINT := pg_catalog.format('Correct the source value you are trying to cast to %s data type and try again.',
                                 v_err_message);
END;
$BODY$
LANGUAGE plpgsql
IMMUTABLE
RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE FUNCTION sys.datetimefromparts(IN p_year NUMERIC,
                                                               IN p_month NUMERIC,
                                                               IN p_day NUMERIC,
                                                               IN p_hour NUMERIC,
                                                               IN p_minute NUMERIC,
                                                               IN p_seconds NUMERIC,
                                                               IN p_milliseconds NUMERIC)
RETURNS TIMESTAMP WITHOUT TIME ZONE
AS
$BODY$
DECLARE
    v_err_message VARCHAR;
    v_calc_seconds NUMERIC;
    v_milliseconds SMALLINT;
    v_resdatetime TIMESTAMP WITHOUT TIME ZONE;
BEGIN
    -- Check if arguments are out of range
    IF ((floor(p_year)::SMALLINT NOT BETWEEN 1753 AND 9999) OR
        (floor(p_month)::SMALLINT NOT BETWEEN 1 AND 12) OR
        (floor(p_day)::SMALLINT NOT BETWEEN 1 AND 31) OR
        (floor(p_hour)::SMALLINT NOT BETWEEN 0 AND 23) OR
        (floor(p_minute)::SMALLINT NOT BETWEEN 0 AND 59) OR
        (floor(p_seconds)::SMALLINT NOT BETWEEN 0 AND 59) OR
        (floor(p_milliseconds)::SMALLINT NOT BETWEEN 0 AND 999))
    THEN
        RAISE invalid_datetime_format;
    END IF;

    v_milliseconds := sys.babelfish_round_fractseconds(p_milliseconds::INTEGER);

    v_calc_seconds := pg_catalog.format('%s.%s',
                             floor(p_seconds)::SMALLINT,
                             CASE v_milliseconds
                                WHEN 1000 THEN '0'
                                ELSE lpad(v_milliseconds::VARCHAR, 3, '0')
                             END)::NUMERIC;
    v_resdatetime := make_timestamp(floor(p_year)::SMALLINT,
                                    floor(p_month)::SMALLINT,
                                    floor(p_day)::SMALLINT,
                                    floor(p_hour)::SMALLINT,
                                    floor(p_minute)::SMALLINT,
                                    v_calc_seconds);
    RETURN CASE
              WHEN (v_milliseconds != 1000) THEN v_resdatetime
              ELSE v_resdatetime + INTERVAL '1 second'
           END;
EXCEPTION
    WHEN invalid_datetime_format THEN
        RAISE USING MESSAGE := 'Cannot construct data type datetime, some of the arguments have values which are not valid.',
                    DETAIL := 'Possible use of incorrect value of date or time part (which lies outside of valid range).',
                    HINT := 'Check each input argument belongs to the valid range and try again.';
    WHEN numeric_value_out_of_range THEN
        GET STACKED DIAGNOSTICS v_err_message = MESSAGE_TEXT;
        v_err_message := upper(split_part(v_err_message, ' ', 1));

        RAISE USING MESSAGE := pg_catalog.format('Error while trying to cast to %s data type.', v_err_message),
                    DETAIL := pg_catalog.format('Source value is out of %s data type range.', v_err_message),
                    HINT := pg_catalog.format('Correct the source value you are trying to cast to %s data type and try again.',
                                   v_err_message);
END;
$BODY$
LANGUAGE plpgsql
IMMUTABLE
RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE FUNCTION sys.timefromparts(IN p_hour NUMERIC,
                                                           IN p_minute NUMERIC,
                                                           IN p_seconds NUMERIC,
                                                           IN p_fractions NUMERIC,
                                                           IN p_precision NUMERIC)
RETURNS TIME WITHOUT TIME ZONE
AS
$BODY$
DECLARE
    v_fractions VARCHAR;
    v_precision SMALLINT;
    v_err_message VARCHAR;
    v_calc_seconds NUMERIC;
BEGIN
    v_fractions := floor(p_fractions)::INTEGER::VARCHAR;
    v_precision := p_precision::SMALLINT;
    IF (scale(p_precision) > 0) THEN
        RAISE most_specific_type_mismatch;
    ELSIF ((p_hour::SMALLINT NOT BETWEEN 0 AND 23) OR
           (p_minute::SMALLINT NOT BETWEEN 0 AND 59) OR
           (p_seconds::SMALLINT NOT BETWEEN 0 AND 59) OR
           (p_fractions::SMALLINT NOT BETWEEN 0 AND 9999999) OR
           (p_fractions::SMALLINT != 0 AND char_length(v_fractions) > p_precision))
    THEN
        RAISE invalid_datetime_format;
    ELSIF (v_precision NOT BETWEEN 0 AND 7) THEN
        RAISE numeric_value_out_of_range;
    END IF;

    v_calc_seconds := pg_catalog.format('%s.%s',
                             floor(p_seconds)::SMALLINT,
                             substring(rpad(lpad(v_fractions, v_precision, '0'), 7, '0'), 1, 6))::NUMERIC;

    RETURN make_time(floor(p_hour)::SMALLINT,
                     floor(p_minute)::SMALLINT,
                     v_calc_seconds);
EXCEPTION
    WHEN most_specific_type_mismatch THEN
        RAISE USING MESSAGE := 'Scale argument is not valid. Valid expressions for data type DATETIME2 scale argument are integer constants and integer constant expressions.',
                    DETAIL := 'Use of incorrect "precision" parameter value during conversion process.',
                    HINT := 'Change "precision" parameter to the proper value and try again.';

    WHEN invalid_parameter_value THEN
        RAISE USING MESSAGE := pg_catalog.format('Specified scale %s is invalid.', v_precision),
                    DETAIL := 'Use of incorrect "precision" parameter value during conversion process.',
                    HINT := 'Change "precision" parameter to the proper value and try again.';

    WHEN invalid_datetime_format THEN
        RAISE USING MESSAGE := 'Cannot construct data type time, some of the arguments have values which are not valid.',
                    DETAIL := 'Possible use of incorrect value of time part (which lies outside of valid range).',
                    HINT := 'Check each input argument belongs to the valid range and try again.';
    WHEN numeric_value_out_of_range THEN
        GET STACKED DIAGNOSTICS v_err_message = MESSAGE_TEXT;
        v_err_message := upper(split_part(v_err_message, ' ', 1));

        RAISE USING MESSAGE := pg_catalog.format('Error while trying to cast to %s data type.', v_err_message),
                    DETAIL := pg_catalog.format('Source value is out of %s data type range.', v_err_message),
                    HINT := pg_catalog.format('Correct the source value you are trying to cast to %s data type and try again.',
                                   v_err_message);
END;
$BODY$
LANGUAGE plpgsql
VOLATILE
RETURNS NULL ON NULL INPUT;
CREATE OR REPLACE FUNCTION sys.timefromparts(IN p_hour TEXT,
                                                           IN p_minute TEXT,
                                                           IN p_seconds TEXT,
                                                           IN p_fractions TEXT,
                                                           IN p_precision TEXT)
RETURNS TIME WITHOUT TIME ZONE
AS
$BODY$
DECLARE
    v_err_message VARCHAR;
BEGIN
    RETURN sys.timefromparts(p_hour::NUMERIC, p_minute::NUMERIC,
                                           p_seconds::NUMERIC, p_fractions::NUMERIC,
                                           p_precision::NUMERIC);
EXCEPTION
    WHEN invalid_text_representation THEN
        GET STACKED DIAGNOSTICS v_err_message = MESSAGE_TEXT;
        v_err_message := substring(lower(v_err_message), 'numeric\:\s\"(.*)\"');

        RAISE USING MESSAGE := pg_catalog.format('Error while trying to convert "%s" value to NUMERIC data type.', v_err_message),
                    DETAIL := 'Supplied string value contains illegal characters.',
                    HINT := 'Correct supplied value, remove all illegal characters and try again.';
END;
$BODY$
LANGUAGE plpgsql
VOLATILE
RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE FUNCTION sys.space(IN number INTEGER, OUT result SYS.VARCHAR) AS $$
-- sys.varchar has default length of 1, so we have to pass in 'number' to be the
-- type modifier.
BEGIN
	EXECUTE pg_catalog.format(E'SELECT repeat(\' \', %s)::SYS.VARCHAR(%s)', number, number) INTO result;
END;
$$
STRICT
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sys.babelfish_get_full_year(IN p_short_year TEXT,
                                                           IN p_base_century TEXT DEFAULT '',
                                                           IN p_year_cutoff NUMERIC DEFAULT 49)
RETURNS VARCHAR
AS
$BODY$
DECLARE
    v_err_message VARCHAR;
    v_full_year SMALLINT;
    v_short_year SMALLINT;
    v_base_century SMALLINT;
    v_result_param_set JSONB;
    v_full_year_res_jsonb JSONB;
BEGIN
    v_short_year := p_short_year::SMALLINT;

    BEGIN
        v_full_year_res_jsonb := nullif(current_setting('sys.full_year_res_json'), '')::JSONB;
    EXCEPTION
        WHEN undefined_object THEN
        v_full_year_res_jsonb := NULL;
    END;

    SELECT result
      INTO v_full_year
      FROM jsonb_to_recordset(v_full_year_res_jsonb) AS result_set (param1 SMALLINT,
                                                                    param2 TEXT,
                                                                    param3 NUMERIC,
                                                                    result VARCHAR)
     WHERE param1 = v_short_year
       AND param2 = p_base_century
       AND param3 = p_year_cutoff;

    IF (v_full_year IS NULL)
    THEN
        IF (v_short_year <= 99)
        THEN
            v_base_century := CASE
                                 WHEN (p_base_century ~ '^\s*([1-9]{1,2})\s*$') THEN concat(trim(p_base_century), '00')::SMALLINT
                                 ELSE trunc(extract(year from current_date)::NUMERIC, -2)
                              END;

            v_full_year = v_base_century + v_short_year;
            v_full_year = CASE
                             WHEN (v_short_year::NUMERIC > p_year_cutoff) THEN v_full_year - 100
                             ELSE v_full_year
                          END;
        ELSE v_full_year := v_short_year;
        END IF;

        v_result_param_set := jsonb_build_object('param1', v_short_year,
                                                 'param2', p_base_century,
                                                 'param3', p_year_cutoff,
                                                 'result', v_full_year);
        v_full_year_res_jsonb := CASE
                                    WHEN (v_full_year_res_jsonb IS NULL) THEN jsonb_build_array(v_result_param_set)
                                    ELSE v_full_year_res_jsonb || v_result_param_set
                                 END;

        PERFORM set_config('sys.full_year_res_json',
                           v_full_year_res_jsonb::TEXT,
                           FALSE);
    END IF;

    RETURN v_full_year;
EXCEPTION
	WHEN invalid_text_representation THEN
        GET STACKED DIAGNOSTICS v_err_message = MESSAGE_TEXT;
        v_err_message := substring(lower(v_err_message), 'integer\:\s\"(.*)\"');

        RAISE USING MESSAGE := pg_catalog.format('Error while trying to convert "%s" value to SMALLINT data type.',
                                      v_err_message),
                    DETAIL := 'Supplied value contains illegal characters.',
                    HINT := 'Correct supplied value, remove all illegal characters.';
END;
$BODY$
LANGUAGE plpgsql
STABLE
RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE PROCEDURE sys.sp_helpdbfixedrole("@rolename" sys.SYSNAME = NULL) AS
$$
BEGIN
	-- Returns a list of the fixed database roles. 
	-- Only fixed role present in babelfish is db_owner.
	IF LOWER(RTRIM(@rolename)) IS NULL OR LOWER(RTRIM(@rolename)) = 'db_owner'
	BEGIN
		SELECT CAST('db_owner' AS sys.SYSNAME) AS DbFixedRole, CAST('DB Owners' AS sys.nvarchar(70)) AS Description;
	END
	ELSE IF LOWER(RTRIM(@rolename)) IN (
			'db_accessadmin','db_securityadmin','db_ddladmin', 'db_backupoperator', 
			'db_datareader', 'db_datawriter', 'db_denydatareader', 'db_denydatawriter')
	BEGIN
		-- Return an empty result set instead of raising an error
		SELECT CAST(NULL AS sys.SYSNAME) AS DbFixedRole, CAST(NULL AS sys.nvarchar(70)) AS Description
		WHERE 1=0;	
	END
	ELSE
		RAISERROR('''%s'' is not a known fixed role.', 16, 1, @rolename);
END
$$
LANGUAGE 'pltsql';
GRANT EXECUTE ON PROCEDURE sys.sp_helpdbfixedrole TO PUBLIC;


-- BABELFISH_FUNCTION_EXT
CREATE TABLE sys.babelfish_function_ext (
	nspname NAME NOT NULL,
	funcname NAME NOT NULL,
	orig_name sys.NVARCHAR(128), -- users' original input name
	funcsignature TEXT NOT NULL COLLATE "C",
	default_positions TEXT COLLATE "C",
	create_date SYS.DATETIME NOT NULL,
	modify_date SYS.DATETIME NOT NULL,
	PRIMARY KEY(nspname, funcsignature)
);
GRANT SELECT ON sys.babelfish_function_ext TO PUBLIC;

SELECT pg_catalog.pg_extension_config_dump('sys.babelfish_function_ext', '');

ALTER TABLE sys.babelfish_view_def ADD COLUMN create_date SYS.DATETIME, add COLUMN modify_date SYS.DATETIME;

CREATE OR REPLACE FUNCTION sys.babelfish_get_pltsql_function_signature(IN funcoid OID)
RETURNS text
AS 'babelfishpg_tsql', 'get_pltsql_function_signature' LANGUAGE C;

create or replace view sys.tables as
select
  CAST(t.relname as sys._ci_sysname) as name
  , CAST(t.oid as int) as object_id
  , CAST(NULL as int) as principal_id
  , CAST(sch.schema_id as int) as schema_id
  , 0 as parent_object_id
  , CAST('U' as CHAR(2)) as type
  , CAST('USER_TABLE' as sys.nvarchar(60)) as type_desc
  , CAST((select string_agg(
                  case
                  when option like 'bbf_rel_create_date=%%' then substring(option, 21)
                  else NULL
                  end, ',')
          from unnest(t.reloptions) as option)
        as sys.datetime) as create_date
  , CAST((select string_agg(
                  case
                  when option like 'bbf_rel_create_date=%%' then substring(option, 21)
                  else NULL
                  end, ',')
          from unnest(t.reloptions) as option)
        as sys.datetime) as modify_date
  , CAST(0 as sys.bit) as is_ms_shipped
  , CAST(0 as sys.bit) as is_published
  , CAST(0 as sys.bit) as is_schema_published
  , case reltoastrelid when 0 then 0 else 1 end as lob_data_space_id
  , CAST(NULL as int) as filestream_data_space_id
  , CAST(relnatts as int) as max_column_id_used
  , CAST(0 as sys.bit) as lock_on_bulk_load
  , CAST(1 as sys.bit) as uses_ansi_nulls
  , CAST(0 as sys.bit) as is_replicated
  , CAST(0 as sys.bit) as has_replication_filter
  , CAST(0 as sys.bit) as is_merge_published
  , CAST(0 as sys.bit) as is_sync_tran_subscribed
  , CAST(0 as sys.bit) as has_unchecked_assembly_data
  , 0 as text_in_row_limit
  , CAST(0 as sys.bit) as large_value_types_out_of_row
  , CAST(0 as sys.bit) as is_tracked_by_cdc
  , CAST(0 as sys.tinyint) as lock_escalation
  , CAST('TABLE' as sys.nvarchar(60)) as lock_escalation_desc
  , CAST(0 as sys.bit) as is_filetable
  , CAST(0 as sys.tinyint) as durability
  , CAST('SCHEMA_AND_DATA' as sys.nvarchar(60)) as durability_desc
  , CAST(0 as sys.bit) is_memory_optimized
  , case relpersistence when 't' then CAST(2 as sys.tinyint) else CAST(0 as sys.tinyint) end as temporal_type
  , case relpersistence when 't' then CAST('SYSTEM_VERSIONED_TEMPORAL_TABLE' as sys.nvarchar(60)) else CAST('NON_TEMPORAL_TABLE' as sys.nvarchar(60)) end as temporal_type_desc
  , CAST(null as integer) as history_table_id
  , CAST(0 as sys.bit) as is_remote_data_archive_enabled
  , CAST(0 as sys.bit) as is_external
from pg_class t inner join sys.schemas sch on t.relnamespace = sch.schema_id
where t.relpersistence in ('p', 'u', 't')
and t.relkind = 'r'
and not sys.is_table_type(t.oid)
and has_schema_privilege(sch.schema_id, 'USAGE')
and has_table_privilege(t.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER');
GRANT SELECT ON sys.tables TO PUBLIC;

create or replace view sys.views as 
select 
  t.relname as name
  , t.oid as object_id
  , null::integer as principal_id
  , sch.schema_id as schema_id
  , 0 as parent_object_id
  , 'V'::varchar(2) as type 
  , 'VIEW'::varchar(60) as type_desc
  , vd.create_date::timestamp as create_date
  , vd.create_date::timestamp as modify_date
  , 0 as is_ms_shipped 
  , 0 as is_published 
  , 0 as is_schema_published 
  , 0 as with_check_option 
  , 0 as is_date_correlation_view 
  , 0 as is_tracked_by_cdc 
from pg_class t inner join sys.schemas sch on t.relnamespace = sch.schema_id 
left outer join sys.babelfish_view_def vd on t.relname = vd.object_name and sch.name = vd.schema_name and vd.dbid = sys.db_id() 
where t.relkind = 'v'
and has_schema_privilege(sch.schema_id, 'USAGE')
and has_table_privilege(t.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER');
GRANT SELECT ON sys.views TO PUBLIC;

create or replace view sys.procedures as
select
  cast(p.proname as sys.sysname) as name
  , cast(p.oid as int) as object_id
  , cast(null as int) as principal_id
  , cast(sch.schema_id as int) as schema_id
  , cast (0 as int) as parent_object_id
  , cast(case p.prokind
      when 'p' then 'P'
      when 'a' then 'AF'
      else
        case format_type(p.prorettype, null) when 'trigger'
          then 'TR'
          else 'FN'
        end
    end as sys.bpchar(2)) as type
  , cast(case p.prokind
      when 'p' then 'SQL_STORED_PROCEDURE'
      when 'a' then 'AGGREGATE_FUNCTION'
      else
        case format_type(p.prorettype, null) when 'trigger'
          then 'SQL_TRIGGER'
          else 'SQL_SCALAR_FUNCTION'
        end
    end as sys.nvarchar(60)) as type_desc
  , cast(f.create_date as sys.datetime) as create_date
  , cast(f.create_date as sys.datetime) as modify_date
  , cast(0 as sys.bit) as is_ms_shipped
  , cast(0 as sys.bit) as is_published
  , cast(0 as sys.bit) as is_schema_published
  , cast(0 as sys.bit) as is_auto_executed
  , cast(0 as sys.bit) as is_execution_replicated
  , cast(0 as sys.bit) as is_repl_serializable_only
  , cast(0 as sys.bit) as skips_repl_constraints
from pg_proc p
inner join sys.schemas sch on sch.schema_id = p.pronamespace
left join sys.babelfish_function_ext f on p.proname = f.funcname and sch.schema_id::regnamespace::name = f.nspname
and sys.babelfish_get_pltsql_function_signature(p.oid) = f.funcsignature collate "C"
where has_schema_privilege(sch.schema_id, 'USAGE')
and format_type(p.prorettype, null) <> 'trigger'
and has_function_privilege(p.oid, 'EXECUTE');
GRANT SELECT ON sys.procedures TO PUBLIC;

CREATE OR REPLACE VIEW sys.triggers
AS
SELECT
  CAST(p.proname as sys.sysname) as name,
  CAST(p.oid as int) as object_id,
  CAST(1 as sys.tinyint) as parent_class,
  CAST('OBJECT_OR_COLUMN' as sys.nvarchar(60)) AS parent_class_desc,
  CAST(tr.tgrelid as int) AS parent_id,
  CAST('TR' as sys.bpchar(2)) AS type,
  CAST('SQL_TRIGGER' as sys.nvarchar(60)) AS type_desc,
  CAST(f.create_date as sys.datetime) AS create_date,
  CAST(f.create_date as sys.datetime) AS modify_date,
  CAST(0 as sys.bit) AS is_ms_shipped,
  CAST(
      CASE WHEN tr.tgenabled = 'D'
      THEN 1
      ELSE 0
      END
      AS sys.bit
  )	AS is_disabled,
  CAST(0 as sys.bit) AS is_not_for_replication,
  CAST(get_bit(CAST(CAST(tr.tgtype as int) as bit(7)),0) as sys.bit) AS is_instead_of_trigger
FROM pg_proc p
inner join sys.schemas sch on sch.schema_id = p.pronamespace
left join pg_trigger tr on tr.tgfoid = p.oid
left join sys.babelfish_function_ext f on p.proname = f.funcname and sch.schema_id::regnamespace::name = f.nspname
and sys.babelfish_get_pltsql_function_signature(p.oid) = f.funcsignature collate "C"
where has_schema_privilege(sch.schema_id, 'USAGE')
and has_function_privilege(p.oid, 'EXECUTE')
and p.prokind = 'f'
and format_type(p.prorettype, null) = 'trigger';
GRANT SELECT ON sys.triggers TO PUBLIC;

ALTER VIEW sys.default_constraints RENAME TO default_constraints_deprecated_in_2_3_0;
ALTER VIEW sys.check_constraints RENAME TO check_constraints_deprecated_in_2_3_0;

create or replace view sys.default_constraints
AS
select CAST(('DF_' || tab.name || '_' || d.oid) as sys.sysname) as name
  , CAST(d.oid as int) as object_id
  , CAST(null as int) as principal_id
  , CAST(tab.schema_id as int) as schema_id
  , CAST(d.adrelid as int) as parent_object_id
  , CAST('D' as char(2)) as type
  , CAST('DEFAULT_CONSTRAINT' as sys.nvarchar(60)) AS type_desc
  , CAST(null as sys.datetime) as create_date
  , CAST(null as sys.datetime) as modified_date
  , CAST(0 as sys.bit) as is_ms_shipped
  , CAST(0 as sys.bit) as is_published
  , CAST(0 as sys.bit) as is_schema_published
  , CAST(d.adnum as int) as  parent_column_id
  -- use a simple regex to strip the datatype and collation that pg_get_expr returns after a double-colon that is not expected in SQL Server
  , CAST(regexp_replace(pg_get_expr(d.adbin, d.adrelid), '::"?\w+"?| COLLATE "\w+"', '', 'g') as sys.nvarchar(4000)) as definition
  , CAST(1 as sys.bit) as is_system_named
from pg_catalog.pg_attrdef as d
inner join pg_attribute a on a.attrelid = d.adrelid and d.adnum = a.attnum
inner join sys.tables tab on d.adrelid = tab.object_id
WHERE a.atthasdef = 't' and a.attgenerated = ''
AND has_schema_privilege(tab.schema_id, 'USAGE')
AND has_column_privilege(a.attrelid, a.attname, 'SELECT,INSERT,UPDATE,REFERENCES');
GRANT SELECT ON sys.default_constraints TO PUBLIC;

CREATE or replace VIEW sys.check_constraints AS
SELECT CAST(c.conname as sys.sysname) as name
  , CAST(oid as integer) as object_id
  , CAST(NULL as integer) as principal_id 
  , CAST(c.connamespace as integer) as schema_id
  , CAST(conrelid as integer) as parent_object_id
  , CAST('C' as char(2)) as type
  , CAST('CHECK_CONSTRAINT' as sys.nvarchar(60)) as type_desc
  , CAST(null as sys.datetime) as create_date
  , CAST(null as sys.datetime) as modify_date
  , CAST(0 as sys.bit) as is_ms_shipped
  , CAST(0 as sys.bit) as is_published
  , CAST(0 as sys.bit) as is_schema_published
  , CAST(0 as sys.bit) as is_disabled
  , CAST(0 as sys.bit) as is_not_for_replication
  , CAST(0 as sys.bit) as is_not_trusted
  , CAST(c.conkey[1] as integer) AS parent_column_id
  -- use a simple regex to strip the datatype and collation that pg_get_constraintdef returns after a double-colon that is not expected in SQL Server
  , CAST(regexp_replace(substring(pg_get_constraintdef(c.oid) from 7), '::"?\w+"?| COLLATE "\w+"', '', 'g') as sys.nvarchar(4000)) AS definition
  , CAST(1 as sys.bit) as uses_database_collation
  , CAST(0 as sys.bit) as is_system_named
FROM pg_catalog.pg_constraint as c
INNER JOIN sys.schemas s on c.connamespace = s.schema_id
WHERE has_schema_privilege(s.schema_id, 'USAGE')
AND c.contype = 'c' and c.conrelid != 0;
GRANT SELECT ON sys.check_constraints TO PUBLIC;

-- Rebuild dependent view sys.objects
create or replace view sys.objects as
select
      CAST(t.name as sys.sysname) as name 
    , CAST(t.object_id as int) as object_id
    , CAST(t.principal_id as int) as principal_id
    , CAST(t.schema_id as int) as schema_id
    , CAST(t.parent_object_id as int) as parent_object_id
    , CAST('U' as char(2)) as type
    , CAST('USER_TABLE' as sys.nvarchar(60)) as type_desc
    , CAST(t.create_date as sys.datetime) as create_date
    , CAST(t.modify_date as sys.datetime) as modify_date
    , CAST(t.is_ms_shipped as sys.bit) as is_ms_shipped
    , CAST(t.is_published as sys.bit) as is_published
    , CAST(t.is_schema_published as sys.bit) as is_schema_published
from  sys.tables t
union all
select
      CAST(v.name as sys.sysname) as name
    , CAST(v.object_id as int) as object_id
    , CAST(v.principal_id as int) as principal_id
    , CAST(v.schema_id as int) as schema_id
    , CAST(v.parent_object_id as int) as parent_object_id
    , CAST('V' as char(2)) as type
    , CAST('VIEW' as sys.nvarchar(60)) as type_desc
    , CAST(v.create_date as sys.datetime) as create_date
    , CAST(v.modify_date as sys.datetime) as modify_date
    , CAST(v.is_ms_shipped as sys.bit) as is_ms_shipped
    , CAST(v.is_published as sys.bit) as is_published
    , CAST(v.is_schema_published as sys.bit) as is_schema_published
from  sys.views v
union all
select
      CAST(f.name as sys.sysname) as name
    , CAST(f.object_id as int) as object_id
    , CAST(f.principal_id as int) as principal_id
    , CAST(f.schema_id as int) as schema_id
    , CAST(f.parent_object_id as int) as parent_object_id
    , CAST('F' as char(2)) as type
    , CAST('FOREIGN_KEY_CONSTRAINT' as sys.nvarchar(60)) as type_desc
    , CAST(f.create_date as sys.datetime) as create_date
    , CAST(f.modify_date as sys.datetime) as modify_date
    , CAST(f.is_ms_shipped as sys.bit) as is_ms_shipped
    , CAST(f.is_published as sys.bit) as is_published
    , CAST(f.is_schema_published as sys.bit) as is_schema_published
 from sys.foreign_keys f
union all
select
      CAST(p.name as sys.sysname) as name
    , CAST(p.object_id as int) as object_id
    , CAST(p.principal_id as int) as principal_id
    , CAST(p.schema_id as int) as schema_id
    , CAST(p.parent_object_id as int) as parent_object_id
    , CAST('PK' as char(2)) as type
    , CAST('PRIMARY_KEY_CONSTRAINT' as sys.nvarchar(60)) as type_desc
    , CAST(p.create_date as sys.datetime) as create_date
    , CAST(p.modify_date as sys.datetime) as modify_date
    , CAST(p.is_ms_shipped as sys.bit) as is_ms_shipped
    , CAST(p.is_published as sys.bit) as is_published
    , CAST(p.is_schema_published as sys.bit) as is_schema_published
from sys.key_constraints p
where p.type = 'PK'
union all
select
      CAST(pr.name as sys.sysname) as name
    , CAST(pr.object_id as int) as object_id
    , CAST(pr.principal_id as int) as principal_id
    , CAST(pr.schema_id as int) as schema_id
    , CAST(pr.parent_object_id as int) as parent_object_id
    , CAST(pr.type as char(2)) as type
    , CAST(pr.type_desc as sys.nvarchar(60)) as type_desc
    , CAST(pr.create_date as sys.datetime) as create_date
    , CAST(pr.modify_date as sys.datetime) as modify_date
    , CAST(pr.is_ms_shipped as sys.bit) as is_ms_shipped
    , CAST(pr.is_published as sys.bit) as is_published
    , CAST(pr.is_schema_published as sys.bit) as is_schema_published
 from sys.procedures pr
union all
select
      CAST(tr.name as sys.sysname) as name
    , CAST(tr.object_id as int) as object_id
    , CAST(NULL as int) as principal_id
    , CAST(p.pronamespace as int) as schema_id
    , CAST(tr.parent_id as int) as parent_object_id
    , CAST(tr.type as char(2)) as type
    , CAST(tr.type_desc as sys.nvarchar(60)) as type_desc
    , CAST(tr.create_date as sys.datetime) as create_date
    , CAST(tr.modify_date as sys.datetime) as modify_date
    , CAST(tr.is_ms_shipped as sys.bit) as is_ms_shipped
    , CAST(0 as sys.bit) as is_published
    , CAST(0 as sys.bit) as is_schema_published
  from sys.triggers tr
  inner join pg_proc p on p.oid = tr.object_id
union all 
select
    CAST(def.name as sys.sysname) as name
  , CAST(def.object_id as int) as object_id
  , CAST(def.principal_id as int) as principal_id
  , CAST(def.schema_id as int) as schema_id
  , CAST(def.parent_object_id as int) as parent_object_id
  , CAST(def.type as char(2)) as type
  , CAST(def.type_desc as sys.nvarchar(60)) as type_desc
  , CAST(def.create_date as sys.datetime) as create_date
  , CAST(def.modified_date as sys.datetime) as modify_date
  , CAST(def.is_ms_shipped as sys.bit) as is_ms_shipped
  , CAST(def.is_published as sys.bit) as is_published
  , CAST(def.is_schema_published as sys.bit) as is_schema_published
  from sys.default_constraints def
union all
select
    CAST(chk.name as sys.sysname) as name
  , CAST(chk.object_id as int) as object_id
  , CAST(chk.principal_id as int) as principal_id
  , CAST(chk.schema_id as int) as schema_id
  , CAST(chk.parent_object_id as int) as parent_object_id
  , CAST(chk.type as char(2)) as type
  , CAST(chk.type_desc as sys.nvarchar(60)) as type_desc
  , CAST(chk.create_date as sys.datetime) as create_date
  , CAST(chk.modify_date as sys.datetime) as modify_date
  , CAST(chk.is_ms_shipped as sys.bit) as is_ms_shipped
  , CAST(chk.is_published as sys.bit) as is_published
  , CAST(chk.is_schema_published as sys.bit) as is_schema_published
  from sys.check_constraints chk
union all
select
    CAST(p.relname as sys.sysname) as name
  , CAST(p.oid as int) as object_id
  , CAST(null as int) as principal_id
  , CAST(s.schema_id as int) as schema_id
  , CAST(0 as int) as parent_object_id
  , CAST('SO' as char(2)) as type
  , CAST('SEQUENCE_OBJECT' as sys.nvarchar(60)) as type_desc
  , CAST(null as sys.datetime) as create_date
  , CAST(null as sys.datetime) as modify_date
  , CAST(0 as sys.bit) as is_ms_shipped
  , CAST(0 as sys.bit) as is_published
  , CAST(0 as sys.bit) as is_schema_published
from pg_class p
inner join sys.schemas s on s.schema_id = p.relnamespace
and p.relkind = 'S'
and has_schema_privilege(s.schema_id, 'USAGE')
union all
select
    CAST(('TT_' || tt.name || '_' || tt.type_table_object_id) as sys.sysname) as name
  , CAST(tt.type_table_object_id as int) as object_id
  , CAST(tt.principal_id as int) as principal_id
  , CAST(tt.schema_id as int) as schema_id
  , CAST(0 as int) as parent_object_id
  , CAST('TT' as char(2)) as type
  , CAST('TABLE_TYPE' as sys.nvarchar(60)) as type_desc
  , CAST((select string_agg(
                    case
                    when option like 'bbf_rel_create_date=%%' then substring(option, 21)
                    else NULL
                    end, ',')
          from unnest(c.reloptions) as option)
     as sys.datetime) as create_date
  , CAST((select string_agg(
                    case
                    when option like 'bbf_rel_create_date=%%' then substring(option, 21)
                    else NULL
                    end, ',')
          from unnest(c.reloptions) as option)
     as sys.datetime) as modify_date
  , CAST(1 as sys.bit) as is_ms_shipped
  , CAST(0 as sys.bit) as is_published
  , CAST(0 as sys.bit) as is_schema_published
from sys.table_types tt
inner join pg_class c on tt.type_table_object_id = c.oid;
GRANT SELECT ON sys.objects TO PUBLIC;

CREATE OR REPLACE FUNCTION objectproperty(
    id INT,
    property SYS.VARCHAR
    )
RETURNS INT
AS $$
BEGIN

    IF NOT EXISTS(SELECT ao.object_id FROM sys.all_objects ao WHERE object_id = id)
    THEN
        RETURN NULL;
    END IF;

    property := RTRIM(LOWER(COALESCE(property, '')));

    IF property = 'ownerid' -- OwnerId
    THEN
        RETURN (
                SELECT CAST(COALESCE(t1.principal_id, pn.nspowner) AS INT)
                FROM sys.all_objects t1
                INNER JOIN pg_catalog.pg_namespace pn ON pn.oid = t1.schema_id
                WHERE t1.object_id = id);

    ELSEIF property = 'isdefaultcnst' -- IsDefaultCnst
    THEN
        RETURN (SELECT count(distinct dc.object_id) FROM sys.default_constraints dc WHERE dc.object_id = id);

    ELSEIF property = 'execisquotedidenton' -- ExecIsQuotedIdentOn
    THEN
        RETURN (SELECT CAST(sm.uses_quoted_identifier as int) FROM sys.all_sql_modules sm WHERE sm.object_id = id);

    ELSEIF property = 'tablefulltextpopulatestatus' -- TableFullTextPopulateStatus
    THEN
        IF NOT EXISTS (SELECT object_id FROM sys.tables t WHERE t.object_id = id) THEN
            RETURN NULL;
        END IF;
        RETURN 0;

    ELSEIF property = 'tablehasvardecimalstorageformat' -- TableHasVarDecimalStorageFormat
    THEN
        IF NOT EXISTS (SELECT object_id FROM sys.tables t WHERE t.object_id = id) THEN
            RETURN NULL;
        END IF;
        RETURN 0;

    ELSEIF property = 'ismsshipped' -- IsMSShipped
    THEN
        RETURN (SELECT CAST(ao.is_ms_shipped AS int) FROM sys.all_objects ao WHERE ao.object_id = id);

    ELSEIF property = 'isschemabound' -- IsSchemaBound
    THEN
        RETURN (SELECT CAST(sm.is_schema_bound AS int) FROM sys.all_sql_modules sm WHERE sm.object_id = id);

    ELSEIF property = 'execisansinullson' -- ExecIsAnsiNullsOn
    THEN
        RETURN (SELECT CAST(sm.uses_ansi_nulls AS int) FROM sys.all_sql_modules sm WHERE sm.object_id = id);

    ELSEIF property = 'isdeterministic' -- IsDeterministic
    THEN
        RETURN 0;

    ELSEIF property = 'isprocedure' -- IsProcedure
    THEN
        RETURN (SELECT count(distinct object_id) from sys.all_objects WHERE object_id = id and type = 'P');

    ELSEIF property = 'istable' -- IsTable
    THEN
        RETURN (SELECT count(distinct object_id) from sys.all_objects WHERE object_id = id and type in ('IT', 'TT', 'U', 'S'));

    ELSEIF property = 'isview' -- IsView
    THEN
        RETURN (SELECT count(distinct object_id) from sys.all_objects WHERE object_id = id and type = 'V');

    ELSEIF property = 'isusertable' -- IsUserTable
    THEN
        RETURN (SELECT count(distinct object_id) from sys.all_objects WHERE object_id = id and type = 'U' and is_ms_shipped = 0);

    ELSEIF property = 'istablefunction' -- IsTableFunction
    THEN
        RETURN (SELECT count(distinct object_id) from sys.all_objects WHERE object_id = id and type in ('IF', 'TF', 'FT'));

    ELSEIF property = 'isinlinefunction' -- IsInlineFunction
    THEN
        RETURN 0;

    ELSEIF property = 'isscalarfunction' -- IsScalarFunction
    THEN
        RETURN (SELECT count(distinct object_id) from sys.all_objects WHERE object_id = id and type in ('FN', 'FS'));

    ELSEIF property = 'isprimarykey' -- IsPrimaryKey
    THEN
        RETURN (SELECT count(distinct object_id) from sys.all_objects WHERE object_id = id and type = 'PK');

    ELSEIF property = 'isindexed' -- IsIndexed
    THEN
        RETURN (SELECT count(distinct object_id) from sys.indexes WHERE object_id = id and index_id > 0);

    ELSEIF property = 'isdefault' -- IsDefault
    THEN
        RETURN 0;

    ELSEIF property = 'isrule' -- IsRule
    THEN
        RETURN 0;

    ELSEIF property = 'istrigger' -- IsTrigger
    THEN
        RETURN (SELECT count(distinct object_id) from sys.all_objects WHERE object_id = id and type in ('TA', 'TR'));
    END IF;

    RETURN NULL;
END;
$$
LANGUAGE plpgsql;

CALL sys.babelfish_drop_deprecated_view('sys', 'check_constraints_deprecated_in_2_3_0');
CALL sys.babelfish_drop_deprecated_view('sys', 'default_constraints_deprecated_in_2_3_0');

-- Drops the temporary procedure used by the upgrade script.
-- Please have this be one of the last statements executed in this upgrade script.
DROP PROCEDURE sys.babelfish_drop_deprecated_view(varchar, varchar);

-- Reset search_path to not affect any subsequent scripts
SELECT set_config('search_path', trim(leading 'sys, ' from current_setting('search_path')), false);
