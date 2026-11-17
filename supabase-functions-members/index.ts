// دالة Edge باسم: members
// تُنشئ حسابات الأعضاء وتعيد تعيين كلمات المرور. مفتاح الخدمة يبقى على الخادم ولا يصل إلى التطبيق.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'طريقة غير مسموحة' }, 405);
  try {
    // 1) من المتصل؟ يجب أن يكون مديراً فعّالاً
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    const { data: u, error: ue } = await admin.auth.getUser(token);
    if (ue || !u?.user) return json({ error: 'سجّل الدخول أولاً' }, 401);
    const { data: caller } = await admin.from('profiles').select('id, role, active').eq('id', u.user.id).maybeSingle();
    if (!caller || !caller.active || !['owner', 'admin', 'supervisor'].includes(caller.role)) {
      return json({ error: 'هذه العملية للمدير فقط' }, 403);
    }
    const isTrueOwner = caller.role === 'owner';                      // صاحب الفريق الأصلي
    const isOwner = caller.role === 'owner' || caller.role === 'admin'; // صلاحيات صاحب الفريق (المدير مثله)

    const body = await req.json();
    const action = String(body.action || '');

    if (action === 'create') {
      const username = String(body.username || '').trim().toLowerCase();
      const name = String(body.name || '').trim();
      const password = String(body.password || '');
      const role = body.role === 'admin' ? 'admin' : body.role === 'supervisor' ? 'supervisor' : 'member';
      const realEmail = String(body.email || '').trim().toLowerCase();
      if (!/^[a-z0-9._-]{3,30}$/.test(username)) return json({ error: 'اسم المستخدم: 3 إلى 30 حرفًا إنكليزيًا أو أرقامًا أو (. _ -)' }, 400);
      if (!name) return json({ error: 'اكتب اسم العضو' }, 400);
      if (password.length < 8) return json({ error: 'كلمة المرور 8 أحرف على الأقل' }, 400);
      if (role === 'supervisor' && !isOwner) return json({ error: 'صاحب الفريق أو المدير فقط يضيف مشرفًا' }, 403);
      if (role === 'admin' && !isTrueOwner) return json({ error: 'صاحب الفريق فقط يضيف مديرًا' }, 403);
      if (realEmail && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(realEmail)) return json({ error: 'البريد غير صحيح' }, 400);

      const { data: taken } = await admin.from('profiles').select('id').eq('username', username).maybeSingle();
      if (taken) return json({ error: 'اسم المستخدم مستخدم من قبل' }, 409);

      const { data: created, error: ce } = await admin.auth.admin.createUser({
        email: realEmail || `${username}@midan.app`,
        password,
        email_confirm: true,
        user_metadata: { name, username },
      });
      if (ce || !created?.user) {
        const m = ce?.message || '';
        return json({ error: /already|registered|exists/i.test(m) ? 'هذا البريد مسجّل من قبل' : 'تعذّر إنشاء الحساب: ' + m }, 400);
      }
      if (role === 'supervisor' || role === 'admin') {
        await admin.from('profiles').update({ role }).eq('id', created.user.id);
      }
      return json({ ok: true, id: created.user.id, username });
    }

    if (action === 'reset_password' || action === 'update') {
      const id = String(body.user_id || '');
      const { data: target } = await admin.from('profiles').select('id, role').eq('id', id).maybeSingle();
      if (!target) return json({ error: 'العضو غير موجود' }, 404);
      if (target.role !== 'member' && !isOwner) return json({ error: 'صاحب الفريق أو المدير فقط يعدّل المشرفين' }, 403);
      if (target.role === 'admin' && !isTrueOwner && target.id !== caller.id) return json({ error: 'صاحب الفريق فقط يعدّل المدير' }, 403);
      if (target.role === 'owner' && target.id !== caller.id) return json({ error: 'لا يمكن تعديل صاحب الفريق' }, 403);

      if (action === 'reset_password') {
        const password = String(body.password || '');
        if (password.length < 8) return json({ error: 'كلمة المرور 8 أحرف على الأقل' }, 400);
        const { error } = await admin.auth.admin.updateUserById(id, { password });
        if (error) return json({ error: 'تعذّر تغيير كلمة المرور: ' + error.message }, 400);
        return json({ ok: true });
      }
      const patch: Record<string, string> = {};
      if (typeof body.name === 'string' && body.name.trim()) patch.name = body.name.trim();
      if (typeof body.username === 'string' && body.username.trim()) {
        const un = body.username.trim().toLowerCase();
        if (!/^[a-z0-9._-]{3,30}$/.test(un)) return json({ error: 'اسم المستخدم غير صالح' }, 400);
        patch.username = un;
      }
      if (!Object.keys(patch).length) return json({ error: 'لا يوجد تغيير' }, 400);
      const { error } = await admin.from('profiles').update(patch).eq('id', id);
      if (error) return json({ error: /duplicate|unique/i.test(error.message) ? 'اسم المستخدم مستخدم من قبل' : error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: 'عملية غير معروفة' }, 400);
  } catch (e) {
    return json({ error: 'خطأ في الخادم: ' + (e as Error).message }, 500);
  }
});
