import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView } from 'react-native';
import { useRouter } from 'expo-router';
import { X } from 'lucide-react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import ThemeSettings from '../../src/components/settings/ThemeSettings';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

export default function ThemeModal() {
    const { colors } = useThemeStore();
    const router = useRouter();
    const insets = useSafeAreaInsets();

    return (
        <View style={[styles.container, { backgroundColor: colors.background, paddingTop: insets.top }]}>
            {/* Header */}
            <View style={styles.header}>
                <Text style={[styles.title, { color: colors.text }]}>Appearance</Text>
                <TouchableOpacity onPress={() => router.back()} style={styles.closeBtn}>
                    <X size={24} color={colors.text} />
                </TouchableOpacity>
            </View>

            <ScrollView contentContainerStyle={{ padding: 20 }}>
                <ThemeSettings />
            </ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 20,
        paddingVertical: 16,
    },
    title: {
        fontSize: 20,
        fontWeight: 'bold',
    },
    closeBtn: {
        padding: 4,
    }
});
