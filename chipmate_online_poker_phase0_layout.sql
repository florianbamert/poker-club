-- =====================================================================
-- Chipmate — Online Poker Phase 0: Tisch-Layout (Table Designer) übernehmen
-- =====================================================================
-- Nach den bisherigen chipmate_online_poker_*.sql-Dateien ausführen.
--
-- Hintergrund: der Online-Tisch soll optisch genau wie im Handerfassungs-
-- modus aussehen, inklusive selbst gestalteter Table-Designer-Layouts
-- (layoutTemplates). Diese Layouts leben weiterhin NUR im club_data-JSON
-- (kein eigenes Postgres-Objekt), daher speichern wir hier nur die
-- gewählte layout_id als unverbindlichen Verweis — genau wie player_id
-- bei online_seats. Das Frontend löst die id beim Rendern gegen
-- layoutTemplates auf (siehe getSeatSlotsForRender-Aufruf mit
-- layoutOverride).
--
-- Nullable und ohne Fremdschlüssel: ein Tisch ohne (oder mit ungültiger/
-- gelöschter) layout_id fällt einfach auf die generische Standard-Optik
-- zurück.
-- =====================================================================

alter table online_tables add column if not exists layout_id text;

-- Wer am Tisch sitzt, darf das Layout wählen/ändern. Statt einer neuen
-- zusätzlichen PERMISSIVE Policy (die per OR mit "online_tables_close"
-- kombiniert würde und dessen status='finished'-Einschränkung dadurch
-- versehentlich für ALLE Updates aufheben würde), ersetzen wir die
-- bestehende Policy durch eine einzige, die beides abdeckt: Sitzende
-- dürfen den Tisch aktualisieren (Layout wählen, schliessen). Wie schon
-- bei der ursprünglichen online_tables_close-Policy vermerkt, wird
-- bewusst nicht Spalte für Spalte eingeschränkt, welche Felder sich im
-- selben UPDATE sonst noch ändern dürfen — in einer Runde unter
-- bekannten Mitspielern kein echtes Risiko, für eine spätere Härtung
-- aber vermerkt.
drop policy if exists "online_tables_close" on online_tables;
create policy "online_tables_update" on online_tables
  for update using (is_seated_at(id)) with check (true);
