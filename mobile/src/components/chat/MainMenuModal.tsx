import React, { useEffect, useMemo, useRef, useState } from 'react'
import { View, Text, StyleSheet, Dimensions, Pressable, TouchableOpacity, Image, Modal, TextInput, ActivityIndicator, Keyboard, FlatList, Alert, TouchableWithoutFeedback } from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    useAnimatedScrollHandler,
    withTiming,
    runOnJS,
    Easing,
    SharedValue,
} from 'react-native-reanimated'
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler'
import { useRouter } from 'expo-router'
import MaskedView from '@react-native-masked-view/masked-view'
import { BlurView } from 'expo-blur'
import { LinearGradient } from 'expo-linear-gradient'
import { useThemeStore } from '../../lib/stores/theme-store'
import { useContactStore } from '../../lib/stores/contact-store'
import { useChatStore } from '../../lib/ChatStore'
import { useAuthStore } from '../../lib/stores/auth-store'
import { useToastStore } from '../../lib/stores/toast-store'
import { apiClient } from '../../lib/api-client'
import { X, Users, Megaphone, Search, Check, Sparkles, ArrowLeft, MessageCircle, Image as ImageIcon } from 'lucide-react-native'
import AnimatedGlassButton from '../native/AnimatedGlassButton'
import SafeLiquidGlass from '../native/SafeLiquidGlass'
import { EditChatVibeIcon } from '../Icons'
import NewChatModal from './NewChatModal'

const MaskedViewAny = MaskedView as any
const AnimatedView = Animated.View as any
const GestureHandlerRootViewAny = GestureHandlerRootView as any
const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window')
const CHILD_PAGE_WIDTH = SCREEN_WIDTH - 48 // `childContent` has 24px padding on each side.

const MODAL_HEIGHT = SCREEN_HEIGHT * 0.94
const OPEN_Y = 0
const CLOSED_Y = SCREEN_HEIGHT
const SMOOTH_TIMING = { duration: 400, easing: Easing.bezier(0.25, 0.1, 0.25, 1) }
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const PHONE_REGEX = /^\+?[0-9\-\s]{7,15}$/

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color
}

type ChildView = 'menu' | 'newChat' | 'newGroup' | 'newChannel'

interface FoundUser {
    id: string
    userId: string
    username: string
    profileImage?: string
    phoneNumber?: string
}

interface MainMenuModalProps {
    visible: boolean
    onClose: () => void
    parentScale?: SharedValue<number>
}

