-- Timebank / Zugzeit für Online-Tische
-- 15 s pro Entscheid (Server foldet bei Ablauf), +45 s Timebank pro Sitz einmal alle 50 Hände.
alter table online_hand_state add column if not exists turn_deadline timestamptz;
alter table online_seats add column if not exists timebank_last_hand integer;
