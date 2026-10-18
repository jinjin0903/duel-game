-- DUEL online: Supabase SQL Editor 에서 한 번에 실행하세요.
-- 전제: Authentication > Providers 에서 "Anonymous sign-ins" 활성화.

drop table if exists public.moves, public.room_state, public.rooms cascade;

create table public.rooms(
  code text primary key,
  p1 uuid not null, p2 uuid,
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  seq int not null default 0,          -- 판정 완료된 턴 수(전체 누적)
  turn int not null default 1,         -- 현재 대결 내 턴
  rc int not null default 0,           -- 재대결 횟수
  limit_ms int not null default 3000,
  turn_start timestamptz, deadline timestamptz,
  hp1 int not null default 1, hp2 int not null default 1,
  winner int, coin boolean not null default false,
  last jsonb,                          -- 공개 가능한 마지막 판정 결과(재대결이면 숨김 처리됨)
  created_at timestamptz not null default now());

-- 비공개 테이블: 클라이언트 정책 없음 = 직접 접근 불가
create table public.room_state(
  code text primary key references public.rooms on delete cascade,
  ammo int[] not null default '{0,0}', pb boolean[] not null default '{false,false}');
create table public.moves(
  code text references public.rooms on delete cascade, seq int, seat int,
  act text not null check (act in ('shoot','block','reload','pass')),
  primary key (code, seq, seat));

alter table public.rooms enable row level security;
alter table public.room_state enable row level security;
alter table public.moves enable row level security;
revoke all on public.rooms, public.room_state, public.moves from anon, authenticated;
grant select on public.rooms to authenticated;
create policy rooms_member_select on public.rooms for select to authenticated
  using (auth.uid() in (p1, p2));

alter publication supabase_realtime add table public.rooms;

create or replace function public.limit_ms_for(rc int, t int) returns int language sql immutable as $$
  select case when v <= 0 then 100 else (v*1000)::int end
  from (select round((3 - 0.2*(rc+1)*(t-1))::numeric, 1) v) s $$;

create or replace function public.create_room() returns text
language plpgsql security definer set search_path=public as $$
declare c text;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  loop
    c := upper(substr(md5(gen_random_uuid()::text),1,5));
    begin
      insert into rooms(code,p1) values (c, auth.uid());
      insert into room_state(code) values (c);
      return c;
    exception when unique_violation then null;
    end;
  end loop;
end $$;

create or replace function public.join_room(c text) returns void
language plpgsql security definer set search_path=public as $$
declare r rooms;
begin
  select * into r from rooms where code = upper(c) for update;
  if not found then raise exception 'room not found'; end if;
  if auth.uid() in (r.p1, r.p2) then return; end if;      -- 재접속
  if r.p2 is not null then raise exception 'room full'; end if;
  update rooms set p2=auth.uid(), status='playing', seq=0, turn=1, rc=0, limit_ms=3000,
    turn_start = now() + interval '7.2 seconds',            -- 인트로 시간
    deadline   = now() + interval '7.2 seconds' + interval '3 seconds'
  where code = r.code;
end $$;

