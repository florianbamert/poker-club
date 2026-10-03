-- =====================================================================
-- Chipmate — Online Poker Phase 0: Spieler-Verknüpfung & Tisch schliessen
-- =====================================================================
-- Nach chipmate_online_poker_schema.sql, chipmate_online_poker_phase0_
-- functions.sql und chipmate_online_poker_phase0_lobby_rls.sql ausführen.
--
-- Hintergrund: Damit ein Online-Sitzplatz einem echten Spieler-Eintrag aus
-- der Statistik (currentClub.players, im club_data-JSON-Blob) zugeordnet
-- werden kann, braucht online_seats eine Referenz auf dessen id. Diese id
-- ist KEIN Postgres-UUID (die App generiert sie clientseitig mit einem
-- simplen Base36-String, siehe uid() in poker-club.html), darum text und
-- nicht uuid als Spaltentyp.
--
-- Bewusst KEINE Fremdschlüssel-Beziehung zu einer Spieler-Tabelle, weil
-- Spieler weiterhin nur im club_data-JSON leben, nicht in einer eigenen
-- Postgres-Tabelle — player_id ist hier nur ein unverbindlicher Verweis,
-- den das Frontend beim Übernehmen der Session auflöst.
-- =====================================================================

alter table online_seats add column if not exists player_id text;
alter table online_seats add column if not exists buyin_total numeric;

-- Erlaubt es einem sitzenden Spieler, den Tisch auf 'finished' zu setzen
-- (passiert beim Klick auf "Tisch schliessen & Ergebnis übernehmen").
-- Für Phase 0 bewusst einfach gehalten: die Policy schränkt nur den
-- RESULTIERENDEN status-Wert ein (muss 'finished' sein), nicht aber,
-- welche anderen Spalten im selben UPDATE sonst noch verändert werden
-- könnten (z.B. die Blinds) — in einer Runde unter bekannten Mitspielern
-- kein echtes Risiko, für eine spätere Härtung aber vermerkt.
create policy "online_tables_close" on online_tables
  for update using (is_seated_at(id)) with check (status = 'finished');

-- =====================================================================
-- Server-seitige Absicherung der Spieler-Verknüpfung
-- =====================================================================
-- Die App verhindert im UI, dass man sich einen fremden Spieler-Eintrag
-- zuordnet (myPlayer() sucht nur nach der EIGENEN E-Mail) — das allein
-- reicht aber nicht, weil ein API-Aufruf am UI vorbei (z.B. per curl mit
-- dem eigenen Auth-Token) sonst trotzdem eine BELIEBIGE player_id
-- mitschicken könnte. Diese Funktion prüft direkt im club_data-JSON, ob
-- der angegebene Spieler tatsächlich per linkedEmail auf die E-Mail des
-- gerade authentifizierten Nutzers zeigt.
create or replace function player_belongs_to_me(p_club_id uuid, p_player_id text)
returns boolean language sql stable security definer as $$
  select exists (
    select 1
    from club_data cd, jsonb_array_elements(cd.data->'players') as player
    where cd.club_id = p_club_id
      and player->>'id' = p_player_id
      and lower(player->>'linkedEmail') = lower((select email from auth.users where id = auth.uid()))
  );
$$;

drop policy if exists "online_seats_claim" on online_seats;
create policy "online_seats_claim" on online_seats
  for insert with check (
    user_id = auth.uid()
    and is_club_member((select club_id from online_tables t where t.id = online_seats.table_id))
    and (
      player_id is null
      or player_belongs_to_me((select club_id from online_tables t where t.id = online_seats.table_id), player_id)
    )
  );
