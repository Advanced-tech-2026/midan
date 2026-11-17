-- ============================================================
-- ميدان: التحديث الثاني لقاعدة البيانات (schema_v2)
-- شغّل schema.sql أولاً (إن لم تكن شغّلته)، ثم الصق هذا الملف كاملاً في SQL Editor واضغط Run.
-- يُشغَّل مرة واحدة فقط.
-- ============================================================

-- ---------- 1. اسم المستخدم ----------
alter table public.profiles add column if not exists username text;
alter table public.profiles add constraint profiles_username_fmt
  check (username is null or username ~ '^[a-z0-9._-]{3,30}$');
create unique index profiles_username_key on public.profiles (username) where username is not null;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, name, username, role)
  values (
    new.id, new.email,
    coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(new.email, '@', 1)),
    nullif(lower(new.raw_user_meta_data ->> 'username'), ''),
    case when exists (select 1 from public.profiles) then 'member' else 'owner' end   -- الدور لا يُؤخذ من الطلب أبداً
  );
  return new;
end $$;

create or replace function public.guard_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_owner() then
    new.id := old.id;
    new.email := old.email;
    new.username := old.username;
    new.role := old.role;
    new.active := old.active;
  end if;
  return new;
end $$;

-- اسم المستخدم -> بريد الدخول (للزائر أيضاً، ليتمكن من تسجيل الدخول)
create function public.login_email(p_username text) returns text
language sql stable security definer set search_path = '' as $$
  select email from public.profiles
  where username = lower(trim(p_username)) and active limit 1;
$$;

-- ---------- 2. الحضور الحي (آخر ظهور وآخر موقع): للمدير ولصاحبه فقط ----------
create table public.presence (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  last_seen timestamptz not null default now(),
  lat double precision, lng double precision, acc int,
  loc_at timestamptz
);
alter table public.presence enable row level security;
create policy presence_read on public.presence for select to authenticated
  using (public.is_active() and (user_id = auth.uid() or public.is_manager()));

