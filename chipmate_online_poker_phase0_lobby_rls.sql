-- =====================================================================
-- Chipmate — Online Poker Phase 0: Lobby-RLS (Tisch erstellen, Platz nehmen)
-- =====================================================================
-- Nach chipmate_online_poker_schema.sql und
-- chipmate_online_poker_phase0_functions.sql ausführen.
--
-- Grund für diese Datei: Die ursprünglichen Policies für online_tables und
-- online_seats (in chipmate_online_poker_schema.sql) erlauben SELECT nur,
-- wenn man schon an diesem Tisch sitzt (is_seated_at). Das ist ein Henne-
-- Ei-Problem: ein neuer Tisch mit noch leeren Plätzen wäre für niemanden
-- sichtbar, also könnte sich auch niemand hinsetzen. Ausserdem fehlten
-- bisher komplett die Policies, um überhaupt einen Tisch anzulegen oder
-- einen Platz zu beanspruchen — das ging bisher nur rein lesend.
--
-- Neues Modell: alle MITGLIEDER DES CLUBS (is_club_member, bereits aus dem
-- Rollen-Schema vorhanden) sehen die Tischliste und wer wo sitzt — wie an
-- einem echten Tisch im Raum, wo jeder sieht, wer mitspielt. Die
-- geheimen Karten bleiben weiterhin ausschliesslich über
-- get_my_hole_cards() / den privaten Realtime-Kanal erreichbar.
-- =====================================================================

-- --- online_tables: Sichtbarkeit für alle Club-Mitglieder, nicht nur Sitzende ---
drop policy if exists "online_tables_select" on online_tables;
create policy "online_tables_select" on online_tables
  for select using (is_club_member(club_id));

-- Tisch anlegen dürfen dieselben Rollen, die auch Sessions anlegen dürfen.
create policy "online_tables_insert" on online_tables
  for insert with check (club_role_of(club_id) in ('erfassend','app_gestaltend'));

-- Aufräumen (z. B. Testtische) nur für App-gestaltend-Rolle; Kaskaden
-- löschen automatisch die zugehörigen Sitze/Hände (on delete cascade).
create policy "online_tables_delete" on online_tables
  for delete using (club_role_of(club_id) = 'app_gestaltend');

-- Anzeigename am Tisch (wie bei club_memberships.user_email) — wird beim
-- Platznehmen vom Client mitgeschickt, damit der Mitspieler nicht nur eine
-- UUID sieht.
alter table online_seats add column if not exists user_email text;

-- --- online_seats: Sichtbarkeit für alle Club-Mitglieder ---
drop policy if exists "online_seats_select" on online_seats;
create policy "online_seats_select" on online_seats
  for select using (
    is_club_member((select club_id from online_tables t where t.id = online_seats.table_id))
  );

-- Platz beanspruchen: jeder Club-Mitglied darf eine Sitzzeile für SICH
-- SELBST anlegen (user_id muss der eigene sein). Der unique(table_id,
-- seat_no)-Constraint verhindert, dass zwei Leute denselben Platz belegen.
create policy "online_seats_claim" on online_seats
  for insert with check (
    user_id = auth.uid()
    and is_club_member((select club_id from online_tables t where t.id = online_seats.table_id))
  );

-- Platz wieder verlassen: nur die eigene Sitzzeile darf gelöscht werden.
-- (Phase 0 bewusst einfach gehalten — keine Sperre "nicht während einer
-- laufenden Hand verlassen"; das ist ein Komfort-Feature für später.)
create policy "online_seats_leave" on online_seats
  for delete using (user_id = auth.uid());

-- =====================================================================
-- Absicherung: deal_hand() darf NUR die start_hand Edge Function (per
-- Service-Role-Key) auslösen, nicht jeder eingeloggte Nutzer direkt per
-- RPC — sonst könnte irgendwer bei jedem Tisch jederzeit eine neue Hand
-- erzwingen, auch ohne selbst zu sitzen (deal_hand prüft das nicht
-- selbst, nur dass beide Plätze besetzt sind).
-- =====================================================================
revoke execute on function deal_hand(uuid) from public;
revoke execute on function deal_hand(uuid) from authenticated;
grant execute on function deal_hand(uuid) to service_role;

-- =====================================================================
-- get_public_hand_state: nicht-geheimer Spielzustand für den initialen
-- Ladevorgang bzw. nach einem Reload — die Edge Functions pushen Updates
-- zusätzlich per Realtime-Broadcast, aber ohne diese Funktion hätte ein
-- Client, der die Seite neu lädt oder später dazukommt, keine Möglichkeit,
-- den aktuellen Stand (Board, Pot, wer am Zug ist) überhaupt zu laden.
-- =====================================================================
create or replace function get_public_hand_state(p_table_id uuid)
returns jsonb language plpgsql security definer as $$
declare
  v_row online_hand_state%rowtype;
  v_result jsonb;
begin
  if not is_seated_at(p_table_id) then
    return null; -- nur Sitzende dürfen den Stand abfragen
  end if;
  select * into v_row from online_hand_state where table_id = p_table_id;
  if v_row.table_id is null then
    return null;
  end if;
  v_result := jsonb_build_object(
    'hand_no', v_row.hand_no, 'phase', v_row.phase, 'dealer_seat', v_row.dealer_seat,
    'board', v_row.board, 'pot', v_row.pot, 'current_seat', v_row.current_seat,
    'bets', v_row.bets, 'acted', v_row.acted, 'folded', v_row.folded,
    'last_raise_size', v_row.last_raise_size, 'updated_at', v_row.updated_at
  );
  -- Am Showdown/nach Handende sind alle Karten regelkonform öffentlich,
  -- genau wie beim Live-Broadcast in submit_action.
  if v_row.phase in ('showdown','done') then
    v_result := v_result || jsonb_build_object('hole_cards', v_row.hole_cards);
  end if;
  return v_result;
end;
$$;
