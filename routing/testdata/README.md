# Shared routing fixtures

These UTF-8 fixtures are shared by the controller, Android, iOS and the mobile
core. The controller currently consumes `documents/`; its test-only reference
implementation also checks `merge.json` and `decisions.json`.

- `documents/valid/*.json` contains complete base-list documents that must pass
  validation. `documents/invalid/*.json` contains documents that must fail.
- `overrides/valid/*.json` and `overrides/invalid/*.json` follow the same layout
  for personal overrides. The limit is 500 entries **per list**; the valid limit
  fixture contains 500 direct and 500 proxy entries.
- Each invalid document or override has a sibling with the same basename and
  the `.error` extension. It contains one ASCII error code followed by a newline,
  for example `tld-not-allowed.json` and `tld-not-allowed.error`. Consumers read
  the sibling as UTF-8 and trim surrounding whitespace. The code is not embedded
  in the document being validated.
- `input.json` is an array of `{name, input, expected}` objects. `expected` is the
  normalized ASCII host, or JSON `null` when the input must be rejected.
- `merge.json` is an array of `{name, routing, base, overrides, expected}` objects.
  `base` and `overrides` are complete documents. `expected` contains the three
  arrays `proxy_suffix`, `direct_suffix` and `direct_domain`. Compare each array
  as a set: output order is irrelevant and duplicates must be removed.
- `decisions.json` is an array of `{name, rules, cases}` objects. Every case is
  `{host, expected}`, with `expected` equal to `direct` or `proxy`. Host comparison
  is case-insensitive and ignores a final dot. Address cases cover private,
  loopback and link-local bypass before domain matching.

The document error fixtures distinguish malformed document structure, unknown
fields and null collections (`invalid_document`), unsupported integer formats
(`format_unsupported`), absent or invalid positive integer versions
(`invalid_version`), invalid category metadata/count/content (`invalid_category`),
invalid domain syntax or a single-label exact name (`invalid_domain`), forbidden
single-label suffixes (`tld_not_allowed`), repeated names (`duplicate_entry`),
more than 3000 entries (`too_many_entries`) and more than 65536 UTF-8 bytes
(`too_large`). Personal overrides also reject the otherwise allowed base-list
single-label suffixes. Their repeated name and count errors use `duplicate_entry`
and `too_many_entries` respectively.

`documents/valid/max-bytes.json` is exactly 65536 bytes and
`documents/invalid/too-large.json` is exactly 65537 bytes. Both contain internal
JSON whitespace padding intentionally; do not reformat them. The entry-limit fixtures
use compact JSON so that the entry limit is checked independently of byte size.

## Punycode verification

`backend/go.sum` does not include `golang.org/x/net/idna`, so no dependency was
added. The Cyrillic examples were checked manually with Python 3's standard
library IDNA codec, using:

```sh
python3 - <<'PY'
for name in ['пример.рф', 'яндекс.рф']:
    print(name + ' -> ' + name.encode('idna').decode('ascii'))
PY
```

The results are `пример.рф -> xn--e1afmkfd.xn--p1ai` and
`яндекс.рф -> xn--d1acpjx3f.xn--p1ai`. The uppercase URL example is lowercased
before conversion and uses the first result. These examples use plain Cyrillic
labels and do not depend on differences between IDNA mapping profiles.
