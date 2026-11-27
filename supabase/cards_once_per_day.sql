CREATE OR REPLACE FUNCTION forum_private.cards(action_name text, pair_id uuid DEFAULT NULL::uuid, enabled boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 me uuid;
 slot_start timestamptz;
 target uuid;
 other_user uuid;
 pair forum_private.card_pairs%rowtype;
 is_enabled boolean;
 now_time timestamptz := statement_timestamp();
 result jsonb;
begin
 me := forum_private.card_member();
 if action_name not in ('load','join','respond_yes','respond_skip','block','unblock','end_friend') or action_name is null then
  raise exception '無效的操作' using errcode='22023';
 end if;
 -- One short shared lock serializes matching, responses, opt-out and blocking.
 perform pg_advisory_xact_lock(42872,914);
 slot_start := date_trunc('day', now_time at time zone 'Asia/Taipei') at time zone 'Asia/Taipei';

 if action_name='join' then
  if enabled is null then raise exception '請選擇是否參加' using errcode='22023'; end if;
  insert into forum_private.card_settings(user_id,enabled) values(me,enabled)
  on conflict(user_id) do update set enabled=excluded.enabled;
 end if;
 select coalesce(s.enabled,false) into is_enabled from forum_private.card_settings s where s.user_id=me;
 is_enabled := coalesce(is_enabled,false);

 if action_name in ('respond_yes','respond_skip','block','end_friend') then
  select * into pair from forum_private.card_pairs p
   where p.id=pair_id and me in(p.user_a,p.user_b) for update;
  if not found then raise exception '找不到可操作的卡片' using errcode='42501'; end if;
  other_user := case when me=pair.user_a then pair.user_b else pair.user_a end;
  if action_name='block' then
   insert into forum_private.card_blocks(user_id,blocked_id) values(me,other_user) on conflict do nothing;
   update forum_private.card_pairs set ended_at=coalesce(ended_at,now_time)
    where (user_a=me and user_b=other_user) or (user_b=me and user_a=other_user);
  elsif action_name='end_friend' then
   if pair.matched_at is null then raise exception '尚未成為卡友' using errcode='22023'; end if;
   update forum_private.card_pairs set ended_at=coalesce(ended_at,now_time) where id=pair.id;
  else
   if not is_enabled or pair.expires_at<=now_time or pair.ended_at is not null
    or not exists(select 1 from forum_private.card_settings s where s.user_id=other_user and s.enabled)
    or exists(select 1 from forum_private.card_blocks b where (b.user_id=me and b.blocked_id=other_user) or (b.user_id=other_user and b.blocked_id=me))
    then raise exception '這張卡片已失效或暫停' using errcode='22023'; end if;
   if pair.choice_a='skip' or pair.choice_b='skip' then
    raise exception '這張卡片已略過' using errcode='22023';
   end if;
   if (me=pair.user_a and pair.choice_a is not null and pair.choice_a<>case when action_name='respond_yes' then 'yes' else 'skip' end)
     or (me=pair.user_b and pair.choice_b is not null and pair.choice_b<>case when action_name='respond_yes' then 'yes' else 'skip' end) then
    raise exception '此邀請已回覆' using errcode='22023';
   end if;
   update forum_private.card_pairs set
    choice_a=case when me=user_a then case when action_name='respond_yes' then 'yes' else 'skip' end else choice_a end,
    choice_b=case when me=user_b then case when action_name='respond_yes' then 'yes' else 'skip' end else choice_b end
   where id=pair.id;
   update forum_private.card_pairs set matched_at=coalesce(matched_at,now_time)
    where id=pair.id and choice_a='yes' and choice_b='yes';
  end if;
 elsif action_name='unblock' then
  -- pair_id contains an existing relationship ID, never an arbitrary member lookup.
  select case when user_a=me then user_b else user_a end into other_user
  from forum_private.card_pairs where id=pair_id and me in(user_a,user_b);
  if not found then raise exception '找不到封鎖紀錄' using errcode='42501'; end if;
  delete from forum_private.card_blocks where user_id=me and blocked_id=other_user;
 end if;

 if action_name in ('load','join') and is_enabled
  and not exists(select 1 from forum_private.card_pairs p where (p.slot_at >= slot_start and p.slot_at < slot_start+interval '1 day') and me in(p.user_a,p.user_b)) then
  select s.user_id into target from forum_private.card_settings s
   join public.profiles p on p.id=s.user_id
   join auth.users u on u.id=s.user_id
   where s.enabled and s.user_id<>me
    and p.profile_completed_at is not null and nullif(btrim(p.avatar_url),'') is not null and nullif(btrim(p.bio),'') is not null
    and u.email_confirmed_at is not null and not coalesce(u.is_anonymous,false)
    and (u.banned_until is null or u.banned_until <= now_time)
    and not exists(select 1 from forum_private.card_pairs x where (x.slot_at >= slot_start and x.slot_at < slot_start+interval '1 day') and s.user_id in(x.user_a,x.user_b))
    and not exists(select 1 from forum_private.card_blocks b where (b.user_id=me and b.blocked_id=s.user_id) or (b.user_id=s.user_id and b.blocked_id=me))
    and not exists(select 1 from forum_private.card_pairs x
      where ((x.user_a=me and x.user_b=s.user_id) or (x.user_b=me and x.user_a=s.user_id))
       and ((x.matched_at is not null and x.ended_at is null)
         or (x.ended_at is null and x.expires_at>now_time and x.choice_a is distinct from 'skip' and x.choice_b is distinct from 'skip')
         or x.slot_at>=slot_start-interval '7 days'))
   order by random() limit 1;
  if target is not null then
   insert into forum_private.card_pairs(user_a,user_b,slot_at,expires_at)
    values(least(me,target),greatest(me,target),slot_start,slot_start+interval '7 days');
  end if;
 end if;

 select jsonb_build_object(
  'enabled',is_enabled,'server_time',now_time,'slot_at',slot_start,'next_at',slot_start+interval '1 day',
  'cards',coalesce((
   select jsonb_agg(jsonb_build_object(
    'id',p.id,'slot_at',p.slot_at,'expires_at',p.expires_at,'matched_at',p.matched_at,
    'current',(p.slot_at >= slot_start and p.slot_at < slot_start+interval '1 day'),'choice',case when p.user_a=me then p.choice_a else p.choice_b end,
    'available',p.ended_at is null and p.choice_a is distinct from 'skip' and p.choice_b is distinct from 'skip',
    'person',case when (p.matched_at is not null or (is_enabled and s.enabled)) and p.ended_at is null
      then jsonb_build_object('display_name',pr.display_name,'avatar_url',pr.avatar_url,'occupation',pr.occupation,'city',pr.city,'bio',pr.bio) else null end)
    order by p.slot_at desc)
   from forum_private.card_pairs p
   join public.profiles pr on pr.id=case when p.user_a=me then p.user_b else p.user_a end
   left join forum_private.card_settings s on s.user_id=pr.id
   join auth.users u on u.id=pr.id
   where me in(p.user_a,p.user_b) and p.ended_at is null
     and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until<=now_time)
     and not exists(select 1 from forum_private.card_blocks b where (b.user_id=me and b.blocked_id=pr.id) or (b.user_id=pr.id and b.blocked_id=me))
     and ((p.slot_at >= slot_start and p.slot_at < slot_start+interval '1 day') or p.matched_at is not null
       or (p.expires_at>now_time and p.choice_a is distinct from 'skip' and p.choice_b is distinct from 'skip'))
  ),'[]'::jsonb),
  'blocks',coalesce((
   select jsonb_agg(jsonb_build_object('id',p.id,'display_name',pr.display_name))
   from forum_private.card_blocks b join public.profiles pr on pr.id=b.blocked_id
   join lateral (select id from forum_private.card_pairs p where (p.user_a=me and p.user_b=b.blocked_id) or (p.user_b=me and p.user_a=b.blocked_id) order by p.slot_at desc limit 1)p on true
   where b.user_id=me
  ),'[]'::jsonb)
 ) into result;
 return result;
end $function$
