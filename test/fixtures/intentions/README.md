# Criterion 10's sessions

Criterion 10 (docs/spec.md §A.2, §A.9): intentions are surfaced when due, and
only then. Every due list in these files was worked out by hand, from the
spec's rules, and committed before the code that computes due lists. One entry
missing, extra or out of order fails the test.

## `session.json`: 30 intentions, 20 recalls

Every memory and intention is written at 2026-03-02 08:00 UTC under a fixed
clock, for the owner `agent:c10`. The twelve memories `B01`–`B12` are what
recall finds; each recall's one query word is in exactly one of them it may
see (`rollback` is in two, and `B11` comes first by key), and the recall asks
for `k: 1`. The intentions' words ("Reminder …") are in no query, so no
intention is ever in `memories` or in the focus.

The recalls run in order, with the store's clock set to each one's `at`, and
one focus (`Reminisce.Focus.new()`, the defaults) handed from each recall to
the next. After recall 2, `N01` is fulfilled by `B10`. `due` is the list under
the default `due_bases` (`told`, `inferred`, `generated`); `due_observed` the
list with `observed` added, in a second run of the same session.

How the lists follow:

- **The focus.** A cue comes in at 1,000 and fades to 700, 490, 343, 240, 168
  and 117 over the next six recalls; at the seventh it is 81, below 100, and
  leaves. Each recall brings in its query's one term and its one memory, both
  at 1,000, and that memory's source at 1,000: at most three cues a recall, so
  no more than 21 are ever held and the bound of 32 never acts. A cue is in
  the focus answered by the recall that brings it in and by the six after it,
  within one audience.
- **The audiences.** Recalls 1–11 are unscoped; 12–15 are for `ana`; 16 is for
  `ben`; 17–20 are unscoped again. Each change starts an empty focus
  (`focus_reset: true`), with no surfaced keys: an unscoped intention one
  audience was shown is shown again to the next.
- **Due.** An intention is due when it is active, its audience may see it,
  `valid_from` ≤ the clock < `valid_to`, and a trigger fires: its `due_at` is
  at or before the clock (`"time"`), an event the recall names, or a cue in
  the focus answered. The focus leaves out what it has surfaced. Of the rest,
  at most 3 come, by `due_at` (those without one last), then by key. `because`
  is `"time"` first, then each cue that fired.
- **What never comes, and why.** `N07` is due at 09:35 and expires at 09:38,
  between two recalls. `N29`'s event comes at 10:10, after its expiry at
  10:00. `N24` has no trigger. `N13`'s first `deploy`, at recall 7, is before
  its "not before"; its second, at recall 11, fires it. `N15`'s term comes in
  at recall 3, before its "not before", and fires it at recall 4 from the
  focus. `N01` would come again at recall 12, to `ana`, had it not been
  fulfilled. `N19` and `N21` are `ana`'s and `N20` is `ben`'s: no other
  audience is shown them. `N06`, `N16` and `N28` are `observed`: in no
  `due` list, and in `due_observed` where their triggers put them.
- **Deferred.** At recall 2, `N03`–`N05`, `N10`, `N14` and `N17` are due; three
  come, and the rest come at recall 3, `N14` from the focus's faded `lantern`
  (700) and `N17` from `B01`'s source.

`passes` are run on a fresh copy, without the session: each archives as
expired exactly the intentions whose `valid_to` its interval end reaches.

## `bound.json`: 80 intentions, 12 recalls, `due_k: 10`

The intentions `M01`–`M80` of `agent:c10-bound` are due a minute apart,
07:01 to 08:20, and every recall comes after 08:20 with one focus. Each
recall shows the 10 earliest not held. The focus keeps at most 64 surfaced
keys, and when more join, the earliest to join leave first:

- recalls 1–7 show `M01`–`M70`, and after recall 7 the keys of `M01`–`M06`
  leave;
- recall 8 shows `M01`–`M06` again, since their keys have gone, and `M71`–`M74`;
  `M07`–`M16` leave;
- recalls 9–12 show `M07`–`M16`, `M17`–`M26`, `M27`–`M36` and `M37`–`M46`, each
  batch let go by the recall before. `M75`–`M80` never come: there is always an
  earlier one whose key has gone.

Recall 13 is for another audience, so it starts an empty focus and shows
`M01`–`M10` again.
