// Pure-Vala GLib.Time (valadoc.org/glib-2.0/GLib.Time.html) and clock helpers.
using Planet;

namespace GLib {

    public struct Time {
        public int second;
        public int minute;
        public int hour;
        public int day;
        public int month;
        public int year;
        public int weekday;
        public int day_of_year;
        public int isdst;

        private static bool is_leap (int full_year) {
            if (full_year % 4 != 0)
                return false;
            if (full_year % 100 != 0)
                return true;
            return (full_year % 400 == 0);
        }

        private static int days_in_month (int full_year, int mon0) {
            switch (mon0) {
                case 0: return 31;
                case 1: return is_leap (full_year) ? 29 : 28;
                case 2: return 31;
                case 3: return 30;
                case 4: return 31;
                case 5: return 30;
                case 6: return 31;
                case 7: return 31;
                case 8: return 30;
                case 9: return 31;
                case 10: return 30;
                case 11: return 31;
                default: return 30;
            }
        }

        private static int64 floor_div (int64 a, int64 b) {
            int64 q = a / b;
            int64 r = a % b;
            if (r != 0 && ((r < 0) != (b < 0)))
                q--;
            return q;
        }

        private static int64 floor_mod (int64 a, int64 b) {
            int64 r = a % b;
            if (r != 0 && ((r < 0) != (b < 0)))
                r += b;
            return r;
        }

        public static Time gm (int64 time) {
            int64 days = floor_div (time, 86400);
            int64 rem = floor_mod (time, 86400);

            Time tm = Time ();
            tm.hour = (int) (rem / 3600);
            rem = rem % 3600;
            tm.minute = (int) (rem / 60);
            tm.second = (int) (rem % 60);
            tm.isdst = 0;

            // 1970-01-01 was a Thursday (weekday = 4).
            tm.weekday = (int) floor_mod (days + 4, 7);

            // Howard Hinnant's civil-from-days algorithm (epoch 1970-01-01).
            int64 z = days + 719468;
            int64 era = (z >= 0 ? z : z - 146096) / 146097;
            int64 doe = z - era * 146097;
            int64 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
            int64 y = yoe + era * 400;
            int64 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            int64 mp = (5 * doy + 2) / 153;
            int d = (int) (doy - (153 * mp + 2) / 5 + 1);
            int m = (int) (mp + (mp < 10 ? 3 : -9));
            int full_y = (int) (y + (m <= 2 ? 1 : 0));

            tm.year = full_y - 1900;
            tm.month = m - 1;
            tm.day = d;

            int yday = 0;
            for (int i = 0; i < tm.month; i++)
                yday += days_in_month (full_y, i);
            tm.day_of_year = yday + (d - 1);
            return tm;
        }

        public static Time local (int64 time) {
            return gm (time);
        }

        public int64 mktime () {
            int full_y = year + 1900;
            int m = month + 1;
            int d = day;

            // Normalize month overflow/underflow into full_y.
            if (m < 1 || m > 12) {
                int adj_y = (int) floor_div ((int64) (m - 1), 12);
                full_y += adj_y;
                m = (int) floor_mod ((int64) (m - 1), 12) + 1;
            }

            int64 y = (int64) full_y - (m <= 2 ? 1 : 0);
            int64 era = (y >= 0 ? y : y - 399) / 400;
            int64 yoe = y - era * 400;
            int64 doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
            int64 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
            int64 days = era * 146097 + doe - 719468;

            return days * 86400 + (int64) hour * 3600 + (int64) minute * 60 + (int64) second;
        }

        private static string pad2 (int v) {
            if (v < 0)
                return v.to_string ();
            if (v < 10)
                return "0" + v.to_string ();
            return v.to_string ();
        }

        private static string pad4 (int v) {
            if (v < 0)
                return v.to_string ();
            if (v < 10) return "000" + v.to_string ();
            if (v < 100) return "00" + v.to_string ();
            if (v < 1000) return "0" + v.to_string ();
            return v.to_string ();
        }

