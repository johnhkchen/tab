// Tab's extraction service. Reads bills and receipts and proposes structured data
// for a person to confirm. It has no database credentials and no write path:
// it can only ever propose, never commit (spec §5, §5.0).

function version() -> string {
    "0.1.0"
}

function route(req: baml.http.ServerRequest) -> baml.http.Response throws never {
    let path = req.url.split("?")[0];
    if (path.ends_with("/health")) {
        baml.http.Response.new(
            200,
            { "content-type": "application/json" },
            ("{\"status\":\"ok\",\"service\":\"extract\",\"version\":\"" + version() + "\"}")
                .to_utf8(),
        )
    } else {
        baml.http.Response.new(404, { "content-type": "text/plain" }, "not found".to_utf8())
    }
}

function main() -> never {
    let port = baml.env.get("PORT") ?? "4100";
    let server = baml.http.Server.bind("0.0.0.0:" + port);
    log.info("extract listening on " + server.addr);
    server.serve(route)
}

test "health reports ok" {
    let resp = route(baml.http.ServerRequest { method: "GET", url: "/health", headers: {}, body: "" });
    assert.equal(resp.status_code, 200)
}

test "unknown path is 404" {
    let resp = route(baml.http.ServerRequest { method: "GET", url: "/nope", headers: {}, body: "" });
    assert.equal(resp.status_code, 404)
}
