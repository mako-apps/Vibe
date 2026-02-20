import React, { useState } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, SafeAreaView, StatusBar } from 'react-native';
import { useSharedValue, withSpring } from 'react-native-reanimated';
import SubscriptionModal from './SubscriptionModal';
import { useThemeStore } from '../../lib/stores/theme-store';
import { Sparkles, ArrowLeft } from 'lucide-react-native';
import { SkiaAnimatedBackground } from '../native/SkiaAnimatedBackground';

/**
 * SubscriptionUsage Screen
 * 
 * Demonstrates the usage of the SubscriptionModal component integrated
 * with SkiaAnimatedBackground for a premium, luxurious feel.
 */
export default function SubscriptionUsage() {
    const { colors, effectiveTheme } = useThemeStore();
    const [modalVisible, setModalVisible] = useState(false);
    const isLight = effectiveTheme === 'light';

    // Parent scale shared value for the modal transition animation
    const parentScale = useSharedValue(1);

    const handleOpenModal = () => {
        parentScale.value = withSpring(0.95);
        setModalVisible(true);
    };

    const handleCloseModal = () => {
        parentScale.value = withSpring(1);
        setModalVisible(false);
    };

    return (
        <View style={styles.container}>
            <StatusBar barStyle={isLight ? 'dark-content' : 'light-content'} />

            {/* Background for the main screen */}
            <SkiaAnimatedBackground
                baseColor={isLight ? '#f5f5f5' : '#121212'}
                glowColor={isLight ? '#E0E7FF' : '#1E1B4B'}
                cyanColor={isLight ? '#D1FAE5' : '#065F46'}
                backgroundColor={isLight ? '#f5f5f5' : '#121212'}
            />

            <SafeAreaView style={styles.content}>
                <View style={styles.header}>
                    <TouchableOpacity style={styles.backButton}>
                        <ArrowLeft size={24} color={colors.text} />
                    </TouchableOpacity>
                    <Text style={[styles.headerTitle, { color: colors.text }]}>Account</Text>
                    <View style={{ width: 24 }} />
                </View>

                <View style={styles.main}>
                    <View style={[styles.card, { backgroundColor: isLight ? 'rgba(255,255,255,0.7)' : 'rgba(30,30,30,0.5)' }]}>
                        <Sparkles size={32} color={isLight ? '#6366F1' : '#818CF8'} />
                        <Text style={[styles.cardTitle, { color: colors.text }]}>Premium Status</Text>
                        <Text style={[styles.cardSubtitle, { color: colors.textSecondary }]}>
                            Unlock advanced AI features and priority processing for your business.
                        </Text>

                        <TouchableOpacity
                            style={[styles.upgradeButton, { backgroundColor: colors.text }]}
                            onPress={handleOpenModal}
                        >
                            <Text style={[styles.upgradeButtonText, { color: colors.background }]}>
                                UPGRADE TO PREMIUM
                            </Text>
                        </TouchableOpacity>
                    </View>
                </View>
            </SafeAreaView>

            <SubscriptionModal
                visible={modalVisible}
                onClose={handleCloseModal}
                parentScale={parentScale}
                userId="demo-user-id"
            />
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    content: {
        flex: 1,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 20,
        height: 60,
    },
    headerTitle: {
        fontSize: 18,
        fontWeight: '700',
    },
    backButton: {
        padding: 4,
    },
    main: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'center',
        paddingHorizontal: 30,
    },
    card: {
        width: '100%',
        padding: 30,
        borderRadius: 32,
        alignItems: 'center',
        borderWidth: 1,
        borderColor: 'rgba(150,150,150,0.1)',
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 10 },
        shadowOpacity: 0.1,
        shadowRadius: 20,
        elevation: 5,
    },
    cardTitle: {
        fontSize: 24,
        fontWeight: '700',
        marginTop: 20,
        marginBottom: 10,
    },
    cardSubtitle: {
        fontSize: 14,
        textAlign: 'center',
        lineHeight: 20,
        marginBottom: 30,
        paddingHorizontal: 10,
    },
    upgradeButton: {
        width: '100%',
        height: 56,
        borderRadius: 16,
        alignItems: 'center',
        justifyContent: 'center',
    },
    upgradeButtonText: {
        fontSize: 12,
        fontWeight: '900',
        letterSpacing: 1.5,
    },
});
