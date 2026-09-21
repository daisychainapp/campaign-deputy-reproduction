# Campaign Deputy API: issues found

API: `https://us.api.campaigndeputy.app` (spec: `/openapi/v1.json`, docs: `/scalar/`)
Investigated 2026-09-18 → 2026-09-19 against a Daisychain test account (US region).
Re-checked against the live API on 2026-09-21 after Campaign Deputy reported the issues fixed.
Repro client: [`repro.rb`](repro.rb) (plain Ruby, stdlib only).

## Status at the 2026-09-21 re-check

| # | Issue | Status |
|---|---|---|
| 1 | A person's `id` changes when the record is updated | **Still reproduces** through the web UI. Fixed on the new `PATCH` path. |
| 2 | `POST /v1/people` returns "queued" but the update never applies | Behaviour is now documented as intended. `requestId` is still unobservable. |
| 3 | `PUT /v1/people` response doesn't match the spec | Unchanged |
| 4 | Timestamp format differs between endpoints | Unchanged |
| 5 | Minor (204 instead of 404, endpoint naming, …) | Unchanged |
| 6 | `PATCH /v1/people/{personId}` is undocumented and returns 500 on success | **New** |

Two changes since the first report: the new `PATCH /v1/people/{personId}` endpoint, and a
rewritten description for `POST /v1/people`. `legacyId` is still documented as "Legacy numeric
identifier. Will be removed in the future."

---

## 1. A person's `id` changes when the record is updated (old id then returns 204)

**Severity: high. Still reproduces as of 2026-09-21 when the person is edited in the web UI.**

The docs say `legacyId` "will be removed in the future" and that "most API interactions used
the new ID method", yet the new `id` is not stable. After an edit the record gets a new `id`;
only `legacyId` stays the same. There is no redirect or link from the old id.
`GET /v1/people/{old id}` returns `204 No Content`, which is the same response as for an id
that never existed.

The behaviour now depends on how the record is edited: an update through
`PATCH /v1/people/{personId}` keeps the id, an edit in the web UI still replaces it. For an
integration this is not a partial fix, because the people in an account are overwhelmingly
edited by staff in the web app rather than through the API.

### Evidence: web UI edit still replaces the id (2026-09-21)

Record "FixCheck Alpha", `legacyId` 66899527, created through `PUT /v1/people` and not touched
since. Its name was changed to "FixCheckTest AlphaTest" in the web UI and saved:

| | `id` | `name` | `lastUpdatedOnUTC` | id's KSUID timestamp |
|---|---|---|---|---|
| before edit | `3JbouyRqryZyAsv4ut2WhJZdLu9` | FixCheck Alpha | 2026-09-20T21:22:34.42 | 2026-09-20T21:22:34Z |
| after edit | `3JdRhVLXs2b1gn8DgzqY2Bq5idy` | FixCheckTest AlphaTest | 2026-09-21T11:11:17.78Z | 2026-09-21T11:11:17Z |

```
GET /v1/people/3JbouyRqryZyAsv4ut2WhJZdLu9 (id held before the edit) -> 204
```

`createOnUTC` (2026-09-20T21:22:34.42Z) and `legacyId` (66899527) are unchanged. As in
September, the KSUID timestamp embedded in the new id is exactly the update time.

### Evidence: `PATCH` keeps the id (2026-09-21)

Record "Sortprobe Charlie", `legacyId` 66891255, updated with
`PATCH /v1/people/3JW0n6OLKxJys8KQllCdoEFk0ix` and a body of
`{"person":{"occupation":"IdStabilityProbe"}}` (see issue 6 for why that shape):

| | `id` | `occupation` | `lastUpdatedOnUTC` |
|---|---|---|---|
| before | `3JW0n6OLKxJys8KQllCdoEFk0ix` | — | 2026-09-18T20:01:20.22 |
| after | `3JW0n6OLKxJys8KQllCdoEFk0ix` | IdStabilityProbe | 2026-09-21T11:06:10.36Z |

```
GET /v1/people/3JW0n6OLKxJys8KQllCdoEFk0ix -> 200
```

The id is unchanged and its embedded KSUID timestamp is still `2026-09-18T20:01:20Z`, the
creation time, so on this path the id and `lastUpdatedOnUTC` have decoupled. This is the
behaviour we would expect of a stable identifier, and it suggests the new endpoint was built
without the re-minting while the web app's existing update path kept it.

### Original evidence (2026-09-18/19)

Record "Sortprobe Alpha", `legacyId` 66891253. Its last name was changed from `Alpha`
to `AlphaAlpha` in the Campaign Deputy web UI:

