// ─────────────────────────────────────────────
//  DFK – Supabase configuratie
//  Vul hieronder jouw Project URL en Anon Key in
//  (te vinden in Supabase → Project Settings → API)
// ─────────────────────────────────────────────

const SUPABASE_URL  = 'https://zkcowflzazhihdmhcaeo.supabase.co';
const SUPABASE_KEY  = 'sb_publishable_7kztQEoAdZvSNNnhaazKyw_ftT16HvZ';

function esc(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const _supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: {
    persistSession:     true,
    detectSessionInUrl: false,   // e-mail+wachtwoord heeft geen URL-token nodig
    autoRefreshToken:   true,
  }
});

// ── Auth helpers ──────────────────────────────

async function getSession() {
  const { data } = await _supabase.auth.getSession();
  return data.session;
}

async function getUser() {
  const { data } = await _supabase.auth.getUser();
  return data.user;
}

async function getProfile(userId) {
  const { data } = await _supabase
    .from('profiles')
    .select('*')
    .eq('id', userId)
    .single();
  return data;
}

// Redirect naar login als niet ingelogd
async function requireAuth() {
  const session = await getSession();
  if (!session) { window.location.href = 'index.html'; return null; }
  return session;
}

// Redirect naar login als geen admin- of office-rol
async function requireAdmin() {
  const session = await requireAuth();
  if (!session) return null;
  const profile = await getProfile(session.user.id);
  if (!profile || !['admin', 'office'].includes(profile.rol)) {
    window.location.href = 'evenementen.html';
    return null;
  }
  return { session, profile };
}

// Redirect naar login als geen werkplaats- of admin-rol (office heeft geen toegang)
async function requireWerkplaats() {
  const session = await requireAuth();
  if (!session) return null;
  const profile = await getProfile(session.user.id);
  const heeftToegang = profile && (
    profile.rol === 'admin' ||
    profile.rol === 'werkplaats' ||
    (Array.isArray(profile.rechten) && profile.rechten.includes('werkplaats'))
  );
  if (!heeftToegang) {
    window.location.href = startpaginaVoorRol(profile?.rol);
    return null;
  }
  return { session, profile };
}

// Geeft de juiste startpagina terug op basis van rol
function startpaginaVoorRol(rol) {
  if (rol === 'admin')      return 'admin.html';
  if (rol === 'office')     return 'admin.html';
  if (rol === 'werkplaats') return 'werkplaats.html';
  return 'evenementen.html';
}
