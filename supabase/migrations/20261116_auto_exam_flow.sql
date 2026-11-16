-- Automatic exam flow: WordPress shortcode -> exam link email -> pass -> certificate email.
-- Run once in Supabase SQL Editor (after the earlier examination migrations).

-- 1. Per-course exam + certificate template ---------------------------------
alter table public.examinations
  add column if not exists wp_course_id text default '',
  add column if not exists certificate_template_id text default '',
  add column if not exists certificate_design jsonb;

create index if not exists examinations_wp_course_idx on public.examinations (wp_course_id);

alter table public.exam_invitations
  add column if not exists wp_user_id text default '',
  add column if not exists source text default 'admin';

alter table public.exam_attempts
  add column if not exists certificate_emailed_at timestamptz;

-- 2. Shared secret between WordPress and Supabase --------------------------
create table if not exists public.integration_secrets (
  key text primary key,
  value text not null default '',
  updated_at timestamptz not null default now()
);

alter table public.integration_secrets enable row level security;
drop policy if exists "integration secrets for authenticated" on public.integration_secrets;
create policy "integration secrets for authenticated" on public.integration_secrets
  for all to authenticated using (true) with check (true);

insert into public.integration_secrets (key, value)
values ('bridge_secret', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
on conflict (key) do nothing;

insert into public.integration_secrets (key, value)
values ('wp_notify_url', '')
on conflict (key) do nothing;

-- Lets the database call the send-certificate Edge Function the moment a student passes.
do $$
begin
  create extension if not exists pg_net with schema extensions;
exception when others then
  raise notice 'pg_net not enabled; WordPress cron will deliver certificate emails.';
end $$;

create or replace function public.bridge_check_secret(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(p_secret, '') <> ''
    and exists (
      select 1 from public.integration_secrets
      where key = 'bridge_secret' and value = p_secret
    );
$$;
revoke all on function public.bridge_check_secret(text) from public;

-- 3. WordPress asks for an exam invitation ---------------------------------
create or replace function public.bridge_request_exam_invitation(
  p_secret text,
  p_wp_course_id text,
  p_wp_user_id text,
  p_name text,
  p_email text,
  p_token_hash text,
  p_exam_id text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  ex public.examinations%rowtype;
begin
  if not public.bridge_check_secret(p_secret) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;

  if btrim(coalesce(p_exam_id, '')) <> '' then
    -- Shortcode named a specific exam.
    select * into ex
    from public.examinations
    where id = btrim(p_exam_id) and active = true;
  else
    select * into ex
    from public.examinations
    where wp_course_id = btrim(coalesce(p_wp_course_id, ''))
      and active = true
    order by created_at desc
    limit 1;
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_exam');
  end if;
  if jsonb_array_length(ex.questions) = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_questions');
  end if;

  -- Already passed this exam?
  if exists (
    select 1
    from public.exam_attempts a
    join public.exam_invitations i on i.id = a.invitation_id
    where a.exam_id = ex.id
      and a.passed = true
      and (i.wp_user_id = p_wp_user_id or lower(i.student_email) = lower(p_email))
  ) then
    return jsonb_build_object('ok', false, 'error', 'already_passed');
  end if;

  -- Exam currently open?
  if exists (
    select 1
    from public.exam_attempts a
    join public.exam_invitations i on i.id = a.invitation_id
    where a.exam_id = ex.id
      and a.status = 'in_progress'
      and (i.wp_user_id = p_wp_user_id or lower(i.student_email) = lower(p_email))
  ) then
    return jsonb_build_object('ok', false, 'error', 'in_progress');
  end if;

  -- Replace any unused link so only the newest one works.
  update public.exam_invitations
    set status = 'revoked'
    where exam_id = ex.id
      and status = 'unused'
      and (wp_user_id = p_wp_user_id or lower(student_email) = lower(p_email));

  insert into public.exam_invitations
    (id, exam_id, student_name, student_email, token_hash, status, wp_user_id, source)
  values
    (gen_random_uuid()::text, ex.id, btrim(p_name), btrim(p_email), p_token_hash, 'unused', p_wp_user_id, 'wordpress');

  return jsonb_build_object(
    'ok', true,
    'examTitle', ex.title,
    'courseTitle', ex.course_title,
    'durationMinutes', ex.duration_minutes,
    'passMarks', ex.pass_marks,
    'totalMarks', ex.total_marks
  );
end;
$$;

-- 4. Certificate email queue for WordPress ----------------------------------
create or replace function public.bridge_pending_certificates(p_secret text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.bridge_check_secret(p_secret) then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'attemptId', a.id,
      'name', a.student_name,
      'email', a.student_email,
      'courseTitle', e.course_title,
      'score', a.score,
      'totalMarks', e.total_marks,
      'certificateId', c.certificate_id,
      'publicToken', coalesce(c.public_token, c.certificate_id)
    ))
    from public.exam_attempts a
    join public.examinations e on e.id = a.exam_id
    join public.certificates c on c.id = a.certificate_id
    where a.passed = true
      and a.certificate_emailed_at is null
      and coalesce(a.student_email, '') <> ''
  ), '[]'::jsonb);
end;
$$;

