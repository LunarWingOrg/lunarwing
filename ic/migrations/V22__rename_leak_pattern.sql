-- Rename nearai_session leak detection pattern to lunarwing_cloud_session.
-- Aligns PostgreSQL seed data with libSQL (which already uses lunarwing_cloud_session).
-- See issue #209.
UPDATE leak_detection_patterns
SET name = 'lunarwing_cloud_session'
WHERE name = 'nearai_session';
