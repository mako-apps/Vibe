import { Stack } from 'expo-router'
import { StatusBar } from 'expo-status-bar'
import { useFonts } from 'expo-font'
import { GestureHandlerRootView } from 'react-native-gesture-handler'
import { View } from 'react-native'
import { Appearance } from 'react-native'
import { KeyboardProvider } from 'react-native-keyboard-controller'
import {
  SpaceGrotesk_400Regular,
  SpaceGrotesk_500Medium,
  SpaceGrotesk_600SemiBold,
  SpaceGrotesk_700Bold,
} from '@expo-google-fonts/space-grotesk'
import { useEffect } from 'react'
import { useNotificationStore } from './src/lib/stores/notification-store'
import { useAuthStore } from './src/lib/stores/auth-store'
import { syncContactsInBackground } from './src/lib/contact-sync'


const getDefaultBackgroundColor = () => {
  const colorScheme = Appearance.getColorScheme()
  return colorScheme === 'light' ? '#f8faf4' : '#0a0d0a'
}

export default function RootLayout() {
  const [fontsLoaded] = useFonts({
    SpaceGrotesk_400Regular,
    SpaceGrotesk_500Medium,
    SpaceGrotesk_600SemiBold,
    SpaceGrotesk_700Bold,
  })

  const { initNotifications } = useNotificationStore()
  const { isAuthenticated } = useAuthStore()

  useEffect(() => {
    if (isAuthenticated) {
      initNotifications()
      syncContactsInBackground()
    }
  }, [isAuthenticated])


  if (!fontsLoaded) {
    return (
      <View style={{ flex: 1, backgroundColor: getDefaultBackgroundColor() }} />
    )
  }

  const backgroundColor = getDefaultBackgroundColor()

  const GestureHandlerRootViewAny = GestureHandlerRootView as any

  return (
    <GestureHandlerRootViewAny style={{ flex: 1 }}>
      <KeyboardProvider>
        <View style={{ flex: 1, backgroundColor }}>
          <StatusBar />
          <Stack
            screenOptions={{
              headerShown: false,
              contentStyle: { backgroundColor },
            }}
          >
            <Stack.Screen name="index" />
            <Stack.Screen name="(onboarding)" />
            <Stack.Screen name="(auth)" />
            <Stack.Screen name="(tabs)" />
            <Stack.Screen name="agent-settings" />
            <Stack.Screen name="email-settings" />
            <Stack.Screen name="email-logs" />
            <Stack.Screen name="integrations" />
            <Stack.Screen name="media-generator" />
            <Stack.Screen name="telegram-config" />
            <Stack.Screen name="email-templates" />
            <Stack.Screen name="email-template-editor" />
            <Stack.Screen name="scroll-test" />

          </Stack>
        </View>
      </KeyboardProvider>
    </GestureHandlerRootViewAny>
  )
}
