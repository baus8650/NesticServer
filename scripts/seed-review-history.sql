-- Add 30 completed calendar days to the existing App Review fixture only.
-- Run with psql -v ON_ERROR_STOP=1 -f scripts/seed-review-history.sql.
-- Existing records, credentials, settings, and health episodes are preserved.
-- Repeat runs skip populated subject/tracker days; deterministic IDs also
-- prevent duplicate inserts for an identical calendar day.
BEGIN;
WITH target AS (
    SELECT DISTINCT u.id AS actor_id, n.id AS nest_id
    FROM users u JOIN nest_members m ON m.user_id = u.id
    JOIN nests n ON n.id = m.nest_id
    WHERE u.email = 'test@test.com' AND n.name = 'Our Little Nest'
), days AS (
    SELECT d, (CURRENT_TIMESTAMP AT TIME ZONE 'America/New_York')::date - d AS day
    FROM generate_series(1, 30) d
), schedule(subject, tracker, hour, cadence) AS (
    VALUES ('Parker','Meal',8,1), ('Parker','Outdoor time',9,1),
           ('Parker','Energy',18,1), ('Parker','Daily supplement',8,3),
           ('Parker','Weight',10,7), ('Penny','Mood',20,2),
           ('Penny','Water intake',19,2), ('Home','Home check',17,3)
), candidates AS (
    SELECT t.*, e.id AS entity_id, a.id AS action_id, s.tracker, ds.d, ds.day,
           ((ds.day + make_interval(hours => s.hour,
                mins => ((ds.d * 7 + s.hour) % 31) - 15)
              + CASE WHEN extract(isodow FROM ds.day) IN (6,7)
                     THEN interval '45 minutes' ELSE interval '0 minutes' END)
             AT TIME ZONE 'America/New_York') AT TIME ZONE 'UTC' AS occurred_at,
           'Synthetic QA history (30-day seed) / ' || ds.day || ' / ' || s.tracker AS note
    FROM target t JOIN entities e ON e.nest_id = t.nest_id
    JOIN schedule s ON s.subject = e.name
    JOIN trackable_actions a ON a.nest_id = t.nest_id AND a.name = s.tracker
    JOIN entity_pinned_actions p ON p.entity_id = e.id AND p.action_id = a.id
    CROSS JOIN days ds
    WHERE (s.tracker = 'Mood' AND ds.d % 2 = 0)
       OR (s.tracker = 'Water intake' AND ds.d % 2 = 1)
       OR (s.tracker NOT IN ('Mood','Water intake') AND (ds.d - 1) % s.cadence = 0)
), inserted AS (
    INSERT INTO action_events
        (id,nest_id,entity_id,action_id,actor_user_id,occurred_at,
         value_number,value_text,note,was_accident,include_in_predictions,created_at)
    SELECT md5('review-history-v1/' || c.entity_id || '/' || c.action_id || '/' || c.day)::uuid,
           c.nest_id,c.entity_id,c.action_id,c.actor_id,c.occurred_at,
           CASE c.tracker WHEN 'Meal' THEN 1.0 + (c.d % 3) * 0.125
                WHEN 'Outdoor time' THEN 20 + (c.d * 7 % 21)
                WHEN 'Energy' THEN 6 + (c.d * 3 % 4)
                WHEN 'Weight' THEN 72.1 + (c.d % 5) * 0.1
                WHEN 'Water intake' THEN 5 + (c.d % 4) END,
           CASE WHEN c.tracker = 'Mood' THEN
                (ARRAY['Steady','Relaxed','Energetic','Tired'])[1 + (c.d / 2 % 4)] END,
           c.note,false,true,CURRENT_TIMESTAMP AT TIME ZONE 'UTC'
    FROM candidates c WHERE NOT EXISTS (
        SELECT 1 FROM action_events ev
        WHERE ev.entity_id = c.entity_id AND ev.action_id = c.action_id
          AND ((ev.occurred_at AT TIME ZONE 'UTC') AT TIME ZONE 'America/New_York')::date = c.day
    ) ON CONFLICT (id) DO NOTHING
    RETURNING id
) SELECT count(*) AS inserted_records FROM inserted;
COMMIT;

SELECT e.name AS subject, a.name AS tracker, count(*) AS records,
       min(ev.occurred_at)::date AS earliest, max(ev.occurred_at)::date AS latest
FROM action_events ev JOIN entities e ON e.id = ev.entity_id
JOIN trackable_actions a ON a.id = ev.action_id
WHERE ev.nest_id IN (
    SELECT n.id FROM nests n JOIN nest_members m ON m.nest_id = n.id
    JOIN users u ON u.id = m.user_id
    WHERE u.email = 'test@test.com' AND n.name = 'Our Little Nest'
) GROUP BY e.name,a.name ORDER BY e.name,a.name;