        private static string pad_space2 (int v) {
            if (v >= 0 && v < 10)
                return " " + v.to_string ();
            return v.to_string ();
        }

        private static string pad3 (int v) {
            if (v < 0) return v.to_string ();
            if (v < 10) return "00" + v.to_string ();
            if (v < 100) return "0" + v.to_string ();
            return v.to_string ();
        }

        private static string abbr_wday (int w) {
            switch (w) {
                case 0: return "Sun";
                case 1: return "Mon";
                case 2: return "Tue";
                case 3: return "Wed";
                case 4: return "Thu";
                case 5: return "Fri";
                case 6: return "Sat";
                default: return "?";
            }
        }

        private static string full_wday (int w) {
            switch (w) {
                case 0: return "Sunday";
                case 1: return "Monday";
                case 2: return "Tuesday";
                case 3: return "Wednesday";
                case 4: return "Thursday";
                case 5: return "Friday";
                case 6: return "Saturday";
                default: return "?";
            }
        }

        private static string abbr_month (int m) {
            switch (m) {
                case 0: return "Jan";
                case 1: return "Feb";
                case 2: return "Mar";
                case 3: return "Apr";
                case 4: return "May";
                case 5: return "Jun";
                case 6: return "Jul";
                case 7: return "Aug";
                case 8: return "Sep";
                case 9: return "Oct";
                case 10: return "Nov";
                case 11: return "Dec";
                default: return "?";
            }
        }

        private static string full_month (int m) {
            switch (m) {
                case 0: return "January";
                case 1: return "February";
                case 2: return "March";
                case 3: return "April";
                case 4: return "May";
                case 5: return "June";
                case 6: return "July";
                case 7: return "August";
                case 8: return "September";
                case 9: return "October";
                case 10: return "November";
                case 11: return "December";
                default: return "?";
            }
        }

        public string format (string fmt) {
            var sb = new StringBuilder ();
            int n = fmt.length;
            int full_y = year + 1900;
            for (int i = 0; i < n; i++) {
                char c = fmt[i];
                if (c != '%' || i + 1 >= n) {
                    sb.append_c (c);
                    continue;
                }
                i++;
                char sp = fmt[i];
                if (sp == '%') {
                    sb.append_c ('%');
                } else if (sp == 'Y') {
                    sb.append (pad4 (full_y));
                } else if (sp == 'y') {
                    int yy = full_y % 100;
                    if (yy < 0) yy += 100;
                    sb.append (pad2 (yy));
                } else if (sp == 'm') {
                    sb.append (pad2 (month + 1));
                } else if (sp == 'd') {
                    sb.append (pad2 (day));
                } else if (sp == 'e') {
                    sb.append (pad_space2 (day));
                } else if (sp == 'H') {
                    sb.append (pad2 (hour));
                } else if (sp == 'I') {
                    int h12 = hour % 12;
                    if (h12 == 0) h12 = 12;
                    sb.append (pad2 (h12));
                } else if (sp == 'M') {
                    sb.append (pad2 (minute));
                } else if (sp == 'S') {
                    sb.append (pad2 (second));
                } else if (sp == 'p') {
                    sb.append (hour < 12 ? "AM" : "PM");
                } else if (sp == 'P') {
                    sb.append (hour < 12 ? "am" : "pm");
                } else if (sp == 'j') {
                    sb.append (pad3 (day_of_year + 1));
                } else if (sp == 'w') {
                    sb.append (weekday.to_string ());
                } else if (sp == 'u') {
                    sb.append ((weekday == 0 ? 7 : weekday).to_string ());
                } else if (sp == 'a') {
                    sb.append (abbr_wday (weekday));
                } else if (sp == 'A') {
                    sb.append (full_wday (weekday));
                } else if (sp == 'b' || sp == 'h') {
                    sb.append (abbr_month (month));
                } else if (sp == 'B') {
                    sb.append (full_month (month));
                } else if (sp == 'F') {
                    sb.append (pad4 (full_y));
                    sb.append_c ('-');
                    sb.append (pad2 (month + 1));
                    sb.append_c ('-');
                    sb.append (pad2 (day));
                } else if (sp == 'T' || sp == 'X') {
                    sb.append (pad2 (hour));
                    sb.append_c (':');
                    sb.append (pad2 (minute));
                    sb.append_c (':');
                    sb.append (pad2 (second));
                } else if (sp == 'R') {
                    sb.append (pad2 (hour));
                    sb.append_c (':');
                    sb.append (pad2 (minute));
                } else if (sp == 'D' || sp == 'x') {
                    int yy = full_y % 100;
                    if (yy < 0) yy += 100;
                    sb.append (pad2 (month + 1));
                    sb.append_c ('/');
                    sb.append (pad2 (day));
                    sb.append_c ('/');
                    sb.append (pad2 (yy));
                } else if (sp == 'c') {
                    sb.append (format ("%a %b %e %H:%M:%S %Y"));
                } else if (sp == 'n') {
                    sb.append_c ('\n');
                } else if (sp == 't') {
                    sb.append_c ('\t');
                } else if (sp == 's') {
                    sb.append (mktime ().to_string ());
                } else if (sp == 'Z') {
                    sb.append ("UTC");
                } else if (sp == 'z') {
                    sb.append ("+0000");
                } else {
                    sb.append_c ('%');
                    sb.append_c (sp);
                }
            }
            return sb.str;
        }

