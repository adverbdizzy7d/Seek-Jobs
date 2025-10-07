export async function onRequest(context) {
  const { request, env } = context;

  // Preflight beantworten
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": env.ALLOW_ORIGIN || "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Max-Age": "600",
      },
    });
  }

  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "Use POST" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const body = await request.text(); // GraphQL JSON 1:1 durchreichen

  const upstream = await fetch("https://www.seek.com.au/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "*/*",
      "seek-request-brand": "seek",
      "seek-request-country": "AU",
      "X-Seek-Site": "chalice",
      "Origin": "https://www.seek.com.au", // optional, einige Backends prüfen das
    },
    body,
  });

  const buf = await upstream.arrayBuffer();

  return new Response(buf, {
    status: upstream.status,
    headers: {
      "Content-Type": upstream.headers.get("Content-Type") || "application/json",
      "Access-Control-Allow-Origin": env.ALLOW_ORIGIN || "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "*",
      "Vary": "Origin",
    },
  });
}
