
begin;
create table forum_private.direct_messages (
 seq bigint generated always as identity primary key,
 id uuid not null unique,
 pair_id uuid not null references forum_private.card_pairs(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade,
 body text not null check(char_length(btrim(body)) between 1 and 2000),
 created_at timestamptz not null default statement_timestamp()
);
create index direct_messages_pair_seq on forum_private.direct_messages(pair_id,seq desc);
create index direct_messages_sender on forum_private.direct_messages(sender_id);
create table forum_private.direct_message_reads (
 pair_id uuid not null references forum_private.card_pairs(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 through_seq bigint not null default 0,
 primary key(pair_id,user_id)
);
create index direct_message_reads_user on forum_private.direct_message_reads(user_id);
alter table forum_private.direct_messages enable row level security;
alter table forum_private.direct_message_reads enable row level security;
revoke all on forum_private.direct_messages,forum_private.direct_message_reads from public,anon,authenticated;
revoke all on sequence forum_private.direct_messages_seq_seq from public,anon,authenticated;

create function forum_private.direct_chat(
 action_name text, pair_id uuid default null, body text default null,
 request_id uuid default null,before_seq bigint default null,through_seq bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 me uuid := auth.uid();
 pair forum_private.card_pairs%rowtype;
 target uuid;
 can_send boolean;
 message forum_private.direct_messages%rowtype;
 latest bigint;
 result jsonb;
begin
 if me is null or forum_private.access_level()<1 then
  raise exception '請先登入並驗證 Email' using errcode='42501';
 end if;
 if action_name is null or action_name not in ('inbox','history','send','read') then
  raise exception '無效操作' using errcode='22023';
 end if;
 if action_name='inbox' then
  select jsonb_build_object('conversations',coalesce(jsonb_agg(row_data order by sort_at desc),'[]'::jsonb)) into result
  from (
   select jsonb_build_object('pair_id',p.id,'name',pr.display_name,'avatar_url',pr.avatar_url,
    'active',p.ended_at is null and not exists(select 1 from forum_private.card_blocks b
     where (b.user_id=me and b.blocked_id=pr.id) or (b.user_id=pr.id and b.blocked_id=me)),
    'last_body',left(m.body,100),'last_at',m.created_at,'matched_at',p.matched_at,
    'unread',(select count(*) from forum_private.direct_messages x
      where x.pair_id=p.id and x.sender_id<>me and x.seq>coalesce(r.through_seq,0))) as row_data,
    coalesce(m.created_at,p.matched_at) as sort_at
   from forum_private.card_pairs p
   join public.profiles pr on pr.id=case when p.user_a=me then p.user_b else p.user_a end
   left join lateral(select x.body,x.created_at from forum_private.direct_messages x where x.pair_id=p.id order by seq desc limit 1)m on true
   left join forum_private.direct_message_reads r on r.pair_id=p.id and r.user_id=me
   where me in(p.user_a,p.user_b) and p.matched_at is not null
  ) rows;
  return result;
 end if;
 if action_name='send' then
  -- Use the same lock as card blocking and relationship changes.
  perform pg_advisory_xact_lock(42872,914);
 end if;
 select * into pair from forum_private.card_pairs p
  where p.id=pair_id and me in(p.user_a,p.user_b) and p.matched_at is not null;
 if not found then raise exception '無法存取這段對話' using errcode='42501'; end if;
 target:=case when pair.user_a=me then pair.user_b else pair.user_a end;
 can_send:=pair.ended_at is null
  and not exists(select 1 from forum_private.card_blocks b where (b.user_id=me and b.blocked_id=target) or (b.user_id=target and b.blocked_id=me))
  and exists(select 1 from auth.users u where u.id=target and u.email_confirmed_at is not null
    and (u.banned_until is null or u.banned_until<=statement_timestamp()));

 if action_name='history' then
  select jsonb_build_object('pair_id',pair.id,'name',pr.display_name,'avatar_url',pr.avatar_url,'active',can_send,
   'messages',coalesce((
    select jsonb_agg(jsonb_build_object('seq',x.seq::text,'id',x.id,'mine',x.sender_id=me,'body',x.body,'created_at',x.created_at) order by x.seq)
    from(select * from forum_private.direct_messages m where m.pair_id=pair.id and (before_seq is null or m.seq<before_seq)
      order by m.seq desc limit 50)x
   ),'[]'::jsonb)
  ) into result from public.profiles pr where pr.id=target;
  return result;
 elsif action_name='read' then
  if through_seq is null or through_seq<0 then raise exception '無效的已讀位置' using errcode='22023';end if;
  select coalesce(max(seq),0) into latest from forum_private.direct_messages m where m.pair_id=pair.id and m.seq<=through_seq;
  insert into forum_private.direct_message_reads as r(pair_id,user_id,through_seq) values(pair.id,me,latest)
   on conflict on constraint direct_message_reads_pkey do update set through_seq=greatest(r.through_seq,excluded.through_seq);
  return jsonb_build_object('read',true);
 elsif action_name='send' then
  if request_id is null or body is null or char_length(btrim(body)) not between 1 and 2000 then
   raise exception '訊息需為 1 到 2000 個字' using errcode='22023';end if;
  select * into message from forum_private.direct_messages m where m.id=request_id;
  if found then
   if message.pair_id<>pair.id or message.sender_id<>me or message.body<>btrim(body) then
    raise exception '訊息識別碼已使用' using errcode='22023';end if;
  else
   if not can_send then raise exception '這段卡友關係已結束或遭封鎖，無法傳送新訊息' using errcode='42501';end if;
   insert into forum_private.direct_messages(id,pair_id,sender_id,body)
    values(request_id,pair.id,me,btrim(body)) returning * into message;
  end if;
  return jsonb_build_object('id',message.id,'seq',message.seq::text,'created_at',message.created_at);
 end if;
end $$;
revoke all on function forum_private.direct_chat(text,uuid,text,uuid,bigint,bigint) from public,anon,authenticated;
grant execute on function forum_private.direct_chat(text,uuid,text,uuid,bigint,bigint) to authenticated;
create function public.forum_direct_chat(
 action_name text default 'inbox',pair_id uuid default null,body text default null,
 request_id uuid default null,before_seq bigint default null,through_seq bigint default null)
returns jsonb language sql security invoker set search_path='' as $$
 select forum_private.direct_chat(action_name,pair_id,body,request_id,before_seq,through_seq)
$$;
revoke all on function public.forum_direct_chat(text,uuid,text,uuid,bigint,bigint) from public,anon,authenticated;
grant execute on function public.forum_direct_chat(text,uuid,text,uuid,bigint,bigint) to authenticated;
commit;