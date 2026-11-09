begin;

create table public.forum_boards (
  board_key text primary key,
  label text not null check (
    label = btrim(label) and char_length(label) between 1 and 40
    and label not in ('全部', '推薦文章', '未分類')
  )
);
create unique index forum_boards_unique_label on public.forum_boards (lower(label));

insert into public.forum_boards (board_key, label)
select name, name from unnest(array[
  '八卦閒聊', '健保申報／職涯', '課程／進修', '開業', '交友',
  '徵人／徵工作', '生活／吃喝玩樂', '理財', '學生事務交流', '團購', '二手／買賣'
]) as boards(name);

alter table public.forum_boards enable row level security;
revoke all on public.forum_boards from public, anon, authenticated;
grant select on public.forum_boards to anon, authenticated;
grant update (label) on public.forum_boards to authenticated;

create policy forum_read_board_labels on public.forum_boards
for select to anon, authenticated using (true);
create policy forum_admin_edit_board_labels on public.forum_boards
for update to authenticated
using ((select forum_private.access_level()) = 4)
with check ((select forum_private.access_level()) = 4);

grant delete on public.posts to authenticated;
create policy forum_admin_read_hidden_posts on public.posts
for select to authenticated
using (hidden_at is not null and (select forum_private.access_level()) = 4);
create policy forum_admin_delete_posts on public.posts
for delete to authenticated
using ((select forum_private.access_level()) = 4);

commit;
