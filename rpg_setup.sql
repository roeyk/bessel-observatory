/* Run once in the dedicated BESSELAB library after CRTLIB.
   Input: an IBM i SQL session with CREATE TABLE authority.
   Output: durable cross-job work storage. Used by parent and batch RPG jobs.
   Each generated run ID isolates concurrent invocations of the observatory. */
CREATE TABLE BESSELAB.WORK_ITEMS (
    run_id VARCHAR(32) NOT NULL,
    ordinal INTEGER NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL DEFAULT 0,
    pid INTEGER NOT NULL DEFAULT 0,
    state CHAR(1) NOT NULL DEFAULT 'Q' CHECK (state IN ('Q','D','E')),
    PRIMARY KEY (run_id, ordinal)
);
