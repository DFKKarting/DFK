-- ══════════════════════════════════════════════════════
--  DFK – Beveiliging rollen & rechten
--  Plak dit in Supabase → SQL Editor → Run
--
--  Probleem: de policy "Eigen profiel aanpassen" laat een
--  gebruiker ELKE kolom van zijn profiel wijzigen, ook
--  `rol` en `rechten`. Daardoor kon iedereen die een account
--  aanmaakt zichzelf admin maken via de API.
--
--  Daarnaast mag office geen crewprofielen of -accounts meer
--  verwijderen (alleen rijders), en controleert de database
--  bij in- en uitschrijven de deadline en zichtbaarheid, met
--  maximale lengtes en max. 10 extra rijders per account.
--
--  Oplossing: een trigger die rol, rechten en account_id
--  bewaakt. Alleen een gebruiker met rol 'admin' mag rollen
--  en rechten wijzigen (office dus niet). De SQL Editor, het
--  Supabase-dashboard en
--  SECURITY DEFINER-functies (zoals handle_new_user en
--  maak_extra_rijder) blijven gewoon werken.
--
--  Veilig om meerdere keren uit te voeren.
-- ══════════════════════════════════════════════════════


-- ── 1. Is de huidige gebruiker echt admin (niet office)? ──

CREATE OR REPLACE FUNCTION public.is_hoofdadmin()
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


-- ── 2. Trigger-functie ────────────────────────────────
--  SECURITY INVOKER (standaard): zo is current_user de rol van
--  het API-verzoek ('authenticated' / 'anon'). Verzoeken met een
--  andere rol (postgres, service_role, security-definer-functies)
--  worden niet beperkt.

CREATE OR REPLACE FUNCTION public.bescherm_profiel_rechten()
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


-- ── 3. Trigger koppelen aan profiles ──────────────────

DROP TRIGGER IF EXISTS bescherm_profiel_rechten ON public.profiles;

CREATE TRIGGER bescherm_profiel_rechten
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.bescherm_profiel_rechten();


-- ── 4. Hulpfuncties: vaste search_path (Supabase-advies) ──

ALTER FUNCTION public.is_admin()      SET search_path = public;
ALTER FUNCTION public.is_werkplaats() SET search_path = public;


-- ── 5. Profielen verwijderen: office enkel rijders ────
--  Anders kon office het profiel van een admin (of ander
--  crewlid) verwijderen en zo diens rechten afnemen.

DROP POLICY IF EXISTS "Admin verwijdert profielen" ON public.profiles;

CREATE POLICY "Admin verwijdert profielen"
  ON public.profiles FOR DELETE
  USING (public.is_hoofdadmin() OR (public.is_admin() AND rol = 'rijder'));


-- ── 6. Accounts verwijderen: office enkel rijders ─────

