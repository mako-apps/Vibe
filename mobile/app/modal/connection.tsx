import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Platform } from 'react-native';
import { useRouter } from 'expo-router';
import { X } from 'lucide-react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import ConnectionSettings from '../../src/components/settings/ConnectionSettings';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

export default function ConnectionModal() {
    const { colors, effectiveTheme } = useThemeStore();
    const router = useRouter();
    const insets = useSafeAreaInsets();

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            {/* Header */}
            <View style={[styles.header, { paddingTop: Platform.OS === 'ios' ? 20 : 16 }]}>
                <Text style={[styles.title, { color: colors.text }]}>Connection</Text>
                <TouchableOpacity
                    onPress={() => router.back()}
                    style={[styles.closeBtn, { backgroundColor: 'rgba(120,120,120,0.1)' }]}
                >
                    <X size={20} color={colors.text} />
                </TouchableOpacity>
            </View>

            <ScrollView contentContainerStyle={{ padding: 20 }}>
                <ConnectionSettings />
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
        paddingBottom: 16,
        paddingTop: 16, // Safe area handled manually
        borderBottomWidth: 1,
        borderBottomColor: 'rgba(0,0,0,0.05)'
    },
    title: {
        fontSize: 18,
        fontWeight: 'bold',
    },
    closeBtn: {
        padding: 6,
        borderRadius: 20,
    }
});
