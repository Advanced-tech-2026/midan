-- ============================================================
-- ميدان: التحديث الخامس (schema_v5)
-- بعد schema_v4.sql: الصق هذا الملف كاملاً في SQL Editor واضغط Run.
-- آمن لإعادة التشغيل أكثر من مرة.
-- يضيف: تعديل المهمة وإغلاقها وحذفها (للمدير)، واستراحة تلقائية عند إيقاف الموقع.
-- ============================================================

-- ---------- 1. المهام: إغلاق / تعديل / حذف ----------
alter table public.tasks add column if not exists closed_at timestamptz;
alter table public.tasks add column if not exists closed_by uuid references public.profiles (id) on delete set null;

create or replace function public.task_is_closed(p_task uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select closed_at is not null from public.tasks where id = p_task), false);
$$;

-- تعديل العنوان والمكان والإحداثيات (المدير أو المشرف)
create or replace function public.task_update(
  p_task uuid, p_title text, p_place text,
  p_lat double precision default null, p_lng double precision default null, p_clear_loc boolean default false
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_active() and public.is_manager()) then raise exception 'غير مصرّح'; end if;
  if p_title is null or length(btrim(p_title)) = 0 then raise exception 'اكتب عنوان المهمة'; end if;
  if p_lat is not null and (p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180) then
    raise exception 'إحداثيات غير صحيحة';
  end if;
  update public.tasks set
    title = btrim(p_title),
    place = coalesce(btrim(p_place), ''),
    lat = case when p_clear_loc then null when p_lat is not null then p_lat else lat end,
    lng = case when p_clear_loc then null when p_lat is not null then p_lng else lng end
  where id = p_task;
  if not found then raise exception 'المهمة غير موجودة'; end if;
end $$;

-- إغلاق المهمة (تُقفل: لا صور ولا تغيير حالة من رئيس المهمة) أو إعادة فتحها
create or replace function public.task_close(p_task uuid, p_closed boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_active() and public.is_manager()) then raise exception 'غير مصرّح'; end if;
  update public.tasks set
    closed_at = case when p_closed then now() else null end,
    closed_by = case when p_closed then auth.uid() else null end
  where id = p_task;
  if not found then raise exception 'المهمة غير موجودة'; end if;
end $$;

-- حذف المهمة نهائيًا مع صورها ومحادثتها ومواردها
create or replace function public.task_delete(p_task uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_active() and public.is_manager()) then raise exception 'غير مصرّح'; end if;
  delete from public.task_photos where task_id = p_task;
  delete from public.ptt_keys where chan = p_task::text;
  delete from public.tasks where id = p_task;
end $$;

-- المهمة المغلقة: المدير فقط يغيّر حالتها أو تقييمها أو يضيف صورًا
create or replace function public.set_task_status(p_task uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_manager() or public.is_task_head(p_task)) then
    raise exception 'رئيس المهمة فقط يغيّر حالتها';
  end if;
  if public.task_is_closed(p_task) and not public.is_manager() then
    raise exception 'المهمة مغلقة. تواصل مع المدير لإعادة فتحها';
  end if;
  update public.tasks set status = p_status where id = p_task;
end $$;

create or replace function public.set_task_review(p_task uuid, p_quality int, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_manager() or public.is_task_head(p_task)) then
    raise exception 'رئيس المهمة فقط يقيّم المهمة';
  end if;
  if public.task_is_closed(p_task) and not public.is_manager() then
    raise exception 'المهمة مغلقة. تواصل مع المدير لإعادة فتحها';
  end if;
  update public.tasks set quality = p_quality, qnote = coalesce(p_note, '') where id = p_task;
end $$;

drop policy if exists photos_insert on public.task_photos;
create policy photos_insert on public.task_photos for insert to authenticated
  with check (public.is_active() and created_by = auth.uid()
              and (public.is_manager() or (public.is_task_head(task_id) and not public.task_is_closed(task_id))));

-- ---------- 2. إيقاف الموقع = استراحة تلقائية لا تُحتسب من الدوام ----------
-- kind: manual استراحة عادية | loc_off أبلغ التطبيق أن الموقع أُغلق | loc_gap انقطع وصول الموقع مدة طويلة
alter table public.breaks add column if not exists kind text not null default 'manual';
alter table public.breaks drop constraint if exists breaks_kind_chk;
alter table public.breaks add constraint breaks_kind_chk check (kind in ('manual', 'loc_off', 'loc_gap'));