        public size_t strftime (uint8[] s, string fmt) {
            if (s.length == 0)
                return 0;
            string out_s = format (fmt);
            int n = out_s.length;
            if (n >= s.length)
                return 0;
            for (int i = 0; i < n; i++)
                s[i] = (uint8) out_s[i];
            s[n] = 0;
            return (size_t) n;
        }

        private static bool parse_digits (string buf, ref int pos, int max_digits, out int val) {
            val = 0;
            int n = buf.length;
            int count = 0;
            while (pos < n && count < max_digits) {
                char c = buf[pos];
                if (c < '0' || c > '9')
                    break;
                val = val * 10 + (int) (c - '0');
                pos++;
                count++;
            }
            return count > 0;
        }

        public string? strptime (string buf, string fmt) {
            int bi = 0;
            int bn = buf.length;
            int fn = fmt.length;
            for (int fi = 0; fi < fn; fi++) {
                char fc = fmt[fi];
                if (fc == ' ' || fc == '\t' || fc == '\n') {
                    while (bi < bn && (buf[bi] == ' ' || buf[bi] == '\t' || buf[bi] == '\n'))
                        bi++;
                    continue;
                }
                if (fc != '%' || fi + 1 >= fn) {
                    if (bi >= bn || buf[bi] != fc)
                        return null;
                    bi++;
                    continue;
                }
                fi++;
                char sp = fmt[fi];
                int v = 0;
                if (sp == '%') {
                    if (bi >= bn || buf[bi] != '%')
                        return null;
                    bi++;
                } else if (sp == 'Y') {
                    if (!parse_digits (buf, ref bi, 4, out v)) return null;
                    year = v - 1900;
                } else if (sp == 'm') {
                    if (!parse_digits (buf, ref bi, 2, out v) || v < 1 || v > 12) return null;
                    month = v - 1;
                } else if (sp == 'd') {
                    if (!parse_digits (buf, ref bi, 2, out v) || v < 1 || v > 31) return null;
                    day = v;
                } else if (sp == 'H') {
                    if (!parse_digits (buf, ref bi, 2, out v) || v < 0 || v > 23) return null;
                    hour = v;
                } else if (sp == 'M') {
                    if (!parse_digits (buf, ref bi, 2, out v) || v < 0 || v > 59) return null;
                    minute = v;
                } else if (sp == 'S') {
                    if (!parse_digits (buf, ref bi, 2, out v) || v < 0 || v > 60) return null;
                    second = v;
                } else if (sp == 'F') {
                    int yv = 0;
                    int mv = 0;
                    int dv = 0;
                    if (!parse_digits (buf, ref bi, 4, out yv)) return null;
                    if (bi >= bn || buf[bi] != '-') return null;
                    bi++;
                    if (!parse_digits (buf, ref bi, 2, out mv) || mv < 1 || mv > 12) return null;
                    if (bi >= bn || buf[bi] != '-') return null;
                    bi++;
                    if (!parse_digits (buf, ref bi, 2, out dv) || dv < 1 || dv > 31) return null;
                    year = yv - 1900;
                    month = mv - 1;
                    day = dv;
                } else if (sp == 'T') {
                    int hv = 0;
                    int mv = 0;
                    int sv = 0;
                    if (!parse_digits (buf, ref bi, 2, out hv) || hv < 0 || hv > 23) return null;
                    if (bi >= bn || buf[bi] != ':') return null;
                    bi++;
                    if (!parse_digits (buf, ref bi, 2, out mv) || mv < 0 || mv > 59) return null;
                    if (bi >= bn || buf[bi] != ':') return null;
                    bi++;
                    if (!parse_digits (buf, ref bi, 2, out sv) || sv < 0 || sv > 60) return null;
                    hour = hv;
                    minute = mv;
                    second = sv;
                } else {
                    return null;
                }
            }
            return buf.substring (bi);
        }