create function public.touch_presence(
  p_lat double precision default null, p_lng double precision default null, p_acc int default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_active() then return; end if;
  insert into public.presence (user_id, last_seen, lat, lng, acc, loc_at)
  values (auth.uid(), now(), p_lat, p_lng, p_acc, case when p_lat is not null then now() end)
  on conflict (user_id) do update set
    last_seen = now(),
    lat = coalesce(excluded.lat, public.presence.lat),
    lng = coalesce(excluded.lng, public.presence.lng),
    acc = case when excluded.lat is not null then excluded.acc else public.presence.acc end,
    loc_at = case when excluded.lat is not null then now() else public.presence.loc_at end;
end $$;

-- ---------- 3. المهام: فريق لكل مهمة ورئيس للمهمة ----------
alter table public.tasks add column head_id uuid references public.profiles (id);

create table public.task_members (
  task_id uuid not null references public.tasks (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  primary key (task_id, user_id)
);
create index on public.task_members (user_id);
alter table public.task_members enable row level security;

create function public.is_task_member(p_task uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_manager() or exists (
    select 1 from public.task_members tm
    where tm.task_id = p_task and tm.user_id = auth.uid() and public.is_active());
$$;

create function public.is_task_head(p_task uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tasks t
                 where t.id = p_task and t.head_id = auth.uid() and public.is_active());
$$;

create policy task_members_read on public.task_members for select to authenticated
  using (public.is_manager() or user_id = auth.uid() or public.is_task_member(task_id));

-- التحقق من الفريق: كلهم أعضاء (role = member) فعّالون
create function public._check_team(p_head uuid, p_members uuid[]) returns uuid[]
language plpgsql stable security definer set search_path = '' as $$
declare team uuid[];
begin
  if p_head is null then raise exception 'اختر رئيس المهمة'; end if;
  team := array(select distinct x from unnest(coalesce(p_members, '{}') || p_head) x);
  if (select count(*) from public.profiles
       where id = any (team) and role = 'member' and active) <> array_length(team, 1) then
    raise exception 'يجب أن يكون رئيس المهمة وأعضاؤها من الأعضاء الفعّالين';
  end if;
  return team;
end $$;

create function public.create_task(
  p_title text, p_place text, p_lat double precision, p_lng double precision,
  p_head uuid, p_members uuid[]
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare new_id uuid; team uuid[];
begin
  if not public.is_manager() then raise exception 'غير مصرّح'; end if;
  team := public._check_team(p_head, p_members);
  insert into public.tasks (title, place, lat, lng, head_id, created_by)
  values (p_title, coalesce(p_place, ''), p_lat, p_lng, p_head, auth.uid())
  returning id into new_id;
  insert into public.task_members (task_id, user_id) select new_id, unnest(team);
  return new_id;
end $$;

create function public.set_task_team(p_task uuid, p_head uuid, p_members uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare team uuid[];
begin
  if not public.is_manager() then raise exception 'غير مصرّح'; end if;
  team := public._check_team(p_head, p_members);
  update public.tasks set head_id = p_head where id = p_task;
  delete from public.task_members where task_id = p_task;
  insert into public.task_members (task_id, user_id) select p_task, unnest(team);
end $$;

-- الموافقة على طلب: المقدِّم يصبح رئيس المهمة افتراضياً (يعدّل المدير الفريق بعد ذلك)
drop function public.approve_request(uuid);
create function public.approve_request(p_id uuid, p_head uuid default null, p_members uuid[] default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.task_requests; new_id uuid; team uuid[]; head uuid;
begin
  if not public.is_manager() then raise exception 'غير مصرّح'; end if;
  select * into r from public.task_requests where id = p_id and status = 'pending';
  if not found then raise exception 'الطلب غير موجود'; end if;
  head := coalesce(p_head, r.requested_by);
  team := public._check_team(head, coalesce(p_members, array[r.requested_by]));
  insert into public.tasks (title, place, lat, lng, head_id, created_by)
  values (r.title, r.place, r.lat, r.lng, head, auth.uid())
  returning id into new_id;
  insert into public.task_members (task_id, user_id) select new_id, unnest(team);
  delete from public.task_requests where id = p_id;
  return new_id;
end $$;

-- الحالة والتقييم: رئيس المهمة أو المدير فقط
create or replace function public.set_task_status(p_task uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_manager() or public.is_task_head(p_task)) then
    raise exception 'رئيس المهمة فقط يغيّر حالتها';
  end if;
  update public.tasks set status = p_status where id = p_task;
end $$;

create or replace function public.set_task_review(p_task uuid, p_quality int, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_manager() or public.is_task_head(p_task)) then
    raise exception 'رئيس المهمة فقط يقيّم المهمة';
  end if;
  update public.tasks set quality = p_quality, qnote = coalesce(p_note, '') where id = p_task;
end $$;

-- سياسات المهام والصور: الرؤية لأعضاء المهمة والمدير فقط
drop policy tasks_read on public.tasks;
drop policy tasks_insert on public.tasks;     -- الإنشاء عبر create_task فقط
create policy tasks_read on public.tasks for select to authenticated
  using (public.is_active() and public.is_task_member(id));

drop policy photos_read on public.task_photos;
drop policy photos_insert on public.task_photos;
create policy photos_read on public.task_photos for select to authenticated
  using (public.is_active() and public.is_task_member(task_id));
create policy photos_insert on public.task_photos for insert to authenticated
  with check (public.is_active() and created_by = auth.uid()
              and (public.is_manager() or public.is_task_head(task_id)));

-- ---------- 4. المحادثة: عامة أو خاصة بمهمة ----------
alter table public.messages add column task_id uuid references public.tasks (id) on delete cascade;
create index on public.messages (task_id, created_at desc);

drop policy messages_read on public.messages;
drop policy messages_insert on public.messages;
create policy messages_read on public.messages for select to authenticated
  using (public.is_active() and (task_id is null or public.is_task_member(task_id)));
create policy messages_insert on public.messages for insert to authenticated
  with check (public.is_active() and user_id = auth.uid()
              and (task_id is null or public.is_task_member(task_id)));

-- ---------- 5. الاستراحات ----------
create table public.breaks (
  id uuid primary key default gen_random_uuid(),
  attendance_id uuid not null references public.attendance (id) on delete cascade,
  user_id uuid not null references public.profiles (id) default auth.uid(),
  start_at timestamptz not null default now(),
  start_lat double precision, start_lng double precision, start_acc int,
  end_at timestamptz,
  end_lat double precision, end_lng double precision, end_acc int
);
create index on public.breaks (attendance_id);
create index on public.breaks (user_id, start_at desc);
create unique index breaks_one_open on public.breaks (user_id) where end_at is null;
alter table public.breaks enable row level security;
create policy breaks_read on public.breaks for select to authenticated
  using (public.is_active() and (user_id = auth.uid() or public.is_manager()));

-- المدير لا يسجّل دواماً، والموقع (GPS) إلزامي لكل تسجيل
create or replace function public.check_in(
  p_lat double precision default null, p_lng double precision default null,
  p_acc int default null, p_place text default null,
  p_photo text default null, p_photo_taken timestamptz default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare new_id uuid;
begin
  if not public.is_active() then raise exception 'غير مصرّح'; end if;
  if public.is_manager() then raise exception 'المدير لا يسجّل دوامًا'; end if;
  if p_lat is null or p_lng is null then raise exception 'فعّل GPS ثم أعد المحاولة (الموقع مطلوب لتسجيل الدخول)'; end if;
  perform public.auto_close_stale(auth.uid());
  if exists (select 1 from public.attendance where user_id = auth.uid() and out_at is null) then
    raise exception 'لديك دخول مفتوح بالفعل';
  end if;
  if p_photo_taken is not null and now() - p_photo_taken > interval '3 minutes' then
    raise exception 'الصورة قديمة، التقط صورة جديدة بالكاميرا';
  end if;
  insert into public.attendance (user_id, in_lat, in_lng, in_acc, in_place, in_photo, in_photo_taken_at)
  values (auth.uid(), p_lat, p_lng, p_acc, nullif(p_place, ''), p_photo, p_photo_taken)
  returning id into new_id;
  return new_id;
end $$;

create function public.break_start(
  p_lat double precision default null, p_lng double precision default null, p_acc int default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a public.attendance; new_id uuid;
begin
  if not public.is_active() or public.is_manager() then raise exception 'غير مصرّح'; end if;
  if p_lat is null or p_lng is null then raise exception 'فعّل GPS ثم أعد المحاولة (الموقع مطلوب لتسجيل الاستراحة)'; end if;
  select * into a from public.attendance where user_id = auth.uid() and out_at is null;
  if not found then raise exception 'سجّل دخولك أولاً'; end if;
  if exists (select 1 from public.breaks where user_id = auth.uid() and end_at is null) then
    raise exception 'أنت في استراحة بالفعل';
  end if;
  insert into public.breaks (attendance_id, start_lat, start_lng, start_acc)
  values (a.id, p_lat, p_lng, p_acc) returning id into new_id;
  return new_id;
end $$;

create function public.break_end(
  p_lat double precision default null, p_lng double precision default null, p_acc int default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_active() or public.is_manager() then raise exception 'غير مصرّح'; end if;
  if p_lat is null or p_lng is null then raise exception 'فعّل GPS ثم أعد المحاولة (الموقع مطلوب لإنهاء الاستراحة)'; end if;
  update public.breaks set end_at = now(), end_lat = p_lat, end_lng = p_lng, end_acc = p_acc
   where user_id = auth.uid() and end_at is null;
  if not found then raise exception 'لا توجد استراحة مفتوحة'; end if;
end $$;

create or replace function public.auto_close_stale(p_user uuid default null) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  with closed as (
    update public.attendance a
       set out_at = greatest(public.shift_end_for(a.in_at), a.in_at),
           auto_closed = true, ot_answer = 'no', ot_minutes = 0
     where a.out_at is null
       and (p_user is null or a.user_id = p_user)
       and (
         (a.ot_answer is null
            and a.in_at < public.shift_end_for(a.in_at)
            and now() > public.shift_end_for(a.in_at) + interval '15 minutes')
         or now() > greatest(public.shift_end_for(a.in_at), a.in_at) + interval '6 hours'
       )
    returning a.id, a.out_at
  )
  update public.breaks b set end_at = greatest(b.start_at, c.out_at)
    from closed c where b.attendance_id = c.id and b.end_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.check_out(
  p_lat double precision default null, p_lng double precision default null,
  p_acc int default null, p_place text default null,
  p_photo text default null, p_photo_taken timestamptz default null,
  p_ot text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.attendance;
  end_ts timestamptz;
  ans text;
  stale boolean;
  closed_at_end boolean;
  final_out timestamptz;
begin
  if not public.is_active() then raise exception 'غير مصرّح'; end if;
  if public.is_manager() then raise exception 'المدير لا يسجّل دوامًا'; end if;
  select * into a from public.attendance
   where user_id = auth.uid() and out_at is null for update;
  if not found then
    raise exception 'لا يوجد دخول مفتوح (ربما أُغلق تلقائياً عند نهاية الدوام)';
  end if;
  if p_photo_taken is not null and now() - p_photo_taken > interval '3 minutes' then
    raise exception 'الصورة قديمة، التقط صورة جديدة بالكاميرا';
  end if;
  if p_ot is not null and p_ot not in ('yes', 'no') then raise exception 'إجابة غير صحيحة'; end if;

  end_ts := public.shift_end_for(a.in_at);
  stale := now() > greatest(end_ts, a.in_at) + interval '6 hours';
  if not stale and (p_lat is null or p_lng is null) then
    raise exception 'فعّل GPS ثم أعد المحاولة (الموقع مطلوب لتسجيل الخروج)';
  end if;
  ans := case when stale then 'no' else coalesce(p_ot, a.ot_answer) end;
  closed_at_end := stale or (ans = 'no' and now() > end_ts and a.in_at < end_ts);
  final_out := case when stale then greatest(end_ts, a.in_at)
                    when closed_at_end then end_ts
                    else now() end;

  update public.attendance set
    out_at = final_out,
    out_recorded_at = case when closed_at_end then now() else null end,
    auto_closed = stale,
    ot_answer = ans,
    ot_minutes = case when ans = 'yes'
                      then greatest(0, floor(extract(epoch from (now() - greatest(end_ts, a.in_at))) / 60))::int
                      else 0 end,
    out_lat = p_lat, out_lng = p_lng, out_acc = p_acc, out_place = nullif(p_place, ''),
    out_photo = p_photo, out_photo_taken_at = p_photo_taken
  where id = a.id;

  -- استراحة مفتوحة تُغلق مع الخروج
  update public.breaks set end_at = greatest(start_at, final_out)
   where attendance_id = a.id and end_at is null;
end $$;

-- ---------- 6. الوسائط: كل ملف يراه من يحق له رؤية ما يرتبط به ----------
create function public.can_read_media(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_active() and (
    public.is_manager()
    or (storage.foldername(p_name))[1] = auth.uid()::text
    or exists (select 1 from public.task_photos tp
               where tp.path = p_name and public.is_task_member(tp.task_id))
    or exists (select 1 from public.messages m
               where m.path = p_name and (m.task_id is null or public.is_task_member(m.task_id)))
  );
$$;

drop policy media_read on storage.objects;
create policy media_read on storage.objects for select to authenticated
  using (bucket_id = 'media' and public.can_read_media(name));

-- ---------- 7. الصلاحيات والتحديث الفوري ----------
revoke all on public.presence, public.task_members, public.breaks from anon;
revoke all on function
  public.login_email(text), public.touch_presence(double precision, double precision, int),
  public.is_task_member(uuid), public.is_task_head(uuid), public._check_team(uuid, uuid[]),
  public.create_task(text, text, double precision, double precision, uuid, uuid[]),
  public.set_task_team(uuid, uuid, uuid[]),
  public.approve_request(uuid, uuid, uuid[]),
  public.break_start(double precision, double precision, int),
  public.break_end(double precision, double precision, int),
  public.can_read_media(text)
  from public, anon;
revoke all on function
  public.set_task_status(uuid, text), public.set_task_review(uuid, int, text),
  public.check_in(double precision, double precision, int, text, text, timestamptz),
  public.check_out(double precision, double precision, int, text, text, timestamptz, text),
  public.auto_close_stale(uuid)
  from anon;
grant execute on function public.login_email(text) to anon, authenticated;
grant execute on function public.is_task_member(uuid), public.is_task_head(uuid), public.can_read_media(text) to authenticated;
grant execute on function
  public.touch_presence(double precision, double precision, int),
  public.create_task(text, text, double precision, double precision, uuid, uuid[]),
  public.set_task_team(uuid, uuid, uuid[]),
  public.approve_request(uuid, uuid, uuid[]),
  public.break_start(double precision, double precision, int),
  public.break_end(double precision, double precision, int)
  to authenticated;

alter publication supabase_realtime add table public.breaks, public.presence, public.task_members;
