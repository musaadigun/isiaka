# isiaka
isiaka ideas

## XVISION Gold News Straddle EA (V9)

`XVISION_Gold_NewsStraddle_EA.mq4` — MT4 expert advisor that straddles
Gold/XAU around a scheduled news event with pending buy/sell stops, a
break-even stage, trailing exits, and an on-chart status panel.

**Configuration is done in the native F7 "Inputs" tab.** The trade-setup
fields (news time, lot, exit mode, distances, per-side TP/SL, trailing,
break-even) head the list; the news time is a `datetime` picker, so it can't
be mistyped. The on-chart panel is read-only status, apart from the CLOSE NOW
and CANCEL SETUP action buttons.

Version history:

- **V9** — interface redesign: all config in F7, `datetime` news picker,
  full input validation, rebuilt read-only panel.
- **V8** — fixed four V7 bugs (two of them traded the wrong size or traded a
  cancelled event).

See [REVIEW.md](REVIEW.md) for the full review and compare the commits
touching the `.mq4` file for the exact diffs. Compile in MetaEditor and
verify on a demo account through at least one event before live use.
