-- 플랜두씨 다이어리 2 — 로그인이 있는 DB (Supabase / PostgreSQL)
-- Supabase 의 SQL Editor 에 통째로 붙여 넣고 Run 하세요. (여러 번 실행해도 안전합니다)
-- 7번 자료는 'diary2' 라는 별도 칸(스키마)에만 만듭니다. 같은 프로젝트에 있는 6번(public 칸)의 표·함수·사이트는 건드리지 않습니다.
--
-- 보안 설계
--  1) 로그인(가입·비밀번호 보관·토큰 발급)은 Supabase Auth 가 맡습니다. 비밀번호는 bcrypt 로 바꿔 auth.users 에 저장됩니다.
--  2) 모든 표에는 주인(user_id)이 있고, 표를 직접 읽고 쓰는 권한은 아무에게도 주지 않습니다(anon·authenticated 모두 거절).
--  3) 자료는 아래 함수로만 다룹니다. 함수는 "지금 요청한 사람(auth.uid())"을 확인해 그 사람의 자료만 다룹니다.
--     남의 자료를 가리키면 "없음(404)"으로만 답해서 존재 여부도 알려 주지 않습니다. 로그인하지 않았으면 401 입니다.
--  4) 로그아웃하면 서버가 그 로그인 값(세션)을 지우고, 요청마다 check_session() 이 확인해서 이전 값은 401 로 거절합니다.
--  5) (같은 프로젝트의 6번과 분리) 7번은 diary2 칸에만 둔다.
--  6) 날짜는 date, 시각은 timestamptz(UTC 저장, 서울 시간 표시). 시간 단위는 분. "오늘"은 DB가 서울 기준으로 계산합니다.

create schema if not exists diary2;
set search_path = diary2;   -- 이 파일의 모든 만들기는 diary2 안에서만 일어난다 (public 의 6번 것과 이름이 같아도 겹치지 않음)

-- ===================================================== 표
create table if not exists plans (
  seq bigint generated always as identity,
  id text primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  category text not null check (char_length(category) between 1 and 30),
  start_date date not null,
  end_date date not null,
  priority smallint not null check (priority between 1 and 3),
  success_criteria text not null check (char_length(success_criteria) between 1 and 500),
  estimated_minutes integer not null check (estimated_minutes >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date >= start_date)
);

create table if not exists plan_history (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  plan_id text not null references plans(id) on delete cascade,
  field text not null,
  old_value text,
  new_value text,
  changed_at timestamptz not null default now()
);

