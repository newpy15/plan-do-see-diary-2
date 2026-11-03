-- 플랜두씨 다이어리 DB (Supabase / PostgreSQL)
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여 넣고 Run 하세요. (여러 번 실행해도 안전합니다)
--
-- 규칙
--  · 날짜는 date, 시각은 timestamptz(UTC로 저장). 화면에서는 항상 서울(Asia/Seoul) 시간으로 보여 줍니다.
--  · "오늘"은 DB가 서울 시간으로 계산합니다(seoul_today). 접속한 사람의 PC 시계는 쓰지 않습니다.
--  · 시간 단위는 분(*_minutes, 정수). 차이 = 실제 − 예상.
--  · 완료·되돌리기·집계·거르기·정렬은 모두 DB 함수에서 처리합니다.

-- ===================================================== 표
create table if not exists plans (
  seq bigint generated always as identity,
  id text primary key,
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
  plan_id text not null references plans(id) on delete cascade,
  field text not null,
  old_value text,
  new_value text,
  changed_at timestamptz not null default now()
);

create table if not exists todos (
  seq bigint generated always as identity,
  id text primary key,
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
  todo_id text not null references todos(id) on delete cascade,
  started_at timestamptz,
  ended_at timestamptz,
  actual_minutes integer check (actual_minutes is null or actual_minutes >= 0),
  blocked_reason text not null default '',
  is_completion boolean not null default false,
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  check (ended_at is null or started_at is null or ended_at >= started_at)
);
-- 할 일 하나에 완료 기록은 최대 1건 (완료 버튼을 연달아 눌러도 1건)
create unique index if not exists ux_one_completion_per_todo on exec_logs(todo_id) where is_completion;
create index if not exists ix_todos_plan on todos(plan_id);
create index if not exists ix_logs_todo on exec_logs(todo_id);

create table if not exists reviews (
  plan_id text primary key references plans(id) on delete cascade,
  carry_text text not null default '' check (char_length(carry_text) <= 200),
  updated_at timestamptz not null default now()
);

-- ===================================================== 도우미
create or replace function seoul_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Seoul')::date $$;

create or replace function new_id(prefix text) returns text
language sql volatile as $$ select prefix || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8) $$;

-- 계획을 고치면 바뀐 항목마다 예전 값·지금 값을 plan_history에 따로 남깁니다.
create or replace function plans_track_history() returns trigger
language plpgsql as $$
begin
  if new.title is distinct from old.title then
    insert into plan_history(plan_id, field, old_value, new_value) values (old.id, 'title', old.title, new.title); end if;
  if new.category is distinct from old.category then
    insert into plan_history(plan_id, field, old_value, new_value) values (old.id, 'category', old.category, new.category); end if;
  if new.start_date is distinct from old.start_date then
    insert into plan_history(plan_id, field, old_value, new_value) values (old.id, 'start_date', old.start_date::text, new.start_date::text); end if;
  if new.end_date is distinct from old.end_date then
    insert into plan_history(plan_id, field, old_value, new_value) values (old.id, 'end_date', old.end_date::text, new.end_date::text); end if;
  if new.priority is distinct from old.priority then
    insert into plan_history(plan_id, field, old_value, new_value) values (old.id, 'priority', old.priority::text, new.priority::text); end if;
  if new.success_criteria is distinct from old.success_criteria then
    insert into plan_history(plan_id, field, old_value, new_value) values (old.id, 'success_criteria', old.success_criteria, new.success_criteria); end if;
  if new.estimated_minutes is distinct from old.estimated_minutes then
    insert into plan_history(plan_id, field, old_value, new_value) values (old.id, 'estimated_minutes', old.estimated_minutes::text, new.estimated_minutes::text); end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists trg_plans_history on plans;
create trigger trg_plans_history before update on plans for each row execute function plans_track_history();

