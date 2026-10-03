-- =====================================================================
-- Chipmate — Online Poker Phase 0: variable Tischgrösse (2/6/10 Sitze)
-- =====================================================================
-- Nach den bisherigen chipmate_online_poker_*.sql-Dateien ausführen.
--
-- Hintergrund: bisher waren Online-Tische fest auf 2 Sitze (seat_no 0/1)
-- ausgelegt — das betraf sowohl die Lobby/Sitzplatz-UI als auch den
-- Karten-Dealer (deal_hand/submit_action/resolve_showdown). Die Spalte
-- seat_count erlaubt jetzt grössere Tische (6-Max, 10-Max), ABER: der
-- Karten-Dealer (automatisches Austeilen/Setzrunden) bleibt vorerst
-- bewusst heads-up-only (siehe deal_hand: "Beide Sitze müssen besetzt
-- sein", hartcodiert auf seat_no 0 und 1) — ein echter Multiway-Dealer
-- (Side-Pots, Aktionsreihenfolge über mehr als 2 Spieler, Mehrweg-
-- Showdown) ist ein eigenes, grösseres Stück Arbeit, das hier NICHT
-- mitgemacht wird.
--
-- Für Tische mit mehr als 2 Sitzen dient die App also vorerst als reiner
-- Sitzplatz-/Buy-in-/Stack-Tracker mit dem echten Tisch-Layout (wie ein
-- digitales Clipboard am Tisch) — "Hand starten" bleibt nur bei genau 2
-- besetzten Sitzen (0 und 1) verfügbar. Das Tisch-SCHLIESSEN (Ergebnis
-- in die Statistik übernehmen) hat schon vorher mit beliebig vielen
-- Sitzen funktioniert (siehe reallyCloseOnlineTable in poker-club.html),
-- das ändert sich hier nicht.
-- =====================================================================

alter table online_tables add column if not exists seat_count int not null default 2;

-- "add constraint" kennt kein IF NOT EXISTS in Postgres — das Skript soll aber
-- wie die anderen chipmate_*.sql-Dateien gefahrlos mehrfach laufen können.
do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'online_tables_seat_count_check'
  ) then
    alter table online_tables add constraint online_tables_seat_count_check check (seat_count between 2 and 10);
  end if;
end $$;
