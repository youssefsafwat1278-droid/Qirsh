-- Run only on a disposable loopback Supabase stack after full-chain.
begin;
do $$
declare
  apple_uid uuid := '88880000-0000-4000-8000-000000000001';
  google_uid uuid := '88880000-0000-4000-8000-000000000002';
  email_uid uuid := '88880000-0000-4000-8000-000000000003';
  issued jsonb;
  second_code jsonb;
  result jsonb;
  payload jsonb := '{"user":{"app_metadata":{"provider":"google"},"user_metadata":{"sub":"900000000001"}}}';
begin
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
  values (apple_uid,'apple-proof@example.test',clock_timestamp(),'{"provider":"apple"}'),
         (google_uid,'google-proof@example.test',clock_timestamp(),'{"provider":"google"}'),
         (email_uid,'email-proof@example.test',clock_timestamp(),'{"provider":"email"}');
  insert into auth.identities(user_id,provider,provider_id,identity_data)
  values (apple_uid,'apple','synthetic-apple','{"sub":"synthetic-apple"}'),
         (apple_uid,'google','900000000000','{"sub":"900000000000"}'),
         (google_uid,'google','900000000001','{"sub":"900000000001"}');

  issued := public.account_deletion_issue_challenge_v2(apple_uid,true);
  assert issued->>'proof_method' = 'apple', 'An Apple-linked account must use Apple';
  result := public.account_deletion_accept(repeat('a',64),apple_uid,issued->>'challenge_id',
    (issued->>'expires_at_ms')::bigint,repeat('b',64),null,'apple-no-proof');
  assert result->>'outcome' = 'challenge_expired', 'Apple proof cannot be skipped';

  issued := public.account_deletion_issue_challenge_v2(google_uid,false);
  assert issued->>'proof_method' = 'google', 'Google-only account must get a Google challenge';
  assert public.account_deletion_read_challenge(apple_uid,issued->>'challenge_id') is null;
  assert public.account_deletion_read_challenge(google_uid,issued->>'challenge_id')->>'google_subject' = '900000000001';
  result := public.account_deletion_accept(repeat('c',64),google_uid,issued->>'challenge_id',
    (issued->>'expires_at_ms')::bigint,repeat('d',64),null,'google-proof-accepted');
  assert result->>'outcome' = 'accepted';
  assert (select completed_steps = array['apple_revoke'] and apple_material_ref is null
    from account_fence.deletion_job where job_id = (result->>'job_id')::uuid);

  issued := public.account_deletion_issue_challenge_v2(email_uid,false);
  assert issued->>'proof_method' = 'email';
  assert not public.account_deletion_bind_email_code(email_uid,issued->>'challenge_id');
  result := public.account_deletion_accept(repeat('e',64),email_uid,issued->>'challenge_id',
    (issued->>'expires_at_ms')::bigint,repeat('f',64),null,'email-no-proof');
  assert result->>'outcome' = 'challenge_expired', 'Unverified email challenge may not accept';
  update auth.users set reauthentication_sent_at = clock_timestamp(),
    reauthentication_token = encode(sha224(convert_to(email || '00123456','UTF8')),'hex')
    where id = email_uid;
  assert public.account_deletion_bind_email_code(email_uid,issued->>'challenge_id');
  assert not public.account_deletion_verify_email_code(apple_uid,issued->>'challenge_id','00123456');
  assert not public.account_deletion_verify_email_code(email_uid,issued->>'challenge_id','87654321');
  assert public.account_deletion_verify_email_code(email_uid,issued->>'challenge_id','00123456');
  assert not public.account_deletion_verify_email_code(email_uid,issued->>'challenge_id','00123456');
  assert (select reauthentication_token = '' from auth.users where id = email_uid);
  second_code := public.account_deletion_issue_challenge_v2(email_uid,false);
  update auth.users set reauthentication_sent_at = clock_timestamp(),
    reauthentication_token = encode(sha224(convert_to(email || '12345678','UTF8')),'hex')
    where id = email_uid;
  assert public.account_deletion_bind_email_code(email_uid,second_code->>'challenge_id');
  for i in 1..5 loop
    assert not public.account_deletion_verify_email_code(email_uid,second_code->>'challenge_id','00000000');
  end loop;
  assert not public.account_deletion_verify_email_code(email_uid,second_code->>'challenge_id','12345678');
  result := public.account_deletion_accept(repeat('e',64),email_uid,issued->>'challenge_id',
    (issued->>'expires_at_ms')::bigint,repeat('f',64),null,'email-proof-accepted');
  assert result->>'outcome' = 'accepted';

  assert qirsh_auth_hooks.require_google_enrollment_intent(payload)->'error'->>'http_code' = '403';
  perform public.qirsh_permit_google_enrollment('900000000001');
  assert qirsh_auth_hooks.require_google_enrollment_intent(
    jsonb_set(payload,'{user,user_metadata,sub}','"900000000002"'))->'error'->>'http_code' = '403';
  assert qirsh_auth_hooks.require_google_enrollment_intent(payload) = '{}'::jsonb;
  assert qirsh_auth_hooks.require_google_enrollment_intent(payload)->'error'->>'http_code' = '403';
  assert not has_function_privilege('anon','public.qirsh_permit_google_enrollment(text)','EXECUTE');
  assert not has_function_privilege('authenticated','public.account_deletion_verify_email_code(uuid,text,text)','EXECUTE');
end
$$;
rollback;
