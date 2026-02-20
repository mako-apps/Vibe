import React from 'react';
import {
    View,
    Text,
    TouchableOpacity,
    StyleSheet,
    Dimensions
} from 'react-native';
import Animated, {
    FadeIn,
    FadeOut,
    StretchInY
} from 'react-native-reanimated';
import { Sparkles } from 'lucide-react-native';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { useThemeStore } from '../../lib/stores/theme-store';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

interface MentionOption {
    id: string;
    label: string;
    description: string;
    icon: React.ReactNode;
    color: string;
}

interface MentionMenuProps {
    visible: boolean;
    searchText: string;
    onSelect: (option: MentionOption) => void;
    onClose: () => void;
}

const withAlpha = (color: string, opacity: number) => {
    if (!color) return `rgba(0,0,0,${opacity})`;
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16);
        const g = parseInt(color.slice(3, 5), 16);
        const b = parseInt(color.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${opacity})`;
    }
    return color;
};

const MentionMenu = ({
    visible,
    searchText,
    onSelect,
    onClose
}: MentionMenuProps) => {
    const { colors, effectiveTheme } = useThemeStore();

    const mentionOptions = React.useMemo(() => [
        {
            id: 'vibe',
            label: 'vibe',
            description: 'Ask AI assistant',
            icon: <Sparkles size={18} color={colors.primary} />,
            color: colors.primary
        }
    ], [colors.primary]);

    const filteredOptions = React.useMemo(() =>
        mentionOptions.filter(option =>
            option.label.toLowerCase().startsWith(searchText.toLowerCase())
        ),
        [mentionOptions, searchText]);

    if (!visible || filteredOptions.length === 0) return null;

    return (
        <Animated.View
            style={styles.container}
            entering={StretchInY.duration(300)}
            exiting={FadeOut.duration(150)}
        >
            <View style={styles.menuContainer}>
                {filteredOptions.map((option, index) => (
                    <TouchableOpacity
                        key={option.id}
                        style={[
                            styles.optionRow,
                            index < filteredOptions.length - 1 && {
                                borderBottomWidth: StyleSheet.hairlineWidth,
                                borderBottomColor: withAlpha(colors.text, 0.1)
                            }
                        ]}
                        onPress={() => onSelect(option)}
                        activeOpacity={0.7}
                    >
                        <View style={styles.optionContent}>
                            <Text style={[styles.optionLabel, { color: colors.text }]}>
                                @{option.label}
                            </Text>
                            <Text style={[styles.optionDescription, { color: withAlpha(colors.text, 0.6) }]}>
                                {option.description}
                            </Text>
                        </View>
                    </TouchableOpacity>
                ))}
            </View>
        </Animated.View>
    );
};

const styles = StyleSheet.create({
    container: {
        width: '100%',
        zIndex: 100,
    },
    menuContainer: {
        overflow: 'hidden',
    },
    optionRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 16,
        paddingVertical: 12,
    },
    optionContent: {
        flex: 1,
    },
    optionLabel: {
        fontSize: 15,
        fontWeight: '600',
    },
    optionDescription: {
        fontSize: 12,
        marginTop: 1,
    },
});

export default React.memo(MentionMenu);
