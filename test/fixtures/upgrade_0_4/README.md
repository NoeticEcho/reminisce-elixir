# A store made by reminisce 0.4

Criterion 15 (docs/spec.md §C.12) upgrades this store to 0.5 and holds the
upgrade to its promise: a store with no DNA answers as it did.

- `backup/` is the store, as 0.4's `Reminisce.backup/2` wrote it, after one
  pass to 2026-02-01: the 60 invented records of `test/fixtures/import`,
  imported for the owner `project:quillmark`, and the invented memories of
  `make.exs`. They are, besides the records:
  - six intentions among I-101 to I-109: term, event, source and audience
    cues, and time triggers; I-104 is `:observed`, I-107 is about `reader-7`;
  - N-001, an `:observed` memory that contradicts D-002, and a causation from
    L-033 to D-002;
  - S-001, about `reader-7`, and S-002, about `reader-9`, with consents;
  - six affects: the owner's own on L-001 (told), D-002 and I-101
    (generated) and N-001 (resting on outside text, so capped), one felt by
    `reader-7` on S-001, and one on S-002, whose holder's affects were then
    withdrawn on their own (an `affect_withdrawing`);
  - D-003 superseded by D-101, and L-042 forgotten;
  - L-001, L-002 and D-002 marked recalled once;
  - Q-101, an intention of another owner, `agent:scribe`.
- `orders.json` is what 0.4 recalls for each of criterion 7's 20 queries
  (`k: 50`), with no audience and with the audience `reader-7`: the keys in
  order, the scores, the affect's part of each score, and the due list with
  what fired.
- `session.json` is the same queries as one session (`k: 8`), each recall
  given the focus the one before answered and the first told of
  `session_start`.
- `pass.json` is what 0.4's second pass, to 2026-06-01, answered, and
  `after_pass.jsonl` the `data.jsonl` of a backup taken after it.
- `orders_after_pass.json` is `orders.json` recalled again, after that pass.
- `make.exs` made all of it, run from a checkout of 0.4 (this repository's
  `main` at 2b97e4a), under a clock that starts on 2026-01-01 and moves a
  second a call until the backup, and then stays at 2026-06-01. The store
  decays with `decay: [inactive_below: 0.1]`; criterion 15 makes it the same.

## What the upgrade must answer, by hand

0.5 adds the fifteen types of §C.9 and converts nothing (§C.11). No memory of
this store has the aspect `persona`, and none of the fifteen names is a type,
so the upgrade is not refused, and it counts nothing: it answers
`from: "0.4"`, `to: "0.5"` and the fifteen names.

A store with no DNA recalls, decays and expires as 0.4 did (§C.4): no memory
grounds a strand, so no score is lifted and every `parts.persona` is 0. So
every order, affect part and due list above is 0.5's, the second pass answers
what `pass.json` holds, and the store it leaves backs up to
`after_pass.jsonl`, byte for byte.
