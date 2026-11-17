-- ============================================================
-- ميدان: التحديث الثالث (schema_v3)
-- بعد schema_v2.sql: الصق هذا الملف كاملاً في SQL Editor واضغط Run.
-- آمن لإعادة التشغيل أكثر من مرة.
-- ============================================================

-- ---------- 1. تتبع الموقع: يُحفظ أثناء الدوام فقط ----------
alter table public.presence add column if not exists loc_src text;   -- 'gps' أو 'net' (الشبكة)

-- نسخة جديدة بمعامل مصدر الموقع. الموقع يُقبل فقط إن كان للموظف دخول مفتوح (أي داخل الدوام).
drop function if exists public.touch_presence(double precision, double precision, int);
create or replace function public.touch_presence(
  p_lat double precision default null, p_lng double precision default null, p_acc int default null,
  p_src text default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_active() then return; end if;
  if p_lat is not null and (p_lng is null or not exists (
       select 1 from public.attendance where user_id = auth.uid() and out_at is null)) then
    p_lat := null; p_lng := null; p_acc := null; p_src := null;
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

revoke all on function public.touch_presence(double precision, double precision, int, text) from public, anon;
grant execute on function public.touch_presence(double precision, double precision, int, text) to authenticated;

-- عند تسجيل الخروج (يدوياً أو تلقائياً) يُمسح آخر موقع محفوظ: لا يبقى موقع بعد انتهاء الدوام
create or replace function public.clear_presence_loc() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.out_at is null and new.out_at is not null then
    update public.presence
       set lat = null, lng = null, acc = null, loc_src = null, loc_at = null
     where user_id = new.user_id;
  end if;
  return new;
end $$;

drop trigger if exists attendance_clear_loc on public.attendance;
create trigger attendance_clear_loc after update of out_at on public.attendance
  for each row execute function public.clear_presence_loc();

-- ---------- 2. اللاسلكي: اسم قناة سري لكل محادثة ----------
-- الصوت يُبث مباشرة عبر Realtime ولا يُخزَّن. اسم القناة مفتاح عشوائي لا يعرفه إلا من له حق
-- دخول المحادثة (الفريق العام: كل الأعضاء الفعّالين، قناة المهمة: أعضاء المهمة والمدير فقط).
create table if not exists public.ptt_keys (
  chan text primary key,
  k text not null default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
);
alter table public.ptt_keys enable row level security;   -- بلا سياسات: لا وصول مباشر من التطبيق
revoke all on public.ptt_keys from anon, authenticated;

create or replace function public.ptt_topic(p_chan text) returns text
language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  if not public.is_active() then raise exception 'غير مصرّح'; end if;
  if p_chan is null or p_chan = '' then raise exception 'قناة غير صحيحة'; end if;
  if p_chan <> 'general' and not public.is_task_member(p_chan::uuid) then raise exception 'غير مصرّح'; end if;
  insert into public.ptt_keys (chan) values (p_chan) on conflict (chan) do nothing;
  select k into v from public.ptt_keys where chan = p_chan;
  return 'ptt-' || v;
end $$;

revoke all on function public.ptt_topic(text) from public, anon;
grant execute on function public.ptt_topic(text) to authenticated;
