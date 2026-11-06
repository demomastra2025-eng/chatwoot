# Contact name search

`Search::ContactNameQuery` is shared by `Search::ContactQuery` (UI/global/conversation searches),
Captain/MCP `search_contacts.name`, and synthetic Playground contacts. It searches `name`,
`last_name`, and `middle_name`, including partial names and up to five words in any order.
All words must match. Longer queries retain the literal full-phrase search without dropping words.

Names can be typed in Cyrillic or Latin: `Алмас`, `Almas`, `АЛМ` and `alm` find both spellings.
The helper preserves case-insensitive matching and `е/ё`, and cleans pasted Unicode spaces/marks.
It escapes SQL wildcards and regexp operators: `%` and `_` in a name mean those literal characters.

The bounded query-side spelling rules use at most four Latin profiles plus the original text,
one original `е/ё` regexp, its Latin `e/yo` counterpart and one greedy Latin-to-Cyrillic regexp. No stored column is transformed;
ILIKE and regexp predicates can use existing trigram indexes. Input is capped at 200 characters.
Latin digraphs include `shch/sch`, `zh`, `ch`, `sh`, `kh`, `gh`, `ng`, `yo`, `yu`, `ya`, `ye`, `ts`.
Fixed Kazakh spelling candidates cover `q/k→қ`, `gh/g→ғ`, `ng→ң/нг`, `a→а/ә`, `o→о/ө`,
`u→у/ұ/ү`, `i→и/і/й`, and `y→ы/й`. Cyrillic-to-Latin profiles include `қ→q/k`, `ғ→gh/g`,
`х→kh/h`, `ё→yo/e`, `й→y/i`; distinct original Cyrillic letters are not equated.
This is a finite spelling convention, not arbitrary name translation or fuzzy matching.
It returns all candidates, including collisions; agents must clarify ambiguous results.

MCP still intersects exact email and existing phone filters, retains tenant/patient scope, permission
checks, count-before-limit and the 50-result cap. Its payload adds `last_name`, `middle_name`, and
`display_full_name` to help choose a candidate; existing fields and the IIN sanitizer remain.
Names do not search email, identifiers, or phone columns. General `ContactQuery` keeps its existing
literal email/identifier and normalized phone predicates and IIN visibility policy.
