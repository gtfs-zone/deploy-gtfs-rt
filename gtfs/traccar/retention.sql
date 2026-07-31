-- Traccar position-history retention. Ported verbatim from music-student's
-- scripts/traccar_retention.sql, with the psql \set replaced by a :days variable
-- passed in by the CronJob (psql -v days=...).
--
-- Traccar has NO built-in retention config key (verified against 6.14.5): it
-- persists every fix to tc_positions forever. On a single-node cluster with one
-- Longhorn volume this is the only thing bounding disk growth, so this CronJob is
-- required, not optional.
--
-- Safety: tc_positions has no DB-level FK in 6.14.5, but tc_devices (positionid,
-- motionpositionid) and tc_events (positionid) reference position rows as "latest
-- known" / event anchors. Deleting those would strand a device's last-known
-- position, so they are explicitly preserved below.

BEGIN;

DELETE FROM tc_positions p
WHERE p.fixtime < now() - make_interval(days => :days)
  AND p.id NOT IN (SELECT positionid       FROM tc_devices WHERE positionid       IS NOT NULL)
  AND p.id NOT IN (SELECT motionpositionid FROM tc_devices WHERE motionpositionid IS NOT NULL)
  AND p.id NOT IN (SELECT positionid       FROM tc_events  WHERE positionid       IS NOT NULL);

COMMIT;
