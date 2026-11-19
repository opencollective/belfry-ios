#!/usr/bin/env python3
"""Writes vectors/ticket-prices.json: what a ticket (kind 30402) costs now.

The reference is the server: collective-belfry services/onboarding/belfry_onboarding/events.py
(price_of, Ticket.price_text). This script runs THAT code (given as a file) on the cases below,
so the vector is what the belfry answers:

  git -C <collective-belfry> show origin/belfry-sh:services/onboarding/belfry_onboarding/events.py > /tmp/events.py
  python3 -I tools/vectors/ticket-prices.py /tmp/events.py <commit> > vectors/ticket-prices.json
"""
import json, re, sys, time

src = open(sys.argv[1]).read()
commit = sys.argv[2] if len(sys.argv) > 2 else ""


def cut(name, end):
    a = src.index(name)
    return src[a:src.index(end, a)]


ns = {"re": re, "time": time, "Any": object}
exec("from __future__ import annotations\n" + cut("CURRENCY_RE = ", "@dataclass"), ns)
price_of = ns["price_of"]


def line(p):
    """Ticket.price_text without its "· until <day>" end (a date is written by each app in the reader's own way)."""
    if not p["priced"]:
        return "Free"
    if not p["on_sale"]:
        return "Not on sale now"
    if not p["amount"]:
        return "Paid"
    if p["currency"] == "EUR":
        out = "€" + p["amount"]
    elif p["currency"] == "HOUR":
        out = f"{p['amount']} {'hour' if p['amount'] == '1' else 'hours'}"
    else:
        out = f"{p['amount']} {p['currency']}"
    if p["vat"]:
        out += f" incl. {p['vat']}% VAT" if p["vat_included"] else f" + {p['vat']}% VAT"
    return out


# the server's own text must agree with line() above (minus the date)
assert "Not on sale now" in src and '"Paid"' in src and 'incl. {self.vat}% VAT' in src and '+ {self.vat}% VAT' in src

NOW = 1795000000  # 2026-11-18
JAN1 = 1798761600  # 2027-01-01 00:00 UTC
cases = [
    ("no price tag: free", [["title", "Workshop seat"]], NOW),
    ("a price in euros", [["price", "50", "EUR"]], NOW),
    ("cents, a lower-case code", [["price", "15.50", "eur"]], NOW),
    ("leading zeros and a trailing zero", [["price", "007.10", "EUR"]], NOW),
    ("one decimal reads as two", [["price", "12.5", "EUR"]], NOW),
    ("zero is free", [["price", "0", "EUR"]], NOW),
    ("0.00 is free", [["price", "0.00", "EUR"]], NOW),
    ("another currency", [["price", "20", "usd"]], NOW),
    ("hours", [["price", "2", "hours"]], NOW),
    ("one hour", [["price", "1", "HOUR"]], NOW),
    ("the host's own label, as written", [["price", "3", "Time credits"]], NOW),
    ("a label of 13 characters can't be read: priced, no amount", [["price", "3", "Thirteen char"]], NOW),
    ("no currency: priced, no amount", [["price", "5"]], NOW),
    ("not a number: priced, no amount", [["price", "lots", "<b>"]], NOW),
    ("three decimals: priced, no amount", [["price", "5.123", "EUR"]], NOW),
    ("a comma: priced, no amount", [["price", "5,50", "EUR"]], NOW),
    ("VAT on top", [["price", "50", "EUR"], ["vat", "21"]], NOW),
    ("VAT included", [["price", "60.50", "EUR"], ["vat", "21", "included"]], NOW),
    ("a VAT rate with zeros", [["price", "12.5", "EUR"], ["vat", "6.00", "included"]], NOW),
    ("a VAT rate with a decimal", [["price", "10", "EUR"], ["vat", "5.5"]], NOW),
    ("no VAT on hours", [["price", "2", "HOUR"], ["vat", "21"]], NOW),
    ("no VAT on an own label", [["price", "3", "tokens"], ["vat", "21"]], NOW),
    ("an unreadable VAT rate is no VAT", [["price", "50", "EUR"], ["vat", "a lot"]], NOW),
    ("early bird: the dated price while it lasts", [["price_at", "50", "EUR", "", str(JAN1)], ["price", "75", "EUR"], ["vat", "21"]], JAN1 - 10),
    ("early bird over: the plain price", [["price_at", "50", "EUR", "", str(JAN1)], ["price", "75", "EUR"], ["vat", "21"]], JAN1),
    ("the plain price holds until a later dated one starts", [["price", "50", "EUR"], ["price_at", "75", "EUR", str(JAN1), ""]], JAN1 - 10),
    ("the later dated price has started", [["price", "50", "EUR"], ["price_at", "75", "EUR", str(JAN1), ""]], JAN1 + 5),
    ("two dated prices: the first whose time it is", [["price_at", "40", "EUR", "", str(JAN1)], ["price_at", "45", "EUR", "", str(JAN1 + 86400)], ["price", "60", "EUR"]], JAN1 - 10),
    ("two dated prices: the second once the first ended", [["price_at", "40", "EUR", "", str(JAN1)], ["price_at", "45", "EUR", "", str(JAN1 + 86400)], ["price", "60", "EUR"]], JAN1 + 10),
    ("dated prices only, none now: not on sale", [["price_at", "50", "EUR", "", str(JAN1)]], JAN1 + 1),
    ("dated prices only, not started yet: not on sale", [["price_at", "50", "EUR", str(JAN1), ""]], JAN1 - 1),
    ("a dated price only, current", [["price_at", "50", "EUR", str(JAN1 - 100), str(JAN1)]], JAN1 - 50),
    ("an unreadable date: priced, no amount", [["price_at", "50", "EUR", "soon", ""], ["price", "75", "EUR"]], NOW),
    ("a dated zero now: free", [["price_at", "0", "EUR", "", str(JAN1)], ["price", "20", "EUR"]], JAN1 - 10),
]
out = {
    "about": "What a ticket type (kind 30402) costs now (collective-belfry docs/checkin.md \"Ticket prices\"). tags in, at `now` (unix seconds); out: priced (false = free: self-served unless closed), amount (decimal string; empty = priced but unreadable, or not on sale), currency (an ISO code in capitals, HOUR, or the host's own label as written), vat (percent, only on an ISO currency; empty = none stated), vat_included, until (when the current price ends or the next one starts, else null), on_sale (false = dated prices and none of them now), and line = the words shown (the server's Ticket.price_text without its \"· until <day>\" end; \"Free\" is the apps' word for a ticket without a price). A priced ticket is never self-served: the person asks, the host admits once it is settled.",
    "generated_by": "tools/vectors/ticket-prices.py in belfry-ios, running the server's price_of" + (f" (collective-belfry {commit})" if commit else ""),
    "cases": [],
}
for name, tags, now in cases:
    p = price_of({"tags": tags}, now=now)
    out["cases"].append({"name": name, "now": now, "tags": tags,
                         "out": {k: p[k] for k in ("priced", "amount", "currency", "vat", "vat_included", "until", "on_sale")}, "line": line(p)})
print(json.dumps(out, indent=2, ensure_ascii=False))