-- المدة (بالدقائق) التي إن لم يصل فيها أي موقع للموظف المسجَّل دخوله نعدّ الفترة استراحة. غيّر الرقم إن أردت.
create or replace function public.loc_gap_minutes() returns int
language sql immutable as $$ select 15 $$;

-- التطبيق يبلّغ: الموقع يعمل (true) أو أُغلق (false). أثناء الدوام فقط.
create or replace function public.loc_state(p_on boolean) returns text
language plpgsql security definer set search_path = '' as $$
declare a public.attendance; b public.breaks;
begin
  if not public.is_active() or public.is_manager() then return 'none'; end if;
  select * into a from public.attendance where user_id = auth.uid() and out_at is null;
  if not found then return 'none'; end if;
  select * into b from public.breaks where user_id = auth.uid() and end_at is null;
  if p_on then
    if found and b.kind <> 'manual' then
      update public.breaks set end_at = now() where id = b.id;
      return 'resumed';
    end if;
    return 'on';
  end if;
  if found then return 'break'; end if;      -- في استراحة أصلًا
  insert into public.breaks (attendance_id, user_id, kind) values (a.id, auth.uid(), 'loc_off')
  on conflict do nothing;
  return 'off';
end $$;

-- وصول موقع جديد: يُنهي استراحة الموقع المفتوحة، وإن كان بين آخر موقع وهذا انقطاع طويل يُسجَّل استراحة بأثر رجعي
create or replace function public.touch_presence(
  p_lat double precision default null, p_lng double precision default null, p_acc int default null,
  p_src text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.attendance; prev timestamptz; gs timestamptz; closed int;
begin
  if not public.is_active() then return; end if;
  if p_lat is not null and (p_lng is null or not exists (
       select 1 from public.attendance where user_id = auth.uid() and out_at is null)) then
    p_lat := null; p_lng := null; p_acc := null; p_src := null;
  end if;

  if p_lat is not null and not public.is_manager() then
    select * into a from public.attendance where user_id = auth.uid() and out_at is null;
    if found then
      update public.breaks set end_at = now()
       where user_id = auth.uid() and end_at is null and kind <> 'manual';
      get diagnostics closed = row_count;
      if closed = 0 and not exists (select 1 from public.breaks where user_id = auth.uid() and end_at is null) then
        select loc_at into prev from public.presence where user_id = auth.uid();
        gs := greatest(coalesce(prev, a.in_at), a.in_at);
        gs := greatest(gs, coalesce((select max(end_at) from public.breaks where attendance_id = a.id), gs));
        if now() - gs > make_interval(mins => public.loc_gap_minutes()) then
          insert into public.breaks (attendance_id, user_id, kind, start_at, end_at)
          values (a.id, auth.uid(), 'loc_gap', gs, now());
        end if;
      end if;
    end if;
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

-- مسح للموظفين الذين انقطع موقعهم (يستدعيه تطبيق المدير دوريًا): تُفتح لهم استراحة من وقت آخر موقع
create or replace function public.loc_sweep() returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.is_active() then return 0; end if;
  insert into public.breaks (attendance_id, user_id, kind, start_at)
  select a.id, a.user_id, 'loc_gap',
         greatest(coalesce(p.loc_at, a.in_at), a.in_at,
                  coalesce((select max(b.end_at) from public.breaks b where b.attendance_id = a.id), a.in_at))
    from public.attendance a
    left join public.presence p on p.user_id = a.user_id
   where a.out_at is null
     and greatest(coalesce(p.loc_at, a.in_at), a.in_at) < now() - make_interval(mins => public.loc_gap_minutes())
     and not exists (select 1 from public.breaks b where b.user_id = a.user_id and b.end_at is null)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- 3. الصلاحيات ----------
revoke all on function
  public.task_is_closed(uuid),
  public.task_update(uuid, text, text, double precision, double precision, boolean),
  public.task_close(uuid, boolean), public.task_delete(uuid),
  public.loc_state(boolean), public.loc_sweep()
  from public, anon;
grant execute on function
  public.task_is_closed(uuid),
  public.task_update(uuid, text, text, double precision, double precision, boolean),
  public.task_close(uuid, boolean), public.task_delete(uuid),
  public.loc_state(boolean), public.loc_sweep()
  to authenticated;
