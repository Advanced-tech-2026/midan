-- ============================================================
-- ميدان: التحديث الرابع (schema_v4)
-- بعد schema_v3.sql: الصق هذا الملف كاملاً في SQL Editor واضغط Run.
-- آمن لإعادة التشغيل أكثر من مرة.
-- يضيف: ساعة السيرفر، العهدة وعدة الورشة، مواد المهمة، مواقع المهمة، السلف.
-- ============================================================

-- ---------- 1. ساعة السيرفر (منع التلاعب بوقت جهاز الموظف) ----------
-- أوقات الدخول والخروج والاستراحة تُسجَّل أصلاً بساعة السيرفر (now()) ولا يستطيع الجهاز تغييرها.
-- هذه الدالة تعطي التطبيق ساعة السيرفر ليعرض العدادات والتذكيرات ووقت الصورة بها لا بساعة الجهاز،
-- وتسجّل تنبيهًا للمدير إن اختلفت ساعة جهاز الموظف عن السيرفر بأكثر من دقيقتين.
create table if not exists public.clock_alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  skew_s int not null,                         -- ساعة الجهاز ناقص ساعة السيرفر بالثواني
  created_at timestamptz not null default now()
);
create index if not exists clock_alerts_user_idx on public.clock_alerts (user_id, created_at desc);
alter table public.clock_alerts enable row level security;
drop policy if exists clock_alerts_read on public.clock_alerts;
create policy clock_alerts_read on public.clock_alerts for select to authenticated
  using (public.is_active() and public.is_manager());

create or replace function public.report_clock(p_device timestamptz) returns timestamptz
language plpgsql security definer set search_path = '' as $$
declare srv timestamptz := clock_timestamp(); skew int;
begin
  if p_device is null or not public.is_active() or public.is_manager() then return srv; end if;
  skew := round(extract(epoch from (p_device - srv)))::int;
  if abs(skew) > 120 and not exists (
       select 1 from public.clock_alerts where user_id = auth.uid() and created_at > now() - interval '30 minutes') then
    insert into public.clock_alerts (user_id, skew_s) values (auth.uid(), skew);
  end if;
  return srv;
end $$;
revoke all on function public.report_clock(timestamptz) from public, anon;
grant execute on function public.report_clock(timestamptz) to authenticated;

