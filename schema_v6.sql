-- ============================================================
-- ميدان: التحديث السادس (schema_v6)
-- بعد schema_v5.sql: الصق هذا الملف كاملاً في SQL Editor واضغط Run. آمن لإعادة التشغيل.
-- يضيف: دور «مدير» (أعلى من المشرف، بصلاحيات صاحب الفريق)،
--        سجل انقطاع الموقع مع مراجعة السبب (شبكة/إنترنت = محتسب، إغلاق الموقع = استراحة)،
--        تسليم المواد والعدة من المستودع إلى الموظف وإرجاعها.
-- ============================================================

-- ---------- 1. دور «مدير» (admin) ----------
-- السماح بالقيمة الجديدة في عمود الدور (سواء كان text مع قيد، أو نوع enum)
do $$
declare c record; et text;
begin
  select t.typname into et from pg_attribute a join pg_type t on t.oid = a.atttypid
   where a.attrelid = 'public.profiles'::regclass and a.attname = 'role' and t.typtype = 'e';
  if et is not null then
    execute format('alter type public.%I add value if not exists %L', et, 'admin');
  else
    for c in select conname from pg_constraint
              where conrelid = 'public.profiles'::regclass and contype = 'c'
                and pg_get_constraintdef(oid) ilike '%supervisor%' loop
      execute format('alter table public.profiles drop constraint %I', c.conname);
    end loop;
    alter table public.profiles drop constraint if exists profiles_role_chk;
    alter table public.profiles add constraint profiles_role_chk check (role in ('owner', 'admin', 'supervisor', 'member'));
  end if;
end $$;

-- is_owner: صلاحيات صاحب الفريق (صاحب الفريق + المدير)، is_manager: كل من يدير (مع المشرف)
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active and role::text in ('owner', 'admin'));
$$;
create or replace function public.is_manager() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active and role::text in ('owner', 'admin', 'supervisor'));
$$;
-- صاحب الفريق الأصلي فقط (يعيّن المديرين)
create or replace function public.is_true_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active and role::text = 'owner');
$$;
revoke all on function public.is_true_owner() from public, anon;
grant execute on function public.is_true_owner() to authenticated;

-- حماية الحسابات: المدير لا يستطيع تغيير دور/تعطيل صاحب الفريق أو مدير آخر، ولا ترقية أحد إلى مدير
create or replace function public.guard_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_owner() then
    new.id := old.id;
    new.email := old.email;
    new.username := old.username;
    new.role := old.role;
    new.active := old.active;
  elsif auth.uid() is not null and not public.is_true_owner() then
    new.id := old.id;
    if old.role::text in ('owner', 'admin') or new.role::text in ('owner', 'admin') then
      new.role := old.role;
      new.active := old.active;
    end if;
  end if;
  return new;
end $$;

-- ---------- 2. انقطاع الموقع: تسجيل ثم مراجعة ----------
-- الاستراحة التلقائية صارت لإغلاق الموقع فقط. انقطاع التغطية/الإنترنت لا يُخصم، بل يُسجَّل للمراجعة.
-- migrate: أي استراحة انقطاع (loc_gap) من schema_v5 تتحول إلى سجل انقطاع غير مخصوم.
alter table public.breaks drop constraint if exists breaks_kind_chk;

