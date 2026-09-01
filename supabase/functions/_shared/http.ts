const DEFAULT_SITE_URL = "https://go-go-shop.github.io/online/";
const LOCAL_ORIGINS = new Set([
  "http://127.0.0.1:8769",
  "http://localhost:8769"
]);

export function siteUrl(): string {
  return Deno.env.get("SITE_URL") || DEFAULT_SITE_URL;
}

export function requestOriginAllowed(request: Request): boolean {
  const origin = request.headers.get("origin");
  if (!origin) return true;
  if (LOCAL_ORIGINS.has(origin)) return true;
  return origin === new URL(siteUrl()).origin;
}

export function corsHeaders(request: Request): HeadersInit {
  const origin = request.headers.get("origin");
  const allowedOrigin = origin && requestOriginAllowed(request)
    ? origin
    : new URL(siteUrl()).origin;
  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin"
  };
}

export function jsonResponse(
  request: Request,
  body: Record<string, unknown>,
  status = 200
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(request),
      "Content-Type": "application/json"
    }
  });
}
