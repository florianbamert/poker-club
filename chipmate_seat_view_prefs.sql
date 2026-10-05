-- =====================================================================
-- Chipmate — Persönliche Tisch-Ansicht (Wunschposition) pro Login und Club
-- =====================================================================
-- Speichert, wohin der eigene Sitz am Tisch gedreht werden soll (je Tischgrösse
-- Heads-up / 6-Max / 10-Max). Rein persönlich: Zugriff nur auf die eigene Zeile.
-- Ohne diese Tabelle funktioniert die Funktion weiter, aber nur lokal pro Gerät.
-- =====================================================================

create table if not exists seat_view_prefs (
  user_id uuid not null references auth.users(id) on delete cascade,
  club_id uuid not null references clubs(id) on delete cascade,
  prefs jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, club_id)
);

alter table seat_view_prefs enable row level security;

drop policy if exists "seat_view_prefs_own" on seat_view_prefs;
create policy "seat_view_prefs_own" on seat_view_prefs
  for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

notify pgrst, 'reload schema';
