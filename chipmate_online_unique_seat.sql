-- Ein Spieler / Login darf nur einmal pro Tisch sitzen.
-- Vorher doppelte Sitze entfernen (sonst schlägt der Index fehl):
--   select table_id, player_id, count(*) from online_seats where player_id is not null group by 1,2 having count(*) > 1;
create unique index if not exists online_seats_one_player_per_table on online_seats (table_id, player_id) where player_id is not null;
create unique index if not exists online_seats_one_user_per_table on online_seats (table_id, user_id) where user_id is not null;
