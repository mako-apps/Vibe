import React from 'react';
import { Stack, useRouter } from 'expo-router';
import PrivacySettings from '../../src/components/settings/PrivacySettings';

export default function PrivacySettingsScreen() {
    return (
        <>
            <Stack.Screen options={{ title: 'Privacy' }} />
            <PrivacySettings />
        </>
    );
}
