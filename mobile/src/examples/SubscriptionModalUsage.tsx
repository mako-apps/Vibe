import React, { useState } from 'react';
import { View, TouchableOpacity, Text, StyleSheet } from 'react-native';
import SkiaPremiumSubscriptionModal from '../components/settings/SkiaPremiumSubscriptionModal';
import { useAuthStore } from '../lib/stores/auth-store';
import { useThemeStore } from '../lib/stores/theme-store';

/**
 * Example Usage of SkiaPremiumSubscriptionModal
 * This file demonstrates how to implement the Premium Subscription Modal in a screen.
 */
export default function SubscriptionModalUsage() {
    const [visible, setVisible] = useState(false);
    const { user } = useAuthStore();
    const { colors } = useThemeStore();

    const handleOpenModal = () => {
        setVisible(true);
    };

    const handleCloseModal = () => {
        setVisible(false);
    };

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <TouchableOpacity
                activeOpacity={0.8}
                style={[styles.button, { backgroundColor: colors.text }]}
                onPress={handleOpenModal}
            >
                <Text style={[styles.buttonText, { color: colors.background }]}>Upgrade to Premium</Text>
            </TouchableOpacity>

            <SkiaPremiumSubscriptionModal
                visible={visible}
                onClose={handleCloseModal}
                userId={user?.userId || 'demo_user'}
            />
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'center',
    },
    button: {
        paddingVertical: 16,
        paddingHorizontal: 32,
        borderRadius: 12,
        elevation: 4,
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.25,
        shadowRadius: 3.84,
    },
    buttonText: {
        color: '#FFFFFF',
        fontSize: 16,
        fontWeight: '700',
        letterSpacing: 0.5,
    },
});