        public string to_string () {
            return format ("%Y-%m-%d %H:%M:%S");
        }
    }

    public int64 get_real_time () {
        return ((int64) Sys.rtc_time ()) * 1000000L;
    }

    public const int64 TIME_SPAN_DAY = 86400000000L;
    public const int64 TIME_SPAN_HOUR = 3600000000L;
    public const int64 TIME_SPAN_MINUTE = 60000000L;
    public const int64 TIME_SPAN_SECOND = 1000000L;
    public const int64 TIME_SPAN_MILLISECOND = 1000L;

    /**
     * Immutable UTC date/time with microsecond resolution (GLib.DateTime).
     */
    public class DateTime : Object {
        private int64 usec;
        private Time tm;

        private DateTime (int64 us) {
            usec = us;
            int64 secs = us / TIME_SPAN_SECOND;
            if (us < 0 && (us % TIME_SPAN_SECOND) != 0)
                secs--;
            tm = Time.gm ((int) secs);
        }

        public static DateTime now_utc () {
            return new DateTime (get_real_time ());
        }

        public static DateTime from_unix_utc (int64 t) {
            return new DateTime (t * TIME_SPAN_SECOND);
        }

        public int64 to_unix () {
            int64 secs = usec / TIME_SPAN_SECOND;
            if (usec < 0 && (usec % TIME_SPAN_SECOND) != 0)
                secs--;
            return secs;
        }

        public int get_year () { return tm.year + 1900; }
        public int get_month () { return tm.month + 1; }
        public int get_day_of_month () { return tm.day; }
        public int get_hour () { return tm.hour; }
        public int get_minute () { return tm.minute; }
        public int get_second () { return tm.second; }

        public int get_microsecond () {
            int64 rem = usec % TIME_SPAN_SECOND;
            if (rem < 0) rem += TIME_SPAN_SECOND;
            return (int) rem;
        }

        public DateTime add (int64 span) {
            return new DateTime (usec + span);
        }

        public DateTime add_seconds (double seconds) {
            return new DateTime (usec + (int64) (seconds * 1000000.0));
        }

        public int64 difference (DateTime begin) {
            return usec - begin.usec;
        }

        public int compare (DateTime other) {
            if (usec < other.usec) return -1;
            if (usec > other.usec) return 1;
            return 0;
        }

        public bool equal (DateTime other) {
            return usec == other.usec;
        }

        public string format_iso8601 () {
            return tm.format ("%Y-%m-%dT%H:%M:%SZ");
        }
    }
}