-- 완료 상태는 complete_todo / reopen_todo 함수로만 바꿀 수 있습니다. (버튼을 잠그는 것만으로 막지 않고 DB가 막습니다)
create or replace function todos_guard_status() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'done' then raise exception '완료 상태로 바로 만들 수 없습니다.'; end if;
  elsif new.status is distinct from old.status
        and (new.status = 'done' or old.status = 'done')
        and coalesce(current_setting('pds.allow_done', true), '') <> '1' then
    raise exception '완료·되돌리기는 전용 기능으로만 바꿀 수 있습니다.';
  end if;
  return new;
end $$;
drop trigger if exists trg_todos_guard on todos;
create trigger trg_todos_guard before insert or update on todos for each row execute function todos_guard_status();

-- ===================================================== 할 일 + 실행 기록 합친 보기
create or replace view todo_view with (security_invoker = true) as
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

-- ===================================================== 함수 (화면이 rpc로 부릅니다)
create or replace function app_meta() returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'today_seoul', seoul_today(),
    'counts', jsonb_build_object(
      'plans', (select count(*) from plans),
      'todos', (select count(*) from todos),
      'exec_logs', (select count(*) from exec_logs)))
$$;

-- 거르기·검색·정렬은 여기(DB)에서 합니다. 값이 같으면 우선순위(높은 순) → 만든 순서. 값이 비면 항상 뒤.
create or replace function todo_list(
  p_plan_id text default null, p_status text default null, p_priority integer default null,
  p_tag text default null, p_q text default null, p_delayed boolean default false,
  p_sort text default 'deadline', p_dir text default 'asc', p_todo_id text default null
) returns jsonb
language plpgsql stable as $$
declare
  v_col text;
  v_dir text := case when p_dir = 'desc' then 'desc' else 'asc' end;
  v_nulls text := '';
  v_result jsonb;
begin
  v_col := case p_sort
    when 'priority' then 'priority'
    when 'estimate' then 'estimated_minutes'
    when 'created' then 'seq'
    when 'title' then 'lower(title)'
    else 'deadline' end;
  if v_col in ('deadline', 'estimated_minutes') then v_nulls := ' nulls last'; end if;
  execute format($f$
    select coalesce(jsonb_agg(to_jsonb(x) - 'ord' order by x.ord), '[]'::jsonb)
    from (
      select v.*, row_number() over (order by %s %s%s, priority asc, seq asc) as ord
      from todo_view v
      where ($1 is null or $1 = '' or plan_id = $1)
        and ($2 is null or $2 = '' or ($2 = 'open' and status <> 'done') or status = $2)
        and ($3 is null or priority = $3)
        and ($4 is null or $4 = '' or tags @> array[lower(btrim($4))])
        and ($5 is null or btrim($5) = '' or position(lower(btrim($5)) in lower(title)) > 0
             or exists (select 1 from unnest(tags) g where position(lower(btrim($5)) in g) > 0))
        and (not coalesce($6, false) or delayed)
        and ($7 is null or $7 = '' or id = $7)
    ) x $f$, v_col, v_dir, v_nulls)
  into v_result using p_plan_id, p_status, p_priority, p_tag, p_q, p_delayed, p_todo_id;
  return v_result;
end $$;

-- 완료는 할 일당 한 번만 기록합니다. 행을 잠가서 동시에 두 번 눌러도 기록 1건, 완료 수 +1입니다.
create or replace function complete_todo(
  p_todo_id text, p_key text default null, p_started timestamptz default null,
  p_ended timestamptz default null, p_actual integer default null, p_blocked text default ''
) returns jsonb
language plpgsql as $$
declare
  v_todo todos%rowtype;
  v_log exec_logs%rowtype;
  v_key text := coalesce(nullif(btrim(p_key), ''), 'complete:' || p_todo_id || ':' || gen_random_uuid()::text);
  v_actual integer := p_actual;
  v_dup boolean := false;
