-- ══════════════════════════════════════════════════════
--  DFK Database Schema  –  gelijk met live (22 okt 2026)
--  Plak dit in Supabase → SQL Editor → Run
--
--  Volledig opnieuw uitvoerbaar: tabellen met IF NOT EXISTS,
--  functies met CREATE OR REPLACE, policies worden eerst
--  verwijderd en opnieuw aangemaakt.
--
--  Bevat ook de beveiliging uit beveiliging.sql (enkel admin
--  beheert rollen en rechten).
-- ══════════════════════════════════════════════════════


-- ── 1. Profiles ───────────────────────────────────────
--  Eén rij per rijder. Een account (auth.users) heeft een
--  eigen profiel (id = account_id = auth-id) en kan extra
--  rijders hebben (sub-rijders: eigen id, account_id = eigenaar).
--  Rollen:
--    rijder     – gewone klant/rijder
--    admin      – volledige toegang, enige die rollen/rechten beheert
--    office     – toegang tot admin-panel, geen rollenbeheer
--    werkplaats – alleen werkplaats-pagina

CREATE TABLE IF NOT EXISTS profiles (
  id                    UUID PRIMARY KEY,
  account_id            UUID,                          -- eigenaar-account (auth.users.id)

  -- Identiteit
  voornaam              TEXT,
  naam                  TEXT,
  email                 TEXT,
  geboortedatum         DATE,
  telefoon              TEXT,

  -- Toegang
  rol                   TEXT NOT NULL DEFAULT 'rijder'
                          CHECK (rol IN ('rijder', 'admin', 'office', 'werkplaats')),
  rechten               TEXT[]   DEFAULT '{}',
    -- mogelijke waarden: 'evenementen' | 'zichtbaarheid' | 'inschrijvingen'
    --                    'rijders' | 'werkplaats' | 'crew' (crew: enkel admin)

  -- Kart
  kart_type             TEXT     CHECK (kart_type IN ('eigen', 'huur')),

  -- Eigen kart
  klassen               TEXT[]   DEFAULT '{}',
  startnummer           INT,           -- legacy, vervangen door startnummers (JSONB)
  startnummers          JSONB    DEFAULT '{}',   -- bv. {"KA100": 42, "X30 Junior": 15}
  kampioenschappen      TEXT[]   DEFAULT '{}',
  kart_in_werkplaats    BOOLEAN  DEFAULT false,
  banden_in_werkplaats  BOOLEAN  DEFAULT false,
  bak_in_werkplaats     BOOLEAN  DEFAULT false,
  benzine               TEXT,

  -- Huurkart
  lengte                INT,
  gewicht               INT,
  huurkart_type         TEXT,
  uitrusting            TEXT[]   DEFAULT '{}',

  aangemaakt_op         TIMESTAMPTZ DEFAULT NOW()
);
--  Let op: id heeft live géén foreign key naar auth.users,
--  omdat sub-rijders geen eigen login hebben.


-- ── 2. Weekenden ──────────────────────────────────────
--  Een weekend groepeert één of meer evenementen.
--  zichtbaar = false  →  verborgen voor rijders.

CREATE TABLE IF NOT EXISTS weekenden (
  id            UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  naam          TEXT        NOT NULL,
  datum         DATE,                        -- eerste dag van het weekend
  zichtbaar     BOOLEAN     DEFAULT false,
  aangemaakt_op TIMESTAMPTZ DEFAULT NOW()
);


-- ── 3. Evenementen ────────────────────────────────────
--  Eén trackdag / trainingsdag.
--  weekend_id is optioneel; zonder weekend staat het los.

CREATE TABLE IF NOT EXISTS evenementen (
  id            UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  naam          TEXT        NOT NULL,
  datum         DATE        NOT NULL,
  type          TEXT,
  circuit       TEXT        NOT NULL,
  klassen       TEXT[]      DEFAULT '{}',
  deadline      TIMESTAMPTZ,
  weekend_id    UUID        REFERENCES weekenden(id) ON DELETE SET NULL,
  aangemaakt_op TIMESTAMPTZ DEFAULT NOW()
);


-- ── 4. Inschrijvingen ─────────────────────────────────
--  Elke rijder heeft per evenement maximaal één inschrijving.

CREATE TABLE IF NOT EXISTS inschrijvingen (
  id            UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  rijder_id     UUID        REFERENCES profiles(id)     ON DELETE CASCADE,
  event_id      UUID        REFERENCES evenementen(id)  ON DELETE CASCADE,
  klasse        TEXT,
  startnummer   INT,
  opmerking     TEXT,
  bevestigd_op  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (rijder_id, event_id)
);


-- ── 5. Circuits ───────────────────────────────────────
--  Lijst van beschikbare circuitnamen (vrij te beheren).

