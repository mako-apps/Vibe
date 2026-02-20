
import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity } from 'react-native';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { Search, Plus } from 'lucide-react-native';

interface ModernHeaderProps {
    title?: string;
    onSearch?: () => void;
    onAdd?: () => void;
}

export default function ModernHeader({ title = 'Vibe', onSearch, onAdd }: ModernHeaderProps) {
    return (
        <View style={styles.wrapper}>
            <MaskedView
                style={styles.maskedContainer}
                maskElement={
                    <LinearGradient
                        colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']}
                        start={{ x: 0, y: 0.8 }}
                        end={{ x: 0, y: 1 }}
                        style={StyleSheet.absoluteFill}
                    />
                }
            >
                <View style={styles.content}>
                    <Text style={styles.title}>{title}</Text>

                    <View style={styles.actions}>
                        <TouchableOpacity onPress={onSearch} style={styles.iconBtn}>
                            <Search color="#fff" size={24} />
                        </TouchableOpacity>
                        <TouchableOpacity onPress={onAdd} style={styles.iconBtn}>
                            <Plus color="#fff" size={28} />
                        </TouchableOpacity>
                    </View>
                </View>

                {/* Blur Backing or Gradient Background for the header itself */}
                <LinearGradient
                    colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0.8)', 'rgba(0,0,0,0)']}
                    style={StyleSheet.absoluteFill}
                    pointerEvents="none"
                />
            </MaskedView>
        </View>
    );
}

const styles = StyleSheet.create({
    wrapper: {
        height: 100, // Safe area + header height
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 100,
        paddingTop: 40, // Rough safe area padding for simple testing
    },
    maskedContainer: {
        flex: 1,
    },
    content: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        paddingHorizontal: 20,
        height: 60,
    },
    title: {
        color: '#fff',
        fontSize: 32,
        fontWeight: '800',
        letterSpacing: 0.5,
    },
    actions: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    iconBtn: {
        marginLeft: 20,
        width: 40,
        height: 40,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(255,255,255,0.05)',
        borderRadius: 20,
    }
});
