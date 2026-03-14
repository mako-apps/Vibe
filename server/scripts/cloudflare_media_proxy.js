export default {
  async fetch(request, env, ctx) {
    if (!["GET", "HEAD"].includes(request.method)) {
      return new Response("Method not allowed", {
        status: 405,
        headers: {
          Allow: "GET, HEAD",
          "Cache-Control": "public, max-age=60",
        },
      });
    }

    const url = new URL(request.url);
    const pathParts = url.pathname.split("/").filter(Boolean);

    if (pathParts.length < 2) {
      return new Response("Not found", {
        status: 404,
        headers: {
          "Cache-Control": "public, max-age=60",
        },
      });
    }

    const bucket = pathParts[0];
    const objectPath = pathParts.slice(1).join("/");
    const allowedBuckets = new Set(
      String(env.MEDIA_CDN_ALLOWED_BUCKETS || "chat-media,music-cache")
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean),
    );

    if (!allowedBuckets.has(bucket)) {
      return new Response("Forbidden", {
        status: 403,
        headers: {
          "Cache-Control": "public, max-age=60",
        },
      });
    }

    const supabaseBase = String(env.SUPABASE_URL || "").trim().replace(/\/+$/, "");
    if (!supabaseBase) {
      return new Response("Missing SUPABASE_URL", { status: 500 });
    }

    const originUrl =
      `${supabaseBase}/storage/v1/object/public/${bucket}/${objectPath}` +
      (url.search || "");

    const cacheKey = new Request(url.toString(), {
      method: request.method,
      headers: request.headers,
    });

    const cache = caches.default;
    const cached = await cache.match(cacheKey);
    if (cached) {
      return cached;
    }

    const originRequest = new Request(originUrl, {
      method: request.method,
      headers: forwardHeaders(request.headers),
    });

    const originResponse = await fetch(originRequest, {
      cf: {
        cacheEverything: true,
        cacheTtlByStatus: {
          "200-299": 31536000,
          "404": 60,
        },
      },
    });

    const responseHeaders = new Headers(originResponse.headers);
    responseHeaders.set("Cache-Control", "public, max-age=31536000, immutable");
    responseHeaders.set("X-Content-Type-Options", "nosniff");

    const response = new Response(originResponse.body, {
      status: originResponse.status,
      statusText: originResponse.statusText,
      headers: responseHeaders,
    });

    if (originResponse.ok || originResponse.status === 404 || originResponse.status === 206) {
      ctx.waitUntil(cache.put(cacheKey, response.clone()));
    }

    return response;
  },
};

function forwardHeaders(headers) {
  const nextHeaders = new Headers();

  for (const [key, value] of headers.entries()) {
    const lower = key.toLowerCase();
    if (lower === "host") continue;
    if (lower === "cf-connecting-ip") continue;
    nextHeaders.set(key, value);
  }

  return nextHeaders;
}