-- 본인 비공개 정보(탄약/막기 이력)만 반환. 상대 탄약은 일반 대결에서만(어차피 모든 행동이 공개됨).
create or replace function public.get_state(c text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r rooms; s room_state; me int;
begin
  select * into r from rooms where code = upper(c);
  if not found then raise exception 'room not found'; end if;
  me := case when auth.uid()=r.p1 then 0 when auth.uid()=r.p2 then 1 else -1 end;
  if me < 0 then raise exception 'not a member'; end if;
  select * into s from room_state where code = r.code;
  return jsonb_build_object('room', to_jsonb(r), 'seat', me, 'now', now(),
    'ammo', s.ammo[me+1], 'pb', s.pb[me+1],
    'opp_ammo', case when r.rc = 0 then s.ammo[2-me] end);
end $$;

create or replace function public.resolve_room(c text) returns void
language plpgsql security definer set search_path=public as $$
declare r rooms; s room_state; a text[] := array['pass','pass']; m record;
  hit boolean[]; bl boolean[]; sh text[] := array['','']; rm boolean; dbl boolean;
  i int; w int; nx timestamptz; lst jsonb; lim int;
begin
  select * into r from rooms where code = c for update;
  select * into s from room_state where code = c for update;
  for m in select seat, act from moves where code=c and seq=r.seq+1 loop a[m.seat+1] := m.act; end loop;
  for i in 1..2 loop   -- 서버 재검증: 불가능한 행동은 턴 넘김
    if (a[i]='shoot' and s.ammo[i]<=0) or (a[i]='block' and s.pb[i]) or (a[i]='reload' and s.ammo[i]>=2) then a[i]:='pass'; end if;
  end loop;
  rm  := r.rc > 0;
  hit := array[a[2]='shoot' and a[1]<>'block', a[1]='shoot' and a[2]<>'block'];
  bl  := array[a[1]='shoot' and a[2]='block',  a[2]='shoot' and a[1]='block'];
  for i in 1..2 loop
    sh[i] := case when not rm then a[i] when a[i]='shoot' then 'shoot' else 'hide' end;
    if a[i]='shoot' then s.ammo[i] := s.ammo[i]-1; elsif a[i]='reload' then s.ammo[i] := s.ammo[i]+1; end if;
    s.pb[i] := (a[i]='block');
  end loop;
  dbl := hit[1] and hit[2];
  lst := jsonb_build_object('seq', r.seq+1, 'turn', r.turn, 'rc', r.rc, 'hidden', rm,
           'shown', to_jsonb(sh), 'hit', to_jsonb(hit), 'blocked', to_jsonb(bl));

  if dbl or (not hit[1] and not hit[2] and r.turn >= 15) then          -- 무승부
    if r.rc >= 4 then                                                  -- 최종 동전 던지기
      w := floor(random()*2)::int;
      update rooms set status='finished', winner=w, coin=true, seq=r.seq+1, last=lst,
        hp1=case when w=0 then 1 else 0 end, hp2=case when w=1 then 1 else 0 end, deadline=null where code=c;
    else
      lim := limit_ms_for(r.rc+1, 1);
      nx  := now() + interval '1.6 seconds' + case when dbl then interval '0.7 seconds' else interval '0 seconds' end + interval '2.7 seconds';
      s.ammo := '{0,0}'; s.pb := '{false,false}';
      update rooms set seq=r.seq+1, rc=r.rc+1, turn=1, hp1=1, hp2=1, limit_ms=lim, last=lst,
        turn_start=nx, deadline=nx + make_interval(secs => lim/1000.0) where code=c;
    end if;
  elsif hit[1] or hit[2] then                                          -- 승패 확정
    update rooms set status='finished', winner=case when hit[1] then 1 else 0 end, seq=r.seq+1, last=lst,
      hp1=case when hit[1] then 0 else 1 end, hp2=case when hit[2] then 0 else 1 end, deadline=null where code=c;
  else                                                                 -- 다음 턴
    lim := limit_ms_for(r.rc, r.turn+1);
    nx  := now() + interval '1.6 seconds';
    update rooms set seq=r.seq+1, turn=r.turn+1, limit_ms=lim, last=lst,
      turn_start=nx, deadline=nx + make_interval(secs => lim/1000.0) where code=c;
  end if;
  update room_state set ammo=s.ammo, pb=s.pb where code=c;
end $$;

create or replace function public.submit_move(c text, a text) returns void
language plpgsql security definer set search_path=public as $$
declare r rooms; s room_state; me int;
begin
  select * into r from rooms where code = upper(c) for update;
  if not found then raise exception 'room not found'; end if;
  me := case when auth.uid()=r.p1 then 0 when auth.uid()=r.p2 then 1 else -1 end;
  if me < 0 then raise exception 'not a member'; end if;
  if r.status <> 'playing' then raise exception 'not playing'; end if;
  if now() < r.turn_start - interval '0.3 seconds' or now() > r.deadline + interval '0.7 seconds' then
    raise exception 'out of time'; end if;
  select * into s from room_state where code = r.code for update;
  if a not in ('shoot','block','reload','pass')
     or (a='shoot' and s.ammo[me+1] <= 0) or (a='block' and s.pb[me+1]) or (a='reload' and s.ammo[me+1] >= 2) then
    raise exception 'invalid move'; end if;
  insert into moves(code, seq, seat, act) values (r.code, r.seq+1, me, a);   -- 중복 제출은 PK 위반
  if (select count(*) from moves where code=r.code and seq=r.seq+1) = 2 then perform resolve_room(r.code); end if;
end $$;

-- 시간 초과: 어느 쪽 클라이언트든 호출 가능. 미제출자는 턴 넘김 처리.
create or replace function public.tick(c text) returns void
language plpgsql security definer set search_path=public as $$
declare r rooms;
begin
  select * into r from rooms where code = upper(c) for update;
  if not found or auth.uid() not in (r.p1, r.p2) then raise exception 'not a member'; end if;
  if r.status='playing' and now() >= r.deadline then perform resolve_room(r.code); end if;
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.create_room(), public.join_room(text), public.get_state(text),
  public.submit_move(text, text), public.tick(text) to authenticated;
