# Campaign Deputy API reproduction

Reproduction case and findings for issues in the Campaign Deputy public API
(`https://us.api.campaigndeputy.app`), prepared by [Daisychain](https://daisychain.app)
for Campaign Deputy Support.

- **[report.md](report.md)**: all findings, with evidence. The main one: a person's `id`
  changes when the record is edited, and the old `id` then returns `204 No Content`.
- **[repro.rb](repro.rb)**: small Ruby client (stdlib only) that reproduces it.

## Run it

```
cp .env.example .env      # add your API key(s)
ruby repro.rb <person_id>
```

The script snapshots the person, then polls for up to 10 minutes. While it waits, edit
that person in the Campaign Deputy web UI (for example, change the last name) and save.
It then prints the `id` before and after, the unchanged `legacyId`, and the HTTP status
each `id` now returns.

Other modes:

```
ruby repro.rb <person_id> --api    # make the edit via POST /v1/people instead (see report, issue 2)
ruby repro.rb --api                # create a fresh person via PUT, then edit via POST
ruby repro.rb --decode <id> [...]  # print the timestamp embedded in a person id (KSUID)
```
