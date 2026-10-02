-- =====================================================================
-- Chipmate — Online Poker Phase 0: Deal/Shuffle-Funktionen
-- =====================================================================
-- Nach chipmate_online_poker_schema.sql ausführen.
--
-- Diese Datei ergänzt zwei fehlende Spalten (folded, last_raise_size)
-- und die Shuffle/Deal-Logik. Die eigentliche Setzrunden-Logik (wer darf
-- was, wann ist eine Strasse fertig) liegt bewusst NICHT hier in SQL,
-- sondern als reine, lokal getestete TypeScript-Funktion in
-- supabase/functions/_shared/poker.ts — leichter nachvollziehbar und
-- ohne Datenbankzugriff testbar. Die Edge Function submit_action liest/
-- schreibt den Zustand atomar genug für Phase 0 (siehe deren Kommentar
-- zum optimistischen Locking).
-- =====================================================================

alter table online_hand_state add column if not exists folded jsonb not null default '{}';
alter table online_hand_state add column if not exists last_raise_size numeric not null default 0;

-- Kryptographisch sichere Zufallszahl 0..n-1, auf Basis von pgcrypto
-- (gen_random_bytes) statt des eingebauten random() — siehe Architektur-
-- Spezifikation, Abschnitt "RNG & Sicherheit".
create or replace function crypto_random_int(n int)
returns int language plpgsql as $$
declare
  b bytea := gen_random_bytes(4);
  v bigint;
begin
  v := (get_byte(b,0)::bigint << 24) | (get_byte(b,1)::bigint << 16)
     | (get_byte(b,2)::bigint << 8)  |  get_byte(b,3)::bigint;
  return ((v % n) + n) % n; -- immer 0..n-1, auch wenn v negativ interpretiert wird
end;
$$;

create or replace function shuffle_deck()
returns text[] language plpgsql as $$
declare
  ranks text[] := array['A','K','Q','J','T','9','8','7','6','5','4','3','2'];
  suits text[] := array['♠','♥','♦','♣'];
  deck text[] := '{}';
  r text; s text; i int; j int; tmp text;
begin
  foreach r in array ranks loop
    foreach s in array suits loop
      deck := array_append(deck, r || s);
    end loop;
  end loop;
  for i in reverse array_length(deck,1)..2 loop
    j := crypto_random_int(i) + 1; -- Postgres-Arrays sind 1-indiziert
    tmp := deck[i]; deck[i] := deck[j]; deck[j] := tmp;
  end loop;
  return deck;
end;
$$;

-- Mischt, teilt aus, zieht die Blinds ein, setzt die neue Hand auf.
-- security definer, weil normale Nutzer online_hand_state nicht direkt
-- beschreiben dürfen (siehe Haupt-Schema-Datei).
create or replace function deal_hand(p_table_id uuid)
returns void language plpgsql security definer as $$
declare
  v_table record;
  v_seat0 record;
  v_seat1 record;
  v_prev_dealer int;
  v_dealer int;
  v_deck text[];
  v_sb numeric; v_bb numeric;
  v_hand_no int;
begin
  -- Zeile sperren, damit nicht zwei start_hand-Aufrufe gleichzeitig mischen.
  perform 1 from online_hand_state where table_id = p_table_id for update;

  select * into v_table from online_tables where id = p_table_id;
  if v_table is null then raise exception 'Tisch nicht gefunden'; end if;

  select * into v_seat0 from online_seats where table_id = p_table_id and seat_no = 0;
  select * into v_seat1 from online_seats where table_id = p_table_id and seat_no = 1;
  if v_seat0.user_id is null or v_seat1.user_id is null then
    raise exception 'Beide Sitze müssen besetzt sein';
  end if;
  if coalesce(v_seat0.stack,0) <= 0 or coalesce(v_seat1.stack,0) <= 0 then
    raise exception 'Beide Spieler brauchen einen Stack grösser als 0';
  end if;

  select hand_no, dealer_seat into v_hand_no, v_prev_dealer
    from online_hand_state where table_id = p_table_id;
  v_hand_no := coalesce(v_hand_no, 0) + 1;
  v_dealer := case when v_prev_dealer is null then 0 else 1 - v_prev_dealer end;

  v_deck := shuffle_deck();
  v_sb := least(v_table.small_blind, case when v_dealer=0 then v_seat0.stack else v_seat1.stack end);
  v_bb := least(v_table.big_blind,   case when v_dealer=0 then v_seat1.stack else v_seat0.stack end);

  update online_seats set stack = stack - (case when seat_no = v_dealer then v_sb else v_bb end)
    where table_id = p_table_id;

  insert into online_hand_state (
    table_id, hand_no, phase, dealer_seat, deck, board, pot, current_seat,
    hole_cards, bets, acted, folded, last_raise_size, updated_at
  ) values (
    p_table_id, v_hand_no, 'preflop', v_dealer,
    to_jsonb(v_deck[5:array_length(v_deck,1)]),
    '[]'::jsonb, v_sb + v_bb, v_dealer,
    jsonb_build_object(
      v_dealer::text, jsonb_build_array(v_deck[1], v_deck[2]),
      (1-v_dealer)::text, jsonb_build_array(v_deck[3], v_deck[4])
    ),
    jsonb_build_object(v_dealer::text, v_sb, (1-v_dealer)::text, v_bb),
    '{}'::jsonb,
    jsonb_build_object('0', false, '1', false),
    v_table.big_blind,
    now()
  )
  on conflict (table_id) do update set
    hand_no = excluded.hand_no, phase = excluded.phase, dealer_seat = excluded.dealer_seat,
    deck = excluded.deck, board = excluded.board, pot = excluded.pot,
    current_seat = excluded.current_seat, hole_cards = excluded.hole_cards,
    bets = excluded.bets, acted = excluded.acted, folded = excluded.folded,
    last_raise_size = excluded.last_raise_size, updated_at = excluded.updated_at;

  update online_tables set status = 'running' where id = p_table_id;
end;
$$;
