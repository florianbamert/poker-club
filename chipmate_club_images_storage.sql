-- Bild-Speicher für Clubs (Avatare, Layout-Bilder, Kartendecks, ...)
-- Grosse Bilder liegen NICHT mehr im club_data-JSON (das wurde zu gross und scheiterte beim Speichern/Laden),
-- sondern als Dateien im Supabase Storage. Im JSON steht nur noch die Adresse.
--
-- Der Bucket ist öffentlich lesbar (Bilder haben unratbare Dateinamen), Hochladen dürfen nur Mitglieder
-- mit Schreibrechten (erfassend / app_gestaltend) in den Ordner ihres eigenen Clubs.

insert into storage.buckets (id, name, public)
values ('club-images', 'club-images', true)
on conflict (id) do update set public = true;

drop policy if exists "club_images_read" on storage.objects;
create policy "club_images_read" on storage.objects
  for select using (bucket_id = 'club-images');

drop policy if exists "club_images_insert" on storage.objects;
create policy "club_images_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'club-images'
    and club_role_of(((storage.foldername(name))[1])::uuid) in ('erfassend', 'app_gestaltend')
  );

drop policy if exists "club_images_update" on storage.objects;
create policy "club_images_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'club-images'
    and club_role_of(((storage.foldername(name))[1])::uuid) in ('erfassend', 'app_gestaltend')
  );
