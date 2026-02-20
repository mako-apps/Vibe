import { create } from 'zustand'
import { persist, createJSONStorage } from 'zustand/middleware'
import AsyncStorage from '@react-native-async-storage/async-storage'

export interface ReferralStats {
    referralCode: string | null
    verifiedCount: number
    pendingCount: number
    totalCount: number
    bronzeThreshold: number
    progressPercent: number
}

interface ReferralState {
    referralCode: string | null
    stats: ReferralStats | null
    loading: boolean
    error: string | null

    // Actions
    setReferralCode: (code: string) => void
    setStats: (stats: ReferralStats) => void
    setLoading: (loading: boolean) => void
    setError: (error: string | null) => void
    reset: () => void
}

const initialState = {
    referralCode: null,
    stats: null,
    loading: false,
    error: null,
}

export const useReferralStore = create<ReferralState>()(
    persist(
        (set) => ({
            ...initialState,

            setReferralCode: (code) => set({ referralCode: code }),

            setStats: (stats) => set({ stats, referralCode: stats.referralCode }),

            setLoading: (loading) => set({ loading }),

            setError: (error) => set({ error }),

            reset: () => set(initialState),
        }),
        {
            name: 'referral-storage',
            storage: createJSONStorage(() => AsyncStorage),
            partialize: (state) => ({
                referralCode: state.referralCode,
            }),
        }
    )
)

// Helper to calculate progress to bronze
export const calculateBronzeProgress = (verifiedCount: number, threshold: number = 4000) => {
    const progress = Math.min(100, (verifiedCount / threshold) * 100)
    const remaining = Math.max(0, threshold - verifiedCount)

    return {
        progress: Math.round(progress * 10) / 10, // Round to 1 decimal
        remaining,
        isComplete: verifiedCount >= threshold,
    }
}
