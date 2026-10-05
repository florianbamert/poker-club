-- Zusatzoptionen für Online-Tische (Chipset, Bet-Raster, 7-2 Game, Notizen)
alter table online_tables add column if not exists options jsonb not null default '{}'::jsonb;
notify pgrst, 'reload schema';
