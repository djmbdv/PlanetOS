# Slice 54 - time zones, calendar, URIs and markup

Status: **implemented.** The GLib pieces that were still listed as "future
slices" are in `stdlib/glib/`, and the compositor uses them for a real feature:
a top-bar clock that prints the date and time in the configured zone, plus a
calendar window and a places window.

## 1. New APIs

| API | File | Notes |
|---|---|---|
| `TimeZone`, `Date`, `DateMonth`, `DateWeekday`, `DateDMY` | `stdlib/glib/time.vala` | fixed-offset zones plus a table of common IANA identifiers, EU/US-style DST, `new_local ()` from `TZ`/`PLANET_TZ` |
| `DateTime` extensions | same | `now_local`, `to_timezone`, `to_local`, `get_timezone`, `get_weekday`, `format` |
| `Uri`, `UriFlags`, `UriError` | `stdlib/glib/uri.vala` | RFC 3986 parse/build/resolve, dot-segment removal, percent escaping |
| `BookmarkFile`, `BookmarkFileError` | `stdlib/glib/bookmark.vala` | `[Bookmark N]` groups over `KeyFile`, every URI validated by `Uri.parse` |
| `MarkupParser`, `MarkupParseContext`, `MarkupParseFlags` | `stdlib/glib/utils.vala` | elements, attributes, text, CDATA, comments, processing instructions |
| `OptionGroup` | `stdlib/glib/test_option.vala` | `OptionContext.add_group`; `get_help ()` prints a heading per group |
| `Hmac`, `Checksum.get_digest` | `stdlib/glib/codec.vala` | RFC 2104 over the existing SHA-256 |
| `Datalist` | `stdlib/glib/core.vala` | `g_object_set_data`-shaped key/value store |

## 2. Two dialect limits found while wiring them

**Struct `this` is passed by value.** A mutating method on a struct
(`g_date_add_months` style) cannot change the caller's copy, so `Date` is a
class in this shim. The API surface is unchanged (`Date.dmy`, `set_dmy`,
`add_days`, `add_months`, `clamp`); only the value/reference semantics differ,
and the calendar passes dates around by value.

**Default arguments are only filled for `var x = call (...)`.** A call nested
inside another expression — as an argument, a method receiver, or inside `@"…"`
— fails with `expects N argument(s), got M`. Call sites therefore pass the
optional arguments explicitly (`Uri.parse (s, UriFlags.NONE)`,
`Hmac.compute_for_string (t, key, data, -1)`).

## 3. Compositor integration

| Window / control | API | What it shows |
|---|---|---|
| top bar | `DateTime` + `TimeZone` | `Sat 23 Nov 16:05:33 -04` (zone from `TZ`/`PLANET_TZ`) |
| `Kind.CALENDAR` | `Date` + `DateTime` + `TimeZone` | month grid, today highlighted, zone identifier and numeric offset, seconds in the footer; `[` / `]` change month, `t` returns to today |
| `Kind.PLACES` | `BookmarkFile` + `Uri` | path and title of each bookmark; header says `hmac ok` when `places.sig` matches |
| `cursor.svg` | `MarkupParseContext` | first `<path d="…">`, with the previous string scan kept as a fallback |
| `Win.set_data` | `Datalist` | month shown by each calendar window |

The places list is read once at start-up from `places.gbk`; when the file is
missing or its `places.sig` sidecar (HMAC-SHA256 over `to_data ()`) does not
match, the built-in `/`, `/tmp`, `/test` entries are used.

## 4. Kernel fix the extra file I/O exposed

`Xfs.read_file`/`write_file` used a **per-call** `Pmm.alloc_frame ()` as the ATA
bounce buffer. Under a user CR3 only the supervisor window is mapped, so once
the frame allocator handed out a frame above it, `rep insw` faulted:
`[fault] Page Fault [kernel/write/unmapped] ... rip=ata_read_words`. The
compositor self-test surfaced it as the second and third `compositor` run of
`graphics` dying before their first line, while the first run passed. The
bounce frame is now allocated once, together with `xfs_sec_buf`, and reused.

## 5. Verification

- `tests/cases/calendar.sh` exports `PLANET_TZ=Europe/Madrid`, runs
  `compositor --self-test` and asserts `tz=Europe/Madrid`.
- The self-test adds 20 checks: `Date` fields/leap/clamp/round-trip, Madrid and
  New York DST offsets at a winter and a summer instant, Caracas `-04:00`,
  unknown-zone rejection, `DateTime` round-trip through UTC, `Uri` path/authority
  /query/fragment/escape/resolve, `BookmarkFile` round-trip, the RFC 4231
  HMAC-SHA256 vector, place loading, and signature accept/reject.
- `Date.today ()` is asserted to be in 2024..2100, which is what catches a bad
  `SYS_RTC_TIME` decode.
- `graphics`, `calendar`, `exec`, `gio`, `mainloop`, `time` and `system` pass in
  QEMU: **20/20 cases** with `compositor:summary checks=145 failures=0` on all
  three graphics runs, and `tools/c2vala_tests/run.py` stays at 14/14.