| | `id` | `familyName` | `lastUpdatedOnUTC` | `GET /v1/people/{id}` |
|---|---|---|---|---|
| before edit | `3JW5QrNRekBzUqilb3EZ2st3Dmy` | Alpha | 2026-09-18T20:39:30.87Z | **204 No Content** |
| after edit | `3JWCUlkhCfsMiI0hQbtS96NEYES` | AlphaAlpha | 2026-09-18T21:37:34.92Z | 200 |

Both ids still return the same statuses on 2026-09-21, so no retroactive mapping from
replaced ids was added.

### Why it happens (inferred)

The ids are [KSUIDs](https://github.com/segmentio/ksuid), which start with a
timestamp. For a record edited in the web UI, the timestamp inside the id matches that
record's `lastUpdatedOnUTC` to the second:

```
$ ruby repro.rb --decode 3JbouyRqryZyAsv4ut2WhJZdLu9 3JdRhVLXs2b1gn8DgzqY2Bq5idy 3JW0n6OLKxJys8KQllCdoEFk0ix
3JbouyRqryZyAsv4ut2WhJZdLu9  2026-09-20T21:22:34Z   <- FixCheck before the UI edit (= createOnUTC)
3JdRhVLXs2b1gn8DgzqY2Bq5idy  2026-09-21T11:11:17Z   <- FixCheck after the UI edit (= lastUpdatedOnUTC)
3JW0n6OLKxJys8KQllCdoEFk0ix  2026-09-18T20:01:20Z   <- Sortprobe Charlie, PATCHed: still = createOnUTC
```

Not every update regenerated the id even in September. Person `3JSpBaQIvMzDa3fehlK7WvxQEUB`
(`legacyId` 66879805) was created at 2026-09-17T16:56:28Z and updated at 17:01:56Z, and its id
still carries the creation time.

### Impact

Any integration that stores `id` loses track of the person after the next edit made in the web
UI. Stored ids start returning 204, which looks like a deleted person, and the integration
then has no way to tell a renamed person from a deleted one — on re-sync it creates a
duplicate. The only key that survives both edit paths is `legacyId`, which the docs say will be
removed. So the API still offers no stable identifier that it plans to keep.

### Repro

```
ruby repro.rb <person_id>          # snapshots the person, then waits for you to edit it in the web UI
ruby repro.rb <person_id> --api    # same, but performs the edit via POST /v1/people
ruby repro.rb --api                # creates a fresh person via PUT, then edits it via POST
```

---

## 2. `POST /v1/people` (add-or-update) returns "queued" but the update never applies

**Now documented as intended behaviour.** The endpoint's description has been rewritten since
the first report and now states that `POST /v1/people` is for "untrusted, externally sourced
data", that it "will never overwrite the core fields of a person who already exists", and that
when a submission matches an existing person "the values in the request are discarded". That
explains the observation below: the record matched on email, so the new `familyName` was
dropped on purpose. `PATCH /v1/people/{personId}` is the endpoint for updating a known person.

One part of this is still open: the `201` response carries a `requestId`, but there is no
endpoint to look one up, so a caller cannot find out whether a submission was applied,
matched and discarded, or rejected.

The original observation, for reference. Request (2026-09-19 14:11:10 UTC), with a
full-permission key:

```json
POST /v1/people
{ "person": { "name": { "givenName": "IdProbe", "familyName": "AlphaX" },
              "primaryEmailAddress": "idprobe-20260919140939@example.com" },
  "options": { "matchOnEmail": true } }
```

Response `201`:

```json
{ "requestId": "720a374e-ab2a-4692-90f4-98c5c53eb7ae", "status": "queued",
  "receivedAtUtc": "2026-09-19T14:11:10.0783345Z" }
```

The target person (`legacyId` 66893912, same email) was unchanged 13 minutes later, and no new
record was created. Guessed lookup URLs (`/v1/requests/{id}`, `/v1/people/requests/{id}`,
`/v1/people/status/{id}`, …) return 404, and `GET /v1/people/{requestId}` returns 204.

---

## 3. `PUT /v1/people` response doesn't match the spec

**Unchanged as of 2026-09-21.**

The spec says the `200` response is a `Person` object (`id`, `legacyId`, `name`, …); the schema
for `PUT /v1/people` is still `{"$ref": "#/components/schemas/Person"}`. The actual response,
from a create made on 2026-09-20:

```json
{ "data": { "personId": "3JbouyRqryZyAsv4ut2WhJZdLu9", "messages": null } }
```

No schema in `openapi/v1.json` has this shape. Generated clients will parse it wrong, and there
will be no `id`. The endpoint's description does mention a "Messages" property, so the prose
appears to match the real response and the schema doesn't.

---

## 4. Timestamp format differs between endpoints

**Unchanged as of 2026-09-21.**

The same field is formatted differently depending on the endpoint:

| Endpoint | `lastUpdatedOnUTC` |
|---|---|
| `GET /v1/people/{id}` | `2026-09-20T21:22:34.42` (no zone designator) |
| `GET /v1/peoples` | `2026-09-20T21:22:34.42Z` |

Without the `Z`, most parsers treat the value as local time. Name parts are also inconsistent:
`suffix`/`prefix` are `null` from `/v1/people/{id}` but `""` from `/v1/peoples`.

---

## 5. Minor

**Unchanged as of 2026-09-21** unless noted.

- **Unknown id returns `204`, not `404`.** `GET /v1/people/{id}` answers `204 No Content`
  for an id that doesn't exist, has been replaced (issue 1), or was deleted. The client
  can't tell these cases apart. The new `PATCH /v1/people/{personId}` does document a `404`,
  so the two endpoints now disagree about how a missing person is reported.
- **A newly created person may not be readable right away.** The docs say the id "might
  not be available immediately", so clients have to poll after a create.
- **Endpoint naming violates REST conventions.** A collection and its members should share
  one resource path (`GET /v1/people` lists, `GET /v1/people/{id}` fetches one). Here the
  list lives at a different resource, `GET /v1/peoples`, while `/v1/people` only accepts
  `PUT`/`POST`. The verbs are also reversed from the usual meaning: `PUT /v1/people`
  creates a new record each time (not idempotent), and `POST /v1/people` does the
  add-or-update. Similarly, `PUT /v1/tag` and `PUT /v1/tasks` create records, and
  `POST /v1/attributioncode/{id}` updates one.
- **`DELETE /v1/people/{id}` takes a `Person` request body** according to the spec.
- **`metadata.totalRecords` is `null`** on `GET /v1/peoples`, so the page count is unknown.

---

## 6. `PATCH /v1/people/{personId}` has no usable request schema, and returns 500 when it succeeds

**Severity: high. New endpoint, found during the 2026-09-21 re-check.**

`PATCH /v1/people/{personId}` is the endpoint the docs now point to for updating a person you
already hold the id for, and it is the only update path that preserves the id (issue 1). It
cannot be called from the spec as published, and when it does work it reports failure.

### The request body isn't described

The spec types the request body as a free-form dictionary:

```json
{ "type": "object", "additionalProperties": { "$ref": "#/components/schemas/JsonNode" } }
```

`JsonNode` is a .NET serialization artifact whose properties are `options`, `parent` and
`root`. It describes nothing about the payload, and there are no examples. The prose refers to
`options.overwriteWithNull`, `custom_fields` and `additionalPhones`, which suggests person
fields at the top level alongside an `options` object, but that shape is rejected.

### Documented-looking shapes are rejected; an undocumented one succeeds with a 500

All against `PATCH /v1/people/{personId}` with a valid key, on 2026-09-20 and 2026-09-21:

| Request body | Response | Applied? |
|---|---|---|
| `{"occupation":"Tester"}` | `400 Unable to parse person model` | no |
| `{"name":{"givenName":"Sortprobe","familyName":"BravoPatched"}}` | `400 Unable to parse person model` | no |
| `{"occupation":"Tester","options":{"overwriteWithNull":false}}` | `400 Unable to parse person model` | no |
| `{"Name":{"GivenName":"Sortprobe","FamilyName":"BravoPatched"}}` (PascalCase) | `400 Unable to parse person model` | no |
| `{"person":{"occupation":"IdStabilityProbe"}}` | **`500 Internal server error. Please retry later.`** | **yes** |
| `{"person":{"name":{…}},"options":{"overwriteWithNull":false}}` | **`500 Internal server error. Please retry later.`** | **yes** |

Using `legacyId` in the path instead of `id` also returns `400 Unable to parse person model`.

The 400s are true no-ops: "Sortprobe Charlie" was sent `{"occupation":"IdStabilityProbe"}`, got
a 400, and its `occupation` and `lastUpdatedOnUTC` were both unchanged afterwards. The 500s are
not. The same record, sent `{"person":{"occupation":"IdStabilityProbe"}}`, returned 500 and the
update was applied in full, with `lastUpdatedOnUTC` moving to 2026-09-21T11:06:10.36Z. The
partial-update semantics worked correctly: on another record only `familyName` was sent and
`givenName` was preserved.

So the response appears to be generated after the write, and the write itself is fine.

### Impact

- A client that follows the published spec cannot update a person at all.
- A client that finds the working shape gets a `500` telling it to "retry later" on every
  successful write. Retrying re-applies the update, and a client with normal retry-on-5xx
  behaviour will write repeatedly. There is no way to distinguish this 500 from a real one.
- Because `PATCH` is the only path that preserves `id` (issue 1), this is currently the only
  way to update a person without invalidating the identifier an integration has stored.