begin
  select * into v_todo from todos where id = p_todo_id for update;
  if not found then raise exception '할 일을 찾을 수 없습니다.'; end if;
  select * into v_log from exec_logs where idempotency_key = v_key;
  v_dup := found;
  if not v_dup and v_todo.status = 'done' then
    select * into v_log from exec_logs where todo_id = p_todo_id and is_completion;
    v_dup := found;
  end if;
  if v_dup then return jsonb_build_object('duplicate', true, 'log', to_jsonb(v_log)); end if;
  if p_started is not null and p_ended is not null then
    if p_ended < p_started then raise exception '끝난 시각은 시작 시각보다 같거나 뒤여야 합니다.'; end if;
    if v_actual is null then v_actual := round(extract(epoch from (p_ended - p_started)) / 60)::integer; end if;
  end if;
  insert into exec_logs(id, todo_id, started_at, ended_at, actual_minutes, blocked_reason, is_completion, idempotency_key)
  values (new_id('L'), p_todo_id, p_started, p_ended, v_actual, coalesce(btrim(p_blocked), ''), true, v_key)
  returning * into v_log;
  perform set_config('pds.allow_done', '1', true);
  update todos set status = 'done', completed_at = now(), updated_at = now() where id = p_todo_id;
  return jsonb_build_object('duplicate', false, 'log', to_jsonb(v_log));
end $$;

create or replace function reopen_todo(p_todo_id text) returns jsonb
language plpgsql as $$
declare v_todo todos%rowtype;
begin
  select * into v_todo from todos where id = p_todo_id for update;
  if not found then raise exception '할 일을 찾을 수 없습니다.'; end if;
  if v_todo.status <> 'done' then raise exception '완료된 할 일만 되돌릴 수 있습니다.'; end if;
  update exec_logs set is_completion = false where todo_id = p_todo_id;   -- 기록은 남기고 완료 표시만 해제
  perform set_config('pds.allow_done', '1', true);
  update todos set status = 'doing', completed_at = null, updated_at = now() where id = p_todo_id;
  return jsonb_build_object('ok', true);
end $$;

-- 실행 기록 추가. 같은 키로 두 번 와도 기록은 1건입니다. 계획(todos) 값은 건드리지 않습니다.
create or replace function add_log(
  p_todo_id text, p_key text, p_started timestamptz default null, p_ended timestamptz default null,
  p_actual integer default null, p_blocked text default ''
) returns jsonb
language plpgsql as $$
declare
  v_log exec_logs%rowtype;
  v_actual integer := p_actual;
  v_blocked text := coalesce(btrim(p_blocked), '');
begin
  if p_key is null or btrim(p_key) = '' then raise exception '요청 키(Idempotency-Key)가 필요합니다.'; end if;
  perform 1 from todos where id = p_todo_id;
  if not found then raise exception '할 일을 찾을 수 없습니다.'; end if;
  select * into v_log from exec_logs where idempotency_key = p_key;
  if found then return jsonb_build_object('duplicate', true, 'log', to_jsonb(v_log)); end if;
  if p_started is null and p_ended is null and v_actual is null and v_blocked = '' then
    raise exception '시작·끝 시각, 걸린 시간, 막힌 이유 중 하나는 적어야 합니다.'; end if;
  if p_started is not null and p_ended is not null then
    if p_ended < p_started then raise exception '끝난 시각은 시작 시각보다 같거나 뒤여야 합니다.'; end if;
    if v_actual is null then v_actual := round(extract(epoch from (p_ended - p_started)) / 60)::integer; end if;
  end if;
  insert into exec_logs(id, todo_id, started_at, ended_at, actual_minutes, blocked_reason, is_completion, idempotency_key)
  values (new_id('L'), p_todo_id, p_started, p_ended, v_actual, v_blocked, false, p_key)
  on conflict (idempotency_key) do nothing
  returning * into v_log;
  if not found then
    select * into v_log from exec_logs where idempotency_key = p_key;
    return jsonb_build_object('duplicate', true, 'log', to_jsonb(v_log));
  end if;
  return jsonb_build_object('duplicate', false, 'log', to_jsonb(v_log));
