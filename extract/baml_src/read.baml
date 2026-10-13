// POST /read: one document in, proposed fields out (see read_prompt.baml).

class ReadRequest {
    kind: string,
    content_type: string,
    content: string?,
    subject: string?,
    from: string?,
    text: string?,
}

// What the web app gets back: amounts in whole cents, never floats.
class ReadLine {
    description: string,
    cents: int,
}

class ReadResult {
    doc_type: string,
    merchant: string?,
    total_cents: int?,
    date: string?,
    due_on: string?,
    period_start: string?,
    period_end: string?,
    account_hint: string?,
    tax_cents: int?,
    tip_cents: int?,
    line_items: ReadLine[],
}

function json_response(status: int, body: string) -> baml.http.Response throws never {
    baml.http.Response.new(status, { "content-type": "application/json" }, body.to_utf8())
}

// Handles POST /read. `client` is for tests; null means Claude Haiku.
function handle_read(
    req: baml.http.ServerRequest,
    client: ai.Client? = null,
) -> baml.http.Response throws never {
    //# No key: reading is off, and the app falls back to typing it in
    let key = baml.env.get("ANTHROPIC_API_KEY") catch_all (e) {
        _ => null
    };
    if (client == null && (key ?? "") == "") {
        return json_response(503, "{\"error\":\"off\"}");
    }
    //# Parse the request, read the document, convert to cents
    let parsed = baml.json.from_string<ReadRequest>(req.body) catch_all (e) {
        _ => null
    };
    if (parsed == null) {
        return json_response(400, "{\"error\":\"bad_request\"}");
    }
    let r: ReadRequest = parsed;
    let failure = "";
    let bill = read_bill(r, client = client) catch_all (e) {
        _ => {
            failure = `${e}`;
            log.warn(`read failed: ${failure}`);
            null
        }
    };
    if (bill == null) {
        //# Out of API credit: paused until it refills, not unreadable
        if (out_of_credit(failure)) {
            return json_response(503, "{\"error\":\"paused\"}");
        }
        return json_response(422, "{\"error\":\"unreadable\"}");
    }
    let out = baml.json.to_string(to_result(bill)) catch_all (e) {
        _ => null
    };
    if (out == null) {
        return json_response(422, "{\"error\":\"unreadable\"}");
    }
    json_response(200, out)
}

function read_bill(r: ReadRequest, client: ai.Client? = null) -> Bill? {
    let content = r.content ?? "";
    let agent = ai.Agent.new(client = client);
    if (r.kind == "photo" && content != "") {
        agent.run(ReadPhoto@spec(image.from_base64(content, r.content_type))).value
    } else if (r.kind == "pdf" && content != "") {
        agent.run(ReadPdf@spec(pdf.from_base64(content, "application/pdf"))).value
    } else if (r.kind == "email") {
        agent.run(ReadEmail@spec(r.subject ?? "", r.from ?? "", r.text ?? "")).value
    } else {
        null
    }
}

function to_result(b: Bill) -> ReadResult {
    ReadResult {
        doc_type: b.doc_type.to_string().to_lower_case(),
        merchant: b.merchant,
        total_cents: cents(b.total),
        date: b.date,
        due_on: b.due_on,
        period_start: b.period_start,
        period_end: b.period_end,
        account_hint: b.account_hint,
        tax_cents: cents(b.tax),
        tip_cents: cents(b.tip),
        line_items: b.line_items.filter_map((l) -> {
            let c = cents(l.amount);
            if (c == null) {
                null
            } else {
                ReadLine { description: l.description, cents: c }
            }
        }),
    }
}

// "$1,234.5" -> 123450. Anything unclear (no digits, odd decimals) -> null.
function cents(printed: string?) -> int? {
    if (printed == null) {
        return null;
    }
    let s = printed.replace_all(",", "")
        .replace_all("$", "")
        .replace_all("€", "")
        .replace_all("£", "")
        .trim();
    let parts = s.split(".");
    if (parts.length() > 2 || s == "") {
        return null;
    }
    let whole = baml.Int.parse(parts[0]) catch_all (e) {
        _ => null
    };
    if (whole == null || whole < 0) {
        return null;
    }
    let frac = if (parts.length() == 2) {
        parts[1]
    } else {
        "0"
    };
    if (frac.length() > 2 || frac.length() == 0) {
        return null;
    }
    let f = baml.Int.parse(
        if (frac.length() == 1) {
            frac + "0"
        } else {
            frac
        },
    ) catch_all (e) {
        _ => null
    };
    if (f == null) {
        return null;
    }
    whole * 100 + f
}

// Anthropic's answer when the account has no credit left.
function out_of_credit(failure: string) -> bool {
    failure.to_lower_case().index_of("credit balance is too low") != null
}
