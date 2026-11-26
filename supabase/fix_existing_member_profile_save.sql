CREATE OR REPLACE FUNCTION public.update_my_profile(p_display_name text, p_avatar_url text, p_occupation text, p_city text, p_district text, p_bio text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION '請先登入會員帳號';
  END IF;

  IF NULLIF(BTRIM(p_display_name), '') IS NULL
     OR NULLIF(BTRIM(p_occupation), '') IS NULL
     OR NULLIF(BTRIM(p_city), '') IS NULL
     OR NULLIF(BTRIM(p_district), '') IS NULL
     OR NULLIF(BTRIM(p_bio), '') IS NULL THEN
    RAISE EXCEPTION '所有個人資料欄位皆為必填';
  END IF;

  IF CHAR_LENGTH(BTRIM(p_display_name)) > 40 THEN
    RAISE EXCEPTION '顯示名稱不可超過 40 個字';
  END IF;

  IF CHAR_LENGTH(BTRIM(p_city)) > 30
     OR CHAR_LENGTH(BTRIM(p_district)) > 30 THEN
    RAISE EXCEPTION '所在地資料不可超過 30 個字';
  END IF;

  IF CHAR_LENGTH(BTRIM(p_bio)) > 300 THEN
    RAISE EXCEPTION '個人簡介不可超過 300 個字';
  END IF;

  IF BTRIM(p_occupation) NOT IN (
    '牙醫師',
    '牙醫助理',
    '牙體技術師',
    '牙科衛生師',
    '牙醫學生',
    '牙材廠商',
    '診所行政／管理人員',
    '其他'
  ) THEN
    RAISE EXCEPTION '職業身分選項無效';
  END IF;

  UPDATE public.profiles
  SET
    display_name = BTRIM(p_display_name),
    avatar_url = COALESCE(
      NULLIF(BTRIM(p_avatar_url), ''),
      avatar_url
    ),
    occupation = BTRIM(p_occupation),
    city = BTRIM(p_city),
    district = BTRIM(p_district),
    bio = BTRIM(p_bio),
    updated_at = NOW(),
    profile_completed_at = CASE
      WHEN COALESCE(NULLIF(BTRIM(p_avatar_url), ''), NULLIF(BTRIM(avatar_url), '')) IS NOT NULL
        THEN COALESCE(profile_completed_at, NOW())
      ELSE profile_completed_at
    END
  WHERE id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到會員資料，請重新登入後再試';
  END IF;

  RETURN true;
END;
$function$
