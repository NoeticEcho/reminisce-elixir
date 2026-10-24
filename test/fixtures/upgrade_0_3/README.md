# A store made by reminisce 0.3.0

Criterion 15 (docs/spec.md §B.10) upgrades this store to 0.4 and holds the
upgrade to its promise: a store with no affect answers as it did.

- `backup/` is the store, as 0.3.0's `Reminisce.backup/2` wrote it, after one
  pass to 2026-02-01: the 60 invented records of `test/fixtures/import`,
  imported for the owner `project:quillmark`, and the invented memories of
  `make.exs`. They are, besides the records:
  - nine intentions, I-101 to I-109: term, event, source, memory and audience
    cues, and time triggers; I-104 is `:observed`, I-107 is about `reader-7`,
    I-108 is fulfilled by N-002;
  - N-001, an `:observed` memory that contradicts D-002; a causation from
    L-033 to D-002, and an association of L-004 and D-009;
  - S-001, about `reader-7`, with a consent;
  - D-003 superseded by D-101, and L-042 forgotten;
  - L-001, L-002 and D-002 marked recalled once;
  - Q-101, an intention of another owner, `agent:scribe`.
- `orders.json` is what 0.3.0 recalls for each of criterion 7's 20 queries
  (`k: 50`), with no audience and with the audience `reader-7`: the keys in
  order, the scores, and the due list with what fired.
- `session.json` is the same queries as one session (`k: 8`), each recall
  given the focus the one before answered and the first told of
  `session_start`.
- `pass.json` is what 0.3.0's second pass, to 2026-06-01, answered, and
  `after_pass.jsonl` the `data.jsonl` of a backup taken after it.
- `orders_after_pass.json` is `orders.json` recalled again, after that pass.
- `make.exs` made all of it, run from a checkout of 0.3.0 (this repository's
  `main` at e7079ab), under a clock that starts on 2026-01-01 and moves a
  second a call until the backup, and then stays at 2026-06-01. The store
  decays with `decay: [inactive_below: 0.1]`; criterion 15 makes it the same.

## What the upgrade must answer, by hand

0.4 adds the seven types of §B.7 and converts nothing (§B.9). No memory of
this store has the aspect `affective`, so the upgrade is not refused, and it
counts nothing: it answers `from: "0.3"`, `to: "0.4"` and the seven names.

A store with no affect recalls, decays and expires as 0.3 did (§B.3, §B.4):
no memory has an affect weight above zero, so no score is multiplied, no
`parts.affect` is above zero, no time constant is lengthened and no
`unslowed_salience` is written. So every order and due list above is 0.4's,
the second pass answers what `pass.json` holds (with `erased: 0` beside it),
and the store it leaves backs up to `after_pass.jsonl`, byte for byte.