create table if not exists todos (
  seq bigint generated always as identity,
  id text primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  plan_id text not null references plans(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  status text not null default 'todo' check (status in ('todo','doing','done')),
  deadline date,
  priority smallint not null check (priority between 1 and 3),
  tags text[] not null default '{}',
  estimated_minutes integer check (estimated_minutes is null or estimated_minutes >= 0),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists exec_logs (
  seq bigint generated always as identity,
  id text primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  todo_id text not null references todos(id) on delete cascade,
  started_at timestamptz,
  ended_at timestamptz,
  actual_minutes integer check (actual_minutes is null or actual_minutes >= 0),
  blocked_reason text not null default '',
  is_completion boolean not null default false,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  unique (user_id, idempotency_key),
  check (ended_at is null or started_at is null or ended_at >= started_at)
);
create unique index if not exists ux_one_completion_per_todo on exec_logs(todo_id) where is_completion;
create index if not exists ix_plans_user on plans(user_id);
create index if not exists ix_todos_plan on todos(plan_id);
create index if not exists ix_todos_user on todos(user_id);
create index if not exists ix_logs_todo on exec_logs(todo_id);
create index if not exists ix_logs_user on exec_logs(user_id);

create table if not exists reviews (
  plan_id text primary key references plans(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  carry_text text not null default '' check (char_length(carry_text) <= 200),
  updated_at timestamptz not null default now()
);

-- 5일 기록 실험: 질문·지표·단위(1일차에 고정) / 날짜별 값 / 규칙 변경 1회
create table if not exists experiment (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  question text not null check (char_length(question) between 1 and 200),
  metric_name text not null check (char_length(metric_name) between 1 and 60),
  unit text not null check (char_length(unit) between 1 and 20),
  rounding_digits smallint not null default 1 check (rounding_digits between 0 and 3),
  week_start smallint not null default 1 check (week_start between 1 and 7),   -- 1=월요일 … 7=일요일
  created_at timestamptz not null default now()
);

create table if not exists daily_records (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  record_date date not null,                                   -- 서울 기준 그날
  value numeric(10,2) not null check (value >= 0),
  note text not null default '' check (char_length(note) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, record_date)                                -- 하루에 한 건
);

create table if not exists rule_changes (
  id bigint generated always as identity primary key,
  user_id uuid not null unique default auth.uid() references auth.users(id) on delete cascade,   -- 한 번만
  changed_at timestamptz not null default now(),
  reason text not null check (char_length(reason) between 1 and 300),
  rule_before text not null check (char_length(rule_before) between 1 and 200),
  rule_after text not null check (char_length(rule_after) between 1 and 200),
  records_before smallint not null                              -- 바꿀 때까지 쌓인 기록 일수 (2여야 함)
);

-- ===================================================== 도우미
create or replace function seoul_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Seoul')::date $$;

create or replace function new_id(prefix text) returns text
language sql volatile as $$ select prefix || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8) $$;

-- 로그인한 사람의 id. 로그인하지 않았으면 401 로 거절합니다.
create or replace function require_user() returns uuid
language plpgsql stable as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception '로그인이 필요합니다.' using errcode = 'PT401'; end if;
  return v;
end $$;

-- 요청마다 PostgREST 가 먼저 부르는 검사: 로그인 값(토큰)에 적힌 세션이 서버에 아직 살아 있는지 확인합니다.
-- 로그아웃하면 세션이 지워지므로 이전 토큰은 만료 시각 전이라도 여기서 401 로 거절됩니다.
create or replace function public.check_session() returns void
language plpgsql stable security definer set search_path = diary2 as $$
declare
  c jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
begin
  if c ->> 'role' = 'authenticated' then
    if c ->> 'session_id' is null
       or not exists (select 1 from auth.sessions s where s.id = (c ->> 'session_id')::uuid) then
      raise exception '로그아웃했거나 만료된 로그인 값입니다. 다시 로그인하세요.' using errcode = 'PT401';
    end if;
  end if;
end $$;
alter role authenticator set pgrst.db_pre_request = 'public.check_session';
notify pgrst, 'reload config';

-- 계획을 고치면 바뀐 항목마다 예전 값·지금 값을 plan_history에 따로 남깁니다.
create or replace function plans_track_history() returns trigger
language plpgsql as $$
begin
  if new.title is distinct from old.title then
    insert into plan_history(user_id, plan_id, field, old_value, new_value) values (old.user_id, old.id, 'title', old.title, new.title); end if;
  if new.category is distinct from old.category then
    insert into plan_history(user_id, plan_id, field, old_value, new_value) values (old.user_id, old.id, 'category', old.category, new.category); end if;
  if new.start_date is distinct from old.start_date then
    insert into plan_history(user_id, plan_id, field, old_value, new_value) values (old.user_id, old.id, 'start_date', old.start_date::text, new.start_date::text); end if;
  if new.end_date is distinct from old.end_date then
    insert into plan_history(user_id, plan_id, field, old_value, new_value) values (old.user_id, old.id, 'end_date', old.end_date::text, new.end_date::text); end if;
  if new.priority is distinct from old.priority then
    insert into plan_history(user_id, plan_id, field, old_value, new_value) values (old.user_id, old.id, 'priority', old.priority::text, new.priority::text); end if;
  if new.success_criteria is distinct from old.success_criteria then
    insert into plan_history(user_id, plan_id, field, old_value, new_value) values (old.user_id, old.id, 'success_criteria', old.success_criteria, new.success_criteria); end if;
  if new.estimated_minutes is distinct from old.estimated_minutes then
    insert into plan_history(user_id, plan_id, field, old_value, new_value) values (old.user_id, old.id, 'estimated_minutes', old.estimated_minutes::text, new.estimated_minutes::text); end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists trg_plans_history on plans;
create trigger trg_plans_history before update on plans for each row execute function plans_track_history();

-- 완료 상태는 complete_todo / reopen_todo 함수로만 바꿀 수 있습니다.
create or replace function todos_guard_status() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'done' and coalesce(current_setting('pds.allow_done', true), '') <> '1' then
      raise exception '완료 상태로 바로 만들 수 없습니다.'; end if;
  elsif new.status is distinct from old.status
        and (new.status = 'done' or old.status = 'done')
        and coalesce(current_setting('pds.allow_done', true), '') <> '1' then
    raise exception '완료·되돌리기는 전용 기능으로만 바꿀 수 있습니다.';
  end if;
  return new;
end $$;
drop trigger if exists trg_todos_guard on todos;
create trigger trg_todos_guard before insert or update on todos for each row execute function todos_guard_status();

-- 할 일 + 계획 제목 + 실행 기록 합계 (함수 안에서만 쓰며, 아무에게도 직접 열어 주지 않습니다)
drop view if exists diary2.todo_view cascade;
create view todo_view as
select t.*,
       p.title as plan_title,
       coalesce(l.actual, 0)::integer as actual_minutes,
       coalesce(l.cnt, 0)::integer as log_count,
       coalesce(l.blocked, false) as blocked,
       (t.status <> 'done' and t.deadline is not null and t.deadline < seoul_today()) as delayed
from todos t
join plans p on p.id = t.plan_id
left join lateral (
  select sum(e.actual_minutes) as actual, count(*) as cnt, bool_or(btrim(e.blocked_reason) <> '') as blocked
  from exec_logs e where e.todo_id = t.id
) l on true;

-- ===================================================== 계획
create or replace function plans_list() returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare v uuid := require_user();
begin
  return coalesce((select jsonb_agg(to_jsonb(p) - 'user_id' order by p.priority, p.start_date, p.seq) from plans p where p.user_id = v), '[]'::jsonb);
end $$;

create or replace function plan_create(p_title text, p_category text, p_start date, p_end date, p_priority integer, p_criteria text, p_estimated integer) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user(); r plans%rowtype;
begin
  insert into plans(id, user_id, title, category, start_date, end_date, priority, success_criteria, estimated_minutes)
  values (new_id('P'), v, btrim(p_title), btrim(p_category), p_start, p_end, p_priority, btrim(p_criteria), p_estimated)
  returning * into r;
  return to_jsonb(r) - 'user_id';
end $$;

create or replace function plan_update(p_id text, p_title text, p_category text, p_start date, p_end date, p_priority integer, p_criteria text, p_estimated integer) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user(); r plans%rowtype;
begin
  update plans set title = btrim(p_title), category = btrim(p_category), start_date = p_start, end_date = p_end,
         priority = p_priority, success_criteria = btrim(p_criteria), estimated_minutes = p_estimated
  where id = p_id and user_id = v returning * into r;
  if not found then raise exception '계획을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  return to_jsonb(r) - 'user_id';
end $$;

create or replace function plan_delete(p_id text) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user();
begin
  delete from plans where id = p_id and user_id = v;
  if not found then raise exception '계획을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function plan_history_list(p_id text) returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare v uuid := require_user();
begin
  perform 1 from plans where id = p_id and user_id = v;
  if not found then raise exception '계획을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  return coalesce((select jsonb_agg(to_jsonb(h) - 'user_id' order by h.id desc) from plan_history h where h.plan_id = p_id and h.user_id = v), '[]'::jsonb);
end $$;

create or replace function plan_carry(p_id text, p_text text) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user(); t text := btrim(coalesce(p_text, ''));
begin
  perform 1 from plans where id = p_id and user_id = v;
  if not found then raise exception '계획을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  insert into reviews(plan_id, user_id, carry_text, updated_at) values (p_id, v, t, now())
  on conflict (plan_id) do update set carry_text = excluded.carry_text, updated_at = now();
  return jsonb_build_object('ok', true, 'carry_text', t);
end $$;

-- ===================================================== 할 일
-- 거르기·검색·정렬은 여기(DB)에서 합니다. 값이 같으면 우선순위(높은 순) → 만든 순서. 값이 비면 항상 뒤.
create or replace function todo_list(
  p_plan_id text default null, p_status text default null, p_priority integer default null,
  p_tag text default null, p_q text default null, p_delayed boolean default false,
  p_sort text default 'deadline', p_dir text default 'asc', p_todo_id text default null
) returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare
  v uuid := require_user();
  v_col text;
  v_dir text := case when p_dir = 'desc' then 'desc' else 'asc' end;
  v_nulls text := '';
  v_result jsonb;
begin
  v_col := case p_sort
    when 'priority' then 'priority' when 'estimate' then 'estimated_minutes'
    when 'created' then 'seq' when 'title' then 'lower(title)' else 'deadline' end;
  if v_col in ('deadline', 'estimated_minutes') then v_nulls := ' nulls last'; end if;
  execute format($f$
    select coalesce(jsonb_agg((to_jsonb(x) - 'ord') - 'user_id' order by x.ord), '[]'::jsonb)
    from (
      select tv.*, row_number() over (order by %s %s%s, priority asc, seq asc) as ord
      from todo_view tv
      where user_id = $8
        and ($1 is null or $1 = '' or plan_id = $1)
        and ($2 is null or $2 = '' or ($2 = 'open' and status <> 'done') or status = $2)
        and ($3 is null or priority = $3)
        and ($4 is null or $4 = '' or tags @> array[lower(btrim($4))])
        and ($5 is null or btrim($5) = '' or position(lower(btrim($5)) in lower(title)) > 0
             or exists (select 1 from unnest(tags) g where position(lower(btrim($5)) in g) > 0))
        and (not coalesce($6, false) or delayed)
        and ($7 is null or $7 = '' or id = $7)
    ) x $f$, v_col, v_dir, v_nulls)
  into v_result using p_plan_id, p_status, p_priority, p_tag, p_q, p_delayed, p_todo_id, v;
  return v_result;
end $$;

-- 한 건 조회: 내 것이 아니거나 없으면 똑같이 404
create or replace function todo_get(p_id text) returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare v uuid := require_user(); r jsonb;
begin
  select to_jsonb(tv) - 'user_id' into r from todo_view tv where tv.id = p_id and tv.user_id = v;
  if r is null then raise exception '할 일을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  return r;
end $$;

create or replace function todo_create(p_plan_id text, p_title text, p_deadline date, p_priority integer, p_tags text[], p_estimated integer) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user(); n text := new_id('T');
begin
  perform 1 from plans where id = p_plan_id and user_id = v;
  if not found then raise exception '선택한 계획을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  insert into todos(id, user_id, plan_id, title, status, deadline, priority, tags, estimated_minutes)
  values (n, v, p_plan_id, btrim(p_title), 'todo', p_deadline, p_priority, coalesce(p_tags, '{}'), p_estimated);
  return todo_get(n);
end $$;

create or replace function todo_update(p_id text, p_plan_id text, p_title text, p_deadline date, p_priority integer, p_tags text[], p_estimated integer, p_status text default null) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user(); cur todos%rowtype;
begin
  select * into cur from todos where id = p_id and user_id = v;
  if not found then raise exception '할 일을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  perform 1 from plans where id = p_plan_id and user_id = v;
  if not found then raise exception '선택한 계획을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  if p_status is not null and p_status not in ('todo', 'doing') then
    raise exception '진행 상태는 할 일 또는 진행 중만 직접 바꿀 수 있습니다.'; end if;
  update todos set plan_id = p_plan_id, title = btrim(p_title), deadline = p_deadline, priority = p_priority,
         tags = coalesce(p_tags, '{}'), estimated_minutes = p_estimated,
         status = coalesce(p_status, status), updated_at = now()
  where id = p_id and user_id = v;
  return todo_get(p_id);
end $$;

create or replace function todo_delete(p_id text) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user();
begin
  delete from todos where id = p_id and user_id = v;
  if not found then raise exception '할 일을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- 완료는 할 일당 한 번만 기록합니다. 행을 잠가서 동시에 두 번 눌러도 기록 1건, 완료 수 +1입니다.
create or replace function complete_todo(
  p_todo_id text, p_key text default null, p_started timestamptz default null,
  p_ended timestamptz default null, p_actual integer default null, p_blocked text default ''
) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare
  v uuid := require_user();
  v_todo todos%rowtype;
  v_log exec_logs%rowtype;
  v_key text := coalesce(nullif(btrim(p_key), ''), 'complete:' || p_todo_id || ':' || gen_random_uuid()::text);
  v_actual integer := p_actual;
  v_dup boolean := false;
begin
  select * into v_todo from todos where id = p_todo_id and user_id = v for update;
  if not found then raise exception '할 일을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  select * into v_log from exec_logs where user_id = v and idempotency_key = v_key;
  v_dup := found;
  if not v_dup and v_todo.status = 'done' then
    select * into v_log from exec_logs where todo_id = p_todo_id and is_completion;
    v_dup := found;
  end if;
  if v_dup then return jsonb_build_object('duplicate', true, 'log', to_jsonb(v_log) - 'user_id'); end if;
  if p_started is not null and p_ended is not null then
    if p_ended < p_started then raise exception '끝난 시각은 시작 시각보다 같거나 뒤여야 합니다.'; end if;
    if v_actual is null then v_actual := round(extract(epoch from (p_ended - p_started)) / 60)::integer; end if;
  end if;
  insert into exec_logs(id, user_id, todo_id, started_at, ended_at, actual_minutes, blocked_reason, is_completion, idempotency_key)
  values (new_id('L'), v, p_todo_id, p_started, p_ended, v_actual, coalesce(btrim(p_blocked), ''), true, v_key)
  returning * into v_log;
  perform set_config('pds.allow_done', '1', true);
  update todos set status = 'done', completed_at = now(), updated_at = now() where id = p_todo_id;
  return jsonb_build_object('duplicate', false, 'log', to_jsonb(v_log) - 'user_id');
end $$;

create or replace function reopen_todo(p_todo_id text) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user(); v_todo todos%rowtype;
begin
  select * into v_todo from todos where id = p_todo_id and user_id = v for update;
  if not found then raise exception '할 일을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  if v_todo.status <> 'done' then raise exception '완료된 할 일만 되돌릴 수 있습니다.'; end if;
  update exec_logs set is_completion = false where todo_id = p_todo_id;   -- 기록은 남기고 완료 표시만 해제
  perform set_config('pds.allow_done', '1', true);
  update todos set status = 'doing', completed_at = null, updated_at = now() where id = p_todo_id;
  return jsonb_build_object('ok', true);
end $$;

-- ===================================================== 실행 기록
create or replace function add_log(
  p_todo_id text, p_key text, p_started timestamptz default null, p_ended timestamptz default null,
  p_actual integer default null, p_blocked text default ''
) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare
  v uuid := require_user();
  v_log exec_logs%rowtype;
  v_actual integer := p_actual;
  v_blocked text := coalesce(btrim(p_blocked), '');
begin
  if p_key is null or btrim(p_key) = '' then raise exception '요청 키(Idempotency-Key)가 필요합니다.'; end if;
  perform 1 from todos where id = p_todo_id and user_id = v;
  if not found then raise exception '할 일을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  select * into v_log from exec_logs where user_id = v and idempotency_key = p_key;
  if found then return jsonb_build_object('duplicate', true, 'log', to_jsonb(v_log) - 'user_id'); end if;
  if p_started is null and p_ended is null and v_actual is null and v_blocked = '' then
    raise exception '시작·끝 시각, 걸린 시간, 막힌 이유 중 하나는 적어야 합니다.'; end if;
  if p_started is not null and p_ended is not null then
    if p_ended < p_started then raise exception '끝난 시각은 시작 시각보다 같거나 뒤여야 합니다.'; end if;
    if v_actual is null then v_actual := round(extract(epoch from (p_ended - p_started)) / 60)::integer; end if;
  end if;
  insert into exec_logs(id, user_id, todo_id, started_at, ended_at, actual_minutes, blocked_reason, is_completion, idempotency_key)
  values (new_id('L'), v, p_todo_id, p_started, p_ended, v_actual, v_blocked, false, p_key)
  on conflict (user_id, idempotency_key) do nothing
  returning * into v_log;
  if not found then
    select * into v_log from exec_logs where user_id = v and idempotency_key = p_key;
    return jsonb_build_object('duplicate', true, 'log', to_jsonb(v_log) - 'user_id');
  end if;
  return jsonb_build_object('duplicate', false, 'log', to_jsonb(v_log) - 'user_id');
end $$;

create or replace function log_list(p_todo_id text default null) returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare v uuid := require_user();
begin
  if p_todo_id is not null then
    perform 1 from todos where id = p_todo_id and user_id = v;
    if not found then raise exception '할 일을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  end if;
  return coalesce((
    select jsonb_agg((to_jsonb(e) - 'user_id') || jsonb_build_object('todo_title', t.title, 'plan_id', t.plan_id) order by e.seq desc)
    from exec_logs e join todos t on t.id = e.todo_id
    where e.user_id = v and (p_todo_id is null or e.todo_id = p_todo_id)), '[]'::jsonb);
end $$;

create or replace function log_delete(p_id text) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user(); r exec_logs%rowtype;
begin
  select * into r from exec_logs where id = p_id and user_id = v;
  if not found then raise exception '기록을 찾을 수 없습니다.' using errcode = 'PT404'; end if;
  if r.is_completion then raise exception '완료 기록은 지울 수 없습니다. 할 일을 되돌린 뒤 지우세요.'; end if;
  delete from exec_logs where id = p_id and user_id = v;
  return jsonb_build_object('ok', true);
end $$;

-- ===================================================== 돌아보기
create or replace function review_scope_ids(p_user uuid, p_plan_id text, p_from date, p_to date) returns setof text
language sql stable security definer set search_path = diary2 as $$
  select id from plans
  where user_id = p_user
    and (p_plan_id is null or p_plan_id = '' or id = p_plan_id)
    and (p_from is null or end_date >= p_from)
    and (p_to is null or start_date <= p_to)
$$;

create or replace function review_summary(p_plan_id text default null, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare v uuid := require_user(); r jsonb;
begin
  with ids as (select * from review_scope_ids(v, p_plan_id, p_from, p_to) as id),
       t as (select * from todo_view where user_id = v and plan_id in (select id from ids))
  select jsonb_build_object(
    'today_seoul', seoul_today(),
    'plan_count', (select count(*) from ids),
    'todo_count', (select count(*) from t),
    'done_count', (select count(*) from t where status = 'done'),
    'delayed_count', (select count(*) from t where delayed),
    'blocked_count', (select count(*) from t where blocked),
    'estimated_minutes', (select coalesce(sum(estimated_minutes), 0) from t),
    'actual_minutes', (select coalesce(sum(actual_minutes), 0) from t),
    'diff_minutes', (select coalesce(sum(actual_minutes), 0) - coalesce(sum(estimated_minutes), 0) from t),
    'carry_text', case when p_plan_id is null or p_plan_id = '' then null
                       else coalesce((select carry_text from reviews where plan_id = p_plan_id and user_id = v), '') end)
  into r;
  return r;
end $$;

create or replace function review_records(p_metric text, p_plan_id text default null, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare v uuid := require_user(); v_items jsonb; v_logs jsonb := '[]'::jsonb;
begin
  if p_metric not in ('todo', 'done', 'delayed', 'blocked', 'estimate', 'actual') then
    raise exception 'metric은 todo/done/delayed/blocked/estimate/actual 중 하나여야 합니다.'; end if;
  select coalesce(jsonb_agg(to_jsonb(t) - 'user_id' order by t.seq), '[]'::jsonb) into v_items
  from todo_view t
  where t.user_id = v and plan_id in (select * from review_scope_ids(v, p_plan_id, p_from, p_to))
    and case p_metric when 'done' then status = 'done' when 'delayed' then delayed when 'blocked' then blocked
                      when 'estimate' then estimated_minutes is not null when 'actual' then log_count > 0 else true end;
  if p_metric in ('actual', 'blocked') then
    select coalesce(jsonb_agg((to_jsonb(e) - 'user_id') || jsonb_build_object('todo_title', t.title) order by e.seq), '[]'::jsonb) into v_logs
    from exec_logs e
    join todos t on t.id = e.todo_id
    where e.user_id = v
      and e.todo_id in (select (x ->> 'id') from jsonb_array_elements(v_items) x)
      and (p_metric = 'actual' or btrim(e.blocked_reason) <> '');
  end if;
  return jsonb_build_object('metric', p_metric, 'today_seoul', seoul_today(), 'items', v_items, 'logs', v_logs);
end $$;

create or replace function review_by_period(p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare v uuid := require_user(); r jsonb;
begin
  select coalesce(jsonb_agg(x order by x.start_date, x.seq), '[]'::jsonb) into r from (
    select p.id as plan_id, p.title, p.start_date, p.end_date, p.seq,
           count(t.id)::int as todo_count,
           (count(*) filter (where t.status = 'done'))::int as done_count,
           (count(*) filter (where t.delayed))::int as delayed_count,
           (count(*) filter (where t.blocked))::int as blocked_count,
           coalesce(sum(t.estimated_minutes), 0)::int as estimated_minutes,
           coalesce(sum(t.actual_minutes), 0)::int as actual_minutes,
           (coalesce(sum(t.actual_minutes), 0) - coalesce(sum(t.estimated_minutes), 0))::int as diff_minutes
    from plans p left join todo_view t on t.plan_id = p.id
    where p.id in (select * from review_scope_ids(v, null, p_from, p_to))
    group by p.id
  ) x;
  return r;
end $$;

create or replace function app_meta() returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare v uuid := require_user();
begin
  return jsonb_build_object(
    'today_seoul', seoul_today(),
    'counts', jsonb_build_object(
      'plans', (select count(*) from plans where user_id = v),
      'todos', (select count(*) from todos where user_id = v),
      'exec_logs', (select count(*) from exec_logs where user_id = v)));
end $$;

-- ===================================================== 5일 기록 실험
create or replace function experiment_save(p_question text, p_metric text, p_unit text, p_digits integer default 1, p_week_start integer default 1) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user();
begin
  if exists (select 1 from daily_records where user_id = v) then
    raise exception '첫 기록을 남긴 뒤에는 질문·지표·단위를 바꿀 수 없습니다. (1일차에 고정)'; end if;
  insert into experiment(user_id, question, metric_name, unit, rounding_digits, week_start)
  values (v, btrim(p_question), btrim(p_metric), btrim(p_unit), p_digits, p_week_start)
  on conflict (user_id) do update set question = excluded.question, metric_name = excluded.metric_name,
    unit = excluded.unit, rounding_digits = excluded.rounding_digits, week_start = excluded.week_start;
  return jsonb_build_object('ok', true);
end $$;

-- 오늘(서울) 값을 기록합니다. 하루 한 건이며, 같은 날 다시 보내면 그날 값을 덮어씁니다.
create or replace function daily_save(p_value numeric, p_note text default '') returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user(); d date := seoul_today(); updated boolean := false;
begin
  if not exists (select 1 from experiment where user_id = v) then
    raise exception '먼저 질문·지표·단위를 정해 저장하세요.'; end if;
  if p_value is null or p_value < 0 then raise exception '값은 0 이상의 숫자여야 합니다.'; end if;
  if (select count(*) from daily_records where user_id = v) >= 5
     and not exists (select 1 from daily_records where user_id = v and record_date = d) then
    raise exception '5일 기록이 이미 완성되었습니다.'; end if;
  -- 2일차 기록 뒤에는 계획 규칙을 먼저 바꿔 기록해야 새 날짜(3일차)를 기록할 수 있다. (규칙 변경은 3일차 기록 전에만 가능하므로 순서를 서버가 지킨다)
  if (select count(*) from daily_records where user_id = v) >= 2
     and not exists (select 1 from rule_changes where user_id = v)
     and not exists (select 1 from daily_records where user_id = v and record_date = d) then
    raise exception '먼저 계획 규칙을 바꿔 기록하세요. 3일차 값은 규칙을 바꾼 뒤에만 기록할 수 있습니다. (5일 기록 탭의 "계획 규칙 바꾸기")'; end if;
  if exists (select 1 from daily_records where user_id = v and record_date = d) then
    update daily_records set value = p_value, note = btrim(coalesce(p_note, '')), updated_at = now() where user_id = v and record_date = d;
    updated := true;
  else
    insert into daily_records(user_id, record_date, value, note) values (v, d, p_value, btrim(coalesce(p_note, '')));
  end if;
  return jsonb_build_object('ok', true, 'record_date', d, 'updated', updated);
end $$;

-- 계획 규칙은 한 번만, 2일차 기록 뒤 · 3일차 기록 앞에서만 바꿀 수 있습니다. 바꾼 시각은 서버가 적습니다.
create or replace function rule_change_save(p_reason text, p_before text, p_after text) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user(); n integer;
begin
  select count(*) into n from daily_records where user_id = v;
  if exists (select 1 from rule_changes where user_id = v) then raise exception '규칙 변경은 한 번만 기록할 수 있습니다.'; end if;
  if n <> 2 then
    raise exception '규칙 변경은 2일차 기록 뒤, 3일차 기록 앞에서만 할 수 있습니다. (지금 기록 %일)', n; end if;
  insert into rule_changes(user_id, reason, rule_before, rule_after, records_before)
  values (v, btrim(p_reason), btrim(p_before), btrim(p_after), n);
  return jsonb_build_object('ok', true);
end $$;

create or replace function experiment_summary() returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare
  v uuid := require_user(); e experiment%rowtype; rc rule_changes%rowtype;
  digits integer; med numeric; recs jsonb; miss jsonb; weeks jsonb;
  b_n integer; b_sum numeric; a_n integer; a_sum numeric; t_n integer; t_sum numeric; has_rc boolean;
begin
  select * into e from experiment where user_id = v;
  if not found then
    return jsonb_build_object('experiment', null, 'today_seoul', seoul_today(), 'records', '[]'::jsonb);
  end if;
  digits := e.rounding_digits;
  select * into rc from rule_changes where user_id = v;
  has_rc := found;
  select percentile_cont(0.5) within group (order by value) into med from daily_records where user_id = v;
  select count(*), coalesce(sum(value), 0) into t_n, t_sum from daily_records where user_id = v;
  select count(*), coalesce(sum(value), 0) into b_n, b_sum from daily_records where user_id = v and has_rc and created_at < rc.changed_at;
  select count(*), coalesce(sum(value), 0) into a_n, a_sum from daily_records where user_id = v and has_rc and created_at >= rc.changed_at;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'record_date', d.record_date, 'value', d.value, 'note', d.note, 'created_at', d.created_at,
      'phase', case when not has_rc then null when d.created_at < rc.changed_at then 'before' else 'after' end,
      'outlier', (t_n >= 3 and med > 0 and (d.value >= 2 * med or d.value <= med / 2))
    ) order by d.record_date), '[]'::jsonb) into recs from daily_records d where d.user_id = v;
  select coalesce(jsonb_agg(g::date order by g), '[]'::jsonb) into miss
  from generate_series((select min(record_date) from daily_records where user_id = v),
                       (select max(record_date) from daily_records where user_id = v), interval '1 day') g
  where not exists (select 1 from daily_records d where d.user_id = v and d.record_date = g::date);
  select coalesce(jsonb_agg(jsonb_build_object('week_start', w, 'days', n, 'sum', s) order by w), '[]'::jsonb) into weeks from (
    select (d.record_date - (((extract(isodow from d.record_date)::int - e.week_start) + 7) % 7)) as w, count(*) as n, sum(d.value) as s
    from daily_records d where d.user_id = v group by 1) q;
  return jsonb_build_object(
    'today_seoul', seoul_today(),
    'experiment', jsonb_build_object('question', e.question, 'metric_name', e.metric_name, 'unit', e.unit, 'rounding_digits', e.rounding_digits, 'week_start', e.week_start),
    'records', recs, 'missing_dates', miss, 'weeks', weeks,
    'rule_change', case when has_rc then jsonb_build_object('changed_at', rc.changed_at, 'reason', rc.reason, 'rule_before', rc.rule_before, 'rule_after', rc.rule_after, 'records_before', rc.records_before) else null end,
    'total',  jsonb_build_object('days', t_n, 'sum', t_sum, 'avg', case when t_n > 0 then round(t_sum / t_n, digits) end),
    'before', case when has_rc then jsonb_build_object('days', b_n, 'sum', b_sum, 'avg', case when b_n > 0 then round(b_sum / b_n, digits) end) end,
    'after',  case when has_rc then jsonb_build_object('days', a_n, 'sum', a_sum, 'avg', case when a_n > 0 then round(a_sum / a_n, digits) end) end,
    'rules', jsonb_build_object(
      'average', '평균 = 값이 있는 날의 합계 ÷ 값이 있는 날 수',
      'rounding', '소수 ' || digits || '째 자리까지 반올림(0.5는 올림)',
      'missing', '기록하지 않은 날은 "빠짐"으로 표시하고 평균의 날 수에서 뺀다',
      'duplicate', '하루에 한 건만 저장한다. 같은 날 다시 입력하면 그날 값을 덮어쓴다',
      'outlier', '기록이 3일 이상일 때 중앙값의 2배 이상이거나 절반 이하인 값은 "유난히 튐"으로 표시하되 계산에는 넣는다',
      'week_start', case e.week_start when 1 then '월요일' when 2 then '화요일' when 3 then '수요일' when 4 then '목요일' when 5 then '금요일' when 6 then '토요일' else '일요일' end));
end $$;

-- ===================================================== 내보내기 · 가져오기 · 계정 삭제
create or replace function export_all() returns jsonb
language plpgsql stable security definer set search_path = diary2 as $$
declare v uuid := require_user();
begin
  return jsonb_build_object(
    'schema_version', 'pds-schema-v3', 'exported_at', now(),
    'timezone', '저장은 UTC(timestamptz), 화면 표시는 Asia/Seoul',
    'plans', coalesce((select jsonb_agg(to_jsonb(x) - 'user_id' order by x.seq) from plans x where x.user_id = v), '[]'::jsonb),
    'plan_history', coalesce((select jsonb_agg(to_jsonb(x) - 'user_id' order by x.id) from plan_history x where x.user_id = v), '[]'::jsonb),
    'todos', coalesce((select jsonb_agg(to_jsonb(x) - 'user_id' order by x.seq) from todos x where x.user_id = v), '[]'::jsonb),
    'exec_logs', coalesce((select jsonb_agg(to_jsonb(x) - 'user_id' order by x.seq) from exec_logs x where x.user_id = v), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(to_jsonb(x) - 'user_id') from reviews x where x.user_id = v), '[]'::jsonb),
    'experiment', (select to_jsonb(x) - 'user_id' from experiment x where x.user_id = v),
    'daily_records', coalesce((select jsonb_agg(to_jsonb(x) - 'user_id' order by x.record_date) from daily_records x where x.user_id = v), '[]'::jsonb),
    'rule_changes', coalesce((select jsonb_agg(to_jsonb(x) - 'user_id') from rule_changes x where x.user_id = v), '[]'::jsonb));
end $$;

-- 6번 다이어리에서 내보낸 파일을 내 계정으로 옮깁니다. 번호(id)는 새로 매겨서 다른 사람 것과 겹치지 않게 합니다.
create or replace function import_t06(p jsonb) returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare
  v uuid := require_user();
  m_plan jsonb := '{}'; m_todo jsonb := '{}';
  r jsonb; nid text; np integer := 0; nt integer := 0; nl integer := 0;
begin
  if jsonb_typeof(p -> 'plans') is distinct from 'array' or jsonb_typeof(p -> 'todos') is distinct from 'array'
     or jsonb_typeof(p -> 'exec_logs') is distinct from 'array' then
    raise exception '6번에서 내보낸 파일(plans, todos, exec_logs)이 아닙니다.'; end if;
  if jsonb_array_length(p -> 'plans') > 500 or jsonb_array_length(p -> 'todos') > 5000 or jsonb_array_length(p -> 'exec_logs') > 20000 then
    raise exception '파일이 너무 큽니다.'; end if;
  perform set_config('pds.allow_done', '1', true);
  for r in select * from jsonb_array_elements(p -> 'plans') loop
    nid := new_id('P'); m_plan := m_plan || jsonb_build_object(r ->> 'id', nid);
    insert into plans(id, user_id, title, category, start_date, end_date, priority, success_criteria, estimated_minutes, created_at, updated_at)
    values (nid, v, r ->> 'title', r ->> 'category', (r ->> 'start_date')::date, (r ->> 'end_date')::date, (r ->> 'priority')::smallint,
            r ->> 'success_criteria', (r ->> 'estimated_minutes')::integer,
            coalesce((r ->> 'created_at')::timestamptz, now()), coalesce((r ->> 'updated_at')::timestamptz, now()));
    np := np + 1;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p -> 'plan_history', '[]'::jsonb)) loop
    continue when m_plan ->> (r ->> 'plan_id') is null;
    insert into plan_history(user_id, plan_id, field, old_value, new_value, changed_at)
    values (v, m_plan ->> (r ->> 'plan_id'), r ->> 'field', r ->> 'old_value', r ->> 'new_value', coalesce((r ->> 'changed_at')::timestamptz, now()));
  end loop;
  for r in select * from jsonb_array_elements(p -> 'todos') loop
    continue when m_plan ->> (r ->> 'plan_id') is null;
    nid := new_id('T'); m_todo := m_todo || jsonb_build_object(r ->> 'id', nid);
    insert into todos(id, user_id, plan_id, title, status, deadline, priority, tags, estimated_minutes, completed_at, created_at, updated_at)
    values (nid, v, m_plan ->> (r ->> 'plan_id'), r ->> 'title', r ->> 'status', (r ->> 'deadline')::date, (r ->> 'priority')::smallint,
            coalesce((select array_agg(g) from jsonb_array_elements_text(case when jsonb_typeof(r -> 'tags') = 'array' then r -> 'tags' else '[]'::jsonb end) g), '{}'),
            (r ->> 'estimated_minutes')::integer, (r ->> 'completed_at')::timestamptz,
            coalesce((r ->> 'created_at')::timestamptz, now()), coalesce((r ->> 'updated_at')::timestamptz, now()));
    nt := nt + 1;
  end loop;
  for r in select * from jsonb_array_elements(p -> 'exec_logs') loop
    continue when m_todo ->> (r ->> 'todo_id') is null;
    nid := new_id('L');
    insert into exec_logs(id, user_id, todo_id, started_at, ended_at, actual_minutes, blocked_reason, is_completion, idempotency_key, created_at)
    values (nid, v, m_todo ->> (r ->> 'todo_id'), (r ->> 'started_at')::timestamptz, (r ->> 'ended_at')::timestamptz,
            (r ->> 'actual_minutes')::integer, coalesce(r ->> 'blocked_reason', ''), coalesce((r ->> 'is_completion')::boolean, false),
            'import:' || nid, coalesce((r ->> 'created_at')::timestamptz, now()));
    nl := nl + 1;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p -> 'reviews', '[]'::jsonb)) loop
    continue when m_plan ->> (r ->> 'plan_id') is null;
    insert into reviews(plan_id, user_id, carry_text, updated_at)
    values (m_plan ->> (r ->> 'plan_id'), v, coalesce(r ->> 'carry_text', ''), coalesce((r ->> 'updated_at')::timestamptz, now()));
  end loop;
  return jsonb_build_object('plans', np, 'todos', nt, 'exec_logs', nl);
