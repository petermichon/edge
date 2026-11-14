\set ON_ERROR_STOP on
\pset pager off

SET statement_timeout = '10min';

BEGIN;

DO $$
DECLARE
  cutoff timestamptz := now() - interval '12 months';
  deleted bigint;
BEGIN
  DELETE FROM event_data WHERE created_at < cutoff;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'event_data: %', deleted;

  DELETE FROM session_data WHERE created_at < cutoff;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'session_data: %', deleted;

  DELETE FROM heatmap_event WHERE created_at < cutoff;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'heatmap_event: %', deleted;

  DELETE FROM revenue WHERE created_at < cutoff;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'revenue: %', deleted;

  DELETE FROM session_replay WHERE created_at < cutoff;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'session_replay: %', deleted;

  DELETE FROM session_replay_saved WHERE created_at < cutoff;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'session_replay_saved: %', deleted;

  DELETE FROM session_link WHERE created_at < cutoff;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'session_link: %', deleted;

  DELETE FROM website_event WHERE created_at < cutoff;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'website_event: %', deleted;

  DELETE FROM session WHERE created_at < cutoff;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'session: %', deleted;
END $$;

COMMIT;

VACUUM (ANALYZE) website_event, session;
