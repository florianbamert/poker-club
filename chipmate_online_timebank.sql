-- Timebank / Zugzeit für Online-Tische
-- 15 s pro Entscheid (Server foldet bei Ablauf), +45 s Timebank pro Sitz einmal alle 50 Hände.
alter table online_hand_state add column if not exists turn_deadline timestamptz;
alter table online_seats add column if not exists timebank_last_hand integer;

-- Sit-out: wer sein Zeitlimit überschreitet, wird nicht mehr ausgeteilt, bis er "Ich bin wieder da" drückt.
alter table online_seats add column if not exists sitting_out boolean not null default false;

-- deal_hand() überspringt Sitze mit sitting_out = true
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
    from online_seats where table_id = p_table_id and user_id is not null and coalesce(stack,0) > 0 and coalesce(sitting_out,false) = false;
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
