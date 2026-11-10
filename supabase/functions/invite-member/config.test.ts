import { assertEquals, assertThrows } from '@std/assert';
import { loadConfig } from './config.ts';

const base: Record<string, string> = {
  SUPABASE_URL: 'http://127.0.0.1:54321',
  SUPABASE_ANON_KEY: 'anon-key',
  APP_URL: 'https://app.example.test',
  INVITE_FROM_EMAIL: 'Workspace <no-reply@example.test>',
};

const envOf = (overrides: Record<string, string | undefined> = {}) => {
  const env = { ...base, ...overrides };
  return (name: string) => env[name];
};

Deno.test('loads a complete environment', () => {
  assertEquals(loadConfig(envOf({ RESEND_API_KEY: 're_123' })), {
    supabaseUrl: 'http://127.0.0.1:54321',
    publishableKey: 'anon-key',
    appUrl: 'https://app.example.test',
    allowedOrigin: 'https://app.example.test',
    fromEmail: 'Workspace <no-reply@example.test>',
    resendApiKey: 're_123',
  });
});

Deno.test('every required variable is enforced by name', () => {
  for (const name of Object.keys(base)) {
    for (const missing of [undefined, '', '   ']) {
      assertThrows(
        () => loadConfig(envOf({ [name]: missing })),
        Error,
        `Missing required env var ${name}`,
      );
    }
  }
});

Deno.test('APP_URL must be an http(s) URL', () => {
  assertThrows(() => loadConfig(envOf({ APP_URL: 'not a url' })), Error, 'not a valid URL');
  assertThrows(
    () => loadConfig(envOf({ APP_URL: 'javascript:alert(1)' })),
    Error,
    'must be an http(s) URL',
  );
});

Deno.test('trailing slashes are dropped from APP_URL, paths are kept', () => {
  assertEquals(
    loadConfig(envOf({ APP_URL: 'https://app.example.test/' })).appUrl,
    'https://app.example.test',
  );
  assertEquals(
    loadConfig(envOf({ APP_URL: 'https://example.test/kb//' })).appUrl,
    'https://example.test/kb',
  );
});

Deno.test('ALLOWED_ORIGIN defaults to the APP_URL origin and is normalized', () => {
  assertEquals(
    loadConfig(envOf({ APP_URL: 'https://example.test/kb/' })).allowedOrigin,
    'https://example.test',
  );
  assertEquals(
    loadConfig(envOf({ ALLOWED_ORIGIN: 'https://admin.example.test/some/path' })).allowedOrigin,
    'https://admin.example.test',
  );
  assertThrows(
    () => loadConfig(envOf({ ALLOWED_ORIGIN: 'ftp://x.test' })),
    Error,
    'ALLOWED_ORIGIN must be an http(s) URL',
  );
});

Deno.test('a blank RESEND_API_KEY means mail is disabled', () => {
  assertEquals(loadConfig(envOf()).resendApiKey, undefined);
  assertEquals(loadConfig(envOf({ RESEND_API_KEY: '  ' })).resendApiKey, undefined);
});