CREATE TABLE IF NOT EXISTS circuits (
  naam  TEXT PRIMARY KEY
);


-- ── 6. Laad-status (werkplaats) ───────────────────────
--  Bijhouden wat er al geladen is voor een rijder
--  in een bepaald weekend.

CREATE TABLE IF NOT EXISTS laad_status (
  weekend_id    UUID        REFERENCES weekenden(id)  ON DELETE CASCADE,
  rijder_id     UUID        REFERENCES profiles(id)   ON DELETE CASCADE,
  kart          BOOLEAN     DEFAULT false,
  banden        BOOLEAN     DEFAULT false,
  bak           BOOLEAN     DEFAULT false,
  huur          BOOLEAN     DEFAULT false,
  bijgewerkt_op TIMESTAMPTZ,
  PRIMARY KEY (weekend_id, rijder_id)
);


-- ══════════════════════════════════════════════════════
--  Indexen
-- ══════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_evenementen_datum       ON evenementen (datum);
CREATE INDEX IF NOT EXISTS idx_evenementen_weekend_id  ON evenementen (weekend_id);
CREATE INDEX IF NOT EXISTS idx_inschrijvingen_event_id ON inschrijvingen (event_id);
CREATE INDEX IF NOT EXISTS idx_inschrijvingen_rijder   ON inschrijvingen (rijder_id);
CREATE INDEX IF NOT EXISTS idx_laad_status_weekend     ON laad_status (weekend_id);
CREATE INDEX IF NOT EXISTS idx_profiles_account_id     ON profiles (account_id);


-- ══════════════════════════════════════════════════════
--  Row Level Security
-- ══════════════════════════════════════════════════════

ALTER TABLE profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekenden      ENABLE ROW LEVEL SECURITY;
ALTER TABLE evenementen    ENABLE ROW LEVEL SECURITY;
ALTER TABLE inschrijvingen ENABLE ROW LEVEL SECURITY;
ALTER TABLE circuits       ENABLE ROW LEVEL SECURITY;
ALTER TABLE laad_status    ENABLE ROW LEVEL SECURITY;


-- ── Hulpfuncties ──────────────────────────────────────

-- Is de huidige gebruiker admin of office? (toegang tot admin-panel)
CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
      AND rol IN ('admin', 'office')
  );
$$;

-- Is de huidige gebruiker echt admin (niet office)? (rollenbeheer)
CREATE OR REPLACE FUNCTION is_hoofdadmin()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
      AND rol = 'admin'
  );
$$;

-- Is de huidige gebruiker werkplaats, admin of heeft werkplaats-recht?
CREATE OR REPLACE FUNCTION is_werkplaats()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
      AND (
        rol IN ('admin', 'werkplaats')
        OR rechten @> ARRAY['werkplaats']
      )
  );
$$;


-- ── Bestaande policies verwijderen (zodat herinstallatie veilig is) ──

DROP POLICY IF EXISTS "Eigen profiel lezen"                   ON profiles;
DROP POLICY IF EXISTS "Eigen profiel aanmaken"                ON profiles;
DROP POLICY IF EXISTS "Eigen profiel aanpassen"               ON profiles;
DROP POLICY IF EXISTS "Account eigenaar ziet sub-rijders"     ON profiles;
DROP POLICY IF EXISTS "Gebruiker voegt extra rijder toe"      ON profiles;
DROP POLICY IF EXISTS "Account beheerder past sub-rijder aan" ON profiles;
DROP POLICY IF EXISTS "Admin leest alle profielen"            ON profiles;
DROP POLICY IF EXISTS "Admin maakt profielen aan"             ON profiles;
DROP POLICY IF EXISTS "Admin past alle profielen aan"         ON profiles;
DROP POLICY IF EXISTS "Admin verwijdert profielen"            ON profiles;
DROP POLICY IF EXISTS "Werkplaats leest profielen"            ON profiles;

DROP POLICY IF EXISTS "Ingelogd ziet weekenden"  ON weekenden;
DROP POLICY IF EXISTS "Admin beheert weekenden"  ON weekenden;

DROP POLICY IF EXISTS "Iedereen ziet evenementen"         ON evenementen;
DROP POLICY IF EXISTS "Rijders zien zichtbare evenementen" ON evenementen;
DROP POLICY IF EXISTS "Admin beheert evenementen"         ON evenementen;

