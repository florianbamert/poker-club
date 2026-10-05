-- Aktionsprotokoll pro Online-Hand (damit gespielte Hände samt Replay in die gespeicherten Hände übernommen werden können)
alter table online_hand_state add column if not exists actions jsonb not null default '[]'::jsonb;
notify pgrst, 'reload schema';
