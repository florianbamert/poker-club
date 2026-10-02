-- =====================================================================
-- Chipmate — Nachtrag 1: E-Mail-Adresse pro Mitgliedschaft speichern
-- =====================================================================
-- Nach dem Haupt-Skript (chipmate_rollen_schema.sql) ausführen.
-- Grund: Damit im Mitglieder-Panel ("Einstellungen" → "Mitglieder &
-- Anfragen") die E-Mail-Adresse einer Person angezeigt werden kann,
-- statt nur ihrer internen User-ID.
-- =====================================================================

alter table club_memberships add column if not exists user_email text;

create or replace function create_club(p_code text, p_name text)
returns uuid language plpgsql security definer as $$
declare
  v_club_id uuid;
  v_email text;
begin
  select email into v_email from auth.users where id = auth.uid();

  insert into clubs (code, name) values (p_code, p_name)
    returning id into v_club_id;

  insert into club_memberships (club_id, user_id, role, user_email)
    values (v_club_id, auth.uid(), 'app_gestaltend', v_email);

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

create or replace function approve_join_request(p_request_id uuid, p_role club_role)
returns void language plpgsql security definer as $$
declare
  v_club_id uuid;
  v_user_id uuid;
  v_email text;
begin
  select club_id, user_id, requested_email into v_club_id, v_user_id, v_email
    from club_join_requests where id = p_request_id;

  if v_club_id is null then
    raise exception 'Anfrage nicht gefunden';
  end if;

  if club_role_of(v_club_id) is distinct from 'app_gestaltend' then
    raise exception 'Nur app_gestaltend darf Anfragen genehmigen';
  end if;

  insert into club_memberships (club_id, user_id, role, user_email)
    values (v_club_id, v_user_id, p_role, v_email)
    on conflict (club_id, user_id) do update set role = excluded.role, user_email = excluded.user_email;

  update club_join_requests set status = 'approved' where id = p_request_id;
end;
$$;
