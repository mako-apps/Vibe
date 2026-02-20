import { Platform } from 'react-native'

// Update this with your Vibe backend URL
export const API_BASE = Platform.OS === 'android' ? 'http://10.0.2.2:4000' : 'http://localhost:4000'

export const getAuthHeaders = () => {
    return {
        'Content-Type': 'application/json',
    }
}

export const getAuthHeadersAsync = async () => {
    // Return empty auth for now, or implement token retrieval
    return getAuthHeaders()
}
