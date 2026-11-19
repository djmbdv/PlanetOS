// Pure-Vala Gdk event types for PlanetOS.

namespace Gdk {
    public enum EventType {
        NONE,
        KEY_PRESS,
        BUTTON_PRESS,
        BUTTON_RELEASE,
        MOTION_NOTIFY,
        SCROLL
    }

    /**
     * Input event produced by Gdk.Window.poll_event().
     */
    public class Event : Object {
        public EventType type = EventType.NONE;
        public int32 keyval = 0;
        public int32 x = 0;
        public int32 y = 0;
        public int8 button = 0;
        public uint8 state = 0;
        public int16 scroll_dx = 0;
        public int16 scroll_dy = 0;

        public void reset () {
            type = EventType.NONE;
            keyval = 0;
            x = 0;
            y = 0;
            button = 0;
            state = 0;
            scroll_dx = 0;
            scroll_dy = 0;
        }
    }
}
