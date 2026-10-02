-- =====================================================================
-- Chipmate — Online Poker Phase 0: Datenbank-Schema für Supabase
-- =====================================================================
-- Einfach dieses gesamte Skript in Supabase → SQL Editor → "New query"
-- einfügen und mit "Run" ausführen.
--
-- Scope Phase 0 (siehe Architektur-Spezifikation, Abschnitt "Phase 0 im
-- Detail"): 1 Tisch, 2 Spieler (Heads-up NLHE), fixe Blinds, kein
-- Buy-in-Flow. Ziel: das Geheimnis- und Validierungsmodell verifizieren,
-- nicht ein fertiges Produkt.
--
-- Wichtig zum Verständnis der Sicherheitsarchitektur:
-- Row-Level-Security filtert ganze ZEILEN, nicht einzelne Schlüssel in
-- einem JSON-Feld. online_hand_state enthält die Hole Cards ALLER Sitze
-- in einer einzigen Zeile pro Tisch — deshalb gibt es für diese Tabelle
-- bewusst KEINE select-Policy für normale Nutzer (RLS liefert konstant
-- false). Zugriff auf die eigenen Karten läuft ausschliesslich über:
--   (a) die Security-Definer-Funktion get_my_hole_cards() unten, und
--   (b) einen privaten Realtime-Kanal pro Sitz (Policy ganz unten),
--       dessen Beitritt die Datenbank entscheidet, nicht der Client-Code.
-- =====================================================================

create type online_table_status as enum ('waiting','running','finished');
create type online_hand_phase as enum ('waiting','dealing','preflop','flop','turn','river','showdown','done');

create table online_tables (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  small_blind numeric not null,
  big_blind numeric not null,
  status online_table_status not null default 'waiting',
  created_at timestamptz not null default now()
);

-- Sitzplätze. Phase 0: genau 2 Sitze (seat_no 0 und 1).
create table online_seats (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null references online_tables(id) on delete cascade,
  seat_no int not null,
  user_id uuid references auth.users(id),
  stack numeric,
  created_at timestamptz not null default now(),
  unique (table_id, seat_no)
);

-- Der laufende Spielzustand. hole_cards ist ein JSON-Objekt
-- { "0": ["Ah","Kd"], "1": ["7c","7d"] } — ein Schlüssel pro Sitz.
-- deck ist das ungezogene Rest-Deck (Reihenfolge entscheidet künftige
-- Board-Karten) und darf NIE an einen Client gehen.
create table online_hand_state (
  table_id uuid primary key references online_tables(id) on delete cascade,
  hand_no int not null default 0,
  phase online_hand_phase not null default 'waiting',
  dealer_seat int,
  deck jsonb,
  board jsonb not null default '[]',
  pot numeric not null default 0,
  current_seat int,
  hole_cards jsonb not null default '{}',
  bets jsonb not null default '{}',          -- { "0": 50, "1": 100 } aktuelle Einsätze dieser Setzrunde
  acted jsonb not null default '{}',          -- { "0": true } wer in dieser Setzrunde schon gehandelt hat
  updated_at timestamptz not null default now()
);

-- Abgeschlossene Hände, fürs Replay und für die Übernahme nach club_data
-- am Ende der Session (siehe Architektur-Spezifikation, Datenmodell).
create table online_hand_history (
  id bigint generated always as identity primary key,
  table_id uuid not null references online_tables(id) on delete cascade,
  hand_no int not null,
  summary jsonb not null,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- Row Level Security
-- =====================================================================
alter table online_tables enable row level security;
alter table online_seats enable row level security;
alter table online_hand_state enable row level security;
alter table online_hand_history enable row level security;

create or replace function is_seated_at(p_table_id uuid)
returns boolean language sql stable security definer as $$
  select exists (
    select 1 from online_seats s
    where s.table_id = p_table_id and s.user_id = auth.uid()
  );
$$;

-- Tisch-Konfiguration: alle am Tisch dürfen lesen. Schreiben passiert
-- ausschliesslich über Edge Functions (eigene Rolle/Service-Key),
-- deshalb keine insert/update-Policy für normale Nutzer hier.
create policy "online_tables_select" on online_tables
  for select using (is_seated_at(id));

-- Sitzzuordnung: alle am Tisch sehen, wer wo sitzt (Stack ist öffentlich,
-- wie am echten Tisch auch).
create policy "online_seats_select" on online_seats
  for select using (is_seated_at(table_id));

-- online_hand_state: ABSICHTLICH KEINE select-Policy für normale Nutzer.
-- Ohne eine "for select"-Policy verweigert RLS jeden direkten Zugriff.
-- Lesen läuft nur über get_my_hole_cards() (für die eigenen Karten) und
-- über den öffentlichen Realtime-Broadcast-Kanal, den die Edge Function
-- explizit mit den nicht-geheimen Feldern befüllt (Board/Pot/Zug).

-- online_hand_history: wie bestehende "hands" lesbar für alle Club-
-- Mitglieder des zugehörigen Tisches.
create policy "online_hand_history_select" on online_hand_history
  for select using (is_seated_at(table_id));

-- =====================================================================
-- get_my_hole_cards: der einzige lesende Zugriffsweg auf eigene Karten
-- =====================================================================
create or replace function get_my_hole_cards(p_table_id uuid)
returns jsonb language plpgsql security definer as $$
declare
  v_seat int;
begin
  select seat_no into v_seat from online_seats
    where table_id = p_table_id and user_id = auth.uid();
  if v_seat is null then
    return null; -- nicht an diesem Tisch: keine Karten, kein Fehler mit Infogehalt
  end if;
  return (select hole_cards -> v_seat::text from online_hand_state where table_id = p_table_id);
end;
$$;

-- =====================================================================
-- Realtime Authorization: private Kanäle, einer pro Sitz
-- =====================================================================
-- Voraussetzung in den Supabase-Projekteinstellungen (Realtime):
-- "Allow public access" MUSS deaktiviert sein, und der Client muss den
-- Kanal mit { config: { private: true } } erstellen — sonst greift diese
-- Policy nicht (siehe https://supabase.com/docs/guides/realtime/authorization).
--
-- Kanal-Namenskonvention: 'table:<table_id>:seat:<seat_no>'
-- Diese Policy lässt einen Nutzer nur dem Kanal seines EIGENEN Sitzes
-- beitreten (lesen UND senden) — ein anderer Sitz im selben Tisch ist
-- ein anderer Topic-Name und damit ein anderer Policy-Check.
--
-- WICHTIG: KEIN "alter table realtime.messages enable row level security"
-- davor ausführen! RLS ist auf dieser Tabelle in Supabase bereits aktiv,
-- und die Tabelle gehört der internen Rolle supabase_realtime_admin, nicht
-- "postgres" — ein ALTER TABLE darauf scheitert mit "must be owner of
-- table messages" und reisst (in einer Transaktion) auch den darauf-
-- folgenden create policy-Befehl mit. "postgres" darf auf dieser einen
-- Tabelle zwar Policies erstellen (via supautils-Extension), aber keine
-- ALTER TABLE-Befehle ausführen.
-- Siehe https://supabase.com/docs/guides/troubleshooting/realtime-must-be-owner-of-table-messages
create policy "online_poker_private_seat_channel" on realtime.messages
  for select using (
    extension = 'broadcast'
    and exists (
      select 1 from online_seats s
      where s.user_id = auth.uid()
        and realtime.topic() = 'table:' || s.table_id::text || ':seat:' || s.seat_no::text
    )
  );

-- Hinweis: Die obige Policy prüft nur LESEzugriff (select). Falls Clients
-- selbst auf den privaten Kanal senden dürfen sollen (Phase 0 braucht das
-- nicht — nur die Edge Function sendet), eine analoge "for insert"-Policy
-- ergänzen.
