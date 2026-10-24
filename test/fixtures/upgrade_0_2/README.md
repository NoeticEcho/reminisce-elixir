# A store made by reminisce 0.2.1

Criterion 15 (docs/spec.md §A.9) upgrades this store to 0.3 and holds the
upgrade to its promise: the store answers as it did.

- `backup/` is the store, as 0.2.1's `Reminisce.backup/2` wrote it: the 60
  invented records of `test/fixtures/import`, imported for the owner
  `project:quillmark`, and the invented prospective memories of `make.exs`.
- `orders.json` is the order, with the scores, in which 0.2.1 recalls each of
  criterion 7's 20 queries (`k: 50`, no subject) on that store.
- `orders_after_expiry.json` is the order in which 0.2.1 recalls them once
  P-002, P-004 and P-012, the quillmark memories the first 0.3 pass expires,
  are archived. Taking memories out moves every idf weight, so this, and not
  `orders.json` with three keys struck out, is the order an upgraded store
  must answer after that pass.
- `make.exs` made all three, run from a checkout of 0.2.1, under a clock that
  starts on 2026-01-01 and moves a second a call.
- `expected.json` holds the counts `upgrade/1` must answer under a store clock
  of 2026-06-01, worked out by hand from `make.exs` (below), not by any code.

## The counts, by hand

An intention is an active memory with the aspect `prospective` and a trigger;
in a 0.2 store the only trigger is a `due_at`. The prospective memories:

| key | owner | basis | `due_at` | `valid_to` | status | intention | kept out of `due` | expiring at 2026-06-01 |
|---|---|---|---|---|---|---|---|---|
| P-001 | project:quillmark | told | 2026-02-01 | — | active | yes | no | no |
| P-002 | project:quillmark | told | 2026-03-01 | 2026-03-15 | active | yes | no | yes |
| P-003 | project:quillmark | observed | 2026-02-10 | — | active | yes | yes | no |
| P-004 | project:quillmark | observed | 2026-02-20 | 2026-04-01 | active | yes | yes | yes |
| P-005 | project:quillmark | inferred | 2026-07-01 | — | active | yes | no | no |
| P-006 | project:quillmark | generated | 2026-05-01 | 2026-12-31 | active | yes | no | no |
| P-007 | project:quillmark | told | — | 2026-02-01 | active | no: no `due_at` | — | — |
| P-008 | project:quillmark | told | 2026-03-01 | closed by P-009 | superseded | no: not active | — | — |
| P-009 | project:quillmark | told | 2026-04-01 | — | active | yes | no | no |
| P-010 | project:quillmark | told | 2026-01-20 | 2026-02-15 | forgotten | no: not active | — | — |
| P-011 | project:quillmark, about `reader-7` | told | 2026-03-10 | — | active | yes | no | no |
| P-012 | project:quillmark | generated | 2026-02-25 | 2026-05-01 | active | yes | no | yes |
| Q-001 | agent:scribe | told | 2026-02-02 | 2026-03-01 | active | yes | no | yes |

So: 10 intentions; 2 of them (`observed`) kept out of `due` by the default
`due_bases`; 4 expiring, of which P-002, P-004 and P-012 are quillmark's and
Q-001 is scribe's. P-002, P-004 and P-012 are among the answers recorded in
`orders.json`, so a pass that expires them changes those orders by exactly
their removal.
