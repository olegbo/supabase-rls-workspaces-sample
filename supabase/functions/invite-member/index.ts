// POST /functions/v1/invite-member
// Body: { workspaceId: uuid, email: string, role?: 'member' | 'admin' }
// Creates a single-use invite (RLS: caller must be workspace admin) and emails the link.
import '@supabase/functions-js/edge-runtime.d.ts';
import { createHandler, randomToken } from './handler.ts';
import { resendMailer, supabaseInviteStore } from './adapters.ts';
import { loadConfig } from './config.ts';

const config = loadConfig((name) => Deno.env.get(name));

Deno.serve(createHandler({
  storeFor: (jwt) => supabaseInviteStore(config.supabaseUrl, config.publishableKey, jwt),
  sendInviteEmail: resendMailer(config.resendApiKey, config.fromEmail),
  newToken: randomToken,
  appUrl: config.appUrl,
  allowedOrigin: config.allowedOrigin,
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
}));
