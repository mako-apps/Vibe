-- Create a public bucket for uploads
-- Note: You can also do this in the Supabase Dashboard -> Storage

-- 1. Create the bucket
insert into storage.buckets (id, name, public)
values ('secure-uploads', 'secure-uploads', true)
on conflict (id) do nothing;

-- 2. Allow Public Read Access
create policy "Public Access"
  on storage.objects for select
  using ( bucket_id = 'secure-uploads' );

-- 3. Allow Uploads (Server bypassing RLS via Service Key doesn't technically need this, but good for completeness)
create policy "Allow Uploads"
  on storage.objects for insert
  with check ( bucket_id = 'secure-uploads' );
