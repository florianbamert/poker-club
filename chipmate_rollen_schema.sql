-- =====================================================================
-- Chipmate — Rollen & Auth: Datenbank-Schema für Supabase
-- =====================================================================
-- Einfach dieses gesamte Skript in Supabase → SQL Editor → "New query"
-- einfügen und mit "Run" ausführen. Kann in einem Rutsch laufen.
--
-- Was das hier macht:
--  1. Neue Tabellen: clubs, club_memberships (Rollen), club_join_requests
--     (Beitrittsanfragen), club_data (die eigentlichen Club-Inhalte),
--     club_change_log (Änderungsprotokoll für Transparenz)
--  2. Row Level Security (RLS) auf allen Tabellen — nur wer eine
--     passende Mitgliedschaft hat, darf lesen/schreiben
--  3. Zwei Hilfsfunktionen: einen Club anlegen (create_club) und eine
--     Beitrittsanfrage genehmigen (approve_join_request)
--
-- Das ERSETZT NICHTS Bestehendes automatisch — die alte app_storage-
-- Tabelle bleibt unangetastet, bis die App-Seite umgestellt ist
-- (separater Schritt: bestehende Club-Daten migrieren).
-- =====================================================================

-- Rollen als fester Wertebereich, damit keine Tippfehler wie 'admin'
-- statt 'app_gestaltend' möglich sind.
create type club_role as enum ('lesend', 'erfassend', 'app_gestaltend');

-- Ein Club: der 5-stellige Code bleibt wie bisher der menschenlesbare
-- Zugangsweg, ist aber jetzt nur noch ein Nachschlage-Schlüssel, keine
-- Zugriffsberechtigung mehr für sich allein.
create table clubs (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  created_at timestamptz not null default now()
);

-- Wer ist in welchem Club mit welcher Rolle. player_id verweist optional
-- auf die id eines Eintrags in club_data.data->players (kein echter
-- Fremdschlüssel, weil Spieler weiterhin als JSON-Array in club_data
-- leben, nicht als eigene Tabelle — bewusst so gehalten, um den
-- bestehenden App-Code grösstenteils unverändert zu lassen).
create table club_memberships (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role club_role not null default 'lesend',
  player_id text,
  created_at timestamptz not null default now(),
  unique (club_id, user_id)
);

-- Wenn sich jemand per Club-Code für Lesezugriff anmeldet, landet das
-- hier, bis ein "app_gestaltend"-Mitglied es bestätigt (siehe unsere
-- Besprechung: Code + Admin-Freigabe, kein automatischer Zugriff).
create table club_join_requests (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  requested_email text,
  status text not null default 'pending', -- pending | approved | rejected
  created_at timestamptz not null default now(),
  unique (club_id, user_id)
);

