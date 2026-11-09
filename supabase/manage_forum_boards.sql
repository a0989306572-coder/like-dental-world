begin;

alter table public.forum_boards
  add column archived boolean not null default false,
  add column sort_order integer not null default 100,
  alter column board_key set default gen_random_uuid()::text;

alter table public.forum_boards drop constraint forum_boards_label_check;
alter table public.forum_boards add constraint forum_boards_label_check check (
  (board_key = '未分類' and label = '未分類' and archived)
  or (board_key <> '未分類' and label = btrim(label)
      and char_length(label) between 1 and 40 and label not in ('全部', '推薦文章', '未分類'))
);

insert into public.forum_boards (board_key, label, archived) values ('未分類', '未分類', true);

update public.forum_boards b
set sort_order = existing.position
from unnest(array[
  '八卦閒聊', '健保申報／職涯', '課程／進修', '開業', '交友',
  '徵人／徵工作', '生活／吃喝玩樂', '理財', '學生事務交流', '團購', '二手／買賣'
]) with ordinality as existing(board_key, position)
where b.board_key = existing.board_key;

drop index public.forum_boards_unique_label;
create unique index forum_boards_unique_label on public.forum_boards (lower(label)) where not archived;

grant insert (label), update (archived) on public.forum_boards to authenticated;
create policy forum_admin_create_board on public.forum_boards
for insert to authenticated
with check ((select forum_private.access_level()) = 4 and not archived and board_key <> '未分類');
alter policy forum_admin_edit_board_labels on public.forum_boards
using ((select forum_private.access_level()) = 4 and not archived and board_key <> '未分類')
with check ((select forum_private.access_level()) = 4 and board_key <> '未分類');

alter table public.posts
  drop constraint posts_board_check,
  add constraint posts_board_fkey foreign key (board) references public.forum_boards(board_key);
create index if not exists forum_posts_board_idx on public.posts (board);

create function forum_private.require_active_post_board()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if new.board is not distinct from old.board then return new; end if;
  end if;
  -- Serialize posts assigned to this board against archiving that board.
  perform 1 from public.forum_boards where board_key = new.board and not archived for share;
  if not found then
    raise exception 'The board is unavailable for new posts' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function forum_private.require_active_post_board() from public, anon, authenticated;
create trigger forum_require_active_post_board
before insert or update of board on public.posts
for each row execute function forum_private.require_active_post_board();

commit;
