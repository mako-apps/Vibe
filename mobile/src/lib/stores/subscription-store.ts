import { create } from 'zustand'
import { persist, createJSONStorage } from 'zustand/middleware'
import AsyncStorage from '@react-native-async-storage/async-storage'

export interface Plan {
    id: string
    name: string
    priceCents: number
    interval: string
    features: string[]
    aiEnabled: boolean
    businessAutoReply: boolean
    referralThreshold: number | null
}

export interface Subscription {
    id: string
    planId: string
    planName: string
    status: 'active' | 'cancelled' | 'past_due' | 'trialing'
    currentPeriodEnd: string
}

export type UserTier = 'free' | 'bronze' | 'silver' | 'gold' | 'admin' | 'verified'

interface SubscriptionState {
    plans: Plan[]
    currentSubscription: Subscription | null
    userTier: UserTier
    loading: boolean
    error: string | null

    // Actions
    setPlans: (plans: Plan[]) => void
    setSubscription: (subscription: Subscription | null) => void
    setUserTier: (tier: UserTier) => void
    setLoading: (loading: boolean) => void
    setError: (error: string | null) => void
    reset: () => void
}

const initialState = {
    plans: [],
    currentSubscription: null,
    userTier: 'free' as UserTier,
    loading: false,
    error: null,
}

export const useSubscriptionStore = create<SubscriptionState>()(
    persist(
        (set) => ({
            ...initialState,

            setPlans: (plans) => set({ plans }),

            setSubscription: (subscription) => set({ currentSubscription: subscription }),

            setUserTier: (tier) => set({ userTier: tier }),

            setLoading: (loading) => set({ loading }),

            setError: (error) => set({ error }),

            reset: () => set(initialState),
        }),
        {
            name: 'subscription-storage',
            storage: createJSONStorage(() => AsyncStorage),
            partialize: (state) => ({
                userTier: state.userTier,
                currentSubscription: state.currentSubscription,
            }),
        }
    )
)

// Helper function to check feature access
export const hasFeatureAccess = (tier: UserTier, feature: 'ai' | 'business' | 'badge'): boolean => {
    const tierLevels: Record<UserTier, number> = {
        free: 0,
        bronze: 1,
        silver: 2,
        gold: 3,
        verified: 4,
        admin: 5,
    }

    const featureRequirements: Record<string, number> = {
        badge: 1,      // Bronze+
        ai: 2,         // Silver+
        business: 2,   // Silver+
    }

    return tierLevels[tier] >= (featureRequirements[feature] || 0)
}

// Helper to get tier display info
export const getTierInfo = (tier: UserTier) => {
    const info: Record<UserTier, { label: string; color: string; description: string }> = {
        free: {
            label: 'Free',
            color: '#6b7280',
            description: 'Basic messaging features',
        },
        bronze: {
            label: 'Bronze',
            color: '#CD7F32',
            description: 'Early adopter badge for inviting 4000 users',
        },
        silver: {
            label: 'Silver',
            color: '#C0C0C0',
            description: 'AI agent, business messaging, auto-reply',
        },
        gold: {
            label: 'Gold',
            color: '#FFD700',
            description: 'All features + priority support',
        },
        verified: {
            label: 'Verified',
            color: '#3897f0', // Instagram Blue
            description: 'Verified public figure',
        },
        admin: {
            label: 'Admin',
            color: '#3897f0', // Instagram Blue
            description: 'Vibe Administrator',
        },
    }

    return info[tier] || info.free
}
