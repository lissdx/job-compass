-- 001_init.sql — initial schema.
--
-- Apply:  sqlite3 db/sqlite/jobcompass.db < db/sqlite/migrations/001_init.sql
--
-- Shape:  companies ─< positions ─< applications ─< application_events
--                                        │
--                       headhunters ─<───┘
--
-- Design contract:
--   * `application_events` is an APPEND-ONLY journal. UPDATE and DELETE are
--     blocked by triggers. A correction is a new row, never an edit.
--   * Current status is DERIVED from that journal by the view `v_current`.
--     `applications` deliberately carries NO status column, so nothing can
--     drift out of agreement with the journal.
--   * `applications.closed_at` is the single derived column, because a partial
--     UNIQUE index cannot be built on a view. Only the trigger writes it.
--   * Triggers guard invariants only. Policy — when to set `confirmed_at`, how
--     to resolve a provisional contact — lives in application code, where
--     changing it costs nothing.

PRAGMA foreign_keys = ON;

BEGIN;

-- ---------------------------------------------------------------------------
-- migration bookkeeping
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS schema_migrations (
    version    TEXT PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ---------------------------------------------------------------------------
-- companies — who hires. One row per national arm we deal with: 'Google' in IL
-- and in US are two rows, because you apply to each separately.
-- ---------------------------------------------------------------------------

CREATE TABLE companies (
    id           INTEGER PRIMARY KEY,
    -- INTEGER PRIMARY KEY fills itself. No AUTOINCREMENT keyword: that only
    -- forbids reusing ids of deleted rows, and we never delete companies.

    name         TEXT NOT NULL,
    -- Our label, not the legal name. Legal names are registry entries — the
    -- Israeli Google entities are registered in Hebrew — and looking them up
    -- would be work for no gain: we track applications, not corporate identity.

    country      TEXT NOT NULL DEFAULT 'IL' CHECK (length(country) = 2),
    -- The country we are applying INTO — which national arm of the company we
    -- are dealing with. For a remote role: the country of the hiring entity.
    -- ISO 3166-1 alpha-2, one format only; 'IL' and 'ISR' would be two rows.

    website      TEXT,
    linkedin_url TEXT,
    description  TEXT,   -- what the company does — a public fact
    industry     TEXT,   -- fintech / cyber / medtech / ...
    notes        TEXT,   -- our own judgement — private

    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Guards against entering the same company twice. NOT an identity claim:
-- 'Google Israel' and 'Google Cloud Israel' are two legal entities in one
-- country, and they coexist here as two rows because the labels differ.
CREATE UNIQUE INDEX ux_companies_name_country
    ON companies (lower(name), country);

-- ---------------------------------------------------------------------------
-- headhunters — a contact card for one recruiter. It always reflects who they
-- are TODAY: name, agency, email and phone are all updated in place.
-- ---------------------------------------------------------------------------

CREATE TABLE headhunters (
    id             INTEGER PRIMARY KEY,

    name           TEXT NOT NULL,
    -- A label. Deliberately NOT unique in any combination: two people with the
    -- same name can work at the same agency.

    agency         TEXT,
    -- The recruiter's current agency. NULL means we do not know it. We never
    -- write 'independent' — that would assert something we have not verified.

    email          TEXT,
    -- The practical identity of a recruiter, and the upsert key. Ask for it
    -- early, but it stays nullable: some contacts reach us with no email.

    linkedin_url   TEXT,   -- second hard identifier: one profile, one person
    phone          TEXT,   -- contact only: an agency shares one switchboard
    notes          TEXT,

    confirmed_at   TEXT,
    -- Identity gate. NULL = provisional: we have talked to this person but hold
    -- no hard identifier, so we cannot be sure this row is not the same human
    -- as another one. Provisional rows are resolved by eye, never by upsert —
    -- an upsert would silently create a third row instead of matching.

    deactivated_at TEXT,
    -- Soft delete: do not write here any more. Orthogonal to confirmed_at — a
    -- recruiter can be identified and still be someone we no longer contact.

    created_at     TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at     TEXT NOT NULL DEFAULT (datetime('now')),

    -- A row cannot be confirmed unless it carries a real identifier.
    CHECK (confirmed_at IS NULL OR email IS NOT NULL OR linkedin_url IS NOT NULL)
);

-- Unique only where the value exists: rows with NULL are not indexed at all,
-- which is what makes a provisional contact possible in the first place.
-- NOTE: to upsert against these, the WHERE clause must be repeated inside
-- ON CONFLICT, or SQLite rejects the statement outright.
CREATE UNIQUE INDEX ux_headhunters_email
    ON headhunters (lower(email))        WHERE email IS NOT NULL;
CREATE UNIQUE INDEX ux_headhunters_linkedin
    ON headhunters (lower(linkedin_url)) WHERE linkedin_url IS NOT NULL;

-- ---------------------------------------------------------------------------
-- positions — what the job is, plus our verdict on it. A position exists
-- whether or not we applied: one with no applications is simply a job we
-- reviewed and passed on.
-- ---------------------------------------------------------------------------

CREATE TABLE positions (
    id           INTEGER PRIMARY KEY,

    company_id   INTEGER REFERENCES companies(id),
    -- NULL when a recruiter would not name the company. Normal, it happens.

    role_title   TEXT NOT NULL,
    external_ref TEXT,   -- the employer's requisition id, when they give one
    source_url   TEXT,   -- ad links rot, which is why we keep the description
    location     TEXT,   -- where THIS team sits, not the company headquarters
    description  TEXT,   -- the ad text, frozen as we saw it

    priority     INTEGER CHECK (priority BETWEEN 1 AND 5),
    -- 1 = act now … 5 = worth it only as interview practice

    fit          TEXT CHECK (fit IS NULL OR json_valid(fit)),
    -- Our structured verdict on the role. Fields:
    --   covered_commercial  — requirements met by paid work
    --   covered_self_built  — requirements met by our own projects
    --   gaps                — not covered, but not disqualifying
    --   blockers            — structural gates we do not pass
    --   flags               — warning signs in the ad itself
    --   open_questions      — to ask the recruiter
    --   verdict             — apply / practice-only / skip
    --   score               — integer, our own scale

    notes        TEXT,
    closed_at    TEXT,   -- the employer pulled the vacancy

    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX ux_positions_external_ref
    ON positions (company_id, external_ref) WHERE external_ref IS NOT NULL;
CREATE INDEX ix_positions_company ON positions (company_id);

-- ---------------------------------------------------------------------------
-- applications — ONE attempt at one position. Applying again after a rejection
-- or a reopening creates a SECOND row against the same position.
-- ---------------------------------------------------------------------------

CREATE TABLE applications (
    id            INTEGER PRIMARY KEY,
    position_id   INTEGER NOT NULL REFERENCES positions(id),

    headhunter_id INTEGER REFERENCES headhunters(id),
    -- NULL = we applied directly. The channel belongs to the ATTEMPT, not to
    -- the position: the same job can be pursued directly first and through an
    -- agency later, and those are two attempts.

    applied_at    TEXT NOT NULL,

    closed_at     TEXT,
    -- DERIVED. Written only by trg_events_close, on a terminal event. Never set
    -- this by hand. NULL means the attempt is still live.

    notes         TEXT,

    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

-- At most ONE live attempt per position. A closed one does not block a new try,
-- which is exactly how re-applying is meant to work.
CREATE UNIQUE INDEX ux_applications_live
    ON applications (position_id) WHERE closed_at IS NULL;
CREATE INDEX ix_applications_headhunter ON applications (headhunter_id);

-- ---------------------------------------------------------------------------
-- application_events — append-only chronology of ONE attempt.
-- ---------------------------------------------------------------------------

CREATE TABLE application_events (
    id             INTEGER PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(id),

    to_status      TEXT NOT NULL CHECK (to_status IN (
                       'sent',        -- it went out
                       'replied',     -- they came back to us
                       'interview',   -- an interview round happened; see stage
                       'offer',
                       'hired',       -- terminal
                       'rejected',    -- terminal — they said no
                       'declined',    -- terminal — we withdrew
                       'withdrawn'    -- terminal — they pulled the vacancy
                   )),

    stage          TEXT,
    -- Free-form name of the step, used mainly with 'interview': 'HR screen',
    -- 'home assignment', 'hiring manager', 'system design'. A name rather than
    -- a number, because after a screen and an assignment "round 2" means little.

    occurred_at    TEXT NOT NULL,   -- when it happened; may be backdated
    channel        TEXT,            -- email / linkedin / phone / portal
    note           TEXT,            -- why, in one line

    created_at     TEXT NOT NULL DEFAULT (datetime('now'))
    -- occurred_at is the fact; created_at is when we wrote it down.
);

CREATE INDEX ix_events_application ON application_events (application_id, occurred_at);

-- Append-only enforcement. These are invariants, not conveniences: they hold
-- against any writer, including a hand-typed statement in the sqlite3 shell.
CREATE TRIGGER trg_events_no_update
BEFORE UPDATE ON application_events
BEGIN
    SELECT RAISE(ABORT, 'application_events is append-only: insert a new row instead of updating');
END;

CREATE TRIGGER trg_events_no_delete
BEFORE DELETE ON application_events
BEGIN
    SELECT RAISE(ABORT, 'application_events is append-only: rows cannot be deleted');
END;

-- A terminal event closes the attempt, which releases the live-application
-- index and makes re-applying possible.
CREATE TRIGGER trg_events_close
AFTER INSERT ON application_events
WHEN NEW.to_status IN ('hired', 'rejected', 'declined', 'withdrawn')
BEGIN
    UPDATE applications
       SET closed_at = NEW.occurred_at, updated_at = datetime('now')
     WHERE id = NEW.application_id;
END;

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------

CREATE TRIGGER trg_companies_touch
AFTER UPDATE ON companies FOR EACH ROW
BEGIN
    UPDATE companies SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER trg_headhunters_touch
AFTER UPDATE ON headhunters FOR EACH ROW
BEGIN
    UPDATE headhunters SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER trg_positions_touch
AFTER UPDATE ON positions FOR EACH ROW
BEGIN
    UPDATE positions SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ---------------------------------------------------------------------------
-- v_current — one row per attempt, status derived from the journal.
-- ---------------------------------------------------------------------------

CREATE VIEW v_current AS
WITH latest AS (
    SELECT e.*
      FROM application_events e
      JOIN (SELECT application_id, MAX(id) AS id
              FROM application_events
             GROUP BY application_id) m
        ON m.id = e.id
)
SELECT
    a.id                                  AS application_id,
    COALESCE(c.name, '(company unknown)') AS company,
    p.role_title                          AS role,
    COALESCE(h.name, 'direct')            AS via,
    -- An attempt with no journal rows is a data error, not a state — say so.
    COALESCE(l.to_status, '!! no-events') AS status,
    l.stage,
    p.priority,
    json_extract(p.fit, '$.verdict')      AS fit_verdict,
    json_extract(p.fit, '$.score')        AS fit_score,
    l.occurred_at                         AS status_since,
    -- 'stale' is computed, never stored: no movement for 30 days while live.
    CASE WHEN a.closed_at IS NULL
          AND julianday('now') - julianday(l.occurred_at) > 30
         THEN 1 ELSE 0 END                AS is_stale,
    a.closed_at,
    p.external_ref,
    p.location,
    p.source_url
FROM applications a
JOIN positions        p ON p.id = a.position_id
LEFT JOIN companies   c ON c.id = p.company_id
LEFT JOIN headhunters h ON h.id = a.headhunter_id
LEFT JOIN latest      l ON l.application_id = a.id;

INSERT INTO schema_migrations(version) VALUES ('001_init');

COMMIT;
