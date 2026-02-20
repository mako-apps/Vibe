import React, { useState } from 'react'
import { View, Text, TextInput, TouchableOpacity, StyleSheet, ActivityIndicator, Alert, KeyboardAvoidingView, Platform } from 'react-native'
import SafeLiquidGlass from '../components/native/SafeLiquidGlass'
import { useAuthStore } from '../lib/stores/auth-store'
import { apiClient } from '../lib/api-client'
import { useThemeStore } from '../lib/stores/theme-store'
import * as Crypto from 'expo-crypto'

export default function AuthScreen() {
    const [isLogin, setIsLogin] = useState(true)
    const [username, setUsername] = useState('')
    const [password, setPassword] = useState('')
    const [confirmPassword, setConfirmPassword] = useState('')
    const [loading, setLoading] = useState(false)
    const { login } = useAuthStore()
    const { colors } = useThemeStore()

    const handleAuth = async () => {
        if (!username || !password) {
            Alert.alert('Error', 'Please fill all fields')
            return
        }

        if (!isLogin && password !== confirmPassword) {
            Alert.alert('Error', 'Passwords do not match')
            return
        }

        setLoading(true)
        try {
            console.log('[Auth] Starting authentication process...')

            // Generate device ID if needed, for now use random UUID
            const deviceId = Crypto.randomUUID()
            console.log('[Auth] Device ID generated:', deviceId)

            if (isLogin) {
                // Login
                console.log('[Auth] Logging in with username:', username)
                const response = await apiClient.login({
                    credential: username,
                    password,
                    deviceId
                })

                // CRITICAL DEBUG
                Alert.alert('Debug', 'Login API Success');

                console.log('[Auth] Login API success. Keys:', Object.keys(response))

                // Sanitize user object (check for huge profile image)
                const user = { ...response };
                if (user.profileImage && user.profileImage.length > 1000) {
                    // Log truncated message
                    console.log('[Auth] Profile image too large to log, length:', user.profileImage.length);
                }

                // Manually trigger login
                try {
                    login(user);
                    console.log('[Auth] State updated successfully');
                } catch (stateError: any) {
                    Alert.alert('Debug', 'State Update Failed: ' + stateError);
                    console.error('[Auth] State update failed:', stateError);
                    throw new Error('Failed to save login session: ' + stateError.message);
                }
            } else {
                // Register - need keys
                // Simple key generation placeholder if lib/crypto not ready
                // In real app, use proper signal protocol or similar
                const publicKey = 'dummy_pk_' + Date.now()
                const identityKey = 'dummy_ik_' + Date.now()

                console.log('[Auth] Registering user:', username)
                const response = await apiClient.register({
                    username,
                    password,
                    deviceId,
                    publicKey,
                    identityKey
                })
                console.log('[Auth] Registration successful')
                login(response)
            }
        } catch (e: any) {
            console.log('[Auth] Catch Block Error:', e);
            // Force show error details
            const errorMessage = e instanceof Error ? e.message : JSON.stringify(e);
            Alert.alert('Login Failure Details', errorMessage || 'Unknown error');
        } finally {
            setLoading(false)
        }
    }

    return (
        <KeyboardAvoidingView
            behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
            style={[styles.container, { backgroundColor: colors.background }]}
        >
            <View style={styles.content}>
                <Text style={[styles.title, { color: colors.text }]}>
                    {isLogin ? 'Welcome Back' : 'Create Account'}
                </Text>

                <View style={styles.form}>
                    <Text style={[styles.label, { color: colors.text }]}>Username</Text>
                    <SafeLiquidGlass style={styles.inputContainer} blurIntensity={10}>
                        <TextInput
                            style={[styles.input, { color: colors.text }]}
                            value={username}
                            onChangeText={setUsername}
                            placeholder="Enter username"
                            placeholderTextColor="#999"
                            autoCapitalize="none"
                        />
                    </SafeLiquidGlass>

                    <Text style={[styles.label, { color: colors.text }]}>Password</Text>
                    <SafeLiquidGlass style={styles.inputContainer} blurIntensity={10}>
                        <TextInput
                            style={[styles.input, { color: colors.text }]}
                            value={password}
                            onChangeText={setPassword}
                            placeholder="Enter password"
                            placeholderTextColor="#999"
                            secureTextEntry
                        />
                    </SafeLiquidGlass>

                    {!isLogin && (
                        <>
                            <Text style={[styles.label, { color: colors.text }]}>Confirm Password</Text>
                            <SafeLiquidGlass style={styles.inputContainer} blurIntensity={10}>
                                <TextInput
                                    style={[styles.input, { color: colors.text }]}
                                    value={confirmPassword}
                                    onChangeText={setConfirmPassword}
                                    placeholder="Confirm password"
                                    placeholderTextColor="#999"
                                    secureTextEntry
                                />
                            </SafeLiquidGlass>
                        </>
                    )}

                    <TouchableOpacity onPress={handleAuth} disabled={loading} style={styles.buttonWrapper}>
                        <SafeLiquidGlass style={styles.button} blurIntensity={20}>
                            {loading ? (
                                <ActivityIndicator color={colors.text} />
                            ) : (
                                <Text style={[styles.buttonText, { color: colors.text }]}>
                                    {isLogin ? 'Login' : 'Sign Up'}
                                </Text>
                            )}
                        </SafeLiquidGlass>
                    </TouchableOpacity>

                    <TouchableOpacity onPress={() => setIsLogin(!isLogin)} style={styles.switchButton}>
                        <Text style={[styles.switchText, { color: colors.primary }]}>
                            {isLogin ? "Don't have an account? Sign Up" : "Already have an account? Login"}
                        </Text>
                    </TouchableOpacity>
                </View>
            </View>
        </KeyboardAvoidingView>
    )
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        justifyContent: 'center',
        padding: 20,
    },
    content: {
        width: '100%',
        maxWidth: 400,
        alignSelf: 'center',
    },
    title: {
        fontSize: 32,
        fontWeight: 'bold',
        marginBottom: 40,
        textAlign: 'center',
    },
    form: {
        gap: 16,
    },
    label: {
        fontSize: 14,
        fontWeight: '600',
        marginBottom: 8,
        marginLeft: 4,
    },
    inputContainer: {
        borderRadius: 12,
        overflow: 'hidden',
        height: 50,
    },
    input: {
        flex: 1,
        paddingHorizontal: 16,
        fontSize: 16,
    },
    buttonWrapper: {
        marginTop: 24,
        height: 50,
    },
    button: {
        flex: 1,
        borderRadius: 25,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
    },
    buttonText: {
        fontSize: 16,
        fontWeight: 'bold',
    },
    switchButton: {
        marginTop: 16,
        alignItems: 'center',
    },
    switchText: {
        fontSize: 14,
    }
})
