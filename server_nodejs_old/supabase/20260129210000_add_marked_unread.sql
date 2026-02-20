-- Migration: Add marked_unread to chat_participants
-- Date: 2026-01-29

-- 1. Add column
alter table chat_participants 
add column if not exists marked_unread boolean default false;

-- 2. Update RPC get_user_chats to include marked_unread
create or replace function get_user_chats(p_user_id text)
returns table (
  chat_id text,
  friend_id text,
  friend_name text,
  friend_key text,
  friend_identity_key text,
  friend_image text,
  muted boolean,
  pinned boolean,
  marked_unread boolean,
  last_message jsonb,
  unread_count bigint
)
language plpgsql
security definer
as $$
begin
  return query
  select 
    c.id as chat_id,
    u.id as friend_id,
    u.username as friend_name,
    u.public_key as friend_key,
    u.identity_key as friend_identity_key,
    u.profile_image as friend_image,
    cp.muted,
    cp.pinned,
    cp.marked_unread,
    (
      select to_jsonb(m) from messages m 
      where m.chat_id = c.id 
      order by m.timestamp desc limit 1
    ) as last_message,
    (
      select count(*) from messages m
      left join message_reads mr on m.id = mr.message_id and mr.reader_id = p_user_id
      where m.chat_id = c.id
      and m.from_id != p_user_id
      and mr.read_at is null
    ) as unread_count
  from chat_participants cp
  join chats c on cp.chat_id = c.id
  join chat_participants cp2 on c.id = cp2.chat_id and cp2.user_id != p_user_id
  join users u on cp2.user_id = u.id
  where cp.user_id = p_user_id;
end;
$$;
