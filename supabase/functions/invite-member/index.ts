// POST /functions/v1/invite-member
// Body: { workspaceId: uuid, email: string, role?: 'member' | 'admin' }
// Creates a single-use invite (RLS: caller must be workspace admin) and emails the link.
import '@supabase/functions-js/edge-runtime.d.ts';
import { createHandler, randomToken } from './handler.ts';
import { resendMailer, supabaseInviteStore } from './adapters.ts';

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required env var ${name}`);
  return value;
}

// No silent dev defaults: a misconfigured deployment fails at boot, not in an email link.
const supabaseUrl = requireEnv('SUPABASE_URL');
const publishableKey = requireEnv('SUPABASE_ANON_KEY');
const appUrl = requireEnv('APP_URL');

Deno.serve(createHandler({
  storeFor: (jwt) => supabaseInviteStore(supabaseUrl, publishableKey, jwt),
  // RESEND_API_KEY is optional on purpose: without it the link is returned to the admin.
  sendInviteEmail: resendMailer(Deno.env.get('RESEND_API_KEY'), requireEnv('INVITE_FROM_EMAIL')),
  newToken: randomToken,
  appUrl,
  allowedOrigin: Deno.env.get('ALLOWED_ORIGIN') ?? new URL(appUrl).origin,
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
}));
