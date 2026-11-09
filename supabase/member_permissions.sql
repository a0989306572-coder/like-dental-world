begin;

create schema if not exists forum_private;
revoke all on schema forum_private from public;
grant usage on schema forum_private to authenticated;

create table public.forum_memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  advanced boolean not null default false,
  staff_role text check (staff_role in ('moderator', 'admin'))
);
alter table public.forum_memberships enable row level security;
revoke all on public.forum_memberships from public, anon, authenticated;
grant select on public.forum_memberships to authenticated;
create policy forum_own_membership on public.forum_memberships
for select to authenticated using (user_id = (select auth.uid()));

create function forum_private.access_level()
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((
    select case
      when m.staff_role = 'admin' then 4
      when m.staff_role = 'moderator' then 3
      when m.advanced then 2
      else 1
    end
    from auth.users u left join public.forum_memberships m on m.user_id = u.id
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null
      and not coalesce(u.is_anonymous, false)
      and (u.banned_until is null or u.banned_until <= now())
  ), 0)
$$;
revoke all on function forum_private.access_level() from public, anon, authenticated;
grant execute on function forum_private.access_level() to authenticated;

create function public.forum_access_level()
returns integer language sql stable security invoker set search_path = '' as $$
  select forum_private.access_level()
$$;
revoke all on function public.forum_access_level() from public, anon, authenticated;
grant execute on function public.forum_access_level() to authenticated;

alter table public.posts
  add column board text not null default '未分類' check (board in (
    '未分類', '八卦閒聊', '健保申報／職涯', '課程／進修', '開業', '交友',
    '徵人／徵工作', '生活／吃喝玩樂', '理財', '學生事務交流', '團購', '二手／買賣'
  )),
  add column hidden_at timestamptz;

alter policy "公開閱讀文章" on public.posts using (hidden_at is null);
alter policy "會員發表文章" on public.posts with check (
  user_id = (select auth.uid()) and hidden_at is null
  and (select forum_private.access_level()) >=
    case when board in ('徵人／徵工作', '團購', '二手／買賣') then 2 else 1 end
);
alter policy "會員修改自己的文章" on public.posts
  using (user_id = (select auth.uid()) and hidden_at is null and (select forum_private.access_level()) >= 1)
  with check (
    user_id = (select auth.uid()) and hidden_at is null
    and (select forum_private.access_level()) >=
      case when board in ('徵人／徵工作', '團購', '二手／買賣') then 2 else 1 end
  );
alter policy "會員刪除自己的文章" on public.posts
  using (user_id = (select auth.uid()) and hidden_at is null and (select forum_private.access_level()) >= 1);
revoke insert, update, truncate on public.posts from public, anon, authenticated;
grant insert (user_id, title, body, board), update (title, body, board) on public.posts to authenticated;

alter policy "公開閱讀留言" on public.comments
  using (exists (select 1 from public.posts p where p.id = post_id and p.hidden_at is null));
alter policy "會員發表留言" on public.comments with check (
  user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1
  and exists (select 1 from public.posts p where p.id = post_id and p.hidden_at is null)
);
alter policy "會員修改自己的留言" on public.comments
  using (user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1)
  with check (user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1);
alter policy "會員刪除自己的留言" on public.comments
  using (user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1);
revoke insert, update, truncate on public.comments from public, anon, authenticated;
grant insert (post_id, user_id, body), update (body) on public.comments to authenticated;
create index if not exists forum_comments_post_time_idx on public.comments (post_id, created_at);
create index if not exists forum_posts_feed_idx on public.posts (created_at desc, id desc) where hidden_at is null;

create table public.forum_post_actions (
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  kind text not null check (kind in ('like', 'follow')),
  primary key (user_id, post_id, kind)
);
create index forum_post_actions_post_idx on public.forum_post_actions (post_id);
alter table public.forum_post_actions enable row level security;
revoke all on public.forum_post_actions from public, anon, authenticated;
grant select, delete on public.forum_post_actions to authenticated;
grant insert (post_id, kind) on public.forum_post_actions to authenticated;
create policy forum_own_actions on public.forum_post_actions
for select to authenticated using (user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1);
create policy forum_add_action on public.forum_post_actions
for insert to authenticated with check (
  user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1
  and exists (select 1 from public.posts p where p.id = post_id and p.hidden_at is null)
);
create policy forum_remove_action on public.forum_post_actions
for delete to authenticated using (user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1);

