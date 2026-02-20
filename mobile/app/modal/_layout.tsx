import { Stack } from 'expo-router';

export default function ModalLayout() {
    return (
        <Stack screenOptions={{ headerShown: false }}>
            <Stack.Screen name="connection" />
            <Stack.Screen name="proxy" />
            <Stack.Screen name="relay-network" />
            <Stack.Screen name="theme" />
            <Stack.Screen name="secret-key" />
        </Stack>
    );
}
