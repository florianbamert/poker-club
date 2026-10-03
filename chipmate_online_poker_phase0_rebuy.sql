-- =====================================================================
-- Chipmate — Online Poker Phase 0: Nachkauf (Rebuy) während des Sitzens
-- =====================================================================
-- Nach den bisherigen chipmate_online_poker_*.sql-Dateien ausführen.
--
-- Warum eine eigene Funktion statt einer simplen UPDATE-Policy auf
-- online_seats: Eine UPDATE-Policy, die Spielern erlaubt, ihre eigene
-- stack-Spalte zu verändern, würde es ihnen auch erlauben, sich per
-- direktem API-Call (am UI vorbei) jederzeit einen beliebig hohen Stack
-- zu geben — auch mitten in einer laufenden Hand. Diese Funktion prüft
-- stattdessen serverseitig: nur ein positiver Betrag, nur zwischen zwei
-- Händen (nicht während aktivem Betting), und nur für den eigenen Sitz.
-- =====================================================================
create or replace function add_online_buyin(p_table_id uuid, p_amount numeric)
returns void language plpgsql security definer as $$
declare
  v_seat_no int;
  v_phase online_hand_phase;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'Ungültiger Betrag';
  end if;

  select seat_no into v_seat_no from online_seats
    where table_id = p_table_id and user_id = auth.uid();
  if v_seat_no is null then
    raise exception 'Nicht an diesem Tisch gesetzt';
  end if;

  select phase into v_phase from online_hand_state where table_id = p_table_id;
  if v_phase is not null and v_phase not in ('waiting','done') then
    raise exception 'Nachkauf ist nur zwischen zwei Händen möglich';
  end if;

  update online_seats
    set stack = coalesce(stack,0) + p_amount,
        buyin_total = coalesce(buyin_total,0) + p_amount
    where table_id = p_table_id and seat_no = v_seat_no;
end;
$$;

grant execute on function add_online_buyin(uuid, numeric) to authenticated;
