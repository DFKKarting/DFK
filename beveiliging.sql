-- ══════════════════════════════════════════════════════
--  DFK – Beveiliging rollen & rechten
--  Plak dit in Supabase → SQL Editor → Run
--
--  Probleem: de policy "Eigen profiel aanpassen" laat een
--  gebruiker ELKE kolom van zijn profiel wijzigen, ook
--  `rol` en `rechten`. Daardoor kon iedereen die een account
--  aanmaakt zichzelf admin maken via de API.
--
--  Oplossing: een trigger die rol, rechten en account_id
--  bewaakt. Alleen admin/office (is_admin()) mag die
--  wijzigen. De SQL Editor, het Supabase-dashboard en
--  SECURITY DEFINER-functies (zoals handle_new_user en
--  maak_extra_rijder) blijven gewoon werken.
--
--  Veilig om meerdere keren uit te voeren.
-- ══════════════════════════════════════════════════════


-- ── 1. Trigger-functie ────────────────────────────────
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

  -- Admin en office mogen rollen en rechten beheren
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Nieuw profiel door een gewone gebruiker: altijd rijder zonder extra rechten
    NEW.rol     := 'rijder';
    NEW.rechten := '{}';
    IF NEW.account_id IS NOT NULL AND NEW.account_id <> auth.uid() THEN
      RAISE EXCEPTION 'Je kunt geen profiel aan een ander account koppelen'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NEW.rol IS DISTINCT FROM OLD.rol
     OR NEW.rechten IS DISTINCT FROM OLD.rechten THEN
    RAISE EXCEPTION 'Je mag je rol of rechten niet zelf wijzigen'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.account_id IS DISTINCT FROM OLD.account_id
     AND NEW.account_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Je kunt geen profiel aan een ander account koppelen'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;


-- ── 2. Trigger koppelen aan profiles ──────────────────

DROP TRIGGER IF EXISTS bescherm_profiel_rechten ON public.profiles;

CREATE TRIGGER bescherm_profiel_rechten
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.bescherm_profiel_rechten();


-- ── 3. Hulpfuncties: vaste search_path (Supabase-advies) ──

ALTER FUNCTION public.is_admin()      SET search_path = public;
ALTER FUNCTION public.is_werkplaats() SET search_path = public;


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