end $$;

-- 돌아보기 집계: 선택한 계획(또는 기간과 겹치는 계획)에 딸린 할 일 기준
create or replace function review_scope_ids(p_plan_id text, p_from date, p_to date) returns setof text
language sql stable as $$
  select id from plans
  where (p_plan_id is null or p_plan_id = '' or id = p_plan_id)
    and (p_from is null or end_date >= p_from)
    and (p_to is null or start_date <= p_to)
$$;

create or replace function review_summary(p_plan_id text default null, p_from date default null, p_to date default null) returns jsonb
language sql stable as $$
  with ids as (select * from review_scope_ids(p_plan_id, p_from, p_to) as id),
       t as (select * from todo_view where plan_id in (select id from ids))
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
                       else coalesce((select carry_text from reviews where plan_id = p_plan_id), '') end)
$$;

-- 숫자를 눌렀을 때 그 숫자가 나온 기록
create or replace function review_records(p_metric text, p_plan_id text default null, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable as $$
declare v_items jsonb; v_logs jsonb := '[]'::jsonb;
begin
  if p_metric not in ('todo', 'done', 'delayed', 'blocked', 'estimate', 'actual') then
    raise exception 'metric은 todo/done/delayed/blocked/estimate/actual 중 하나여야 합니다.'; end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.seq), '[]'::jsonb) into v_items
  from todo_view t
  where plan_id in (select * from review_scope_ids(p_plan_id, p_from, p_to))
    and case p_metric when 'done' then status = 'done' when 'delayed' then delayed when 'blocked' then blocked
                      when 'estimate' then estimated_minutes is not null when 'actual' then log_count > 0 else true end;
  if p_metric in ('actual', 'blocked') then
    select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('todo_title', t.title) order by e.seq), '[]'::jsonb) into v_logs
    from exec_logs e
    join todo_view t on t.id = e.todo_id
    where e.todo_id in (select (x ->> 'id') from jsonb_array_elements(v_items) x)
      and (p_metric = 'actual' or btrim(e.blocked_reason) <> '');
  end if;
  return jsonb_build_object('metric', p_metric, 'today_seoul', seoul_today(), 'items', v_items, 'logs', v_logs);
end $$;

-- 기간(계획)별 모아 보기
create or replace function review_by_period(p_from date default null, p_to date default null) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(r order by r.start_date, r.seq), '[]'::jsonb) from (
    select p.id as plan_id, p.title, p.start_date, p.end_date, p.seq,
           count(t.id)::int as todo_count,
           (count(*) filter (where t.status = 'done'))::int as done_count,
           (count(*) filter (where t.delayed))::int as delayed_count,
           (count(*) filter (where t.blocked))::int as blocked_count,
           coalesce(sum(t.estimated_minutes), 0)::int as estimated_minutes,
           coalesce(sum(t.actual_minutes), 0)::int as actual_minutes,
           (coalesce(sum(t.actual_minutes), 0) - coalesce(sum(t.estimated_minutes), 0))::int as diff_minutes
    from plans p left join todo_view t on t.plan_id = p.id
    where p.id in (select * from review_scope_ids(null, p_from, p_to))
    group by p.id
  ) r
$$;

