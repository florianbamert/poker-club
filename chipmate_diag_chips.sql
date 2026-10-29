-- Diagnose: Haende, in denen Chips verloren gegangen sein koennten.
-- 1) Ausgezahlter Betrag vs. Pot der Hand (alte Haende, ohne Bilanzfelder)
select table_id, hand_no, created_at,
       (summary->>'pot_total')::numeric as pot_total,
       (select coalesce(sum(value::numeric), 0) from jsonb_each_text(summary->'payouts')) as ausgezahlt,
       summary->>'phase_ended' as ende,
       summary->'actions' as aktionen
from online_hand_history
where abs((summary->>'pot_total')::numeric - (select coalesce(sum(value::numeric), 0) from jsonb_each_text(summary->'payouts'))) > 0.005
order by created_at desc
limit 50;

-- 2) Neue Haende (nach dem Update): eingebaute Chip-Bilanz
select table_id, hand_no, created_at,
       (summary->>'chips_before')::numeric as chips_vorher,
       (summary->>'chips_after')::numeric as chips_nachher
from online_hand_history
where summary ? 'chips_before'
  and abs((summary->>'chips_before')::numeric - (summary->>'chips_after')::numeric) > 0.005
order by created_at desc
limit 50;
