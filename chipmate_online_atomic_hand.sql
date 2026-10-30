-- Atomarer Hand-Abschluss: Spielzustand, Stacks, Protokoll und Sit-out werden in EINER Transaktion geschrieben.
-- Entweder alles oder nichts — es kann keine halb abgeschlossene Hand mehr geben (Chips gehen nicht mehr verloren).
create or replace function apply_hand_result(
  p_table_id uuid,
  p_expected_updated_at timestamptz,
  p_state jsonb,
  p_stacks jsonb,
  p_history jsonb,
  p_sit_out_seat int
) returns boolean
language plpgsql security definer as $$
declare
  v_rows int;
  k text;
begin
  update online_hand_state set
    phase = (p_state->>'phase')::online_hand_phase,
    board = p_state->'board',
    deck = p_state->'deck',
    pot = (p_state->>'pot')::numeric,
    current_seat = (p_state->>'current_seat')::int,
    bets = p_state->'bets',
    acted = p_state->'acted',
    folded = p_state->'folded',
    all_in = p_state->'all_in',
    contributions = p_state->'contributions',
    last_raise_size = (p_state->>'last_raise_size')::numeric,
    last_aggressor = (p_state->>'last_aggressor')::int,
    actions = coalesce(p_state->'actions', actions),
    turn_deadline = (p_state->>'turn_deadline')::timestamptz,
    revealed_hole_cards = case when p_state ? 'revealed_hole_cards' then p_state->'revealed_hole_cards' else revealed_hole_cards end,
    updated_at = now()
  where table_id = p_table_id and updated_at = p_expected_updated_at;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    return false;
  end if;

  for k in select jsonb_object_keys(coalesce(p_stacks, '{}'::jsonb)) loop
    update online_seats set stack = (p_stacks->>k)::numeric where table_id = p_table_id and seat_no = k::int;
  end loop;

  if p_history is not null then
    insert into online_hand_history(table_id, hand_no, summary)
    values (p_table_id, (p_history->>'hand_no')::int, p_history->'summary');
  end if;

  if p_sit_out_seat is not null then
    update online_seats set sitting_out = true where table_id = p_table_id and seat_no = p_sit_out_seat;
  end if;
  return true;
end $$;

revoke all on function apply_hand_result(uuid, timestamptz, jsonb, jsonb, jsonb, int) from public, anon, authenticated;
grant execute on function apply_hand_result(uuid, timestamptz, jsonb, jsonb, jsonb, int) to service_role;
