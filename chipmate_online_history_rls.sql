-- Hand-Protokoll darf von allen Club-Mitgliedern gelesen werden (nicht nur von sitzenden Spielern),
-- damit ein Club-Admin den Tisch auch schliessen kann, wenn er selbst (oder alle) schon aufgestanden sind.
-- Das Protokoll enthält nur öffentliche Informationen (Aktionen, Board, aufgedeckte Karten, Auszahlungen).
drop policy if exists "online_hand_history_select" on online_hand_history;
create policy "online_hand_history_select" on online_hand_history
  for select using (
    is_seated_at(table_id)
    or is_club_member((select club_id from online_tables t where t.id = online_hand_history.table_id))
  );