CREATE OR REPLACE FUNCTION public.delete_user_account(target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Geen toegang';
  END IF;

  -- Office mag geen account van admin, office of werkplaats verwijderen
  IF NOT public.is_hoofdadmin() AND EXISTS (
    SELECT 1 FROM profiles
    WHERE id = target_user_id AND rol <> 'rijder'
  ) THEN
    RAISE EXCEPTION 'Alleen een admin kan crewaccounts verwijderen';
  END IF;

  -- Verwijder het auth account (cascadeert naar profiles via FK)
  DELETE FROM auth.users WHERE id = target_user_id;
END;
$$;


-- ── 7. Inschrijven/uitschrijven: deadline en zichtbaarheid ──
--  Rijders kunnen zich enkel in- of uitschrijven voor een
--  zichtbaar evenement dat nog niet begonnen is en waarvan de
--  deadline nog niet voorbij is. Admin/office mag altijd.

CREATE OR REPLACE FUNCTION public.controleer_inschrijving()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_event_id UUID := CASE WHEN TG_OP = 'DELETE' THEN OLD.event_id ELSE NEW.event_id END;
  v_ok       BOOLEAN;
BEGIN
  -- Alleen verzoeken via de website/API controleren
  IF current_user NOT IN ('authenticated', 'anon') THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  IF public.is_admin() THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  SELECT
    e.datum > (now() AT TIME ZONE 'Europe/Brussels')::date
    AND (e.deadline IS NULL OR e.deadline > now())
    AND (e.weekend_id IS NULL OR w.zichtbaar = true)
  INTO v_ok
  FROM evenementen e
  LEFT JOIN weekenden w ON w.id = e.weekend_id
  WHERE e.id = v_event_id;

  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'Inschrijvingen voor dit evenement zijn gesloten'
      USING ERRCODE = '42501';
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS controleer_inschrijving ON public.inschrijvingen;

CREATE TRIGGER controleer_inschrijving
  BEFORE INSERT OR UPDATE OR DELETE ON public.inschrijvingen
  FOR EACH ROW EXECUTE FUNCTION public.controleer_inschrijving();


-- ── 8. Maximale lengtes (tegen misbruik met enorme teksten) ──
--  NOT VALID: bestaande rijen worden niet gecontroleerd, enkel
--  nieuwe en gewijzigde. Zo kan dit nooit falen op oude data.

ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_lengtes_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_lengtes_check CHECK (
  coalesce(length(voornaam), 0)      <= 100 AND
  coalesce(length(naam), 0)          <= 100 AND
  coalesce(length(email), 0)         <= 254 AND
  coalesce(length(telefoon), 0)      <= 40  AND
  coalesce(length(benzine), 0)       <= 60  AND
  coalesce(length(huurkart_type), 0) <= 60  AND
  coalesce(cardinality(klassen), 0)          <= 20 AND
  coalesce(cardinality(kampioenschappen), 0) <= 20 AND
  coalesce(cardinality(uitrusting), 0)       <= 20 AND
  coalesce(cardinality(rechten), 0)          <= 10 AND
  length(coalesce(startnummers, '{}'::jsonb)::text) <= 1000
) NOT VALID;

ALTER TABLE public.inschrijvingen DROP CONSTRAINT IF EXISTS inschrijvingen_lengtes_check;
ALTER TABLE public.inschrijvingen ADD CONSTRAINT inschrijvingen_lengtes_check CHECK (
  coalesce(length(klasse), 0)    <= 60 AND
  coalesce(length(opmerking), 0) <= 1000
) NOT VALID;


-- ── 9. Extra rijders: maximaal 10 per account ─────────

CREATE OR REPLACE FUNCTION public.maak_extra_rijder(p_voornaam TEXT, p_naam TEXT, p_kart_type TEXT)
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
  IF (SELECT count(*) FROM profiles WHERE account_id = auth.uid() AND id <> auth.uid()) >= 10 THEN
    RAISE EXCEPTION 'Maximaal 10 extra rijders per account';
  END IF;
  v_id := gen_random_uuid();
  INSERT INTO profiles (id, account_id, voornaam, naam, rol, kart_type)
  VALUES (v_id, auth.uid(), p_voornaam, p_naam, 'rijder', p_kart_type);
  RETURN v_id;
END;
$$;


-- ── 10. Extra rijders enkel via maak_extra_rijder ─────
--  Deze policy liet rechtstreeks profielen invoegen met
--  account_id = jezelf, waardoor de limiet van 10 extra
--  rijders omzeild kon worden. De site gebruikt hiervoor
--  enkel de functie maak_extra_rijder, dus de policy is
--  niet nodig.

DROP POLICY IF EXISTS "Gebruiker voegt extra rijder toe" ON public.profiles;


-- ══════════════════════════════════════════════════════
--  Controle (los uitvoeren na de fix)
-- ══════════════════════════════════════════════════════

-- a) Wie heeft er nu een andere rol dan rijder of extra rechten?
--    Staat hier iemand die je niet kent: zet die terug met
--    UPDATE profiles SET rol = 'rijder', rechten = '{}' WHERE id = '...';
--
-- SELECT id, voornaam, naam, email, rol, rechten, aangemaakt_op
-- FROM profiles
-- WHERE rol <> 'rijder' OR rechten <> '{}'
-- ORDER BY aangemaakt_op DESC;

-- b) Welke policies staan er live op profiles?
--
-- SELECT policyname, cmd, qual, with_check
-- FROM pg_policies
-- WHERE schemaname = 'public' AND tablename = 'profiles';