create table public.forum_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  comment_id uuid not null references public.comments(id) on delete cascade,
  created_at timestamptz not null default now(),
  is_read boolean not null default false
);
create index forum_notifications_user_idx on public.forum_notifications (user_id, created_at desc);
create index forum_notifications_post_idx on public.forum_notifications (post_id);
create index forum_notifications_comment_idx on public.forum_notifications (comment_id);
alter table public.forum_notifications enable row level security;
revoke all on public.forum_notifications from public, anon, authenticated;
grant select, update (is_read) on public.forum_notifications to authenticated;
create policy forum_own_notifications on public.forum_notifications
for select to authenticated using (
  user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1
  and exists (select 1 from public.posts p where p.id = post_id and p.hidden_at is null)
);
create policy forum_read_notifications on public.forum_notifications
for update to authenticated
using (user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1)
with check (user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1);

create function forum_private.notify_forum_comment()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.forum_notifications (user_id, post_id, comment_id)
  select recipient.user_id, new.post_id, new.id
  from (
    select p.user_id from public.posts p where p.id = new.post_id and p.hidden_at is null
    union
    select a.user_id from public.forum_post_actions a
    where a.post_id = new.post_id and a.kind = 'follow'
  ) recipient where recipient.user_id <> new.user_id;
  return new;
end;
$$;
revoke all on function forum_private.notify_forum_comment() from public, anon, authenticated;
create trigger forum_notify_on_comment after insert on public.comments
for each row execute function forum_private.notify_forum_comment();

create table public.forum_reports (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  reason text not null check (char_length(btrim(reason)) between 1 and 500),
  created_at timestamptz not null default now(),
  resolved boolean not null default false,
  unique (post_id, user_id)
);
create index forum_reports_user_idx on public.forum_reports (user_id);
alter table public.forum_reports enable row level security;
revoke all on public.forum_reports from public, anon, authenticated;
grant select, insert (post_id, reason) on public.forum_reports to authenticated;
create policy forum_staff_read_reports on public.forum_reports
for select to authenticated using ((select forum_private.access_level()) >= 3);
create policy forum_members_report on public.forum_reports
for insert to authenticated with check (
  user_id = (select auth.uid()) and (select forum_private.access_level()) >= 1
  and exists (select 1 from public.posts p where p.id = post_id and p.hidden_at is null)
);

create function forum_private.resolve_report(report_id uuid, hide_post boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target_post uuid;
begin
  if (select forum_private.access_level()) < 3 then
    raise exception 'Moderator access required' using errcode = '42501';
  end if;
  select p.id into target_post from public.posts p
  join public.forum_reports r on r.post_id = p.id where r.id = report_id
  for update of p;
  if not found then return; end if;
  update public.forum_reports set resolved = true where id = report_id and not resolved;
  if not found then return; end if;
  if hide_post then
    update public.posts set hidden_at = now() where id = target_post and hidden_at is null;
    update public.forum_reports set resolved = true where post_id = target_post and not resolved;
  end if;
end;
$$;
revoke all on function forum_private.resolve_report(uuid, boolean) from public, anon, authenticated;
grant execute on function forum_private.resolve_report(uuid, boolean) to authenticated;
create function public.forum_resolve_report(report_id uuid, hide_post boolean)
returns void language sql security invoker set search_path = '' as $$
  select forum_private.resolve_report(report_id, hide_post)
$$;
revoke all on function public.forum_resolve_report(uuid, boolean) from public, anon, authenticated;
grant execute on function public.forum_resolve_report(uuid, boolean) to authenticated;

create function forum_private.set_member_access(member_email text, new_access text)
returns void language plpgsql security definer set search_path = '' as $$
declare target_user uuid;
begin
  if (select forum_private.access_level()) <> 4 then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if new_access is null or new_access not in ('member', 'advanced', 'moderator') then
    raise exception 'Invalid access level' using errcode = '22023';
  end if;
  select id into target_user from auth.users
  where lower(email) = lower(btrim(member_email)) and email_confirmed_at is not null
    and not coalesce(is_anonymous, false);
  if not found then
    raise exception 'Verified member not found' using errcode = 'P0002';
  end if;
  insert into public.forum_memberships as m (user_id, advanced, staff_role)
  values (target_user, new_access = 'advanced', case when new_access = 'moderator' then 'moderator' end)
  on conflict (user_id) do update set advanced = excluded.advanced, staff_role = excluded.staff_role
  where m.staff_role is distinct from 'admin';
  if not found then
    raise exception 'Cannot modify administrator' using errcode = '42501';
  end if;
end;
$$;
revoke all on function forum_private.set_member_access(text, text) from public, anon, authenticated;
grant execute on function forum_private.set_member_access(text, text) to authenticated;
create function public.forum_set_member_access(member_email text, new_access text)
returns void language sql security invoker set search_path = '' as $$
  select forum_private.set_member_access(member_email, new_access)
$$;
revoke all on function public.forum_set_member_access(text, text) from public, anon, authenticated;
grant execute on function public.forum_set_member_access(text, text) to authenticated;

revoke execute on function public.handle_new_user(), public.rls_auto_enable()
from public, anon, authenticated;

commit;
