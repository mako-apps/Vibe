export const sanitizeInput = (input: string): string => {
    if (!input) return '';
    // Basic sanitization: Remove script tags and HTML-like tags
    // Helpful for preventing injection if this input hits a WebView or HTML-rendering backend
    return input
        .replace(/<script\b[^>]*>([\s\S]*?)<\/script>/gim, "")
        .replace(/<[^>]+>/g, "")
        .trim();
};

export const validateUsername = (username: string): { isValid: boolean; error?: string } => {
    const sanitized = sanitizeInput(username);
    if (sanitized.length < 3) return { isValid: false, error: 'Username too short (min 3 chars)' };
    if (sanitized.length > 20) return { isValid: false, error: 'Username too long (max 20 chars)' };
    if (!/^[a-zA-Z0-9_]+$/.test(sanitized)) return { isValid: false, error: 'Letters, numbers, and underscores only' };
    return { isValid: true };
};

export const normalizePhoneNumber = (input: string): string | null => {
    if (!input) return null;
    const digits = input.replace(/[^0-9]/g, '');
    if (digits.length < 7 || digits.length > 15) return null;
    return digits;
};
