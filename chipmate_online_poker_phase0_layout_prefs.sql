-- =====================================================================
-- Chipmate — Online Poker: persönliche Layout-Präferenz pro Online-Tisch
-- =====================================================================
-- Bisher lag die gewählte Tisch-Optik (layout_id) direkt auf online_tables —
-- EIN gemeinsamer Wert für alle Sitzenden. Wer ihn änderte, änderte ihn für
-- alle gleichzeitig. Neu: jede Person kann für sich selbst ein anderes
-- Table-Designer-Layout wählen, ohne die Ansicht der anderen zu beeinflussen.
--
-- online_tables.layout_id bleibt als Spalte bestehen (nicht mehr aktiv vom
-- Frontend gesetzt, siehe poker-club.html) und wirkt nur noch als Fallback-
-- Default für Leute, die selbst noch keine eigene Wahl getroffen haben.
--
-- Tri-State pro Person:
--   - keine Zeile vorhanden      -> noch keine eigene Wahl, Fallback auf
--                                   online_tables.layout_id
--   - Zeile mit layout_id = null -> bewusst "Standard-Tisch" gewählt, auch
--                                   wenn der Tisch selbst einen Fallback hat
--   - Zeile mit layout_id = 'x'  -> eigenes Layout 'x'
--
-- Kein club_id-Bezug nötig: Zugriff ist rein über user_id = auth.uid()
-- geregelt, unabhängig von Club-Mitgliedschaft oder Sitzplatz-Status — eine
-- rein persönliche Fensterdeko, kein geteilter Spielzustand.
-- =====================================================================

create table if not exists online_layout_prefs (
  user_id uuid not null references auth.users(id) on delete cascade,
  table_id uuid not null references online_tables(id) on delete cascade,
  layout_id text,
  updated_at timestamptz not null default now(),
  primary key (user_id, table_id)
);

alter table online_layout_prefs enable row level security;

drop policy if exists "online_layout_prefs_own" on online_layout_prefs;
create policy "online_layout_prefs_own" on online_layout_prefs
  for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
