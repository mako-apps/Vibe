export const Haptics = {
    soft: () => {
        if (navigator.vibrate) navigator.vibrate(10);
    },
    medium: () => {
        if (navigator.vibrate) navigator.vibrate(40);
    },
    heavy: () => {
        if (navigator.vibrate) navigator.vibrate(70);
    },
    success: () => {
        if (navigator.vibrate) navigator.vibrate([10, 30, 10]);
    },
    error: () => {
        if (navigator.vibrate) navigator.vibrate([50, 20, 50, 20, 50]);
    },
    // Pattern for incoming call (simulating ring)
    ring: () => {
        // Vibrate for 1s, pause 1s, repeat (managed by interval in App)
        if (navigator.vibrate) navigator.vibrate([800, 800]);
    }
};

export default Haptics;
