# Calendar and time zone: the compositor takes its zone from PLANET_TZ and the
# self-test covers GLib.Date, GLib.TimeZone, GLib.Uri, GLib.BookmarkFile and
# GLib.Hmac, plus one real paint of the calendar and places windows.
export PLANET_TZ=Europe/Madrid
compositor --self-test
