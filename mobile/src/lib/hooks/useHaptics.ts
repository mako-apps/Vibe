import * as Haptics from 'expo-haptics';
import { Platform } from 'react-native';

export const useHaptics = () => {
    const light = async () => {
        if (Platform.OS === 'web') return;
        await Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    };

    const medium = async () => {
        if (Platform.OS === 'web') return;
        await Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    };

    const heavy = async () => {
        if (Platform.OS === 'web') return;
        await Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
    };

    const success = async () => {
        if (Platform.OS === 'web') return;
        await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    };

    const error = async () => {
        if (Platform.OS === 'web') return;
        await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
    };

    const selection = async () => {
        if (Platform.OS === 'web') return;
        await Haptics.selectionAsync();
    };

    return {
        light,
        medium,
        heavy,
        success,
        error,
        selection
    };
};
