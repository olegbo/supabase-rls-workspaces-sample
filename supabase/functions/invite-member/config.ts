// Environment for the function. No silent dev defaults: a misconfigured deployment fails
// at boot, not later inside an email link.
export interface FunctionConfig {
  supabaseUrl: string;
  publishableKey: string;
  appUrl: string;
  allowedOrigin: string;
  fromEmail: string;
  // Optional on purpose: without it no email is sent and the link goes back to the admin.
  resendApiKey: string | undefined;
}

export function loadConfig(env: (name: string) => string | undefined): FunctionConfig {
  const required = (name: string): string => {
    const value = env(name)?.trim();
    if (!value) throw new Error(`Missing required env var ${name}`);
    return value;
  };

  const appUrl = parseUrl('APP_URL', required('APP_URL'));
  const allowedOrigin = env('ALLOWED_ORIGIN')?.trim()
    ? parseUrl('ALLOWED_ORIGIN', env('ALLOWED_ORIGIN')!.trim()).origin
    : appUrl.origin;

  return {
    supabaseUrl: required('SUPABASE_URL'),
    publishableKey: required('SUPABASE_ANON_KEY'),
    // Links are built as `${appUrl}/invites/accept`, so drop trailing slashes.
    appUrl: appUrl.href.replace(/\/+$/, ''),
    allowedOrigin,
    fromEmail: required('INVITE_FROM_EMAIL'),
    resendApiKey: env('RESEND_API_KEY')?.trim() || undefined,
  };
}

function parseUrl(name: string, value: string): URL {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${name} is not a valid URL`);
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    throw new Error(`${name} must be an http(s) URL`);
  }
  return url;
}