-- ===================================================== 접근 정책
-- 로그인이 없으므로 공개용(anon) 키로 읽기·쓰기를 허용합니다. 7번 과제에서 잠급니다.
do $$
declare t text;
begin
  foreach t in array array['plans','plan_history','todos','exec_logs','reviews'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists open_access on %I', t);
    execute format('create policy open_access on %I for all to anon, authenticated using (true) with check (true)', t);
    execute format('grant select, insert, update, delete on %I to anon, authenticated', t);
  end loop;
end $$;
grant select on todo_view to anon, authenticated;
grant usage, select on all sequences in schema public to anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;

-- ===================================================== 시작용 예시 자료 (페이지가 열린 뒤 내 계획·기록으로 직접 고쳐 쓰세요)
insert into plans(id, title, category, start_date, end_date, priority, success_criteria, estimated_minutes, created_at, updated_at) values
 ('P-seed0001', '(예시) 이번 주: ALEPH 과제 6 + 운동 루틴', 'ALEPH', '2026-11-02', '2026-11-08', 1,
  'ALEPH 과제 6 제출, 운동 3회, 영어 단어 150개', 600, '2026-11-03 09:00+09', '2026-11-03 09:00+09')
on conflict (id) do nothing;
insert into todos(id, plan_id, title, status, deadline, priority, tags, estimated_minutes, completed_at, created_at, updated_at) values
 ('T-seed0001', 'P-seed0001', '(예시) ALEPH 카드 1 계획 화면 만들기', 'todo', '2026-11-04', 1, '{aleph}', 90, null, '2026-11-03 09:00+09', '2026-11-03 09:00+09'),
 ('T-seed0002', 'P-seed0001', '(예시) ALEPH 카드 2 할 일 만들기·고치기', 'doing', '2026-11-05', 1, '{aleph}', 120, null, '2026-11-03 09:00+09', '2026-11-03 09:00+09'),
 ('T-seed0003', 'P-seed0001', '(예시) 러닝 30분', 'todo', '2026-11-03', 2, '{운동}', 30, null, '2026-11-03 09:00+09', '2026-11-03 09:00+09'),
 ('T-seed0004', 'P-seed0001', '(예시) 영어 단어 50개 외우기', 'todo', '2026-11-02', 2, '{공부}', 40, null, '2026-11-03 09:00+09', '2026-11-03 09:00+09'),
 ('T-seed0005', 'P-seed0001', '(예시) 게임 연습 랭크 3판', 'todo', '2026-11-06', 3, '{"게임 연습"}', 60, null, '2026-11-03 09:00+09', '2026-11-03 09:00+09'),
 ('T-seed0006', 'P-seed0001', '(예시) 업무 메일 정리', 'todo', '2026-11-07', 2, '{업무}', 20, null, '2026-11-03 09:00+09', '2026-11-03 09:00+09')
on conflict (id) do nothing;
insert into exec_logs(id, todo_id, started_at, ended_at, actual_minutes, blocked_reason, is_completion, idempotency_key, created_at) values
 ('L-seed0003', 'T-seed0002', '2026-11-03 21:00+09', '2026-11-03 21:45+09', 45, '서버에 저장하는 방식을 아직 정하지 못함', false, 'seed:L-seed0003', '2026-11-03 09:00+09')
on conflict (id) do nothing;
-- 예시 완료 2건은 완료 함수를 거쳐 만듭니다 (처음 한 번만)
do $$
begin
  if not exists (select 1 from exec_logs where idempotency_key = 'seed:L-seed0001') then
    perform complete_todo('T-seed0001', 'seed:L-seed0001', '2026-11-02 20:00+09', '2026-11-02 21:40+09', 100, '');
    update todos set completed_at = '2026-11-02 21:40+09' where id = 'T-seed0001';
  end if;
  if not exists (select 1 from exec_logs where idempotency_key = 'seed:L-seed0002') then
    perform complete_todo('T-seed0003', 'seed:L-seed0002', '2026-11-03 07:00+09', '2026-11-03 07:35+09', 35, '');
    update todos set completed_at = '2026-11-03 07:35+09' where id = 'T-seed0003';
  end if;
end $$;
insert into reviews(plan_id, carry_text, updated_at) values
 ('P-seed0001', '다음 계획: 영어 단어는 아침 20분으로 쪼개서 마감 전에 끝낸다', '2026-11-03 09:00+09')
on conflict (plan_id) do nothing;