create table if not exists public.loc_gaps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  attendance_id uuid references public.attendance (id) on delete cascade,
  from_at timestamptz not null,                -- آخر وقت كان فيه موقع قبل الانقطاع
  from_lat double precision, from_lng double precision, from_acc int,
  to_at timestamptz not null,                  -- أول وقت وصل فيه موقع بعد الانقطاع
  to_lat double precision, to_lng double precision, to_acc int,
  cause text not null default 'unknown' check (cause in ('network', 'off', 'unknown')),
  trail jsonb,                                 -- نقاط سجّلها الجهاز أثناء الانقطاع [[ms,lat,lng],...]
  break_ids uuid[] not null default '{}',      -- الاستراحات المخصومة المرتبطة (فارغة = الوقت محتسب)
  decided_by uuid references public.profiles (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists loc_gaps_user_idx on public.loc_gaps (user_id, from_at desc);
alter table public.loc_gaps enable row level security;
drop policy if exists loc_gaps_read on public.loc_gaps;
create policy loc_gaps_read on public.loc_gaps for select to authenticated
  using (public.is_active() and (public.is_manager() or user_id = auth.uid()));
revoke all on public.loc_gaps from anon;
revoke insert, update, delete on public.loc_gaps from authenticated;

insert into public.loc_gaps (user_id, attendance_id, from_at, to_at, cause)
select b.user_id, b.attendance_id, b.start_at, coalesce(b.end_at, now()), 'unknown'
  from public.breaks b where b.kind = 'loc_gap';
delete from public.breaks where kind = 'loc_gap';
alter table public.breaks add constraint breaks_kind_chk check (kind in ('manual', 'loc_off'));

-- التطبيق يبلّغ: الموقع يعمل (true) أو أُغلق (false). p_since = آخر وقت كان فيه موقع (من الجهاز).
drop function if exists public.loc_state(boolean);
create or replace function public.loc_state(
  p_on boolean, p_since timestamptz default null,
  p_lat double precision default null, p_lng double precision default null, p_acc int default null
) returns text
language plpgsql security definer set search_path = '' as $$
declare a public.attendance; b public.breaks; pr public.presence; st timestamptz;
begin
  if not public.is_active() or public.is_manager() then return 'none'; end if;
  select * into a from public.attendance where user_id = auth.uid() and out_at is null;
  if not found then return 'none'; end if;
  select * into b from public.breaks where user_id = auth.uid() and end_at is null;
  if p_on then
    if found and b.kind <> 'manual' then
      update public.breaks set end_at = now(), end_lat = p_lat, end_lng = p_lng, end_acc = p_acc where id = b.id;
      return 'resumed';
    end if;
    return 'on';
  end if;
  if found then return 'break'; end if;
  select * into pr from public.presence where user_id = auth.uid();
  st := greatest(coalesce(p_since, pr.loc_at, now()), a.in_at, now() - interval '30 minutes',
                 coalesce((select max(end_at) from public.breaks where attendance_id = a.id), a.in_at));
  st := least(st, now());
  insert into public.breaks (attendance_id, user_id, kind, start_at, start_lat, start_lng, start_acc)
  values (a.id, auth.uid(), 'loc_off', st, coalesce(p_lat, pr.lat), coalesce(p_lng, pr.lng), coalesce(p_acc, pr.acc))
  on conflict do nothing;
  return 'off';
end $$;

-- وصول موقع: يُنهي استراحة إغلاق الموقع، وإن سبقه انقطاع طويل يُسجَّل في loc_gaps (محتسب) مع الدليل.
-- p_trail: نقاط الموقع التي سجّلها الجهاز أثناء انقطاع الشبكة. p_offs: فترات أبلغ الجهاز أن الموقع كان فيها مغلقًا.
drop function if exists public.touch_presence(double precision, double precision, int, text);
create or replace function public.touch_presence(
  p_lat double precision default null, p_lng double precision default null, p_acc int default null,
  p_src text default null, p_trail jsonb default null, p_offs jsonb default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.attendance; pr public.presence; gs timestamptz; closed int;
  o jsonb; s timestamptz; e timestamptz; offmin numeric := 0; tr jsonb := '[]'::jsonb;
  bids uuid[] := '{}'; bid uuid; cz text;
begin
  if not public.is_active() then return; end if;
  if p_lat is not null and (p_lng is null or not exists (
       select 1 from public.attendance where user_id = auth.uid() and out_at is null)) then
    p_lat := null; p_lng := null; p_acc := null; p_src := null;
  end if;

  if p_lat is not null and not public.is_manager() then
    begin
      select * into a from public.attendance where user_id = auth.uid() and out_at is null;
      if found then
        update public.breaks set end_at = now(), end_lat = p_lat, end_lng = p_lng, end_acc = p_acc
         where user_id = auth.uid() and end_at is null and kind <> 'manual';
        get diagnostics closed = row_count;
        if closed = 0 and not exists (select 1 from public.breaks where user_id = auth.uid() and end_at is null) then
          select * into pr from public.presence where user_id = auth.uid();
          gs := greatest(coalesce(pr.loc_at, a.in_at), a.in_at);
          gs := greatest(gs, coalesce((select max(end_at) from public.breaks where attendance_id = a.id), gs));
          if now() - gs > make_interval(mins => public.loc_gap_minutes()) then
            if jsonb_typeof(p_trail) = 'array' then
              select coalesce(jsonb_agg(x), '[]'::jsonb) into tr from (
                select x from jsonb_array_elements(p_trail) x
                 where jsonb_typeof(x) = 'array' and jsonb_array_length(x) >= 3 and (x ->> 0) ~ '^[0-9]+(\.[0-9]+)?$'
                   and (x ->> 0)::numeric between extract(epoch from gs) * 1000 - 60000 and extract(epoch from now()) * 1000 + 60000
                 limit 100) q;
            end if;
            if jsonb_typeof(p_offs) = 'array' then
              for o in select * from jsonb_array_elements(p_offs) loop
                continue when jsonb_typeof(o) <> 'array' or jsonb_array_length(o) < 2
                          or (o ->> 0) !~ '^[0-9]+(\.[0-9]+)?$' or (o ->> 1) !~ '^[0-9]+(\.[0-9]+)?$';
                s := greatest(to_timestamp((o ->> 0)::numeric / 1000.0), gs);
                e := least(to_timestamp((o ->> 1)::numeric / 1000.0), now());
                if e - s >= interval '2 minutes' then
                  insert into public.breaks (attendance_id, user_id, kind, start_at, end_at, start_lat, start_lng, start_acc, end_lat, end_lng, end_acc)
                  values (a.id, auth.uid(), 'loc_off', s, e, pr.lat, pr.lng, pr.acc, p_lat, p_lng, p_acc) returning id into bid;
                  bids := bids || bid;
                  offmin := offmin + extract(epoch from (e - s)) / 60;
                end if;
              end loop;
            end if;
            cz := case when offmin > 0 then 'off' when jsonb_array_length(tr) > 0 then 'network' else 'unknown' end;
            insert into public.loc_gaps (user_id, attendance_id, from_at, from_lat, from_lng, from_acc, to_at, to_lat, to_lng, to_acc, cause, trail, break_ids)
            values (auth.uid(), a.id, gs, pr.lat, pr.lng, pr.acc, now(), p_lat, p_lng, p_acc, cz, nullif(tr, '[]'::jsonb), bids);
          end if;
        end if;
      end if;
    exception when others then
      null;   -- تسجيل الانقطاع لا يمنع تسجيل الموقع نفسه
    end;
  end if;

  insert into public.presence (user_id, last_seen, lat, lng, acc, loc_src, loc_at)
  values (auth.uid(), now(), p_lat, p_lng, p_acc,
          case when p_lat is not null and p_src in ('gps', 'net') then p_src end,
          case when p_lat is not null then now() end)
  on conflict (user_id) do update set
    last_seen = now(),
    lat = coalesce(excluded.lat, public.presence.lat),
    lng = coalesce(excluded.lng, public.presence.lng),
    acc = case when excluded.lat is not null then excluded.acc else public.presence.acc end,
    loc_src = case when excluded.lat is not null then excluded.loc_src else public.presence.loc_src end,
    loc_at = case when excluded.lat is not null then now() else public.presence.loc_at end;
end $$;

-- لم يعد المسح التلقائي يخصم شيئًا (انقطاع الشبكة لا يُعدّ استراحة). تُبقى الدالة لتوافق النسخ القديمة.
create or replace function public.loc_sweep() returns int
language sql security definer set search_path = '' as $$ select 0 $$;

-- قرار المراجعة: p_break = true اعتبر الانقطاع استراحة (يُخصم)، false احتسبه دوامًا
create or replace function public.loc_gap_decide(p_id uuid, p_break boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.loc_gaps; bid uuid;
begin
  if not (public.is_active() and public.is_manager()) then raise exception 'غير مصرّح'; end if;
  select * into g from public.loc_gaps where id = p_id for update;
  if not found then raise exception 'السجل غير موجود'; end if;
  if p_break then
    if cardinality(g.break_ids) = 0 then
      insert into public.breaks (attendance_id, user_id, kind, start_at, end_at, start_lat, start_lng, start_acc, end_lat, end_lng, end_acc)
      select g.attendance_id, g.user_id, 'loc_off', g.from_at, g.to_at, g.from_lat, g.from_lng, g.from_acc, g.to_lat, g.to_lng, g.to_acc
       where g.attendance_id is not null returning id into bid;
      if bid is null then raise exception 'لا يمكن ربط الانقطاع بسجل دوام'; end if;
      update public.loc_gaps set break_ids = array[bid], decided_by = auth.uid(), decided_at = now() where id = p_id;
    else
      update public.loc_gaps set decided_by = auth.uid(), decided_at = now() where id = p_id;
    end if;
  else
    delete from public.breaks where id = any (g.break_ids);
    update public.loc_gaps set break_ids = '{}', decided_by = auth.uid(), decided_at = now() where id = p_id;
  end if;
end $$;

-- ---------- 3. المستودعان: تسليم المواد والعدة للموظف وإرجاعها ----------
-- المستودع = عناصر custody بنطاق workshop. مستودع المواد: kind = material، مستودع العدة: kind = tool.
create or replace function public.warehouse_issue(p_id uuid, p_holder uuid, p_qty numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.custody; pid uuid;
begin
  if not (public.is_active() and public.is_manager()) then raise exception 'غير مصرّح'; end if;
  select * into w from public.custody where id = p_id and scope = 'workshop' and holder_id is null for update;
  if not found then raise exception 'العنصر غير موجود في المستودع'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'اكتب كمية أكبر من صفر'; end if;
  if p_qty > w.qty then raise exception 'الكمية أكبر من المتوفر في المستودع (%)', w.qty; end if;
  if not exists (select 1 from public.profiles where id = p_holder and active and role::text not in ('owner', 'admin')) then
    raise exception 'الموظف غير موجود أو معطّل';
  end if;
  select id into pid from public.custody
   where scope = 'personal' and holder_id = p_holder and kind = w.kind and name = w.name and unit = w.unit limit 1;
  if pid is null then
    insert into public.custody (scope, kind, name, qty, unit, holder_id, note)
    values ('personal', w.kind, w.name, p_qty, w.unit, p_holder, w.note);
  else
    update public.custody set qty = qty + p_qty, updated_at = now() where id = pid;
  end if;
  update public.custody set qty = qty - p_qty, updated_at = now() where id = p_id;
end $$;

create or replace function public.warehouse_return(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.custody; wid uuid;
begin
  if not (public.is_active() and public.is_manager()) then raise exception 'غير مصرّح'; end if;
  select * into c from public.custody where id = p_id and scope = 'personal' for update;
  if not found then raise exception 'العنصر غير موجود'; end if;
  select id into wid from public.custody
   where scope = 'workshop' and holder_id is null and kind = c.kind and name = c.name and unit = c.unit limit 1;
  if wid is null then
    insert into public.custody (scope, kind, name, qty, unit, holder_id, note)
    values ('workshop', c.kind, c.name, c.qty, c.unit, null, c.note);
  else
    update public.custody set qty = qty + c.qty, updated_at = now() where id = wid;
  end if;
  delete from public.custody where id = p_id;
end $$;

-- ---------- 4. الصلاحيات والتحديث الفوري ----------
revoke all on function
  public.loc_state(boolean, timestamptz, double precision, double precision, int),
  public.touch_presence(double precision, double precision, int, text, jsonb, jsonb),
  public.loc_gap_decide(uuid, boolean), public.loc_sweep(),
  public.warehouse_issue(uuid, uuid, numeric), public.warehouse_return(uuid)
  from public, anon;
grant execute on function
  public.loc_state(boolean, timestamptz, double precision, double precision, int),
  public.touch_presence(double precision, double precision, int, text, jsonb, jsonb),
  public.loc_gap_decide(uuid, boolean), public.loc_sweep(),
  public.warehouse_issue(uuid, uuid, numeric), public.warehouse_return(uuid)
  to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'loc_gaps') then
    alter publication supabase_realtime add table public.loc_gaps;
  end if;
end $$;
