-- ══════════════════════════════════════════════════════
--  DFK Database Schema  –  bijgewerkt 2026
--  Plak dit in Supabase → SQL Editor → Run
--  (gebruik IF NOT EXISTS / IF NOT EXISTS zodat het
--   veilig is op een bestaande database)
-- ══════════════════════════════════════════════════════


-- ── 1. Profiles ───────────────────────────────────────
--  Één rij per gebruiker, gekoppeld aan auth.users.
--  Rollen:
--    rijder     – gewone klant/rijder
--    admin      – volledige toegang
--    office     – toegang tot admin-panel (zelfde als admin)
--    werkplaats – alleen werkplaats-pagina

CREATE TABLE IF NOT EXISTS profiles (
  id                    UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  account_id            UUID,                          -- zelfde als id (migratie-hulpveld)

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
    --                    'rijders' | 'werkplaats' | 'crew'

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
--  Één trackdag / trainingsdag.
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

-- Is de huidige gebruiker admin of office?
CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
      AND rol IN ('admin', 'office')
  );
$$ LANGUAGE sql SECURITY DEFINER;

-- Is de huidige gebruiker werkplaats, admin of heeft werkplaats-recht?
CREATE OR REPLACE FUNCTION is_werkplaats()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
      AND (
        rol IN ('admin', 'werkplaats')
        OR rechten @> ARRAY['werkplaats']
      )
  );
$$ LANGUAGE sql SECURITY DEFINER;


-- ── Bestaande policies verwijderen (zodat herinstallatie veilig is) ──

DROP POLICY IF EXISTS "Eigen profiel lezen"          ON profiles;
DROP POLICY IF EXISTS "Eigen profiel aanmaken"        ON profiles;
DROP POLICY IF EXISTS "Eigen profiel aanpassen"       ON profiles;
DROP POLICY IF EXISTS "Admin leest alle profielen"    ON profiles;
DROP POLICY IF EXISTS "Admin past alle profielen aan" ON profiles;
DROP POLICY IF EXISTS "Admin verwijdert profielen"    ON profiles;
DROP POLICY IF EXISTS "Werkplaats leest profielen"    ON profiles;

DROP POLICY IF EXISTS "Ingelogd ziet weekenden"  ON weekenden;
DROP POLICY IF EXISTS "Admin beheert weekenden"  ON weekenden;

DROP POLICY IF EXISTS "Iedereen ziet evenementen"  ON evenementen;
DROP POLICY IF EXISTS "Admin beheert evenementen"  ON evenementen;

DROP POLICY IF EXISTS "Eigen inschrijvingen zien"      ON inschrijvingen;
DROP POLICY IF EXISTS "Zichzelf inschrijven"           ON inschrijvingen;
DROP POLICY IF EXISTS "Eigen inschrijving verwijderen" ON inschrijvingen;
DROP POLICY IF EXISTS "Admin ziet alle inschrijvingen"    ON inschrijvingen;
DROP POLICY IF EXISTS "Admin beheert alle inschrijvingen" ON inschrijvingen;
DROP POLICY IF EXISTS "Werkplaats ziet alle inschrijvingen" ON inschrijvingen;

DROP POLICY IF EXISTS "Iedereen ziet circuits"  ON circuits;
DROP POLICY IF EXISTS "Admin beheert circuits"  ON circuits;

DROP POLICY IF EXISTS "Werkplaats beheert laad_status" ON laad_status;
DROP POLICY IF EXISTS "Admin ziet laad_status"         ON laad_status;


-- ── Profiles policies ─────────────────────────────────

CREATE POLICY "Eigen profiel lezen"
  ON profiles FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Eigen profiel aanmaken"
  ON profiles FOR INSERT WITH CHECK (auth.uid() = id);

CREATE POLICY "Eigen profiel aanpassen"
  ON profiles FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Admin leest alle profielen"
  ON profiles FOR SELECT USING (is_admin());

CREATE POLICY "Admin past alle profielen aan"
  ON profiles FOR UPDATE USING (is_admin());

CREATE POLICY "Admin verwijdert profielen"
  ON profiles FOR DELETE USING (is_admin());

CREATE POLICY "Werkplaats leest profielen"
  ON profiles FOR SELECT USING (is_werkplaats());


-- ── Weekenden policies ────────────────────────────────

CREATE POLICY "Ingelogd ziet weekenden"
  ON weekenden FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Admin beheert weekenden"
  ON weekenden FOR ALL USING (is_admin());


-- ── Evenementen policies ──────────────────────────────

CREATE POLICY "Iedereen ziet evenementen"
  ON evenementen FOR SELECT USING (true);

CREATE POLICY "Admin beheert evenementen"
  ON evenementen FOR ALL USING (is_admin());


-- ── Inschrijvingen policies ───────────────────────────

CREATE POLICY "Eigen inschrijvingen zien"
  ON inschrijvingen FOR SELECT USING (rijder_id = auth.uid());

CREATE POLICY "Zichzelf inschrijven"
  ON inschrijvingen FOR INSERT WITH CHECK (rijder_id = auth.uid());

CREATE POLICY "Eigen inschrijving verwijderen"
  ON inschrijvingen FOR DELETE USING (rijder_id = auth.uid());

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
--  Trigger: maak automatisch een leeg profiel aan
--  zodra een nieuwe gebruiker zich registreert
-- ══════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- ══════════════════════════════════════════════════════
--  Migratie – alleen uitvoeren op een bestaande DB
--  (sla over bij een verse installatie)
-- ══════════════════════════════════════════════════════

-- Profielen
-- ALTER TABLE profiles ADD COLUMN IF NOT EXISTS email TEXT;
-- ALTER TABLE profiles ADD COLUMN IF NOT EXISTS account_id UUID;
-- ALTER TABLE profiles ADD COLUMN IF NOT EXISTS rechten TEXT[] DEFAULT '{}';
-- ALTER TABLE profiles ALTER COLUMN rol TYPE TEXT;
-- ALTER TABLE profiles ADD CONSTRAINT profiles_rol_check
--   CHECK (rol IN ('rijder', 'admin', 'office', 'werkplaats'));

-- Evenementen
-- ALTER TABLE evenementen ADD COLUMN IF NOT EXISTS weekend_id UUID REFERENCES weekenden(id) ON DELETE SET NULL;

-- Inschrijvingen
-- ALTER TABLE inschrijvingen ADD COLUMN IF NOT EXISTS klasse TEXT;
-- ALTER TABLE inschrijvingen ADD COLUMN IF NOT EXISTS startnummer INT;
-- ALTER TABLE inschrijvingen ADD COLUMN IF NOT EXISTS opmerking TEXT;

-- Weekenden (nieuwe tabel – enkel nodig als die nog niet bestaat)
-- CREATE TABLE IF NOT EXISTS weekenden ( ... );  ← zie definitie hierboven

-- Circuits (nieuwe tabel)
-- CREATE TABLE IF NOT EXISTS circuits ( naam TEXT PRIMARY KEY );

-- Laad-status (nieuwe tabel)
-- CREATE TABLE IF NOT EXISTS laad_status ( ... );  ← zie definitie hierboven
