-- =====================================================================
-- Chipmate — Online Poker Phase 0: Mehrweg-Dealer (2–10 Spieler)
-- =====================================================================
-- Nach allen bisherigen chipmate_online_poker_*.sql-Dateien ausführen,
-- insbesondere nach chipmate_online_poker_phase0_seatcount.sql.
--
-- Ersetzt den bisher strikt heads-up-only deal_hand() (siehe Kommentar
-- dort: "Beide Sitze müssen besetzt sein", hartcodiert seat_no 0/1) durch
-- eine Version, die mit 2 bis 10 besetzten Sitzen klarkommt. Die
-- eigentliche Setzrunden-/Showdown-Logik liegt weiterhin in
-- supabase/functions/_shared/poker.ts (applyAction/resolveMultiwayShowdown) —
-- hier in SQL passiert nur das einmalige Mischen/Austeilen/Blinds-Einziehen
-- beim Start einer neuen Hand.
--
-- Neue Spalten auf online_hand_state:
--   seat_order    — für DIESE Hand fix: aufsteigend sortierte Liste der
--                   besetzten (stack>0) Sitze. Alle Rotations-Berechnungen
--                   (wer ist dran, wer ist SB/BB, Showdown-Reihenfolge)
--                   laufen über dieses Array, nicht mehr über "1 - seat".
--   contributions — Gesamtbeitrag jedes Sitzes zum Pot über die GANZE Hand
--                   (nicht nur die aktuelle Strasse) — nötig für Side-Pots
--                   bei unterschiedlich hohen All-ins.
--   all_in        — wer in dieser Hand all-in ist (kann nicht mehr agieren,
--                   bleibt aber im Pot-Rennen).
--   last_aggressor— wer zuletzt freiwillig gesetzt/erhöht hat (nie durch
--                   Blind-Pflichteinsatz). Showdown-Regel (siehe Absprache
--                   mit dem Club-Admin): nur dieser Sitz wird automatisch
--                   aufgedeckt, alle anderen nur falls sie tatsächlich
--                   einen Pot/Side-Pot gewinnen — niemand muss freiwillig
--                   zeigen.
-- =====================================================================

alter table online_hand_state add column if not exists seat_order int[] not null default '{}';
alter table online_hand_state add column if not exists contributions jsonb not null default '{}';
alter table online_hand_state add column if not exists all_in jsonb not null default '{}';
alter table online_hand_state add column if not exists last_aggressor int;
-- Persistiert, WESSEN Karten beim letzten Showdown tatsächlich aufgedeckt wurden
-- (letzter Aggressor + echte Pot-/Side-Pot-Gewinner, siehe resolveMultiwayShowdown
-- in _shared/poker.ts) — nötig, damit ein Reload/späterer Beitritt nach dem
-- Showdown dieselben (und NUR diese) Karten zeigt wie der Live-Broadcast, statt
-- aus Bequemlichkeit einfach wieder alle hole_cards offenzulegen.
alter table online_hand_state add column if not exists revealed_hole_cards jsonb not null default '{}';

-- Mischt, teilt an ALLE besetzten Sitze mit Stack > 0 aus, zieht die Blinds
-- ein, setzt die neue Hand auf. security definer, weil normale Nutzer
-- online_hand_state nicht direkt beschreiben dürfen (siehe Haupt-Schema).
create or replace function deal_hand(p_table_id uuid)
returns void language plpgsql security definer as $$
declare
  v_table record;
  v_occupied int[];
  n int;
  v_prev_dealer int;
  v_dealer_idx int;
  v_dealer int;
  v_deal_start_idx int; v_bb_idx int; v_utg_idx int;
  v_sb_seat int; v_bb_seat int; v_first_to_act int;
  v_deck text[];
  v_hand_no int;
  v_hole_cards jsonb := '{}'::jsonb;
  v_bets jsonb := '{}'::jsonb;
  v_contrib jsonb := '{}'::jsonb;
  v_folded jsonb := '{}'::jsonb;
  v_allin jsonb := '{}'::jsonb;
  v_pot numeric := 0;
  v_card_idx int := 1;
  v_seat int;
  v_deal_idx int;
  i int;
  v_sb numeric; v_bb numeric;
  v_stack numeric;