-- Die eigentlichen Club-Inhalte (players/sessions/hands/... als EIN
-- JSON-Objekt, genau wie bisher in currentClub) — nur jetzt mit
-- echter Zugriffskontrolle statt einem öffentlichen Key.
create table club_data (
  club_id uuid primary key references clubs(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

-- Änderungsprotokoll: wer hat wann was an einem Club geändert. Bewusst
-- nur eine kurze Zusammenfassung pro Eintrag (kein komplettes Diff),
-- reicht für Transparenz/Abschreckung, wie besprochen.
create table club_change_log (
  id bigint generated always as identity primary key,
  club_id uuid not null references clubs(id) on delete cascade,
  user_id uuid references auth.users(id),
  summary text not null,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- Row Level Security aktivieren
-- =====================================================================
alter table clubs enable row level security;
alter table club_memberships enable row level security;
alter table club_join_requests enable row level security;
alter table club_data enable row level security;
alter table club_change_log enable row level security;

-- Hilfsfunktionen, die Policies unten mehrfach brauchen.
create or replace function is_club_member(p_club_id uuid)
returns boolean language sql stable security definer as $$
  select exists (
    select 1 from club_memberships m
    where m.club_id = p_club_id and m.user_id = auth.uid()
  );
$$;

create or replace function club_role_of(p_club_id uuid)
returns club_role language sql stable security definer as $$
  select role from club_memberships m
  where m.club_id = p_club_id and m.user_id = auth.uid();
$$;

-- clubs: Name/Code dürfen von jeder eingeloggten Person nachgeschlagen
-- werden (nötig, um überhaupt per Code beitreten zu können) — die
-- eigentlichen Club-INHALTE sind separat über club_data geschützt.
create policy "clubs_select_authenticated" on clubs
  for select using (auth.role() = 'authenticated');

-- club_memberships: man sieht seine eigene Mitgliedschaft, oder alle
-- Mitgliedschaften eines Clubs, wenn man dort app_gestaltend ist.
create policy "memberships_select" on club_memberships
  for select using (
    user_id = auth.uid() or club_role_of(club_id) = 'app_gestaltend'
  );

-- Nur app_gestaltend darf Mitgliedschaften anlegen/ändern/entfernen
-- (Rollen vergeben, Mitglieder rauswerfen) — deckt sich mit "Mitglieder
-- hinzufügen/Rollen vergeben" aus unserem Rollenmodell.
create policy "memberships_admin_write" on club_memberships
  for all using (club_role_of(club_id) = 'app_gestaltend')
  with check (club_role_of(club_id) = 'app_gestaltend');

-- club_join_requests: jede Person darf für sich selbst eine Anfrage
-- stellen; sehen kann man seine eigene Anfrage oder (als Admin) alle
-- Anfragen des eigenen Clubs; genehmigen/ablehnen nur als Admin.
create policy "joinreq_insert_own" on club_join_requests
  for insert with check (user_id = auth.uid());

create policy "joinreq_select" on club_join_requests
  for select using (
    user_id = auth.uid() or club_role_of(club_id) = 'app_gestaltend'
  );

create policy "joinreq_admin_update" on club_join_requests
  for update using (club_role_of(club_id) = 'app_gestaltend');

-- club_data: DAS ist die eigentliche Absicherung. Lesen dürfen alle
-- Mitglieder (auch "lesend"), schreiben nur "erfassend" und
-- "app_gestaltend" — "lesend" kann auf DB-Ebene gar nicht schreiben,
-- selbst wenn jemand versucht, das in der App zu umgehen.
create policy "clubdata_select_members" on club_data
  for select using (is_club_member(club_id));

create policy "clubdata_update_writers" on club_data
  for update using (club_role_of(club_id) in ('erfassend', 'app_gestaltend'));

-- club_change_log: alle Mitglieder dürfen das Protokoll einsehen
-- (Transparenz-Prinzip) und Einträge hinzufügen (die App schreibt bei
-- jeder relevanten Änderung automatisch einen Log-Eintrag).
create policy "changelog_select_members" on club_change_log
  for select using (is_club_member(club_id));

create policy "changelog_insert_members" on club_change_log
  for insert with check (is_club_member(club_id));

-- =====================================================================
-- Hilfsfunktionen für die App
-- =====================================================================

-- Club anlegen: legt Club + club_data + macht den Ersteller automatisch
-- zu "app_gestaltend". Läuft mit erhöhten Rechten (security definer),
-- weil sonst ein Henne-Ei-Problem entstünde (man müsste schon Mitglied
-- sein, um sich selbst als Mitglied eintragen zu dürfen).
create or replace function create_club(p_code text, p_name text)
returns uuid language plpgsql security definer as $$
declare
  v_club_id uuid;
begin
  insert into clubs (code, name) values (p_code, p_name)
    returning id into v_club_id;

  insert into club_memberships (club_id, user_id, role)
    values (v_club_id, auth.uid(), 'app_gestaltend');

  insert into club_data (club_id, data) values (
    v_club_id,
    jsonb_build_object(
      'info', jsonb_build_object('name', p_name, 'createdAt', now()),
      'players', '[]'::jsonb,
      'sessions', '[]'::jsonb,
      'hands', '[]'::jsonb,
      'payoutTemplates', '[]'::jsonb
    )
  );

  return v_club_id;
end;
$$;

-- Beitrittsanfrage genehmigen: nur ein app_gestaltend-Mitglied des
-- betroffenen Clubs darf das (wird zusätzlich zur RLS-Policy hier noch
-- einmal geprüft, weil die Funktion mit erhöhten Rechten läuft).
create or replace function approve_join_request(p_request_id uuid, p_role club_role)
returns void language plpgsql security definer as $$
declare
  v_club_id uuid;
  v_user_id uuid;
begin
  select club_id, user_id into v_club_id, v_user_id
    from club_join_requests where id = p_request_id;

  if v_club_id is null then
    raise exception 'Anfrage nicht gefunden';
  end if;

  if club_role_of(v_club_id) is distinct from 'app_gestaltend' then
    raise exception 'Nur app_gestaltend darf Anfragen genehmigen';
  end if;

  insert into club_memberships (club_id, user_id, role)
    values (v_club_id, v_user_id, p_role)
    on conflict (club_id, user_id) do update set role = excluded.role;

  update club_join_requests set status = 'approved' where id = p_request_id;
end;
$$;