DROP POLICY IF EXISTS "Eigen inschrijvingen zien"           ON inschrijvingen;
DROP POLICY IF EXISTS "Zichzelf inschrijven"                ON inschrijvingen;
DROP POLICY IF EXISTS "Eigen inschrijving verwijderen"      ON inschrijvingen;
DROP POLICY IF EXISTS "Account inschrijvingen bekijken"     ON inschrijvingen;
DROP POLICY IF EXISTS "Account inschrijving toevoegen"      ON inschrijvingen;
DROP POLICY IF EXISTS "Account inschrijving verwijderen"    ON inschrijvingen;
DROP POLICY IF EXISTS "Admin ziet alle inschrijvingen"      ON inschrijvingen;
DROP POLICY IF EXISTS "Admin beheert alle inschrijvingen"   ON inschrijvingen;
DROP POLICY IF EXISTS "Werkplaats ziet alle inschrijvingen" ON inschrijvingen;

DROP POLICY IF EXISTS "Iedereen ziet circuits"  ON circuits;
DROP POLICY IF EXISTS "Admin beheert circuits"  ON circuits;

DROP POLICY IF EXISTS "Werkplaats beheert laad_status" ON laad_status;
DROP POLICY IF EXISTS "Admin ziet laad_status"         ON laad_status;


-- ── Profiles policies ─────────────────────────────────
--  Rol, rechten en account_id worden extra bewaakt door de
--  trigger bescherm_profiel_rechten (zie onderaan).

CREATE POLICY "Eigen profiel lezen"
  ON profiles FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Eigen profiel aanmaken"
  ON profiles FOR INSERT WITH CHECK (auth.uid() = id);

CREATE POLICY "Eigen profiel aanpassen"
  ON profiles FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Account eigenaar ziet sub-rijders"
  ON profiles FOR SELECT USING (account_id = auth.uid());

CREATE POLICY "Gebruiker voegt extra rijder toe"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL AND account_id = auth.uid());

CREATE POLICY "Account beheerder past sub-rijder aan"
  ON profiles FOR UPDATE
  USING (account_id = auth.uid())
  WITH CHECK (account_id = auth.uid());

CREATE POLICY "Admin leest alle profielen"
  ON profiles FOR SELECT USING (is_admin());

CREATE POLICY "Admin maakt profielen aan"
  ON profiles FOR INSERT WITH CHECK (is_admin());

CREATE POLICY "Admin past alle profielen aan"
  ON profiles FOR UPDATE USING (is_admin());

-- Office mag enkel rijders verwijderen, admin alles
CREATE POLICY "Admin verwijdert profielen"
  ON profiles FOR DELETE
  USING (is_hoofdadmin() OR (is_admin() AND rol = 'rijder'));

CREATE POLICY "Werkplaats leest profielen"
  ON profiles FOR SELECT USING (is_werkplaats());


-- ── Weekenden policies ────────────────────────────────
--  Zichtbare weekenden zijn voor iedereen leesbaar (ook niet ingelogd).

CREATE POLICY "Ingelogd ziet weekenden"
  ON weekenden FOR SELECT
  USING (zichtbaar = true OR is_admin() OR is_werkplaats());

CREATE POLICY "Admin beheert weekenden"
  ON weekenden FOR ALL USING (is_admin());


-- ── Evenementen policies ──────────────────────────────

CREATE POLICY "Rijders zien zichtbare evenementen"
  ON evenementen FOR SELECT
  USING (
    weekend_id IS NULL
    OR EXISTS (
      SELECT 1 FROM weekenden w
      WHERE w.id = evenementen.weekend_id
        AND (w.zichtbaar = true OR is_admin() OR is_werkplaats())
    )
  );

CREATE POLICY "Admin beheert evenementen"
  ON evenementen FOR ALL USING (is_admin());


-- ── Inschrijvingen policies ───────────────────────────
--  Een account beheert de inschrijvingen van zichzelf én
--  van zijn sub-rijders.

CREATE POLICY "Eigen inschrijvingen zien"
  ON inschrijvingen FOR SELECT USING (rijder_id = auth.uid());

CREATE POLICY "Zichzelf inschrijven"
  ON inschrijvingen FOR INSERT WITH CHECK (rijder_id = auth.uid());

CREATE POLICY "Account inschrijvingen bekijken"
  ON inschrijvingen FOR SELECT
  USING (
    rijder_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = inschrijvingen.rijder_id
        AND profiles.account_id = auth.uid()
    )
  );

CREATE POLICY "Account inschrijving toevoegen"
  ON inschrijvingen FOR INSERT
  WITH CHECK (
    rijder_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = inschrijvingen.rijder_id
        AND profiles.account_id = auth.uid()
    )
  );

CREATE POLICY "Account inschrijving verwijderen"
  ON inschrijvingen FOR DELETE
  USING (
    rijder_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = inschrijvingen.rijder_id
        AND profiles.account_id = auth.uid()
    )
  );

CREATE POLICY "Admin ziet alle inschrijvingen"
  ON inschrijvingen FOR SELECT USING (is_admin());

