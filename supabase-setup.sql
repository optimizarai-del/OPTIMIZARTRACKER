-- ============================================================
-- OPTIMIZAR TRACKER — Setup de Supabase
-- Ejecutar en: Supabase Dashboard → SQL Editor → New query
-- ============================================================

-- ── 1. TABLA DE PERFILES DE USUARIO ─────────────────────────
-- Extiende auth.users con datos del tracker
CREATE TABLE IF NOT EXISTS public.tracker_users (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  email       TEXT,
  role        TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
  avatar_color TEXT DEFAULT '#38bdf8',
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ── 2. TABLA DE TURNOS (SHIFTS) ──────────────────────────────
CREATE TABLE IF NOT EXISTS public.tracker_shifts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES public.tracker_users(id) ON DELETE CASCADE,
  fecha           DATE NOT NULL,
  inicio          TIMESTAMPTZ NOT NULL,
  fin             TIMESTAMPTZ NOT NULL,
  total_segundos  INTEGER NOT NULL DEFAULT 0,
  total_horas     NUMERIC(6,2) NOT NULL DEFAULT 0,
  entradas        JSONB DEFAULT '[]'::jsonb,   -- array de { timestamp, desc, doubt, images[], elapsedSecs }
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Índices para performance
CREATE INDEX IF NOT EXISTS idx_shifts_user_id ON public.tracker_shifts(user_id);
CREATE INDEX IF NOT EXISTS idx_shifts_fecha   ON public.tracker_shifts(fecha);
CREATE INDEX IF NOT EXISTS idx_shifts_user_fecha ON public.tracker_shifts(user_id, fecha);

-- ── 3. ROW LEVEL SECURITY (RLS) ──────────────────────────────
ALTER TABLE public.tracker_users  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tracker_shifts ENABLE ROW LEVEL SECURITY;

-- Políticas para tracker_users
-- Un usuario puede ver su propio perfil
CREATE POLICY "users_select_own" ON public.tracker_users
  FOR SELECT USING (auth.uid() = id);

-- Los admins pueden ver todos los perfiles
CREATE POLICY "admins_select_all_users" ON public.tracker_users
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.tracker_users
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- Los admins pueden insertar/actualizar perfiles
CREATE POLICY "admins_insert_users" ON public.tracker_users
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.tracker_users
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

CREATE POLICY "admins_update_users" ON public.tracker_users
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM public.tracker_users
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

CREATE POLICY "admins_delete_users" ON public.tracker_users
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM public.tracker_users
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- Políticas para tracker_shifts
-- Usuario puede ver/insertar/actualizar sus propios turnos
CREATE POLICY "users_select_own_shifts" ON public.tracker_shifts
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "users_insert_own_shifts" ON public.tracker_shifts
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "users_update_own_shifts" ON public.tracker_shifts
  FOR UPDATE USING (auth.uid() = user_id);

-- Admins pueden ver todos los turnos
CREATE POLICY "admins_select_all_shifts" ON public.tracker_shifts
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.tracker_users
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- Admins pueden eliminar cualquier turno
CREATE POLICY "admins_delete_shifts" ON public.tracker_shifts
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM public.tracker_users
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- ── 4. TRIGGER: AUTO-CREAR PERFIL AL REGISTRARSE ─────────────
-- Cuando se crea un usuario en Supabase Auth, se crea su perfil automáticamente
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
  INSERT INTO public.tracker_users (id, name, email, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'role', 'user')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ── 5. STORAGE BUCKET PARA CAPTURAS ──────────────────────────
-- Ejecutar en: Supabase Dashboard → Storage → New bucket
-- O ejecutar esta query (requiere permisos de storage admin):

INSERT INTO storage.buckets (id, name, public)
VALUES ('tracker-captures', 'tracker-captures', true)
ON CONFLICT (id) DO NOTHING;

-- Política de storage: usuarios autenticados pueden subir
CREATE POLICY "auth_users_upload" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'tracker-captures' AND auth.role() = 'authenticated'
  );

-- Cualquiera puede leer (bucket público)
CREATE POLICY "public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'tracker-captures');

-- ── 6. USUARIO ADMIN INICIAL ──────────────────────────────────
-- OPCIÓN A: Crear desde Supabase Dashboard → Authentication → Users
--   Email: admin@tuempresa.com  |  Password: (elegir)
--
-- OPCIÓN B: Usar la Auth API con service_role key desde tu backend:
--
--   const { data } = await supabase.auth.admin.createUser({
--     email: 'admin@tuempresa.com',
--     password: 'TuPasswordSegura123',
--     email_confirm: true,
--     user_metadata: { name: 'Admin Principal', role: 'admin' }
--   })
--
-- Después de crear el usuario, actualizar su rol:
-- UPDATE public.tracker_users SET role = 'admin' WHERE email = 'admin@tuempresa.com';

-- ── 7. DATOS DE EJEMPLO (OPCIONAL) ───────────────────────────
-- Descomentar para insertar datos de prueba después de crear usuarios reales

/*
-- Ver usuarios existentes
SELECT id, name, email, role FROM public.tracker_users;

-- Insertar un turno de prueba (reemplazar USER_ID con el UUID real)
INSERT INTO public.tracker_shifts (user_id, fecha, inicio, fin, total_segundos, total_horas, entradas)
VALUES (
  'USER_ID_AQUI',
  CURRENT_DATE,
  NOW() - INTERVAL '3 hours',
  NOW(),
  10800,
  3.00,
  '[
    {
      "timestamp": "2026-03-16T09:00:00Z",
      "desc": "Revisión de código del módulo de autenticación",
      "doubt": "",
      "images": [],
      "elapsedSecs": 3600
    },
    {
      "timestamp": "2026-03-16T10:30:00Z",
      "desc": "Implementación de tests unitarios para el módulo de pagos",
      "doubt": "No estoy seguro de cómo mockear la API externa de pagos",
      "images": [],
      "elapsedSecs": 7200
    }
  ]'::jsonb
);
*/

-- ============================================================
-- VERIFICACIÓN FINAL
-- ============================================================
-- Ejecutar para confirmar que todo está OK:
SELECT 
  table_name,
  (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = t.table_name) as columns
FROM information_schema.tables t
WHERE table_schema = 'public' 
  AND table_name IN ('tracker_users', 'tracker_shifts')
ORDER BY table_name;
