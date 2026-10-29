-- Teilnehmer-Protokoll pro Online-Tisch: bleibt auch bestehen, wenn jemand den Platz verlässt.
-- Wird per Trigger automatisch gepflegt (Hinsetzen, Nachkauf, Stack-Änderung, Verlassen).
create table if not exists online_participants (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null references online_tables(id) on delete cascade,
  seat_no int not null,
  user_id uuid,
  player_id text,
  user_email text,
  buyin_total numeric not null default 0,
  final_stack numeric,
  joined_at timestamptz not null default now(),
  left_at timestamptz
);
create index if not exists online_participants_table_idx on online_participants (table_id);
alter table online_participants enable row level security;
drop policy if exists "online_participants_select" on online_participants;
create policy "online_participants_select" on online_participants
  for select using (is_club_member((select club_id from online_tables t where t.id = online_participants.table_id)));

create or replace function online_participants_sync() returns trigger
language plpgsql security definer as $$
begin
  if tg_op = 'INSERT' then
    insert into online_participants(table_id, seat_no, user_id, player_id, user_email, buyin_total, final_stack)
    values (new.table_id, new.seat_no, new.user_id, new.player_id, new.user_email, coalesce(new.buyin_total, new.stack, 0), new.stack);
    return new;
  elsif tg_op = 'UPDATE' then
    update online_participants set buyin_total = coalesce(new.buyin_total, buyin_total), final_stack = new.stack
      where table_id = new.table_id and seat_no = new.seat_no and left_at is null;
    return new;
  else
    update online_participants set final_stack = old.stack, left_at = now()
      where table_id = old.table_id and seat_no = old.seat_no and left_at is null;
    return old;
  end if;
end $$;
drop trigger if exists online_seats_participants on online_seats;
create trigger online_seats_participants after insert or update or delete on online_seats
  for each row execute function online_participants_sync();

-- Bestehende, aktuell sitzende Spieler nachtragen
insert into online_participants(table_id, seat_no, user_id, player_id, user_email, buyin_total, final_stack)
select s.table_id, s.seat_no, s.user_id, s.player_id, s.user_email, coalesce(s.buyin_total, s.stack, 0), s.stack
from online_seats s
where not exists (select 1 from online_participants p where p.table_id = s.table_id and p.seat_no = s.seat_no and p.left_at is null);