begin
  -- Zeile sperren, damit nicht zwei start_hand-Aufrufe gleichzeitig mischen.
  perform 1 from online_hand_state where table_id = p_table_id for update;

  select * into v_table from online_tables where id = p_table_id;
  if v_table is null then raise exception 'Tisch nicht gefunden'; end if;

  select array_agg(seat_no order by seat_no) into v_occupied
    from online_seats where table_id = p_table_id and user_id is not null and coalesce(stack,0) > 0;
  n := coalesce(array_length(v_occupied,1), 0);
  if n < 2 then
    raise exception 'Mindestens zwei Sitze mit Stack grösser als 0 nötig';
  end if;

  select hand_no, dealer_seat into v_hand_no, v_prev_dealer from online_hand_state where table_id = p_table_id;
  v_hand_no := coalesce(v_hand_no, 0) + 1;

  -- Dealer rotiert zum NÄCHSTEN besetzten Sitz nach dem bisherigen Dealer
  -- (nicht stur +1 — dazwischenliegende Sitze können leer sein). Erste Hand:
  -- der Sitz mit der kleinsten seat_no ist Dealer.
  if v_prev_dealer is null then
    v_dealer_idx := 1;
  else
    v_dealer_idx := 1; -- Fallback, falls prev_dealer grösser als alle ist (wrap)
    for i in 1..n loop
      if v_occupied[i] > v_prev_dealer then
        v_dealer_idx := i;
        exit;
      end if;
    end loop;
  end if;
  v_dealer := v_occupied[v_dealer_idx];
  -- Index des Sitzes direkt links vom Dealer in der Rotation — unabhängig davon,
  -- wer welchen Blind postet, bestimmt das nur die AUSTEIL-Reihenfolge (wie am
  -- echten Tisch: links vom Dealer zuerst, der Dealer selbst zuletzt).
  v_deal_start_idx := (v_dealer_idx % n) + 1;

  if n = 2 then
    -- Heads-up-Sonderregel: Dealer ist zugleich Small Blind und agiert
    -- preflop zuerst (Standard-Regel bei genau 2 Spielern).
    v_sb_seat := v_dealer;
    v_bb_idx := v_deal_start_idx;
    v_bb_seat := v_occupied[v_bb_idx];
    v_first_to_act := v_dealer;
  else
    v_bb_idx := (v_deal_start_idx % n) + 1;
    v_utg_idx := (v_bb_idx % n) + 1;
    v_sb_seat := v_occupied[v_deal_start_idx];
    v_bb_seat := v_occupied[v_bb_idx];
    v_first_to_act := v_occupied[v_utg_idx];
  end if;

  v_deck := shuffle_deck();

  -- Karten austeilen: 2 pro besetztem Sitz, beginnend links vom Dealer
  -- (wie am echten Tisch), endend beim Dealer selbst.
  v_card_idx := 1;
  for i in 1..n loop
    v_deal_idx := ((v_deal_start_idx + i - 2) % n) + 1;
    v_seat := v_occupied[v_deal_idx];
    v_hole_cards := v_hole_cards || jsonb_build_object(v_seat::text, jsonb_build_array(v_deck[v_card_idx], v_deck[v_card_idx+1]));
    v_card_idx := v_card_idx + 2;
  end loop;

  v_sb := least(v_table.small_blind, (select stack from online_seats where table_id = p_table_id and seat_no = v_sb_seat));
  v_bb := least(v_table.big_blind,   (select stack from online_seats where table_id = p_table_id and seat_no = v_bb_seat));

  update online_seats set stack = stack - v_sb where table_id = p_table_id and seat_no = v_sb_seat;
  update online_seats set stack = stack - v_bb where table_id = p_table_id and seat_no = v_bb_seat;

  v_bets := jsonb_build_object(v_sb_seat::text, v_sb, v_bb_seat::text, v_bb);
  v_contrib := v_bets;
  v_pot := v_sb + v_bb;

  for i in 1..n loop
    v_seat := v_occupied[i];
    v_folded := v_folded || jsonb_build_object(v_seat::text, false);
    select stack into v_stack from online_seats where table_id = p_table_id and seat_no = v_seat;
    v_allin := v_allin || jsonb_build_object(v_seat::text, coalesce(v_stack,0) <= 0);
  end loop;

  insert into online_hand_state (
    table_id, hand_no, phase, dealer_seat, deck, board, pot, current_seat,
    hole_cards, bets, acted, folded, last_raise_size, seat_order, contributions,
    all_in, last_aggressor, revealed_hole_cards, updated_at
  ) values (
    p_table_id, v_hand_no, 'preflop', v_dealer,
    to_jsonb(v_deck[(2*n+1):array_length(v_deck,1)]),
    '[]'::jsonb, v_pot, v_first_to_act,
    v_hole_cards, v_bets, '{}'::jsonb, v_folded, v_table.big_blind,
    v_occupied, v_contrib, v_allin, null, '{}'::jsonb, now()
  )
  on conflict (table_id) do update set
    hand_no = excluded.hand_no, phase = excluded.phase, dealer_seat = excluded.dealer_seat,
    deck = excluded.deck, board = excluded.board, pot = excluded.pot,
    current_seat = excluded.current_seat, hole_cards = excluded.hole_cards,
    bets = excluded.bets, acted = excluded.acted, folded = excluded.folded,
    last_raise_size = excluded.last_raise_size, seat_order = excluded.seat_order,
    contributions = excluded.contributions, all_in = excluded.all_in,
    last_aggressor = excluded.last_aggressor, revealed_hole_cards = excluded.revealed_hole_cards,
    updated_at = excluded.updated_at;

  update online_tables set status = 'running' where id = p_table_id;
end;
$$;

-- =====================================================================
-- get_public_hand_state neu: all_in (für ALL-IN-Badge) + revealed_hole_cards
-- (statt pauschal aller hole_cards) ergänzen, damit ein Reload/späterer
-- Beitritt nach dem Showdown GENAU dieselben Karten zeigt wie der Live-
-- Broadcast aus submit_action — ein verdecktes/schlechteres Blatt bleibt
-- also auch nach einem Reload verdeckt.
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
    'bets', v_row.bets, 'acted', v_row.acted, 'folded', v_row.folded, 'all_in', v_row.all_in,
    'last_raise_size', v_row.last_raise_size, 'updated_at', v_row.updated_at
  );
  if v_row.phase = 'done' then
    v_result := v_result || jsonb_build_object('hole_cards', v_row.revealed_hole_cards);
  end if;
  return v_result;
end;
$$;