create or replace function public.bridge_mark_certificate_emailed(p_secret text, p_attempt_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.bridge_check_secret(p_secret) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;
  update public.exam_attempts
    set certificate_sent = true, certificate_emailed_at = now()
    where id = p_attempt_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- Only Edge Functions (service role) may call the bridge functions.
revoke all on function public.bridge_request_exam_invitation(text, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.bridge_pending_certificates(text) from public, anon, authenticated;
revoke all on function public.bridge_mark_certificate_emailed(text, text) from public, anon, authenticated;
revoke all on function public.bridge_check_secret(text) from public, anon, authenticated;
grant execute on function public.bridge_request_exam_invitation(text, text, text, text, text, text, text) to service_role;
grant execute on function public.bridge_pending_certificates(text) to service_role;
grant execute on function public.bridge_mark_certificate_emailed(text, text) to service_role;
grant execute on function public.bridge_check_secret(text) to service_role;

-- Optional safety net (needs pg_cron + pg_net): retry certificate emails every 5 minutes.
-- Uncomment after saving the send-certificate function URL in Settings -> WordPress automation.
-- select cron.schedule('certify-send-certificates', '*/5 * * * *', $cron$
--   select net.http_post(
--     url := (select value from public.integration_secrets where key = 'wp_notify_url'),
--     headers := jsonb_build_object('Content-Type','application/json',
--       'X-Certify-Secret', (select value from public.integration_secrets where key = 'bridge_secret')),
--     body := '{}'::jsonb);
-- $cron$);

-- 5. Submit: auto-issue the course certificate when the student passes ------
create or replace function public.submit_exam_attempt(p_token text, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  inv public.exam_invitations%rowtype;
  ex public.examinations%rowtype;
  att public.exam_attempts%rowtype;
  q jsonb;
  qid text;
  chosen text;
  marks numeric;
  v_score numeric := 0;
  earned numeric;
  v_passed boolean;
  v_settings jsonb;
  v_prefix text;
  v_cert_row_id text;
  v_cert_token text;
  v_secret text;
  v_url text;
begin
  inv := public.find_exam_invitation(p_token);
  if inv.id is null then
    return jsonb_build_object('ok', false, 'error', 'This examination link is invalid.');
  end if;
  select * into att from public.exam_attempts where invitation_id = inv.id order by started_at desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No examination attempt was found.');
  end if;
  if att.status = 'submitted' then
    select coalesce(public_token, certificate_id) into v_cert_token
      from public.certificates where id = att.certificate_id;
    return jsonb_build_object('ok', true, 'already', true, 'score', att.score, 'passed', att.passed,
                              'certificateToken', v_cert_token);
  end if;
  if att.status <> 'in_progress' then
    return jsonb_build_object('ok', false, 'error', 'This examination can no longer be submitted.');
  end if;
  select * into ex from public.examinations where id = att.exam_id;

  for qid in select jsonb_array_elements_text(att.question_ids)
  loop
    select value into q
      from jsonb_array_elements(ex.questions) value
      where value->>'id' = qid
      limit 1;
    if q is null then
      continue;
    end if;
    marks := coalesce(nullif(q->>'marks', '')::numeric, ex.marks_per_question);
    chosen := coalesce(p_answers->>qid, '');
    if chosen = '' then
      earned := 0;
    elsif chosen = coalesce(q->>'correctOptionId', '') then
      earned := marks;
    elsif ex.negative_marking then
      earned := -ex.negative_marks;
    else
      earned := 0;
    end if;
    v_score := v_score + earned;
  end loop;

  v_passed := v_score >= ex.pass_marks;

  update public.exam_attempts
    set answers = coalesce(p_answers, '{}'::jsonb),
        status = 'submitted',
        score = v_score,
        passed = v_passed,
        submitted_at = now(),
        remaining_seconds = 0
    where id = att.id;

  -- Auto-issue the certificate using this exam's (course-wise) template.
  if v_passed and ex.certificate_design is not null and coalesce(att.certificate_id, '') = '' then
    select data into v_settings from public.settings where id = 1;
    v_settings := coalesce(v_settings, '{}'::jsonb);
    v_prefix := upper(regexp_replace(coalesce(nullif(v_settings->>'certificatePrefix', ''), 'CERT'), '[^A-Za-z0-9]', '', 'g'));
    if v_prefix = '' then v_prefix := 'CERT'; end if;
    v_cert_row_id := gen_random_uuid()::text;
    v_cert_token := v_prefix || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

    insert into public.certificates
      (id, certificate_id, public_token, recipient_name, recipient_email, course_title, description,
       template_id, design, organization, signature, issue_date, status)
    values
      (v_cert_row_id,
       v_prefix || '-' || extract(year from now())::int || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
       v_cert_token,
       coalesce(att.student_name, inv.student_name),
       coalesce(att.student_email, inv.student_email, ''),
       ex.course_title,
       coalesce(ex.certificate_design->'copy'->>'description', ''),
       ex.certificate_template_id,
       ex.certificate_design,
       v_settings->'organization',
       v_settings->'signature',
       to_char(now() at time zone 'utc', 'FMMonth FMDD, YYYY'),
       'issued');

    update public.exam_attempts set certificate_id = v_cert_row_id where id = att.id;

    -- Trigger the send-certificate Edge Function now (best effort).
    begin
      select value into v_secret from public.integration_secrets where key = 'bridge_secret';
      select value into v_url from public.integration_secrets where key = 'wp_notify_url';
      if coalesce(v_url, '') <> '' then
        perform net.http_post(
          url := v_url,
          body := jsonb_build_object('event', 'exam_passed'),
          headers := jsonb_build_object('Content-Type', 'application/json', 'X-Certify-Secret', coalesce(v_secret, ''))
        );
      end if;
    exception when others then
      null;
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'score', v_score,
    'passed', v_passed,
    'totalMarks', ex.total_marks,
    'passMarks', ex.pass_marks,
    'certificateToken', v_cert_token
  );
end;
$$;

revoke all on function public.submit_exam_attempt(text, jsonb) from public;
grant execute on function public.submit_exam_attempt(text, jsonb) to anon, authenticated;