-- ---------- 2. العهدة وعدة الورشة ----------
-- scope = personal : عهدة موظف (عدة أو مواد مستلمة)   |   workshop : عدة إضافية للورشة
-- holder_id        : الموظف الذي هي في عهدته (فارغ = في مخزن الورشة)
create table if not exists public.custody (
  id uuid primary key default gen_random_uuid(),
  scope text not null default 'personal' check (scope in ('personal', 'workshop')),
  kind text not null default 'tool' check (kind in ('tool', 'material')),
  name text not null check (length(btrim(name)) between 1 and 120),
  qty numeric(12, 2) not null default 1 check (qty >= 0),
  unit text not null default '' check (length(unit) <= 20),
  holder_id uuid references public.profiles (id) on delete set null,
  note text not null default '' check (length(note) <= 300),
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists custody_holder_idx on public.custody (holder_id);
alter table public.custody enable row level security;
drop policy if exists custody_read on public.custody;
create policy custody_read on public.custody for select to authenticated
  using (public.is_active() and (public.is_manager() or scope = 'workshop' or holder_id = auth.uid()));

create table if not exists public.custody_log (
  id uuid primary key default gen_random_uuid(),
  custody_id uuid,
  name text not null,
  action text not null check (action in ('add', 'move', 'qty', 'remove')),
  from_holder uuid references public.profiles (id) on delete set null,
  to_holder uuid references public.profiles (id) on delete set null,
  qty numeric(12, 2),
  by_user uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists custody_log_idx on public.custody_log (created_at desc);
alter table public.custody_log enable row level security;
drop policy if exists custody_log_read on public.custody_log;
create policy custody_log_read on public.custody_log for select to authenticated
  using (public.is_active() and (public.is_manager() or from_holder = auth.uid() or to_holder = auth.uid()));

create or replace function public.custody_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.custody_log (custody_id, name, action, to_holder, qty, by_user)
    values (new.id, new.name, 'add', new.holder_id, new.qty, auth.uid());
    return new;
  elsif tg_op = 'UPDATE' then
    if new.holder_id is distinct from old.holder_id then
      insert into public.custody_log (custody_id, name, action, from_holder, to_holder, qty, by_user)
      values (new.id, new.name, 'move', old.holder_id, new.holder_id, new.qty, auth.uid());
    elsif new.qty is distinct from old.qty then
      insert into public.custody_log (custody_id, name, action, from_holder, to_holder, qty, by_user)
      values (new.id, new.name, 'qty', old.holder_id, new.holder_id, new.qty, auth.uid());
    end if;
    return new;
  else
    insert into public.custody_log (custody_id, name, action, from_holder, qty, by_user)
    values (old.id, old.name, 'remove', old.holder_id, old.qty, auth.uid());
    return old;
  end if;
end $$;
drop trigger if exists custody_audit_trg on public.custody;
create trigger custody_audit_trg after insert or update or delete on public.custody
  for each row execute function public.custody_audit();

create or replace function public.custody_save(
  p_id uuid, p_scope text, p_kind text, p_name text, p_qty numeric, p_unit text, p_holder uuid, p_note text
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  if not (public.is_active() and public.is_manager()) then raise exception 'غير مصرّح'; end if;
  if p_scope not in ('personal', 'workshop') or p_kind not in ('tool', 'material') then raise exception 'بيانات غير صحيحة'; end if;
  if p_scope = 'personal' and p_holder is null then raise exception 'اختر الموظف صاحب العهدة'; end if;
  if p_holder is not null and not exists (select 1 from public.profiles where id = p_holder and active) then
    raise exception 'الموظف غير موجود أو معطّل';
  end if;
  if p_id is null then
    insert into public.custody (scope, kind, name, qty, unit, holder_id, note)
    values (p_scope, p_kind, btrim(p_name), coalesce(p_qty, 1), coalesce(btrim(p_unit), ''), p_holder, coalesce(btrim(p_note), ''))
    returning id into rid;
  else
    update public.custody set kind = p_kind, name = btrim(p_name), qty = coalesce(p_qty, qty), unit = coalesce(btrim(p_unit), ''),
           holder_id = p_holder, note = coalesce(btrim(p_note), ''), updated_at = now()
     where id = p_id returning id into rid;
    if rid is null then raise exception 'العنصر غير موجود'; end if;
  end if;
  return rid;
end $$;

create or replace function public.custody_delete(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_active() and public.is_manager()) then raise exception 'غير مصرّح'; end if;
  delete from public.custody where id = p_id;
end $$;

-- ---------- 3. مواد المهمة (المطلوبة والمستخدمة) ----------
create table if not exists public.task_materials (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  unit text not null default '' check (length(unit) <= 20),
  qty_needed numeric(12, 2) not null default 0 check (qty_needed >= 0),
  qty_used numeric(12, 2) not null default 0 check (qty_used >= 0),
  holder_id uuid references public.profiles (id) on delete set null,   -- في عهدة أي موظف (فارغ = المخزن)
  note text not null default '' check (length(note) <= 300),
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists task_materials_task_idx on public.task_materials (task_id);
alter table public.task_materials enable row level security;
drop policy if exists task_materials_read on public.task_materials;
create policy task_materials_read on public.task_materials for select to authenticated
  using (public.is_active() and public.is_task_member(task_id));

-- رئيس المهمة أو المدير فقط
create or replace function public.task_material_save(
  p_id uuid, p_task uuid, p_name text, p_unit text, p_needed numeric, p_used numeric, p_holder uuid, p_note text
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  if not (public.is_active() and (public.is_manager() or public.is_task_head(p_task))) then
    raise exception 'رئيس المهمة أو المدير فقط يعدّل المواد';
  end if;
  if p_holder is not null and not exists (select 1 from public.profiles where id = p_holder and active) then
    raise exception 'الموظف غير موجود أو معطّل';
  end if;
  if p_id is null then
    insert into public.task_materials (task_id, name, unit, qty_needed, qty_used, holder_id, note)
    values (p_task, btrim(p_name), coalesce(btrim(p_unit), ''), coalesce(p_needed, 0), coalesce(p_used, 0), p_holder, coalesce(btrim(p_note), ''))
    returning id into rid;
  else
    update public.task_materials set name = btrim(p_name), unit = coalesce(btrim(p_unit), ''), qty_needed = coalesce(p_needed, 0),
           qty_used = coalesce(p_used, 0), holder_id = p_holder, note = coalesce(btrim(p_note), ''), updated_at = now()
     where id = p_id and task_id = p_task returning id into rid;
    if rid is null then raise exception 'المادة غير موجودة'; end if;
  end if;
  return rid;
end $$;

create or replace function public.task_material_delete(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t uuid;
begin
  select task_id into t from public.task_materials where id = p_id;
  if t is null then return; end if;
  if not (public.is_active() and (public.is_manager() or public.is_task_head(t))) then
    raise exception 'رئيس المهمة أو المدير فقط يعدّل المواد';
  end if;
  delete from public.task_materials where id = p_id;
end $$;

-- ---------- 4. مواقع المهمة المشتركة مع الفريق ----------
create table if not exists public.task_pins (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks (id) on delete cascade,
  label text not null default '' check (length(label) <= 120),
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  acc int,
  created_by uuid not null references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists task_pins_task_idx on public.task_pins (task_id, created_at desc);
alter table public.task_pins enable row level security;
drop policy if exists task_pins_read on public.task_pins;
create policy task_pins_read on public.task_pins for select to authenticated
  using (public.is_active() and public.is_task_member(task_id));

-- أي عضو في المهمة (أو المدير) يشارك موقعًا
create or replace function public.task_pin_add(
  p_task uuid, p_lat double precision, p_lng double precision, p_label text, p_acc int
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  if not (public.is_active() and public.is_task_member(p_task)) then raise exception 'غير مصرّح'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'إحداثيات غير صحيحة';
  end if;
  if (select count(*) from public.task_pins where task_id = p_task) >= 60 then
    raise exception 'وصلت إلى الحد الأقصى لعدد المواقع في هذه المهمة (60). احذف بعضها أولًا.';
  end if;
  insert into public.task_pins (task_id, label, lat, lng, acc)
  values (p_task, coalesce(btrim(p_label), ''), p_lat, p_lng, p_acc) returning id into rid;
  return rid;
end $$;

-- يحذف الموقع: من أضافه أو رئيس المهمة أو المدير
create or replace function public.task_pin_delete(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.task_pins;
begin
  select * into r from public.task_pins where id = p_id;
  if not found then return; end if;
  if not (public.is_active() and (r.created_by = auth.uid() or public.is_manager() or public.is_task_head(r.task_id))) then
    raise exception 'غير مصرّح';
  end if;
  delete from public.task_pins where id = p_id;
end $$;

-- يجعل موقعًا مشتركًا هو «موقع المهمة» الرئيسي (رئيس المهمة أو المدير)
create or replace function public.task_set_location(p_task uuid, p_lat double precision, p_lng double precision, p_place text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_active() and (public.is_manager() or public.is_task_head(p_task))) then raise exception 'غير مصرّح'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'إحداثيات غير صحيحة';
  end if;
  update public.tasks set lat = p_lat, lng = p_lng, place = case when coalesce(btrim(p_place), '') <> '' then btrim(p_place) else place end
   where id = p_task;
end $$;

-- ---------- 5. السلف ----------
-- طلب الموظف ← قرار صاحب الفريق (موافقة وتسليم أو رفض) ← تسجيل دفعات السداد
create table if not exists public.advances (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade default auth.uid(),
  amount numeric(14, 2) not null check (amount > 0),
  currency text not null default 'USD' check (currency in ('USD', 'SYP')),
  reason text not null default '' check (length(reason) <= 300),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  decided_by uuid references public.profiles (id) on delete set null,
  decided_at timestamptz,
  decision_note text not null default '' check (length(decision_note) <= 300),
  created_at timestamptz not null default now()
);
create index if not exists advances_user_idx on public.advances (user_id, created_at desc);
alter table public.advances enable row level security;
drop policy if exists advances_read on public.advances;
create policy advances_read on public.advances for select to authenticated
  using (public.is_active() and (user_id = auth.uid() or public.is_owner()));

create table if not exists public.advance_payments (
  id uuid primary key default gen_random_uuid(),
  advance_id uuid not null references public.advances (id) on delete cascade,
  amount numeric(14, 2) not null check (amount > 0),
  note text not null default '' check (length(note) <= 200),
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists advance_payments_idx on public.advance_payments (advance_id);
alter table public.advance_payments enable row level security;
drop policy if exists advance_payments_read on public.advance_payments;
create policy advance_payments_read on public.advance_payments for select to authenticated
  using (public.is_active() and (public.is_owner() or exists (
    select 1 from public.advances a where a.id = advance_id and a.user_id = auth.uid())));

create or replace function public.advance_request(p_amount numeric, p_currency text, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  if not public.is_active() or public.is_owner() then raise exception 'غير مصرّح'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'اكتب مبلغًا صحيحًا'; end if;
  if p_currency not in ('USD', 'SYP') then raise exception 'عملة غير صحيحة'; end if;
  if (select count(*) from public.advances where user_id = auth.uid() and status = 'pending') >= 3 then
    raise exception 'لديك 3 طلبات سلفة بانتظار القرار. انتظر الرد عليها أولًا.';
  end if;
  insert into public.advances (user_id, amount, currency, reason)
  values (auth.uid(), round(p_amount, 2), p_currency, coalesce(btrim(p_reason), '')) returning id into rid;
  return rid;
end $$;

create or replace function public.advance_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.advances set status = 'cancelled', decided_at = now()
   where id = p_id and user_id = auth.uid() and status = 'pending';
  if not found then raise exception 'لا يمكن إلغاء هذا الطلب'; end if;
end $$;

create or replace function public.advance_decide(p_id uuid, p_approve boolean, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_active() and public.is_owner()) then raise exception 'صاحب الفريق فقط يقرّر في السلف'; end if;
  update public.advances
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(), decision_note = coalesce(btrim(p_note), '')
   where id = p_id and status = 'pending';
  if not found then raise exception 'الطلب غير موجود أو تم البتّ فيه'; end if;
end $$;

create or replace function public.advance_pay(p_id uuid, p_amount numeric, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.advances; paid numeric;
begin
  if not (public.is_active() and public.is_owner()) then raise exception 'صاحب الفريق فقط يسجّل السداد'; end if;
  select * into a from public.advances where id = p_id for update;
  if not found or a.status <> 'approved' then raise exception 'السلفة غير موافق عليها'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'اكتب مبلغًا صحيحًا'; end if;
  select coalesce(sum(amount), 0) into paid from public.advance_payments where advance_id = p_id;
  if paid + p_amount > a.amount then
    raise exception 'المبلغ أكبر من المتبقي من السلفة (%)', (a.amount - paid);
  end if;
  insert into public.advance_payments (advance_id, amount, note) values (p_id, round(p_amount, 2), coalesce(btrim(p_note), ''));
end $$;

create or replace function public.advance_pay_delete(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_active() and public.is_owner()) then raise exception 'صاحب الفريق فقط يعدّل السداد'; end if;
  delete from public.advance_payments where id = p_id;
end $$;

-- ---------- 6. الصلاحيات والتحديث الفوري ----------
-- الكتابة كلها عبر الدوال أعلاه فقط
revoke all on public.custody, public.custody_log, public.task_materials, public.task_pins,
              public.advances, public.advance_payments, public.clock_alerts from anon;
revoke insert, update, delete on public.custody, public.custody_log, public.task_materials, public.task_pins,
              public.advances, public.advance_payments, public.clock_alerts from authenticated;

revoke all on function
  public.custody_save(uuid, text, text, text, numeric, text, uuid, text), public.custody_delete(uuid),
  public.task_material_save(uuid, uuid, text, text, numeric, numeric, uuid, text), public.task_material_delete(uuid),
  public.task_pin_add(uuid, double precision, double precision, text, int), public.task_pin_delete(uuid),
  public.task_set_location(uuid, double precision, double precision, text),
  public.advance_request(numeric, text, text), public.advance_cancel(uuid), public.advance_decide(uuid, boolean, text),
  public.advance_pay(uuid, numeric, text), public.advance_pay_delete(uuid)
  from public, anon;
grant execute on function
  public.custody_save(uuid, text, text, text, numeric, text, uuid, text), public.custody_delete(uuid),
  public.task_material_save(uuid, uuid, text, text, numeric, numeric, uuid, text), public.task_material_delete(uuid),
  public.task_pin_add(uuid, double precision, double precision, text, int), public.task_pin_delete(uuid),
  public.task_set_location(uuid, double precision, double precision, text),
  public.advance_request(numeric, text, text), public.advance_cancel(uuid), public.advance_decide(uuid, boolean, text),
  public.advance_pay(uuid, numeric, text), public.advance_pay_delete(uuid)
  to authenticated;

do $$
declare t text;
begin
  foreach t in array array['custody', 'custody_log', 'task_materials', 'task_pins', 'advances', 'advance_payments', 'clock_alerts'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
