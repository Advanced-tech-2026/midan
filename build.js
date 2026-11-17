// Usage: APP=manager|member node build.js  -> creates www/ and capacitor.config.json
const fs = require('fs');
const app = process.env.APP;
if (!['manager', 'member'].includes(app)) { console.error('Set APP=manager or APP=member'); process.exit(1); }
const names = { manager: 'ميدان - المدير', member: 'ميدان - الموظف' };
const ids = { manager: 'com.midan.manager', member: 'com.midan.member' };
let html = fs.readFileSync('src/index.html', 'utf8');
html = html.replace("var APP_MODE = 'both';", "var APP_MODE = '" + app + "';");
html = html.replace('<title>ميدان</title>', '<title>' + names[app] + '</title>');
const cfg = JSON.parse(fs.readFileSync('config.json', 'utf8'));
html = html.replace("var WEB_URL = '';", "var WEB_URL = " + JSON.stringify(cfg.webUrl || '') + ";");
html = html.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^"]*supabase\.js"><\/script>/, '<script src="supabase.js"></script>');
html = html.replace('سجّل الدخول باسم المستخدم (أو البريد)', (app === 'manager' ? 'تطبيق المدير والمشرفين. ' : 'تطبيق الموظف. ') + 'سجّل الدخول باسم المستخدم (أو البريد)');
fs.rmSync('www', { recursive: true, force: true });
fs.mkdirSync('www');
fs.writeFileSync('www/index.html', html);
fs.copyFileSync('node_modules/@supabase/supabase-js/dist/umd/supabase.js', 'www/supabase.js');
fs.writeFileSync('capacitor.config.json', JSON.stringify({
  appId: ids[app], appName: names[app], webDir: 'www',
  android: { allowMixedContent: false },
  plugins: { LocalNotifications: { smallIcon: 'ic_launcher', iconColor: '#1f6f5c' } }
}, null, 2));
console.log('built', app);
