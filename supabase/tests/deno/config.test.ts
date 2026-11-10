// Auth settings the database security model depends on. accept_workspace_invite() trusts
// `email_confirmed_at`, which is meaningless if Supabase confirms every signup itself.
import { assert, assertEquals } from '@std/assert';
import { parse } from '@std/toml';

type AuthConfig = {
  auth: {
    enable_signup: boolean;
    enable_anonymous_sign_ins: boolean;
    minimum_password_length: number;
    email: { enable_confirmations: boolean };
  };
};

const config = parse(
  await Deno.readTextFile(new URL('../../config.toml', import.meta.url)),
) as unknown as AuthConfig;

Deno.test('email confirmation is required before an address counts as verified', () => {
  assertEquals(config.auth.email.enable_confirmations, true);
});

Deno.test('anonymous sign-ins stay disabled', () => {
  assertEquals(config.auth.enable_anonymous_sign_ins, false);
});

Deno.test('passwords are at least 8 characters', () => {
  assert(config.auth.minimum_password_length >= 8);
});
