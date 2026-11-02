// Edge Function "mant-usuarios" (proyecto ncughlkgdgigwkggnxri).
// Lo que la app no puede hacer con su clave pública, porque necesita la service role:
//   crear      -> el admin_empresa da de alta a alguien (email, rol, barcos). Si el email es nuevo se crea la
//                 cuenta con una contraseña temporal que se devuelve UNA vez; si ya tenía cuenta, solo se le da acceso.
//   clave_temporal -> el admin genera una contraseña temporal nueva para un usuario que está SOLO en sus empresas.
//   cambiar_mi_clave -> cualquier usuario cambia su contraseña (pide la actual, salvo en el primer ingreso).
// Quien llama se identifica con su sesión (Authorization: Bearer <token>). Los accesos se guardan con la RPC
// mant_accesos_guardar usando la sesión de quien llama, así las reglas RLS vuelven a controlar todo.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const URL_SUPABASE = Deno.env.get('SUPABASE_URL')!;
const CLAVE_ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const CLAVE_SERVICIO = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ROLES = ['admin_empresa', 'jefe', 'operador', 'lectura'];

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const respuesta = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...CORS, 'Content-Type': 'application/json' } });
const error = (mensaje: string, estado = 400) => respuesta({ error: mensaje }, estado);

// Contraseña temporal legible (sin 0/O, 1/l/I): XXXX-XXXX-XXXX
function claveTemporal(): string {
  const letras = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  const azar = crypto.getRandomValues(new Uint32Array(12));
  const c = [...azar].map(n => letras[n % letras.length]).join('');
  return `${c.slice(0, 4)}-${c.slice(4, 8)}-${c.slice(8, 12)}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return error('Método no permitido', 405);

  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return error('Tenés que iniciar sesión', 401);
  const servicio = createClient(URL_SUPABASE, CLAVE_SERVICIO, { auth: { persistSession: false } });
  const { data: quien, error: eQuien } = await servicio.auth.getUser(token);
  if (eQuien || !quien?.user) return error('Tu sesión venció: volvé a entrar', 401);
  const yo = quien.user;
  // Cliente con la sesión de quien llama: lo que haga pasa por RLS
  const comoYo = createClient(URL_SUPABASE, CLAVE_ANON, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  let cuerpo: Record<string, unknown>;
  try { cuerpo = await req.json(); } catch { return error('Pedido inválido'); }
  const accion = cuerpo.accion;

  // Empresas donde quien llama es admin
  const { data: misAdmin } = await servicio.from('mant_accesos').select('empresa_id')
    .eq('user_id', yo.id).eq('rol', 'admin_empresa');
  const empresasAdmin = new Set((misAdmin || []).map(a => a.empresa_id));

  try {
    if (accion === 'crear') {
      const empresa = Number(cuerpo.empresa_id);
      const email = String(cuerpo.email || '').trim().toLowerCase();
      const rol = String(cuerpo.rol || '');
      const barcos = Array.isArray(cuerpo.barcos) ? cuerpo.barcos.map(Number).filter(Number.isInteger) : [];
      if (!empresasAdmin.has(empresa)) return error('Solo el administrador de la empresa puede dar de alta usuarios', 403);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return error('El email no es válido');
      if (!ROLES.includes(rol)) return error('Elegí un rol');
      if (rol !== 'admin_empresa' && !barcos.length) return error('Elegí al menos un barco');

      // ¿Ya tiene cuenta? (todas las cuentas tienen su fila en mant_perfiles)
      const { data: perfil } = await servicio.from('mant_perfiles').select('user_id').eq('email', email).maybeSingle();
      let userId = perfil?.user_id as string | undefined;
      let clave: string | null = null;
      if (userId) {
        if (userId === yo.id) return error('No podés cambiar tu propio acceso');
        const { count } = await servicio.from('mant_accesos').select('id', { count: 'exact', head: true })
          .eq('user_id', userId).eq('empresa_id', empresa);
        if (count) return error('Ese email ya tiene acceso a tu empresa: cambiale el rol o los barcos en la lista');
      } else {
        clave = claveTemporal();
        const { data: nuevo, error: eNuevo } = await servicio.auth.admin.createUser({ email, password: clave, email_confirm: true });
        if (eNuevo || !nuevo?.user) {
          return error(/already|registered|exists/i.test(eNuevo?.message || '') ? 'Ese email ya tiene una cuenta' : 'No se pudo crear el usuario');
        }
        userId = nuevo.user.id;
        const { error: ePerfil } = await servicio.from('mant_perfiles').insert({ user_id: userId, email, debe_cambiar_clave: true });
        if (ePerfil) { await servicio.auth.admin.deleteUser(userId); return error('No se pudo crear el usuario'); }
      }
      const { error: eAcc } = await comoYo.rpc('mant_accesos_guardar', { p_user: userId, p_empresa: empresa, p_rol: rol, p_barcos: barcos });
      if (eAcc) {
        if (clave) await servicio.auth.admin.deleteUser(userId!);  // no dejar una cuenta nueva sin acceso
        return error(eAcc.message || 'No se pudo dar el acceso', eAcc.code === '42501' ? 403 : 400);
      }
      return respuesta({ ok: true, user_id: userId, email, clave_temporal: clave, ya_tenia_cuenta: !clave });
    }

    if (accion === 'clave_temporal') {
      const userId = String(cuerpo.user_id || '');
      if (!empresasAdmin.size) return error('Solo el administrador de la empresa puede hacer esto', 403);
      if (userId === yo.id) return error('Para tu propia contraseña usá "Cambiar mi contraseña"');
      const { data: accesos } = await servicio.from('mant_accesos').select('empresa_id').eq('user_id', userId);
      // Solo usuarios que están únicamente en empresas donde quien llama es admin
      if (!accesos?.length || accesos.some(a => !empresasAdmin.has(a.empresa_id))) {
        return error('Solo podés hacerlo con usuarios que están únicamente en tu empresa', 403);
      }
      const clave = claveTemporal();
      const { error: eClave } = await servicio.auth.admin.updateUserById(userId, { password: clave });
      if (eClave) return error('No se pudo cambiar la contraseña');
      await servicio.from('mant_perfiles').update({ debe_cambiar_clave: true }).eq('user_id', userId);
      return respuesta({ ok: true, clave_temporal: clave });
    }

    if (accion === 'cambiar_mi_clave') {
      const nueva = String(cuerpo.nueva || '');
      const actual = String(cuerpo.actual || '');
      if (nueva.length < 8) return error('La contraseña nueva tiene que tener al menos 8 caracteres');
      const { data: perfil } = await servicio.from('mant_perfiles').select('debe_cambiar_clave').eq('user_id', yo.id).maybeSingle();
      // Fuera del primer ingreso, se pide la contraseña actual
      if (!perfil?.debe_cambiar_clave) {
        const prueba = createClient(URL_SUPABASE, CLAVE_ANON, { auth: { persistSession: false } });
        const { error: eActual } = await prueba.auth.signInWithPassword({ email: yo.email!, password: actual });
        if (eActual) return error('La contraseña actual no es correcta');
        if (actual === nueva) return error('La contraseña nueva tiene que ser distinta de la actual');
      }
      const { error: eClave } = await servicio.auth.admin.updateUserById(yo.id, { password: nueva });
      if (eClave) return error(/weak|short|pwned|leaked/i.test(eClave.message) ? 'Esa contraseña es muy débil: probá con otra más larga' : 'No se pudo cambiar la contraseña');
      await servicio.from('mant_perfiles').upsert({ user_id: yo.id, email: yo.email, debe_cambiar_clave: false });
      return respuesta({ ok: true });
    }

    return error('Acción desconocida');
  } catch (_e) {
    return error('Ocurrió un error inesperado', 500);
  }
});