end $$;

-- 내 계정을 지웁니다. 내 자료(계획·할 일·기록·5일 기록)도 함께 지워집니다.
create or replace function delete_my_account() returns jsonb
language plpgsql security definer set search_path = diary2 as $$
declare v uuid := require_user();
begin
  delete from auth.users where id = v;
  return jsonb_build_object('ok', true);
end $$;

-- ===================================================== 접근 권한
-- 표: 아무에게도 직접 열어 주지 않는다. (RLS 도 켜 두어 한 겹 더 막는다)
do $$
declare t text;
begin
  foreach t in array array['plans','plan_history','todos','exec_logs','reviews','experiment','daily_records','rule_changes'] loop
    execute format('alter table diary2.%I enable row level security', t);
    execute format('revoke all on diary2.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on diary2.todo_view from public, anon, authenticated;
revoke all on all sequences in schema diary2 from public, anon, authenticated;
grant usage on schema diary2 to anon, authenticated;

-- 함수: 기본은 모두 막고, 로그인한 사람(authenticated)에게 필요한 것만 연다. anon(로그인 안 함)에게는 하나도 열지 않는다.
revoke execute on all functions in schema diary2 from public, anon, authenticated;
grant execute on function
  plans_list(), plan_create(text, text, date, date, integer, text, integer),
  plan_update(text, text, text, date, date, integer, text, integer), plan_delete(text),
  plan_history_list(text), plan_carry(text, text),
  todo_list(text, text, integer, text, text, boolean, text, text, text), todo_get(text),
  todo_create(text, text, date, integer, text[], integer),
  todo_update(text, text, text, date, integer, text[], integer, text), todo_delete(text),
  complete_todo(text, text, timestamptz, timestamptz, integer, text), reopen_todo(text),
  add_log(text, text, timestamptz, timestamptz, integer, text), log_list(text), log_delete(text),
  review_summary(text, date, date), review_records(text, text, date, date), review_by_period(date, date),
  app_meta(), experiment_save(text, text, text, integer, integer), daily_save(numeric, text),
  rule_change_save(text, text, text), experiment_summary(),
  export_all(), import_t06(jsonb), delete_my_account()
  to authenticated;
-- 요청 검사 함수는 모든 요청 앞에서 불리므로 요청 역할 모두에게 필요하다
grant execute on function public.check_session() to anon, authenticated, authenticator;

-- Data API 에 diary2 칸을 열어 준다 (기존에 열려 있던 칸은 그대로 두고 diary2 만 더한다)
do $$
declare cur text;
begin
  select coalesce((select substr(c, length('pgrst.db_schemas=') + 1) from pg_roles r, unnest(r.rolconfig) c
                   where r.rolname = 'authenticator' and c like 'pgrst.db_schemas=%'), 'public, graphql_public') into cur;
  if position('diary2' in cur) = 0 then
    execute format('alter role authenticator set pgrst.db_schemas = %L', cur || ', diary2');
  end if;
end $$;
notify pgrst, 'reload config';
notify pgrst, 'reload schema';
