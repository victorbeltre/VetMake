-- Victor (29 oct 2026): las tablas fit13_* eran de otra aplicación que ya no
-- usa. Se eliminan de vetmake-dev. Con IF EXISTS para que una base nueva,
-- que nunca las tuvo, pase esta migración sin error.
drop view if exists public.fit13_body_metrics_estimated cascade;
drop view if exists public.fit13_exercise_prs cascade;
drop view if exists public.fit13_exercise_session_history cascade;
drop table if exists public.fit13_body_metrics_estimated cascade;
drop table if exists public.fit13_exercise_prs cascade;
drop table if exists public.fit13_exercise_session_history cascade;
drop table if exists public.fit13_set_logs cascade;
drop table if exists public.fit13_workout_sessions cascade;
drop table if exists public.fit13_body_metrics cascade;
drop table if exists public.fit13_exercises cascade;
drop table if exists public.fit13_profiles cascade;
drop table if exists public.fit13_members cascade;
drop function if exists public.fit13_set_updated_at() cascade;
drop function if exists public.fit13_is_member() cascade;
drop schema if exists fit13_private cascade;
