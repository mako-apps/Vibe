/**
 * AgentSettingsScreen - Configure AI provider API keys
 */

import React, { useState, useEffect } from 'react';
import {
    View,
    Text,
    StyleSheet,
    TextInput,
    Pressable,
    ScrollView,
    Alert,
    Switch
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { BlurView } from 'expo-blur';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {
    ChevronLeft,
    Key,
    Bot,
    Sparkles,
    Check,
    Eye,
    EyeOff
} from 'lucide-react-native';
import { useAgentStore } from '../../lib/agent/AgentStore';
import { AIProvider, AgentConfig } from '../../lib/agent/types';
import { theme } from '../../lib/theme';

const API_KEYS_STORAGE = 'vibe_agent_api_keys';

interface AgentSettingsScreenProps {
    onBack: () => void;
}

export default function AgentSettingsScreen({ onBack }: AgentSettingsScreenProps) {
    const insets = useSafeAreaInsets();
    const { configure, config, isConfigured } = useAgentStore();
    const currentProvider = config?.provider;

    const [provider, setProvider] = useState<AIProvider>('claude');
    const [claudeKey, setClaudeKey] = useState('');
    const [geminiKey, setGeminiKey] = useState('');
    const [showClaudeKey, setShowClaudeKey] = useState(false);
    const [showGeminiKey, setShowGeminiKey] = useState(false);
    const [saving, setSaving] = useState(false);

    // Load saved keys
    useEffect(() => {
        loadSavedKeys();
    }, []);

    const loadSavedKeys = async () => {
        try {
            const data = await AsyncStorage.getItem(API_KEYS_STORAGE);
            if (data) {
                const keys = JSON.parse(data);
                if (keys.claude) setClaudeKey(keys.claude);
                if (keys.gemini) setGeminiKey(keys.gemini);
                if (keys.provider) setProvider(keys.provider);
            }
        } catch (error) {
            console.error('Failed to load API keys:', error);
        }
    };

    const handleSave = async () => {
        const activeKey = provider === 'claude' ? claudeKey : geminiKey;

        if (!activeKey.trim()) {
            Alert.alert('Error', `Please enter your ${provider === 'claude' ? 'Claude' : 'Gemini'} API key`);
            return;
        }

        setSaving(true);

        try {
            // Save keys securely
            await AsyncStorage.setItem(API_KEYS_STORAGE, JSON.stringify({
                claude: claudeKey,
                gemini: geminiKey,
                provider
            }));

            // Configure the agent
            const config: AgentConfig = {
                provider,
                apiKey: activeKey,
                claudeApiKey: claudeKey,
                geminiApiKey: geminiKey,
                model: provider === 'claude' ? 'claude-sonnet-4-20250514' : 'gemini-2.0-flash',
                maxTokens: 4096,
                temperature: 0.7
            };

            await configure(config);

            Alert.alert('Success', 'AI agent configured successfully!', [
                { text: 'OK', onPress: onBack }
            ]);
        } catch (error: any) {
            Alert.alert('Error', error.message || 'Failed to save settings');
        } finally {
            setSaving(false);
        }
    };

    const ProviderOption = ({
        value,
        label,
        description
    }: {
        value: AIProvider;
        label: string;
        description: string;
    }) => (
        <Pressable
            style={[styles.providerOption, provider === value && styles.providerOptionActive]}
            onPress={() => setProvider(value)}
        >
            <View style={styles.providerHeader}>
                <View style={[styles.providerIcon, provider === value && styles.providerIconActive]}>
                    {value === 'claude' ? (
                        <Sparkles size={20} color={provider === value ? '#fff' : theme.colors.text} />
                    ) : (
                        <Bot size={20} color={provider === value ? '#fff' : theme.colors.text} />
                    )}
                </View>
                <View style={styles.providerInfo}>
                    <Text style={styles.providerLabel}>{label}</Text>
                    <Text style={styles.providerDescription}>{description}</Text>
                </View>
                {provider === value && (
                    <Check size={20} color={theme.colors.primary} />
                )}
            </View>
        </Pressable>
    );

    return (
        <View style={[styles.container, { paddingTop: insets.top }]}>
            {/* Header */}
            <BlurView intensity={80} tint="dark" style={styles.header}>
                <Pressable onPress={onBack} style={styles.backButton}>
                    <ChevronLeft size={24} color={theme.colors.text} />
                </Pressable>
                <Text style={styles.headerTitle}>AI Settings</Text>
                <View style={{ width: 40 }} />
            </BlurView>

            <ScrollView style={styles.content} showsVerticalScrollIndicator={false}>
                {/* Provider Selection */}
                <Text style={styles.sectionTitle}>AI Provider</Text>
                <View style={styles.providersContainer}>
                    <ProviderOption
                        value="claude"
                        label="Claude (Anthropic)"
                        description="Best for reasoning & writing"
                    />
                    <ProviderOption
                        value="gemini"
                        label="Gemini (Google)"
                        description="Best for search & multimodal"
                    />
                </View>

                {/* API Keys */}
                <Text style={styles.sectionTitle}>API Keys</Text>

                {/* Claude API Key */}
                <View style={styles.inputGroup}>
                    <Text style={styles.inputLabel}>Claude API Key</Text>
                    <View style={styles.inputContainer}>
                        <Key size={18} color={theme.colors.textSecondary} style={styles.inputIcon} />
                        <TextInput
                            style={styles.input}
                            placeholder="sk-ant-..."
                            placeholderTextColor={theme.colors.textSecondary}
                            value={claudeKey}
                            onChangeText={setClaudeKey}
                            secureTextEntry={!showClaudeKey}
                            autoCapitalize="none"
                            autoCorrect={false}
                        />
                        <Pressable onPress={() => setShowClaudeKey(!showClaudeKey)} style={styles.eyeButton}>
                            {showClaudeKey ? (
                                <EyeOff size={18} color={theme.colors.textSecondary} />
                            ) : (
                                <Eye size={18} color={theme.colors.textSecondary} />
                            )}
                        </Pressable>
                    </View>
                    <Text style={styles.inputHint}>
                        Get your API key from console.anthropic.com
                    </Text>
                </View>

                {/* Gemini API Key */}
                <View style={styles.inputGroup}>
                    <Text style={styles.inputLabel}>Gemini API Key</Text>
                    <View style={styles.inputContainer}>
                        <Key size={18} color={theme.colors.textSecondary} style={styles.inputIcon} />
                        <TextInput
                            style={styles.input}
                            placeholder="AIza..."
                            placeholderTextColor={theme.colors.textSecondary}
                            value={geminiKey}
                            onChangeText={setGeminiKey}
                            secureTextEntry={!showGeminiKey}
                            autoCapitalize="none"
                            autoCorrect={false}
                        />
                        <Pressable onPress={() => setShowGeminiKey(!showGeminiKey)} style={styles.eyeButton}>
                            {showGeminiKey ? (
                                <EyeOff size={18} color={theme.colors.textSecondary} />
                            ) : (
                                <Eye size={18} color={theme.colors.textSecondary} />
                            )}
                        </Pressable>
                    </View>
                    <Text style={styles.inputHint}>
                        Get your API key from aistudio.google.com
                    </Text>
                </View>

                {/* Info Box */}
                <View style={styles.infoBox}>
                    <Text style={styles.infoTitle}>🔒 Security Note</Text>
                    <Text style={styles.infoText}>
                        API keys are stored securely on your device only. They are never sent to Vibe servers.
                        Your conversations with AI are end-to-end encrypted.
                    </Text>
                </View>

                {/* Save Button */}
                <Pressable
                    style={[styles.saveButton, saving && styles.saveButtonDisabled]}
                    onPress={handleSave}
                    disabled={saving}
                >
                    <Text style={styles.saveButtonText}>
                        {saving ? 'Saving...' : 'Save Settings'}
                    </Text>
                </Pressable>

                <View style={{ height: insets.bottom + 32 }} />
            </ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: theme.colors.background,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 16,
        paddingVertical: 12,
        borderBottomWidth: 1,
        borderBottomColor: 'rgba(255,255,255,0.1)',
    },
    backButton: {
        padding: 8,
    },
    headerTitle: {
        fontSize: 18,
        fontWeight: '600',
        color: theme.colors.text,
    },
    content: {
        flex: 1,
        padding: 16,
    },
    sectionTitle: {
        fontSize: 14,
        fontWeight: '600',
        color: theme.colors.textSecondary,
        textTransform: 'uppercase',
        letterSpacing: 1,
        marginBottom: 12,
        marginTop: 24,
    },
    providersContainer: {
        gap: 12,
    },
    providerOption: {
        backgroundColor: 'rgba(255,255,255,0.05)',
        borderRadius: 16,
        padding: 16,
        borderWidth: 2,
        borderColor: 'transparent',
    },
    providerOptionActive: {
        borderColor: theme.colors.primary,
        backgroundColor: 'rgba(99,102,241,0.1)',
    },
    providerHeader: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    providerIcon: {
        width: 40,
        height: 40,
        borderRadius: 12,
        backgroundColor: 'rgba(255,255,255,0.1)',
        justifyContent: 'center',
        alignItems: 'center',
        marginRight: 12,
    },
    providerIconActive: {
        backgroundColor: theme.colors.primary,
    },
    providerInfo: {
        flex: 1,
    },
    providerLabel: {
        fontSize: 16,
        fontWeight: '600',
        color: theme.colors.text,
        marginBottom: 2,
    },
    providerDescription: {
        fontSize: 13,
        color: theme.colors.textSecondary,
    },
    inputGroup: {
        marginBottom: 20,
    },
    inputLabel: {
        fontSize: 14,
        fontWeight: '500',
        color: theme.colors.text,
        marginBottom: 8,
    },
    inputContainer: {
        flexDirection: 'row',
        alignItems: 'center',
        backgroundColor: 'rgba(255,255,255,0.05)',
        borderRadius: 12,
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.1)',
    },
    inputIcon: {
        marginLeft: 12,
    },
    input: {
        flex: 1,
        padding: 14,
        color: theme.colors.text,
        fontSize: 15,
    },
    eyeButton: {
        padding: 12,
    },
    inputHint: {
        fontSize: 12,
        color: theme.colors.textSecondary,
        marginTop: 6,
    },
    infoBox: {
        backgroundColor: 'rgba(99,102,241,0.1)',
        borderRadius: 12,
        padding: 16,
        marginTop: 24,
        borderWidth: 1,
        borderColor: 'rgba(99,102,241,0.2)',
    },
    infoTitle: {
        fontSize: 14,
        fontWeight: '600',
        color: theme.colors.text,
        marginBottom: 8,
    },
    infoText: {
        fontSize: 13,
        color: theme.colors.textSecondary,
        lineHeight: 20,
    },
    saveButton: {
        backgroundColor: theme.colors.primary,
        borderRadius: 16,
        padding: 16,
        alignItems: 'center',
        marginTop: 32,
    },
    saveButtonDisabled: {
        opacity: 0.6,
    },
    saveButtonText: {
        color: '#fff',
        fontSize: 16,
        fontWeight: '600',
    },
});