export default function MainMenuModal({ visible, onClose, parentScale }: MainMenuModalProps) {
    const router = useRouter()
    const { colors, effectiveTheme } = useThemeStore()
    const { contacts, upsertContact, isContact } = useContactStore()
    const { chats, setActiveChat, createGroup, createChannel, updateChatFriendInfoByFriendId } = useChatStore()
    const { user } = useAuthStore()
    const { showToast } = useToastStore()
    const isLight = effectiveTheme === 'light'
    const isDark = effectiveTheme === 'dark'
    const bgColor = isLight ? '#f5f5f5' : colors.background

    // Main panel animation
    const translateY = useSharedValue(CLOSED_Y)
    const backdrop = useSharedValue(0)
    const startY = useSharedValue(OPEN_Y)
    const scrollY = useSharedValue(0)
    const closeButtonProgress = useSharedValue(0)
    const childProgress = useSharedValue(0)

    // Content scale for child views
    const menuScale = useSharedValue(1)

    // Child view state
    const [activeView, setActiveView] = useState<ChildView>('menu')

    // Child view animation
    const childTranslateY = useSharedValue(SCREEN_HEIGHT)
    const childBackdrop = useSharedValue(0)
    const childStartY = useSharedValue(0)



    // New Group state

    // New Group state
    const [groupName, setGroupName] = useState('')
    const [searchQuery, setSearchQuery] = useState('')
    const [selectedMembers, setSelectedMembers] = useState<{ id: string; name: string }[]>([])
    const [searchResults, setSearchResults] = useState<any[]>([])
    const [isSearching, setIsSearching] = useState(false)
    const [isCreating, setIsCreating] = useState(false)

    // New Channel state
    const [channelName, setChannelName] = useState('')
    const [channelDescription, setChannelDescription] = useState('')

    useEffect(() => {
        if (visible) {
            translateY.value = withTiming(OPEN_Y, { duration: 350, easing: Easing.out(Easing.exp) })
            backdrop.value = withTiming(1, { duration: 250 })
            if (parentScale) parentScale.value = withTiming(0.94, SMOOTH_TIMING)
        }
    }, [visible])

    const handleCloseInternal = () => {
        // If child view is open, close it first
        if (activeView !== 'menu') {
            closeChildView()
            return
        }
        backdrop.value = withTiming(0, { duration: 200 })
        translateY.value = withTiming(CLOSED_Y, { duration: 250 }, () => runOnJS(onClose)())
        if (parentScale) parentScale.value = withTiming(1, SMOOTH_TIMING)
    }

    const handleFullClose = () => {
        Keyboard.dismiss()
        backdrop.value = withTiming(0, { duration: 200 })
        childBackdrop.value = withTiming(0, { duration: 200 })
        translateY.value = withTiming(CLOSED_Y, { duration: 250 }, () => {
            runOnJS(onClose)()
            runOnJS(setActiveView)('menu')
            runOnJS(resetChildState)()
        })
        if (parentScale) parentScale.value = withTiming(1, SMOOTH_TIMING)
    }

    const openChildView = (view: ChildView) => {

        setActiveView(view)
        menuScale.value = withTiming(0.94, SMOOTH_TIMING)
        childTranslateY.value = withTiming(0, { duration: 350, easing: Easing.out(Easing.exp) })
        childBackdrop.value = withTiming(1, { duration: 300 })
    }

    const closeChildView = () => {
        Keyboard.dismiss()
        menuScale.value = withTiming(1, SMOOTH_TIMING)
        childTranslateY.value = withTiming(SCREEN_HEIGHT, { duration: 250 }, () => {
            runOnJS(setActiveView)('menu')
            runOnJS(resetChildState)()
        })
        childBackdrop.value = withTiming(0, { duration: 200 })
    }

    const resetChildState = () => {
        setGroupName('')
        setSearchQuery('')
        setSelectedMembers([])
        setSearchResults([])
        setChannelName('')
        setChannelDescription('')
    }

    const gesture = Gesture.Pan()
        .activeOffsetY([-10, 10])
        .onBegin(() => { startY.value = translateY.value })
        .onUpdate((e) => {
            if (scrollY.value <= 10 && activeView === 'menu') {
                const nextY = startY.value + e.translationY
                translateY.value = Math.max(OPEN_Y, Math.min(CLOSED_Y, nextY))
            }
        })
        .onEnd((e) => {
            if (scrollY.value <= 10 && activeView === 'menu') {
                if (translateY.value > 100 || e.velocityY > 1000) {
                    runOnJS(handleCloseInternal)()
                } else {
                    translateY.value = withTiming(OPEN_Y, { duration: 250 })
                }
            }
        })

    const childGesture = Gesture.Pan()
        .onBegin(() => { childStartY.value = childTranslateY.value })
        .onUpdate((e) => {
            const nextY = childStartY.value + e.translationY
            childTranslateY.value = Math.max(0, nextY)
        })
        .onEnd((e) => {
            if (childTranslateY.value > SCREEN_HEIGHT * 0.2 || e.velocityY > 1000) {
                runOnJS(closeChildView)()
            } else {
                childTranslateY.value = withTiming(0, { duration: 250 })
            }
        })

    const panelStyle = useAnimatedStyle(() => ({
        transform: [
            { translateY: translateY.value },
            { scale: menuScale.value }
        ],
        borderTopLeftRadius: 40,
        borderTopRightRadius: 40,
        height: MODAL_HEIGHT,
        bottom: 0,
        position: 'absolute',
        left: 0,
        right: 0,
        overflow: 'hidden',
    }))

    const overlayStyle = useAnimatedStyle(() => ({
        opacity: backdrop.value,
        backgroundColor: 'rgba(0,0,0,0.4)'
    }))

    const childPanelStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: childTranslateY.value }],
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        height: MODAL_HEIGHT,
        borderTopLeftRadius: 40,
        borderTopRightRadius: 40,
        overflow: 'hidden',
    }))

    const childOverlayStyle = useAnimatedStyle(() => ({
        opacity: childBackdrop.value,
        backgroundColor: 'rgba(0,0,0,0.3)'
    }))

    const scrollHandler = useAnimatedScrollHandler((event) => {
        scrollY.value = event.contentOffset.y
    })

    const handleContactPress = (contact: any) => {
        const friendId = (contact?.id || '').toString()
        const existingChat = chats.find(c => (c.friendId || '').toUpperCase() === friendId.toUpperCase())

        handleCloseInternal()
        setTimeout(() => {
            if (existingChat?.chatId) {
                setActiveChat(existingChat.chatId)
                router.push({ pathname: '/chat', params: { id: existingChat.chatId } })
            } else {
                router.push({
                    pathname: '/chat',
                    params: {
                        friendId,
                        friendName: contact?.username || friendId,
                        friendImage: contact?.profileImage || '',
                    }
                })
            }
        }, 280)
    }



    // === New Group Logic ===
    useEffect(() => {
        if (activeView !== 'newGroup' || searchQuery.length < 2) {
            setSearchResults([])
            return
        }

        const timer = setTimeout(async () => {
            setIsSearching(true)
            try {
                const result = await apiClient.findUserByName(searchQuery)
                if (result && result.id !== user?.userId) {
                    setSearchResults([result])
                } else {
                    setSearchResults([])
                }
            } catch (e) {
                setSearchResults([])
            }
            setIsSearching(false)
        }, 300)

        return () => clearTimeout(timer)
    }, [searchQuery, activeView])

    const toggleMember = (member: { id: string; name: string }) => {
        setSelectedMembers(prev => {
            const exists = prev.find(m => m.id === member.id)
            if (exists) return prev.filter(m => m.id !== member.id)
            return [...prev, member]
        })
    }

    const handleCreateGroup = async () => {
        if (!groupName.trim()) {
            Alert.alert('Error', 'Please enter a group name')
            return
        }
        if (selectedMembers.length === 0) {
            Alert.alert('Error', 'Please add at least one member')
            return
        }

        setIsCreating(true)
        const chatId = await createGroup(groupName.trim(), selectedMembers.map(m => m.id))
        setIsCreating(false)

        if (chatId) {
            closeChildView()
            setTimeout(() => handleCloseInternal(), 100)
        } else {
            Alert.alert('Error', 'Failed to create group')
        }
    }

    // === New Channel Logic ===
    const handleCreateChannel = async () => {
        if (!channelName.trim()) {
            Alert.alert('Error', 'Please enter a channel name')
            return
        }

        setIsCreating(true)
        const chatId = await createChannel(channelName.trim(), channelDescription.trim() || undefined)
        setIsCreating(false)

        if (chatId) {
            closeChildView()
            setTimeout(() => handleCloseInternal(), 100)
        } else {
            Alert.alert('Error', 'Failed to create channel')
        }
    }

    // === Render Child Views ===
    const renderChildContent = () => {
        if (activeView === 'newChat') {
            return <NewChatModal onClose={closeChildView} onFullClose={handleFullClose} />
        }

        if (activeView === 'newGroup') {
            return (
                <>
                    <View style={styles.childHeader}>
                        <AnimatedGlassButton
                            onPress={closeChildView}
                            progress={childProgress}
                            showPanelIcon={false}
                            effectiveTheme={effectiveTheme}
                            size={36}
                            homeIcon={<ArrowLeft size={20} color={colors.text} strokeWidth={1.5} />}
                            panelIcon={<View />}
                            homeBackgroundColor={isLight ? '#FFFFFF' : withAlpha(colors.text, 0.1)}
                        />
                        <Text style={[styles.childTitle, { color: colors.text }]}>New Group</Text>
                        <TouchableOpacity
                            onPress={handleCreateGroup}
                            disabled={isCreating || !groupName.trim() || selectedMembers.length === 0}
                            style={{ opacity: groupName.trim() && selectedMembers.length > 0 ? 1 : 0.4 }}
                        >
                            <SafeLiquidGlass style={styles.headerActionGlass} blurIntensity={10}>
                                {isCreating ? (
                                    <ActivityIndicator size="small" color={colors.primary} />
                                ) : (
                                    <Check size={22} color={colors.primary} strokeWidth={1.5} />
                                )}
                            </SafeLiquidGlass>
                        </TouchableOpacity>
                    </View>

                    <View style={styles.childContent}>
                        <Text style={[styles.iosSectionHeader, { color: colors.textSecondary }]}>GROUP</Text>
                        <View style={[styles.iosSection, { backgroundColor: isLight ? '#ffffff' : colors.card }]}>
                            <View style={styles.iosRow}>
                                <Text style={[styles.iosLabel, { color: colors.text }]}>Name</Text>
                                <TextInput
                                    value={groupName}
                                    onChangeText={setGroupName}
                                    placeholder="Group name"
                                    placeholderTextColor={withAlpha(colors.text, 0.35)}
                                    style={[styles.iosInput, { color: colors.text }]}
                                    maxLength={50}
                                />
                            </View>
                        </View>

                        {selectedMembers.length > 0 && (
                            <View style={styles.selectedRow}>
                                {selectedMembers.map(m => (
                                    <TouchableOpacity
                                        key={m.id}
                                        onPress={() => toggleMember(m)}
                                        style={[styles.chip, { backgroundColor: withAlpha(colors.primary, 0.15) }]}
                                    >
                                        <Text style={[styles.chipText, { color: colors.primary }]}>{m.name}</Text>
                                        <X size={14} color={colors.primary} strokeWidth={1.5} style={{ marginLeft: 4 }} />
                                    </TouchableOpacity>
                                ))}
                            </View>
                        )}

                        <Text style={[styles.iosSectionHeader, { color: colors.textSecondary, marginTop: 18 }]}>ADD PEOPLE</Text>
                        <View style={[styles.iosSection, { backgroundColor: isLight ? '#ffffff' : colors.card }]}>
                            <View style={styles.iosRow}>
                                <Text style={[styles.iosLabel, { color: colors.text }]}>Search</Text>
                                <TextInput
                                    value={searchQuery}
                                    onChangeText={setSearchQuery}
                                    placeholder="Username..."
                                    placeholderTextColor={withAlpha(colors.text, 0.35)}
                                    style={[styles.iosInput, { color: colors.text }]}
                                    autoCapitalize="none"
                                    autoCorrect={false}
                                />
                                {isSearching && <ActivityIndicator size="small" color={colors.primary} />}
                            </View>
                        </View>

                        <View style={[styles.iosSection, { backgroundColor: isLight ? '#ffffff' : colors.card, marginTop: 16, maxHeight: 320 }]}>
                            <FlatList
                                data={searchResults}
                                keyExtractor={item => item.id}
                                keyboardShouldPersistTaps="handled"
                                ItemSeparatorComponent={() => (
                                    <View style={[styles.iosDivider, { backgroundColor: withAlpha(colors.text, 0.05) }]} />
                                )}
                                renderItem={({ item }) => {
                                    const isSelected = selectedMembers.some(m => m.id === item.id)
                                    return (
                                        <TouchableOpacity
                                            onPress={() => toggleMember({ id: item.id, name: item.username })}
                                            activeOpacity={0.85}
                                            style={[styles.iosRow, { backgroundColor: isSelected ? withAlpha(colors.primary, 0.06) : 'transparent' }]}
                                        >
                                            <View style={[styles.userAvatar, { backgroundColor: withAlpha(colors.primary, 0.15) }]}>
                                                <Text style={{ color: colors.primary, fontWeight: '700' }}>
                                                    {(item.username || '?')[0].toUpperCase()}
                                                </Text>
                                            </View>
                                            <Text style={[styles.userName, { color: colors.text, flex: 1 }]} numberOfLines={1}>
                                                {item.username}
                                            </Text>
                                            {isSelected && <Check size={20} color={colors.primary} strokeWidth={1.8} />}
                                        </TouchableOpacity>
                                    )
                                }}
                            />
                        </View>
                    </View>
                </>
            )
        }

        if (activeView === 'newChannel') {
            return (
                <>
                    <View style={styles.childHeader}>
                        <AnimatedGlassButton
                            onPress={closeChildView}
                            progress={childProgress}
                            showPanelIcon={false}
                            effectiveTheme={effectiveTheme}
                            size={36}
                            homeIcon={<ArrowLeft size={20} color={colors.text} strokeWidth={1.5} />}
                            panelIcon={<View />}
                            homeBackgroundColor={isLight ? '#FFFFFF' : withAlpha(colors.text, 0.1)}
                        />
                        <Text style={[styles.childTitle, { color: colors.text }]}>New Channel</Text>
                        <TouchableOpacity
                            onPress={handleCreateChannel}
                            disabled={isCreating || !channelName.trim()}
                            style={{ opacity: channelName.trim() ? 1 : 0.4 }}
                        >
                            <SafeLiquidGlass style={styles.headerActionGlass} blurIntensity={10}>
                                {isCreating ? (
                                    <ActivityIndicator size="small" color={colors.primary} />
                                ) : (
                                    <Check size={22} color={colors.primary} strokeWidth={1.5} />
                                )}
                            </SafeLiquidGlass>
                        </TouchableOpacity>
                    </View>

                    <View style={styles.childContent}>
                        <View style={[styles.channelIconContainer, { backgroundColor: withAlpha('#f59e0b', 0.08) }]}>
                            <SafeLiquidGlass style={styles.channelIconGlass} blurIntensity={15}>
                                <Megaphone size={32} color="#f59e0b" strokeWidth={1.5} />
                            </SafeLiquidGlass>
                        </View>
                        <Text style={[styles.channelSubtitle, { color: colors.textSecondary }]}>
                            Channels are for broadcasting messages to subscribers. Only authors can post.
                        </Text>

                        <View style={styles.channelForm}>
                            <Text style={[styles.modernLabel, { color: colors.textSecondary }]}>Channel name</Text>
                            <SafeLiquidGlass
                                style={[styles.modernInputWrapper, { borderColor: withAlpha(colors.text, 0.08) }]}
                                blurIntensity={15}
                            >
                                <View style={styles.modernInnerInput}>
                                    <TextInput
                                        style={[styles.modernInput, { color: colors.text }]}
                                        placeholder="e.g. Daily Updates"
                                        placeholderTextColor={colors.textSecondary}
                                        value={channelName}
                                        onChangeText={setChannelName}
                                        maxLength={50}
                                    />
                                </View>
                            </SafeLiquidGlass>

                            <Text style={[styles.modernLabel, { color: colors.textSecondary, marginTop: 20 }]}>Description (optional)</Text>
                            <SafeLiquidGlass
                                style={[styles.modernMultilineWrapper, { borderColor: withAlpha(colors.text, 0.08) }]}
                                blurIntensity={15}
                            >
                                <TextInput
                                    style={[styles.modernInput, styles.modernMultilineInput, { color: colors.text }]}
                                    placeholder="What's this channel about?"
                                    placeholderTextColor={colors.textSecondary}
                                    value={channelDescription}
                                    onChangeText={setChannelDescription}
                                    multiline
                                    maxLength={200}
                                    numberOfLines={3}
                                />
                            </SafeLiquidGlass>
                        </View>
                    </View>
                </>
            )
        }

        return null
    }

    return (
        <Modal
            transparent
            visible={visible}
            animationType="none"
            onRequestClose={handleCloseInternal}
            statusBarTranslucent
        >
            <GestureHandlerRootViewAny style={[StyleSheet.absoluteFill, { zIndex: 999 }]}>
                <View style={StyleSheet.absoluteFill}>
                    {/* Main backdrop */}
                    <AnimatedView style={[StyleSheet.absoluteFill, overlayStyle]}>
                        <Pressable style={StyleSheet.absoluteFill} onPress={handleCloseInternal} />
                    </AnimatedView>

                    {/* Main Menu Panel */}
                    <GestureDetector gesture={gesture}>
                        <AnimatedView style={[panelStyle, { backgroundColor: bgColor }]}>
                            {/* Header Blur - Fixed position */}
                            <View style={styles.headerBlur} pointerEvents="none">
                                <MaskedViewAny
                                    style={StyleSheet.absoluteFill}
                                    maskElement={
                                        <LinearGradient
                                            colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0.8)', 'rgba(0,0,0,0)']}
                                            locations={[0, 0.5, 1]}
                                            style={StyleSheet.absoluteFill}
                                        />
                                    }
                                >
                                    <View style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(bgColor, 0.95) }]} />
                                    <BlurView style={StyleSheet.absoluteFill} intensity={15} tint={isLight ? 'light' : 'dark'} />
                                </MaskedViewAny>
                            </View>

                            {/* Header & Close - Fixed */}
                            <View style={styles.headerContainer} pointerEvents="box-none">
                                <Text style={[styles.headerTitle, { color: colors.text }]}>Start Vibe</Text>
                                <AnimatedGlassButton
                                    onPress={handleCloseInternal}
                                    progress={closeButtonProgress}
                                    showPanelIcon={false}
                                    effectiveTheme={effectiveTheme}
                                    size={36}
                                    homeIcon={<X size={20} color={colors.text} strokeWidth={1.5} />}
                                    panelIcon={<View />}
                                    homeBackgroundColor={isLight ? '#FFFFFF' : withAlpha(colors.text, 0.1)}
                                />
                            </View>

                            <Animated.ScrollView
                                onScroll={scrollHandler}
                                scrollEventThrottle={16}
                                contentContainerStyle={styles.scrollContent}
                                showsVerticalScrollIndicator={false}
                            >
                                {/* Actions Row - Modern Glass */}
                                <View style={styles.actionsRow}>
                                    <TouchableOpacity onPress={() => openChildView('newChat')} style={styles.bubbleBtn}>
                                        <SafeLiquidGlass style={styles.bubbleGlass} blurIntensity={12}>
                                            <View style={[styles.bubbleIcon, { backgroundColor: withAlpha(colors.primary, 0.1) }]}>
                                                <EditChatVibeIcon size={24} color={colors.primary} strokeWidth={1.5} />
                                            </View>
                                        </SafeLiquidGlass>
                                        <Text style={[styles.bubbleLabel, { color: colors.text }]}>New Chat</Text>
                                    </TouchableOpacity>

                                    <TouchableOpacity onPress={() => openChildView('newGroup')} style={styles.bubbleBtn}>
                                        <SafeLiquidGlass style={styles.bubbleGlass} blurIntensity={12}>
                                            <View style={[styles.bubbleIcon, { backgroundColor: withAlpha('#8b5cf6', 0.1) }]}>
                                                <Users size={22} color="#8b5cf6" strokeWidth={1.5} />
                                            </View>
                                        </SafeLiquidGlass>
                                        <Text style={[styles.bubbleLabel, { color: colors.text }]}>New Group</Text>
                                    </TouchableOpacity>

                                    <TouchableOpacity onPress={() => openChildView('newChannel')} style={styles.bubbleBtn}>
                                        <SafeLiquidGlass style={styles.bubbleGlass} blurIntensity={12}>
                                            <View style={[styles.bubbleIcon, { backgroundColor: withAlpha('#f59e0b', 0.1) }]}>
                                                <Megaphone size={22} color="#f59e0b" strokeWidth={1.5} />
                                            </View>
                                        </SafeLiquidGlass>
                                        <Text style={[styles.bubbleLabel, { color: colors.text }]}>New Channel</Text>
                                    </TouchableOpacity>

                                    <TouchableOpacity onPress={() => { handleCloseInternal(); setTimeout(() => router.push('/test-animation-basic'), 300); }} style={styles.bubbleBtn}>
                                        <SafeLiquidGlass style={styles.bubbleGlass} blurIntensity={12}>
                                            <View style={[styles.bubbleIcon, { backgroundColor: withAlpha('#10b981', 0.1) }]}>
                                                <Sparkles size={22} color="#10b981" strokeWidth={1.5} />
                                            </View>
                                        </SafeLiquidGlass>
                                        <Text style={[styles.bubbleLabel, { color: colors.text }]}>Test</Text>
                                    </TouchableOpacity>
                                </View>

                                {/* Contacts List */}
                                <Text style={styles.modernLabel}>Contacts</Text>

                                <View style={styles.contactsList}>
                                    {contacts.length === 0 ? (
                                        <View style={[styles.emptyContainer, { backgroundColor: withAlpha(colors.text, 0.03) }]}>
                                            <Text style={[styles.emptyText, { color: colors.textSecondary }]}>
                                                No contacts yet. Start a new chat to add people!
                                            </Text>
                                        </View>
                                    ) : (
                                        contacts.map((contact, i) => (
                                            <TouchableOpacity
                                                key={contact.id}
                                                style={[styles.contactRow, { borderBottomColor: withAlpha(colors.text, 0.05), borderBottomWidth: i === contacts.length - 1 ? 0 : 1 }]}
                                                onPress={() => handleContactPress(contact)}
                                            >
                                                <SafeLiquidGlass style={styles.avatarGlass} blurIntensity={10} tint={isLight ? 'light' : 'dark'}>
                                                    {contact.profileImage ? (
                                                        <Image source={{ uri: contact.profileImage }} style={styles.avatarImage} />
                                                    ) : (
                                                        <View style={[styles.avatarPlaceholder, { backgroundColor: withAlpha(colors.primary, 0.1) }]}>
                                                            <Text style={[styles.avatarText, { color: colors.primary }]}>
                                                                {(contact.username || '?').substring(0, 1).toUpperCase()}
                                                            </Text>
                                                        </View>
                                                    )}
                                                </SafeLiquidGlass>

                                                <View style={styles.contactInfo}>
                                                    <Text style={[styles.contactName, { color: colors.text }]}>{contact.username}</Text>
                                                    {contact.phoneNumber && <Text style={[styles.contactSub, { color: colors.textSecondary }]}>{contact.phoneNumber}</Text>}
                                                </View>

                                                <TouchableOpacity onPress={() => handleContactPress(contact)}>
                                                    <SafeLiquidGlass style={styles.msgBtnGlass} blurIntensity={10}>
                                                        <MessageCircle size={18} color={colors.primary} strokeWidth={1.5} />
                                                    </SafeLiquidGlass>
                                                </TouchableOpacity>
                                            </TouchableOpacity>
                                        ))
                                    )}
                                </View>

                                <View style={{ height: 40 }} />
                            </Animated.ScrollView>
                        </AnimatedView>
                    </GestureDetector>

                    {/* Child View Overlay */}
                    {activeView !== 'menu' && (
                        <>
                            <AnimatedView style={[StyleSheet.absoluteFill, childOverlayStyle]}>
                                <TouchableWithoutFeedback onPress={closeChildView}>
                                    <View style={StyleSheet.absoluteFill} />
                                </TouchableWithoutFeedback>
                            </AnimatedView>

                            <GestureDetector gesture={childGesture}>
                                <AnimatedView style={[childPanelStyle, { backgroundColor: bgColor }]}>
                                    {renderChildContent()}
                                </AnimatedView>
                            </GestureDetector>
                        </>
                    )}
                </View>
            </GestureHandlerRootViewAny>


        </Modal>
    )
}

