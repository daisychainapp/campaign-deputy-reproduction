# Campaign Deputy API: issues found

API: `https://us.api.campaigndeputy.app` (spec: `/openapi/v1.json`, docs: `/scalar/`)
Investigated 2026-09-18 → 2026-09-19 against a Daisychain test account (US region).
Repro client: [`repro.rb`](repro.rb) (plain Ruby, stdlib only).

---

## 1. A person's `id` changes when the record is updated (old id then returns 204)

**Severity: high.** The docs say `legacyId` "will be removed in the future" and that
"most API interactions used the new ID method", yet the new `id` is not stable. After an
edit the record gets a new `id`; only `legacyId` stays the same. There is no redirect or
link from the old id. `GET /v1/people/{old id}` returns `204 No Content`, which is the
same response as for an id that never existed.

### Evidence (live data, read with the API key)

Record "Sortprobe Alpha", `legacyId` 66891253. Its last name was changed from `Alpha`
to `AlphaAlpha` in the Campaign Deputy web UI:

| | `id` | `familyName` | `lastUpdatedOnUTC` | `GET /v1/people/{id}` today |
|---|---|---|---|---|
| before edit | `3JW5QrNRekBzUqilb3EZ2st3Dmy` | Alpha | 2026-09-18T20:39:30.87Z | **204 No Content** |
| after edit | `3JWCUlkhCfsMiI0hQbtS96NEYES` | AlphaAlpha | 2026-09-18T21:37:34.92Z | 200 |

`createOnUTC` (2026-09-18T20:01:02.67Z) and `legacyId` (66891253) are the same in both.

### Why it happens (inferred)

The ids are [KSUIDs](https://github.com/segmentio/ksuid), which start with a
timestamp. The timestamp inside each id matches that record's `lastUpdatedOnUTC` to the
second:

```
$ ruby repro.rb --decode 3JW5QrNRekBzUqilb3EZ2st3Dmy 3JWCUlkhCfsMiI0hQbtS96NEYES 3JW0lKLQkp7SsvBmW64Q3H2gKB9
3JW5QrNRekBzUqilb3EZ2st3Dmy  2026-09-18T20:39:30Z   <- = lastUpdatedOnUTC of the pre-edit record
3JWCUlkhCfsMiI0hQbtS96NEYES  2026-09-18T21:37:34Z   <- = lastUpdatedOnUTC after the edit
3JW0lKLQkp7SsvBmW64Q3H2gKB9  2026-09-18T20:01:06Z   <- never-edited record: = createOnUTC
```

This suggests a new `id` is generated when the person is updated.

Not every update does this, though. Person `3JSpBaQIvMzDa3fehlK7WvxQEUB` (`legacyId`
66879805) was created at 2026-09-17T16:56:28Z and updated at 17:01:56Z. Its id still
carries the creation time, so that update kept the id. We don't know which kinds of
edit generate a new id.

### Impact

Any integration that stores `id` loses track of the person after the next edit. Stored
ids start returning 204, which looks like a deleted person. The only stable key is
`legacyId`, which the docs say will be removed. So the API currently offers no stable
identifier that it plans to keep.

### Repro

```
ruby repro.rb <person_id>          # snapshots the person, then waits for you to edit it in the web UI
ruby repro.rb <person_id> --api    # same, but performs the edit via POST /v1/people
ruby repro.rb --api                # creates a fresh person via PUT, then edits it via POST
```

### Reproduced end to end (2026-09-19)

1. 14:09:40 UTC: `PUT /v1/people` created "IdProbe Alpha" → `personId` `3JY9APPBgKjuFJm4LHnodAjBYGv`.
2. `ruby repro.rb 3JY9APPBgKjuFJm4LHnodAjBYGv` snapshotted it (`GET` → 200, `legacyId` 66893912).
3. 14:30:10 UTC: changed Last Name `Alpha` → `AlphaAlpha` in the web UI
   (`/Persons/Edit/66893912`) and pressed Save. Nothing else was touched.
4. Script output:

```
  before: "id": "3JY9APPBgKjuFJm4LHnodAjBYGv", "legacyId": 66893912, familyName "Alpha",
          lastUpdatedOnUTC 2026-09-19T14:09:50.72   (id's KSUID timestamp: 14:09:50Z)
  after:  "id": "3JYBdkONb2myxhH7GRywmZAmcDu", "legacyId": 66893912, familyName "AlphaAlpha",
          lastUpdatedOnUTC 2026-09-19T14:30:10.76Z  (id's KSUID timestamp: 14:30:10Z)
  GET /v1/people/3JY9APPBgKjuFJm4LHnodAjBYGv (original id) -> 204
  GET /v1/people/3JYBdkONb2myxhH7GRywmZAmcDu (new id)      -> 200
  REPRODUCED: updating the record changed its id; legacyId 66893912 unchanged; old id now returns 204.
```

The new id's embedded timestamp is again exactly the update time.

---

## 2. `POST /v1/people` (add-or-update) returns "queued" but the update never applies

Request (2026-09-19 14:11:10 UTC), with a full-permission key:

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

Resent at 14:21:38 UTC (`requestId` `6c6d1d33-2352-4d20-9d93-7bd3e70016ca`), again `201 queued`.

As of 14:24 UTC, 13 minutes after the first request and 3 minutes after the second:
- The target person (`3JY9APPBgKjuFJm4LHnodAjBYGv`, `legacyId` 66893912, same email)
  is unchanged. `familyName` is still `Alpha` and `lastUpdatedOnUTC` is still the
  creation time.
- No new record was created either.
- The API has no endpoint for looking up a `requestId`, so there's no way to find out
  what happened to the request. The spec doesn't document one, and guessed URLs
  (`/v1/requests/{id}`, `/v1/people/requests/{id}`, `/v1/people/status/{id}`, …) return
  404. `GET /v1/people/{requestId}` returns 204, like any other unknown id.

---

## 3. `PUT /v1/people` response doesn't match the spec

The spec says the `200` response is a `Person` object (`id`, `legacyId`, `name`, …).
The actual response is:

```json
{ "data": { "personId": "3JY9APPBgKjuFJm4LHnodAjBYGv", "messages": null } }
```

No schema in `openapi/v1.json` has this shape. Generated clients will parse it wrong,
and there will be no `id`. The endpoint's description does mention a "Messages"
property, so the prose appears to match the real response and the schema doesn't.

---

## 4. Timestamp format differs between endpoints

The same field is formatted differently depending on the endpoint:

| Endpoint | `lastUpdatedOnUTC` |
|---|---|
| `GET /v1/people/{id}` | `2026-09-18T20:01:06.43` (no zone designator) |
| `GET /v1/peoples` | `2026-09-18T20:01:06.43Z` |

Without the `Z`, most parsers treat the value as local time. Name parts are also
inconsistent: `suffix`/`prefix` are `null` from `/v1/people/{id}` but `""` from
`/v1/peoples`.

---

## 5. Minor

- **Unknown id returns `204`, not `404`.** `GET /v1/people/{id}` answers `204 No Content`
  for an id that doesn't exist, has been replaced (issue 1), or was deleted. The client
  can't tell these cases apart.
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
