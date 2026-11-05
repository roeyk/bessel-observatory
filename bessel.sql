/*
  Bessel Observatory: validate observations, compute J0 in separate OS workers, and save ordered CSV.
  The parent reads input and owns result ordering; the worker computes the midpoint approximation.
  An invalid observation is skipped with a warning, while failed I/O or workers abort the run.
  PostgreSQL 14+ / psql. Run in a disposable database with dblink available.
  psql -X -d observatory -v values='0,1,5,10' -v workers=2 -v output=results.csv -f bessel.sql
  Optional: -v input=/absolute/SERVER/path/values.txt (pg_read_file privileges required).
  Optional: -v conn='service=observatory' for dblink authentication/connection settings.
  Without input/values, psql prompts for a comma-separated list.
  Every dblink connection has its own PostgreSQL OS backend process.
  Stop psql on a failed SQL or meta-command instead of continuing with partial results.
*/
\set ON_ERROR_STOP on
\set QUIET on
\if :{?input}
\else
  \set input '-'
\endif
\if :{?output}
\else
  \set output 'results.csv'
\endif
\if :{?workers}
\else
  \set workers 2
\endif
\if :{?conn}
\else
  SELECT format('dbname=%L', current_database()) AS conn \gset
\endif
SELECT :'input' = '-' AS interactive \gset
\if :interactive
  \if :{?values}
  \else
    \prompt 'Enter x values separated by commas: ' values
  \endif
\else
  \set values ''
\endif

-- Make asynchronous connections available in this dedicated database; extension privileges are required.
CREATE EXTENSION IF NOT EXISTS dblink;
-- Bind psql arguments as quoted data so SQL does not interpret user text as executable syntax.
CREATE TEMP TABLE bessel_config AS
SELECT :'input'::text AS input, :'values'::text AS entered_values,
       :'workers'::integer AS workers, :'conn'::text AS connection;
CREATE TEMP TABLE bessel_input (ordinal integer PRIMARY KEY, x double precision);
CREATE TEMP TABLE bessel_results
    (ordinal integer PRIMARY KEY, x double precision, j0 double precision, worker_pid integer);

-- Main execution block. Inputs: bessel_config and optional server file. Outputs: ordered bessel_results rows. Used by: the psql CSV export below.
DO $observatory$
DECLARE
    config record;
    source text;
    line text;
    value double precision;
    accepted integer := 0;
    first_row integer;
    slot integer;
    active integer;
    connection_name text;
    names text[] := ARRAY[]::text[];
    row record;
BEGIN
    SELECT * INTO STRICT config FROM bessel_config;
    IF config.workers NOT BETWEEN 1 AND 16 THEN
        RAISE EXCEPTION 'workers must be 1..16';
    END IF;
    -- Choose interactive comma-separated text or a file read by the database server.
    source := CASE WHEN config.input = '-'
              THEN replace(config.entered_values, ',', E'\n')
              ELSE pg_read_file(config.input) END;
    -- Normalize input records, end on a blank line, skip comments, and validate individual numbers.
    FOREACH line IN ARRAY string_to_array(source, E'\n') LOOP
        line := btrim(line, E' \t\r');
        EXIT WHEN line = '';
        CONTINUE WHEN left(line, 1) = '#';
        BEGIN
            IF line !~ '^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$' THEN
                RAISE EXCEPTION USING ERRCODE = '22P02', MESSAGE = 'expected one decimal number';
            END IF;
            value := line::double precision;
            IF NOT (value BETWEEN -1000 AND 1000) THEN
                RAISE EXCEPTION USING ERRCODE = '22003', MESSAGE = 'x outside [-1000,1000]';
            END IF;
        -- Recover from a bad value by warning and continuing with the next record.
        EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
            RAISE WARNING 'invalid number: %; skipped', line;
            CONTINUE;
        END;
        accepted := accepted + 1;
        IF accepted > 4096 THEN RAISE EXCEPTION 'at most 4096 values'; END IF;
        INSERT INTO bessel_input VALUES (accepted, value);
    END LOOP;
    IF accepted = 0 THEN RAISE EXCEPTION 'no valid input values'; END IF;

    -- Create a bounded set of database connections, each backed by a separate server OS process.
    FOR slot IN 1..least(config.workers, accepted) LOOP
        connection_name := format('bessel_%s_%s', pg_backend_pid(), slot);
        PERFORM dblink_connect(connection_name, config.connection || ' connect_timeout=10');
        names := array_append(names, connection_name);
        PERFORM dblink_exec(connection_name, 'SET statement_timeout = ''30s''');
    END LOOP;
    first_row := 1;
    -- Reuse the worker connections across bounded groups while retaining original row ordinals.
    WHILE first_row <= accepted LOOP
        active := least(config.workers, accepted - first_row + 1);
        FOR slot IN 1..active LOOP
            SELECT x INTO STRICT value FROM bessel_input WHERE ordinal = first_row + slot - 1;
            -- The numerical kernel is a relational aggregate, wholly in SQL.
            IF dblink_send_query(names[slot], format(
                'SELECT %L::float8 AS x,
                        avg(cos(%L::float8 * sin(pi() * (k + 0.5::float8) / 16384))) AS j0,
                        pg_backend_pid() AS worker_pid FROM generate_series(0,16383) AS g(k)',
                value, value)) <> 1 THEN
                RAISE EXCEPTION 'could not dispatch worker %', slot;
            END IF;
        END LOOP;
        -- Collect one result from each launched worker and associate it with its original input position.
        FOR slot IN 1..active LOOP
            SELECT * INTO STRICT row FROM dblink_get_result(names[slot])
                AS t(x double precision, j0 double precision, worker_pid integer);
            INSERT INTO bessel_results VALUES (first_row + slot - 1, row.x, row.j0, row.worker_pid);
            -- Async dblink requires one extra fetch to clear the command's result.
            PERFORM * FROM dblink_get_result(names[slot])
                AS t(x double precision, j0 double precision, worker_pid integer);
        END LOOP;
        first_row := first_row + active;
    END LOOP;
    FOREACH connection_name IN ARRAY names LOOP PERFORM dblink_disconnect(connection_name); END LOOP;
-- Cancel and disconnect owned worker connections before re-raising the original failure.
EXCEPTION WHEN OTHERS THEN
    FOREACH connection_name IN ARRAY names LOOP
        BEGIN
            PERFORM dblink_cancel_query(connection_name);
            PERFORM dblink_disconnect(connection_name);
        EXCEPTION WHEN OTHERS THEN NULL; -- Preserve the original error during cleanup.
        END;
    END LOOP;
    RAISE EXCEPTION 'Bessel Observatory: %', SQLERRM;
END
$observatory$;

-- Send only the final ordered result relation to a client-local CSV file.
\pset format csv
\pset footer off
\o :output
SELECT x, j0, worker_pid FROM bessel_results ORDER BY ordinal;
\o
\echo Wrote observations to :output