CREATE POLICY "Admin beheert alle inschrijvingen"
  ON inschrijvingen FOR ALL USING (is_admin());

CREATE POLICY "Werkplaats ziet alle inschrijvingen"
  ON inschrijvingen FOR SELECT USING (is_werkplaats());


-- ── Circuits policies ─────────────────────────────────

CREATE POLICY "Iedereen ziet circuits"
  ON circuits FOR SELECT USING (true);

CREATE POLICY "Admin beheert circuits"
  ON circuits FOR ALL USING (is_admin());


-- ── Laad-status policies ──────────────────────────────

CREATE POLICY "Werkplaats beheert laad_status"
  ON laad_status FOR ALL USING (is_werkplaats());

CREATE POLICY "Admin ziet laad_status"
  ON laad_status FOR ALL USING (is_admin());


-- ══════════════════════════════════════════════════════
--  Functies die de website aanroept (RPC)
-- ══════════════════════════════════════════════════════

-- Extra rijder (sub-rijder) aanmaken onder het eigen account
CREATE OR REPLACE FUNCTION maak_extra_rijder(p_voornaam TEXT, p_naam TEXT, p_kart_type TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Niet ingelogd';
  END IF;
  v_id := gen_random_uuid();
  INSERT INTO profiles (id, account_id, voornaam, naam, rol, kart_type)
  VALUES (v_id, auth.uid(), p_voornaam, p_naam, 'rijder', p_kart_type);
  RETURN v_id;
END;
$$;

-- Login-account verwijderen (admin-panel). Office enkel rijders.
CREATE OR REPLACE FUNCTION delete_user_account(target_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_admin() THEN
    RAISE EXCEPTION 'Geen toegang';
  END IF;

  -- Office mag geen account van admin, office of werkplaats verwijderen
  IF NOT is_hoofdadmin() AND EXISTS (
    SELECT 1 FROM profiles
    WHERE id = target_user_id AND rol <> 'rijder'
  ) THEN
    RAISE EXCEPTION 'Alleen een admin kan crewaccounts verwijderen';
  END IF;

  -- Verwijder het auth account (cascadeert naar profiles via FK)
  DELETE FROM auth.users WHERE id = target_user_id;
END;
$$;


-- ══════════════════════════════════════════════════════
--  Triggers
-- ══════════════════════════════════════════════════════

-- Maak automatisch een leeg profiel aan zodra een nieuwe
-- gebruiker zich registreert
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- Bewaakt rol, rechten en account_id op profiles.
--  SECURITY INVOKER (standaard): zo is current_user de rol van
--  het API-verzoek ('authenticated' / 'anon'). Verzoeken met een
--  andere rol (SQL Editor, service_role, security-definer-functies)
--  worden niet beperkt.
CREATE OR REPLACE FUNCTION bescherm_profiel_rechten()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  -- Alleen verzoeken via de website/API controleren
  IF current_user NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;

  -- Alleen admin mag rollen en rechten beheren
  IF public.is_hoofdadmin() THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Nieuw profiel door office of een gewone gebruiker: altijd rijder zonder extra rechten
    NEW.rol     := 'rijder';
    NEW.rechten := '{}';
    IF NOT public.is_admin()
       AND NEW.account_id IS NOT NULL AND NEW.account_id <> auth.uid() THEN
      RAISE EXCEPTION 'Je kunt geen profiel aan een ander account koppelen'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NEW.rol IS DISTINCT FROM OLD.rol
     OR NEW.rechten IS DISTINCT FROM OLD.rechten THEN
    RAISE EXCEPTION 'Alleen een admin kan rollen of rechten wijzigen'
      USING ERRCODE = '42501';
  END IF;

  IF NOT public.is_admin()
     AND NEW.account_id IS DISTINCT FROM OLD.account_id
     AND NEW.account_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Je kunt geen profiel aan een ander account koppelen'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bescherm_profiel_rechten ON profiles;

CREATE TRIGGER bescherm_profiel_rechten
  BEFORE INSERT OR UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION bescherm_profiel_rechten();


-- ══════════════════════════════════════════════════════
--  Realtime
--  De website luistert naar wijzigingen in deze tabellen.
-- ══════════════════════════════════════════════════════

DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['evenementen', 'weekenden', 'inschrijvingen', 'laad_status'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END;
$$;


-- ══════════════════════════════════════════════════════
--  Niet in dit bestand
-- ══════════════════════════════════════════════════════
--  • rls_auto_enable(): standaardfunctie van Supabase die RLS
--    automatisch aanzet op nieuwe tabellen. Wordt door Supabase
--    zelf beheerd.
--  • Auth-instellingen (registratie open, geen e-mailbevestiging)
--    staan in het dashboard: Authentication → Sign In / Providers.