const styles = StyleSheet.create({
    headerBlur: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        height: 100,
        zIndex: 100,
    },
    headerContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 20,
        paddingTop: 28,
        paddingBottom: 10,
        zIndex: 110
    },
    headerTitle: {
        fontSize: 20,
        fontWeight: '700',
    },
    scrollContent: {
        paddingTop: 80,
        paddingHorizontal: 20,
        paddingBottom: 60
    },
    actionsRow: {
        flexDirection: 'row',
        justifyContent: 'space-around',
        marginBottom: 32,
        marginTop: 10,
        paddingHorizontal: 10
    },
    bubbleBtn: {
        alignItems: 'center',
        gap: 10
    },
    bubbleGlass: {
        width: 64,
        height: 64,
        borderRadius: 32,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center'
    },
    bubbleIcon: {
        width: 64,
        height: 64,
        borderRadius: 32,
        alignItems: 'center',
        justifyContent: 'center'
    },
    bubbleLabel: {
        fontSize: 13,
        fontWeight: '600',
    },
    sectionTitle: {
        fontSize: 13,
        fontWeight: '600',
        letterSpacing: 0.5,
        marginBottom: 16,
        marginLeft: 8,
        opacity: 0.6
    },
    contactsList: {
        gap: 4
    },
    contactRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 12,
        paddingHorizontal: 8
    },
    avatarGlass: {
        width: 48,
        height: 48,
        borderRadius: 24,
        overflow: 'hidden',
        marginRight: 16
    },
    avatarImage: {
        width: '100%',
        height: '100%'
    },
    avatarPlaceholder: {
        width: '100%',
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center'
    },
    avatarText: {
        fontSize: 18,
        fontWeight: '700'
    },
    contactInfo: {
        flex: 1,
        gap: 2
    },
    contactName: {
        fontSize: 16,
        fontWeight: '600'
    },
    contactSub: {
        fontSize: 13,
    },
    msgBtn: {
        width: 36,
        height: 36,
        borderRadius: 18,
        alignItems: 'center',
        justifyContent: 'center'
    },
    emptyContainer: {
        padding: 30,
        borderRadius: 16,
        alignItems: 'center',
        justifyContent: 'center'
    },
    emptyText: {
        textAlign: 'center',
        lineHeight: 20
    },
    // Child view styles
    childHeader: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 20,
        paddingTop: 28,
        paddingBottom: 20,
    },
    backBtn: {
        padding: 8,
    },
    childTitle: {
        fontSize: 20,
        fontWeight: '700',
    },
    childContent: {
        paddingHorizontal: 24,
        flex: 1,
    },
    headerIconBtn: {
        width: 44,
        height: 44,
        borderRadius: 22,
        alignItems: 'center',
        justifyContent: 'center',
        shadowOffset: { width: 0, height: 10 },
        shadowOpacity: 0.14,
        shadowRadius: 18,
        elevation: 6,
    },
    childSlider: {
        flexDirection: 'row',
        width: CHILD_PAGE_WIDTH * 2,
    },
    childPage: {
        paddingBottom: 24,
    },
    iosSectionHeader: {
        fontSize: 12,
        fontWeight: '700',
        textTransform: 'uppercase',
        letterSpacing: 0.8,
        marginBottom: 8,
        marginLeft: 12,
        opacity: 0.55,
    },
    iosSection: {
        borderRadius: 26,
        overflow: 'hidden',
    },
    iosRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 16,
        paddingHorizontal: 20,
        minHeight: 58,
    },
    iosLabel: {
        fontSize: 16,
        fontWeight: '500',
        width: 98,
    },
    iosInput: {
        flex: 1,
        fontSize: 16,
        fontWeight: '500',
        paddingVertical: 0,
    },
    iosDivider: {
        height: 1,
        marginLeft: 20,
    },
    detailsAvatar: {
        width: 78,
        height: 78,
        borderRadius: 39,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center',
    },
    detailsAvatarText: {
        color: '#fff',
        fontSize: 28,
        fontWeight: '800',
    },
    detailsName: {
        marginTop: 10,
        fontSize: 20,
        fontWeight: '800',
    },
    detailsSub: {
        marginTop: 4,
        fontSize: 13,
        fontWeight: '600',
        opacity: 0.7,
    },
    newChatProfileCard: {
        borderRadius: 28,
        overflow: 'hidden',
    },
    newChatProfileCardInner: {
        paddingVertical: 28,
        paddingHorizontal: 20,
        alignItems: 'center',
    },
    glassCard: {
        borderRadius: 26,
        overflow: 'hidden',
    },
    cardInner: {
        padding: 16,
    },
    actionInner: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8,
    },
    actionPillsRow: {
        flexDirection: 'row',
        gap: 12,
        width: '100%',
        marginTop: 20,
    },
    actionPill: {
        flex: 1,
        height: 52,
        borderRadius: 16,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 10,
    },
    actionPillText: {
        fontSize: 15,
        fontWeight: '700',
    },
    inputWrapper: {
        height: 56,
        borderRadius: 20,
        borderWidth: 1,
        overflow: 'hidden',
        backgroundColor: 'rgba(150,150,150,0.05)'
    },
    innerInput: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 16
    },
    modernInputWrapper: {
        height: 60,
        borderRadius: 22,
        borderWidth: 1,
        overflow: 'hidden',
        backgroundColor: 'rgba(150,150,150,0.04)'
    },
    modernInnerInput: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        paddingLeft: 16,
        paddingRight: 8
    },
    inputPrefixIcon: {
        width: 32,
        alignItems: 'center',
        marginRight: 8,
        opacity: 0.8
    },
    modernInput: {
        flex: 1,
        fontSize: 16,
        fontWeight: '500',
        height: '100%',
        paddingVertical: 10
    },
    searchIconButton: {
        width: 44,
        height: 44,
        borderRadius: 16,
        alignItems: 'center',
        justifyContent: 'center'
    },
    input: {
        flex: 1,
        fontSize: 16,
        fontWeight: '500',
        height: '100%'
    },
    errorText: {
        marginTop: 12,
        fontSize: 14,
        textAlign: 'center'
    },
    userCardContainer: {
        marginTop: 24,
        gap: 16
    },
    modernUserCard: {
        borderRadius: 24,
        padding: 4,
        borderWidth: 1,
        overflow: 'hidden'
    },
    userCardMain: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 12,
        gap: 16
    },
    modernUserAvatar: {
        width: 52,
        height: 52,
        borderRadius: 20,
        alignItems: 'center',
        justifyContent: 'center'
    },
    modernUserAvatarText: {
        fontSize: 22,
        fontWeight: '700'
    },
    modernUserName: {
        fontSize: 18,
        fontWeight: '700'
    },
    modernUserSub: {
        fontSize: 14,
        marginTop: 2
    },
    addedBadge: {
        width: 32,
        height: 32,
        borderRadius: 12,
        alignItems: 'center',
        justifyContent: 'center'
    },
    modernActionRow: {
        flexDirection: 'row',
        gap: 12,
        marginTop: 8
    },
    actionGlassBtnWrapper: {
        flex: 1
    },
    actionGlassBtn: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 10,
        paddingVertical: 16,
        borderRadius: 20,
        overflow: 'hidden'
    },
    userCard: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 16,
        borderRadius: 20,
        gap: 16,
        borderWidth: 1
    },
    userAvatar: {
        width: 48,
        height: 48,
        borderRadius: 24,
        alignItems: 'center',
        justifyContent: 'center'
    },
    userAvatarText: {
        fontSize: 20,
        fontWeight: '700'
    },
    userName: {
        fontSize: 17,
        fontWeight: '600'
    },
    userSub: {
        fontSize: 13,
        marginTop: 2
    },
    actionRow: {
        flexDirection: 'row',
        gap: 12
    },
    actionBtn: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8,
        paddingVertical: 14,
        borderRadius: 16
    },
    actionBtnText: {
        fontSize: 15,
        fontWeight: '600',
        color: '#fff'
    },
    selectedRow: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: 8,
        marginTop: 16
    },
    chip: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        paddingVertical: 6,
        borderRadius: 20
    },
    chipText: {
        fontSize: 14,
        fontWeight: '500'
    },
    userRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 12,
        paddingHorizontal: 8,
        borderRadius: 12
    },
    channelIconContainer: {
        width: 80,
        height: 80,
        borderRadius: 40,
        justifyContent: 'center',
        alignItems: 'center',
        alignSelf: 'center',
        marginBottom: 16
    },
    channelSubtitle: {
        fontSize: 14,
        textAlign: 'center',
        lineHeight: 20,
        marginBottom: 24
    },
    label: {
        fontSize: 13,
        fontWeight: '600',
        marginBottom: 8,
        textTransform: 'uppercase',
        letterSpacing: 0.5
    },
    multilineWrapper: {
        height: 100,
    },
    multilineInput: {
        paddingTop: 14,
        textAlignVertical: 'top'
    },
    headerActionGlass: {
        width: 44,
        height: 44,
        borderRadius: 16,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden'
    },
    modernLabel: {
        fontSize: 12,
        fontWeight: '700',
        textTransform: 'uppercase',
        letterSpacing: 0.8,
        marginBottom: 8,
        marginLeft: 4,
        opacity: 0.5
    },
    modernMultilineWrapper: {
        height: 120,
        borderRadius: 22,
        borderWidth: 1,
        overflow: 'hidden',
        backgroundColor: 'rgba(150,150,150,0.04)'
    },
    modernMultilineInput: {
        paddingTop: 16,
        paddingHorizontal: 16,
        textAlignVertical: 'top',
        fontSize: 16,
        fontWeight: '500'
    },
    channelForm: {
        marginTop: 10,
        gap: 4
    },
    channelIconGlass: {
        width: 80,
        height: 80,
        borderRadius: 40,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden'
    },
    msgBtnGlass: {
        width: 40,
        height: 40,
        borderRadius: 14,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
        backgroundColor: 'rgba(150,150,150,0.05)'
    },
    settingRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 12,
        paddingHorizontal: 16,
        minHeight: 52
    },
    settingIconContainer: {
        width: 30,
        height: 30,
        borderRadius: 8,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 14
    },
    settingInput: {
        flex: 1,
        fontSize: 16,
        fontWeight: '500',
        height: '100%'
    },
    divider: {
        height: 1,
        marginLeft: 56
    }
})
