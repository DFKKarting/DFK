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
--  verwijderen (alleen rijders).
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
