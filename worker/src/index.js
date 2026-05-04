const INSTALL_SH_URL =
  "https://raw.githubusercontent.com/justrach/mcpsync/main/install.sh";

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Any path on mcpsync.codegraff.com → serve install.sh
    const upstream = await fetch(INSTALL_SH_URL, {
      cf: { cacheTtl: 300 }, // cache for 5 min at the edge
    });

    if (!upstream.ok) {
      return new Response("Failed to fetch install script\n", { status: 502 });
    }

    const script = await upstream.text();

    return new Response(script, {
      status: 200,
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "public, max-age=300",
        "X-Source": "github.com/justrach/mcpsync",
      },
    });
  },
};
