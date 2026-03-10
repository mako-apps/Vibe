import React, { useEffect, useState, useMemo } from 'react'
import { View, Text, StyleSheet, Dimensions, Pressable, TouchableOpacity, ScrollView, Switch, Image } from 'react-native'
import { X, Globe, User, Users, Star, ChevronRight, Check, Megaphone, ChevronLeft, Search, Clock } from 'lucide-react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    runOnJS,
    Easing,
    SharedValue,
    FadeIn,
    FadeOut,
    SlideInRight,
    SlideOutRight
} from 'react-native-reanimated'
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler'
import { BlurView } from 'expo-blur'
import { LinearGradient } from 'expo-linear-gradient'
import MaskedView from '@react-native-masked-view/masked-view'
import * as Haptics from 'expo-haptics'
import { useThemeStore } from '../../lib/stores/theme-store'
import { useContactStore } from '../../lib/stores/contact-store'
import AnimatedGlassButton from '../native/AnimatedGlassButton'
import GlassMorphMenu from '../settings/GlassMorphMenu'

const { height: SCREEN_HEIGHT, width: SCREEN_WIDTH } = Dimensions.get('window')
const MaskedViewAny = MaskedView as any
const AnimatedView = Animated.View as any
const GestureHandlerRootViewAny = GestureHandlerRootView as any

const MODAL_HEIGHT = SCREEN_HEIGHT * 0.75 // Increased height for more content
const OPEN_Y = 0
const CLOSED_Y = SCREEN_HEIGHT
const SMOOTH_TIMING = { duration: 300, easing: Easing.bezier(0.25, 0.1, 0.25, 1) }

export interface ShareOptions {
    audience: 'everyone' | 'contacts' | 'close_friends' | 'selected'
    allowScreenshots: boolean
    postToProfile: boolean
    duration: 12 | 24 | 48
    excludedUsers?: string[]
    includedUsers?: string[]
}

interface ShareModalProps {
    visible: boolean
    onClose: () => void
    onPost: (options: ShareOptions) => void
    onSaveDraft: () => void
    parentScale?: SharedValue<number>
}

const AUDIENCE_OPTIONS = [
    {
        id: 'everyone',
        label: 'Everyone',
        subAction: 'exclude people',
        icon: Megaphone,
        colorKey: 'blue',
        description: ''
    },
    {
        id: 'contacts',
        label: 'My Contacts',
        subAction: 'exclude people',
        icon: User,
        colorKey: 'violet',
        description: ''
    },
    {
        id: 'close_friends',
        label: 'Close Friends',
        subAction: 'edit list',
        icon: Star,
        colorKey: 'sage',
        description: ''
    },
    {
        id: 'selected',
        label: 'Selected Users',
        subAction: 'choose',
        icon: Users,
        colorKey: 'orange',
        description: ''
    },
] as const

type ViewState = 'main' | 'select_users'
type SelectionType = 'exclude' | 'edit_close_friends' | 'choose_selected'

export const ShareModal = ({ visible, onClose, onPost, onSaveDraft, parentScale }: ShareModalProps) => {
    const { colors, effectiveTheme } = useThemeStore()
    const { contacts } = useContactStore() // Assuming this hook works
    const isLight = effectiveTheme === 'light'
    const bgColor = colors.background
    const cardColor = colors.card

    const [showModal, setShowModal] = useState(false)

    // State
    const [view, setView] = useState<ViewState>('main')
    const [selectionType, setSelectionType] = useState<SelectionType>('choose_selected')

    const [selectedAudience, setSelectedAudience] = useState<ShareOptions['audience']>('everyone')
    const [allowScreenshots, setAllowScreenshots] = useState(true)
    const [postToProfile, setPostToProfile] = useState(true)
    const [duration, setDuration] = useState<12 | 24 | 48>(24)

    // Selection sets
    const [excludedUsers, setExcludedUsers] = useState<Set<string>>(new Set())
    const [closeFriends, setCloseFriends] = useState<Set<string>>(new Set())
    const [selectedUsers, setSelectedUsers] = useState<Set<string>>(new Set())

    const translateY = useSharedValue(CLOSED_Y)
    const backdrop = useSharedValue(0)
    const startY = useSharedValue(OPEN_Y)
    const activeHeader = useSharedValue(0)

    useEffect(() => {
        if (visible) {
            setShowModal(true)
            translateY.value = withTiming(OPEN_Y, { duration: 250 })
            backdrop.value = withTiming(1, { duration: 250 })
            if (parentScale) {
                parentScale.value = withTiming(0.92, SMOOTH_TIMING)
            }
        } else {
            // Reset view on close
            setTimeout(() => setView('main'), 300)
        }
    }, [visible])

    const handleCloseInternal = () => {
        backdrop.value = withTiming(0, { duration: 200 })
        translateY.value = withTiming(CLOSED_Y, { duration: 250 }, () => {
            runOnJS(setShowModal)(false)
            runOnJS(onClose)()
        })
        if (parentScale) {
            parentScale.value = withTiming(1, SMOOTH_TIMING)
        }
    }

    const handlePost = () => {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
        handleCloseInternal()
        // Delay callback slightly to allow animation to start
        setTimeout(() => {
            onPost({
                audience: selectedAudience,
                allowScreenshots,
                postToProfile,
                duration,
                excludedUsers: Array.from(excludedUsers),
                includedUsers: selectedAudience === 'close_friends'
                    ? Array.from(closeFriends)
                    : selectedAudience === 'selected'
                        ? Array.from(selectedUsers)
                        : undefined
            })
        }, 100)
    }

    const handleSaveDraft = () => {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
        handleCloseInternal()
        setTimeout(() => {
            onSaveDraft()
        }, 100)
    }

    const handleSubAction = (id: string) => {
        Haptics.selectionAsync()
        if (id === 'everyone' || id === 'contacts') {
            setSelectionType('exclude')
        } else if (id === 'close_friends') {
            setSelectionType('edit_close_friends')
            setSelectedAudience('close_friends')
        } else if (id === 'selected') {
            setSelectionType('choose_selected')
            setSelectedAudience('selected')
        }
        setView('select_users')
    }

    const toggleUserSelection = (userId: string) => {
        Haptics.selectionAsync()
        if (selectionType === 'exclude') {
            const next = new Set(excludedUsers)
            if (next.has(userId)) next.delete(userId)
            else next.add(userId)
            setExcludedUsers(next)
        } else if (selectionType === 'edit_close_friends') {
            const next = new Set(closeFriends)
            if (next.has(userId)) next.delete(userId)
            else next.add(userId)
            setCloseFriends(next)
        } else {
            const next = new Set(selectedUsers)
            if (next.has(userId)) next.delete(userId)
            else next.add(userId)
            setSelectedUsers(next)
        }
    }

    const isUserSelected = (userId: string) => {
        if (selectionType === 'exclude') return excludedUsers.has(userId)
        if (selectionType === 'edit_close_friends') return closeFriends.has(userId)
        return selectedUsers.has(userId)
    }

    const getSelectionTitle = () => {
        if (selectionType === 'exclude') return 'Exclude People'
        if (selectionType === 'edit_close_friends') return 'Edit Close Friends'
        return 'Select Users'
    }

    const gesture = Gesture.Pan()
        .activeOffsetY([-10, 10])
        .onBegin(() => { startY.value = translateY.value })
        .onUpdate((e) => {
            const nextY = startY.value + e.translationY
            translateY.value = Math.max(OPEN_Y, Math.min(CLOSED_Y, nextY))
        })
        .onEnd((e) => {
            if (translateY.value > 120 || e.velocityY > 1000) {
                runOnJS(handleCloseInternal)()
            } else {
                translateY.value = withTiming(OPEN_Y, { duration: 250 })
            }
        })

    const panelStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: translateY.value }],
        borderTopLeftRadius: 24,
        borderTopRightRadius: 24,
    }))

    const overlayStyle = useAnimatedStyle(() => ({
        opacity: backdrop.value,
    }))

    if (!showModal) return null

    // Fallback if no contacts
    const displayContacts = (contacts && contacts.length > 0) ? contacts : [
        { id: '1', username: 'Alex', profileImage: undefined },
        { id: '2', username: 'Sarah', profileImage: undefined },
        { id: '3', username: 'Mike', profileImage: undefined },
        { id: '4', username: 'Jessica', profileImage: undefined },
        { id: '5', username: 'David', profileImage: undefined },
    ]

    return (
        <GestureHandlerRootViewAny style={[StyleSheet.absoluteFill, { zIndex: 999 }]}>
            <View style={StyleSheet.absoluteFill}>
                <AnimatedView style={[styles.overlay, overlayStyle, { backgroundColor: 'rgba(0,0,0,0.5)' }]}>
                    <Pressable style={StyleSheet.absoluteFill} onPress={handleCloseInternal} />
                </AnimatedView>

                <GestureDetector gesture={gesture}>
                    <AnimatedView style={[styles.modalContainer, panelStyle, { backgroundColor: bgColor }]}>

                        {/* Drag Handle Area */}
                        <View style={styles.dragHandleArea}>
                            <View style={styles.dragHandle} />
                        </View>

                        {/* Masked Header Background */}
                        <View style={[StyleSheet.absoluteFill, { height: 80, zIndex: 0 }]} pointerEvents="none">
                            <MaskedViewAny
                                style={StyleSheet.absoluteFill}
                                maskElement={
                                    <LinearGradient
                                        colors={['rgba(0,0,0,1)', 'rgba(0,0,0,1)', 'rgba(0,0,0,0)']}
                                        locations={[0, 0.6, 1]}
                                        style={StyleSheet.absoluteFill}
                                    />
                                }
                            >
                                <View style={[StyleSheet.absoluteFill, { backgroundColor: bgColor }]} />
                                <BlurView style={StyleSheet.absoluteFill} intensity={20} tint={isLight ? 'light' : 'dark'} />
                            </MaskedViewAny>
                        </View>

                        {/* Dynamic Header Content */}
                        <View style={[styles.header, { zIndex: 1, backgroundColor: 'transparent' }]}>
                            {view === 'main' ? (
                                <>
                                    <View style={{ width: 40 }} />
                                    <Animated.Text
                                        entering={FadeIn.duration(200)}
                                        exiting={FadeOut.duration(200)}
                                        style={[styles.headerTitle, { color: colors.text }]}
                                    >
                                        Share Story
                                    </Animated.Text>
                                    <AnimatedGlassButton
                                        onPress={handleCloseInternal}
                                        progress={activeHeader}
                                        showPanelIcon={false}
                                        effectiveTheme={effectiveTheme}
                                        size={32}
                                        homeIcon={<X size={18} color={colors.text} strokeWidth={2.5} />}
                                        panelIcon={<View />}
                                        homeBackgroundColor={isLight ? '#E5E5EA' : '#2C2C2E'}
                                    />
                                </>
                            ) : (
                                <>
                                    <TouchableOpacity
                                        onPress={() => setView('main')}
                                        style={styles.backButton}
                                    >
                                        <ChevronLeft size={24} color={colors.text} />
                                    </TouchableOpacity>
                                    <Animated.Text
                                        entering={FadeIn.duration(200)}
                                        exiting={FadeOut.duration(200)}
                                        style={[styles.headerTitle, { color: colors.text }]}
                                    >
                                        {getSelectionTitle()}
                                    </Animated.Text>
                                    <View style={{ width: 40 }} />
                                </>
                            )}
                        </View>

                        <View style={styles.scrollViewContainer}>
                            {view === 'main' ? (
                                <Animated.ScrollView
                                    entering={FadeIn}
                                    exiting={FadeOut}
                                    style={styles.scrollView}
                                    contentContainerStyle={[styles.scrollContent]}
                                    showsVerticalScrollIndicator={false}
                                >
                                    <Text style={[styles.sectionLabel, { color: colors.textSecondary }]}>WHO CAN VIEW THIS STORY</Text>

                                    {/* Audience List */}
                                    <View style={[styles.sectionContainer, { backgroundColor: cardColor }]}>
                                        {AUDIENCE_OPTIONS.map((option, index) => {
                                            const isSelected = selectedAudience === option.id
                                            const Icon = option.icon
                                            const isLast = index === AUDIENCE_OPTIONS.length - 1
                                            const optionColor = (colors.palette as any)[option.colorKey] || colors.primary

                                            return (
                                                <View key={option.id}>
                                                    <TouchableOpacity
                                                        style={styles.optionRow}
                                                        onPress={() => {
                                                            setSelectedAudience(option.id as any)
                                                            Haptics.selectionAsync()
                                                        }}
                                                        activeOpacity={0.7}
                                                    >
                                                        {/* Selection (Radio) */}
                                                        <View style={[styles.radioContainer, { backgroundColor: isSelected ? optionColor : 'transparent', borderColor: isSelected ? optionColor : colors.border }]}>
                                                            {isSelected && <Check size={12} color="#fff" strokeWidth={4} />}
                                                        </View>

                                                        {/* Icon */}
                                                        <View style={[styles.iconContainer, { backgroundColor: optionColor }]}>
                                                            <Icon size={20} color="#fff" fill={option.id === 'everyone' ? "#fff" : "none"} strokeWidth={2.5} />
                                                        </View>

                                                        {/* Text Content */}
                                                        <View style={styles.optionTextContainer}>
                                                            <Text style={[styles.optionLabel, { color: colors.text }]}>{option.label}</Text>
                                                            <TouchableOpacity onPress={() => handleSubAction(option.id)} style={{ flexDirection: 'row', alignItems: 'center' }}>
                                                                <Text style={[styles.optionSubAction, { color: colors.primary }]}>{option.subAction}</Text>
                                                                <ChevronRight size={12} color={colors.primary} />
                                                            </TouchableOpacity>
                                                        </View>
                                                    </TouchableOpacity>
                                                    {!isLast && <View style={[styles.divider, { backgroundColor: colors.borderSubtle }]} />}
                                                </View>
                                            )
                                        })}
                                    </View>

                                    <Text style={[styles.helperText, { color: colors.textSecondary, marginBottom: 24 }]}>
                                        Select people who will never see your stories.
                                    </Text>

                                    <Text style={[styles.sectionLabel, { color: colors.textSecondary }]}>DURATION</Text>
                                    <View style={[styles.sectionContainer, { backgroundColor: cardColor, padding: 16, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', zIndex: 100 }]}>
                                        <View>
                                            <Text style={{ color: colors.text, fontSize: 16, fontWeight: '500' }}>Story Duration</Text>
                                            <Text style={{ color: colors.textSecondary, fontSize: 13, marginTop: 2 }}>Expires in {duration} hours</Text>
                                        </View>
                                        <GlassMorphMenu
                                            items={[
                                                { id: '12', label: '12 Hours', icon: Clock },
                                                { id: '24', label: '24 Hours', icon: Clock },
                                                { id: '48', label: '48 Hours', icon: Clock },
                                            ]}
                                            onSelect={(id) => {
                                                const d = parseInt(id) as 12 | 24 | 48
                                                if (!isNaN(d)) setDuration(d)
                                                Haptics.selectionAsync()
                                            }}
                                            customIcon={<Clock size={20} color={colors.text} />}
                                            menuWidth={160}
                                            menuHeight={170}
                                            collapsedSize={44}
                                        />
                                    </View>

                                    <Text style={[styles.sectionLabel, { color: colors.textSecondary }]}>PERMISSIONS</Text>
                                    {/* Toggles */}
                                    <View style={[styles.sectionContainer, { backgroundColor: cardColor }]}>
                                        <View style={styles.toggleRow}>
                                            <View style={{ flex: 1 }}>
                                                <Text style={[styles.toggleLabel, { color: colors.text }]}>Allow Screenshots</Text>
                                            </View>
                                            <Switch
                                                value={allowScreenshots}
                                                onValueChange={setAllowScreenshots}
                                                trackColor={{ false: colors.borderStrong, true: colors.success }}
                                                thumbColor={'#fff'}
                                                ios_backgroundColor={colors.input}
                                            />
                                        </View>

                                        <View style={[styles.divider, { backgroundColor: colors.borderSubtle, marginLeft: 16 }]} />

                                        <View style={[styles.toggleRow, { paddingVertical: 14 }]}>
                                            <View style={{ flex: 1, paddingRight: 10 }}>
                                                <Text style={[styles.toggleLabel, { color: colors.text }]}>Post to My Profile</Text>
                                            </View>
                                            <Switch
                                                value={postToProfile}
                                                onValueChange={setPostToProfile}
                                                trackColor={{ false: colors.borderStrong, true: colors.success }}
                                                thumbColor={'#fff'}
                                                ios_backgroundColor={colors.input}
                                            />
                                        </View>
                                    </View>

                                    <Text style={[styles.helperText, { color: colors.textSecondary }]}>
                                        Keep this story on your profile even after it expires in {duration} hours. Privacy settings will apply.
                                    </Text>

                                    <View style={{ height: 120 }} />
                                </Animated.ScrollView>
                            ) : (
                                <Animated.View
                                    entering={SlideInRight}
                                    exiting={SlideOutRight}
                                    style={{ flex: 1 }}
                                >
                                    {/* Search Bar Placeholder */}
                                    <View style={{ paddingHorizontal: 20, marginBottom: 16 }}>
                                        <View style={[styles.searchBar, { backgroundColor: cardColor }]}>
                                            <Search size={18} color={colors.textSecondary} style={{ marginRight: 8 }} />
                                            <Text style={{ color: colors.textSecondary }}>Search</Text>
                                        </View>
                                    </View>

                                    {/* User List */}
                                    <ScrollView contentContainerStyle={{ paddingHorizontal: 20, paddingBottom: 100 }}>
                                        {displayContacts.map((contact, index) => {
                                            const isSelected = isUserSelected(contact.id)
                                            return (
                                                <TouchableOpacity
                                                    key={contact.id}
                                                    style={styles.userRow}
                                                    onPress={() => toggleUserSelection(contact.id)}
                                                    activeOpacity={0.7}
                                                >
                                                    <View style={[styles.avatar, { backgroundColor: colors.border }]}>
                                                        {contact.profileImage ? (
                                                            <Image source={{ uri: contact.profileImage }} style={{ width: '100%', height: '100%' }} />
                                                        ) : (
                                                            <User size={20} color={colors.textSecondary} />
                                                        )}
                                                    </View>
                                                    <Text style={[styles.userName, { color: colors.text }]}>{contact.username}</Text>

                                                    <View style={[
                                                        styles.checkbox,
                                                        {
                                                            borderColor: isSelected ? (selectionType === 'exclude' ? colors.danger : colors.primary) : colors.border,
                                                            backgroundColor: isSelected ? (selectionType === 'exclude' ? colors.danger : colors.primary) : 'transparent'
                                                        }
                                                    ]}>
                                                        {isSelected && <Check size={14} color="#fff" strokeWidth={3} />}
                                                    </View>
                                                </TouchableOpacity>
                                            )
                                        })}
                                    </ScrollView>
                                </Animated.View>
                            )}
                        </View>

                        {/* Footer Button - Changes based on view */}
                        <View style={[styles.footer, { backgroundColor: bgColor, borderTopColor: colors.borderSubtle }]}>
                            {view === 'main' ? (
                                <View style={{ flexDirection: 'row', gap: 12 }}>
                                    <TouchableOpacity
                                        style={[styles.postButton, { flex: 1, backgroundColor: colors.input, shadowOpacity: 0 }]}
                                        onPress={handleSaveDraft}
                                        activeOpacity={0.8}
                                    >
                                        <Text style={[styles.postButtonText, { color: colors.text }]}>Save Draft</Text>
                                    </TouchableOpacity>

                                    <TouchableOpacity
                                        style={[styles.postButton, { flex: 1, backgroundColor: colors.button }]}
                                        onPress={handlePost}
                                        activeOpacity={0.8}
                                    >
                                        <Text style={[styles.postButtonText, { color: colors.buttonText }]}>Post Story</Text>
                                    </TouchableOpacity>
                                </View>
                            ) : (
                                <TouchableOpacity
                                    style={[styles.postButton, { backgroundColor: colors.button }]}
                                    onPress={() => setView('main')}
                                    activeOpacity={0.8}
                                >
                                    <Text style={[styles.postButtonText, { color: colors.buttonText }]}>Done</Text>
                                </TouchableOpacity>
                            )}
                        </View>

                    </AnimatedView>
                </GestureDetector>
            </View>
        </GestureHandlerRootViewAny>
    )
}

const styles = StyleSheet.create({
    overlay: { ...StyleSheet.absoluteFillObject },
    modalContainer: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        height: MODAL_HEIGHT,
        overflow: 'hidden',
        borderTopLeftRadius: 24,
        borderTopRightRadius: 24
    },
    dragHandleArea: {
        width: '100%',
        height: 24,
        alignItems: 'center',
        justifyContent: 'center',
    },
    dragHandle: {
        width: 36,
        height: 5,
        backgroundColor: 'rgba(120,120,120,0.5)',
        borderRadius: 2.5
    },
    header: {
        flexDirection: 'row',
        paddingHorizontal: 20,
        height: 44,
        alignItems: 'center',
        justifyContent: 'space-between',
        marginBottom: 10
    },
    headerTitle: { fontSize: 17, fontWeight: '600' },
    backButton: { width: 40, height: 40, justifyContent: 'center' },

    scrollViewContainer: {
        flex: 1,
    },
    scrollView: { flex: 1 },
    scrollContent: { paddingHorizontal: 20, paddingBottom: 40 },

    sectionLabel: {
        fontSize: 12,
        fontWeight: '500',
        marginBottom: 8,
        marginLeft: 16,
        textTransform: 'uppercase',
        opacity: 0.6
    },
    sectionContainer: {
        borderRadius: 14,
        overflow: 'hidden'
    },

    // Option Rows
    optionRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 12,
        paddingHorizontal: 16,
    },
    radioContainer: {
        width: 24,
        height: 24,
        borderRadius: 12,
        borderWidth: 1.5,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 16
    },

    iconContainer: {
        width: 36,
        height: 36,
        borderRadius: 18,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 12
    },
    optionTextContainer: {
        flex: 1,
        gap: 2
    },
    optionLabel: {
        fontSize: 16,
        fontWeight: '500'
    },
    optionSubAction: {
        fontSize: 13,
        fontWeight: '400',
        marginRight: 2
    },

    divider: {
        height: 0.5,
        marginLeft: 68 // Align with icon start + padding
    },

    helperText: {
        fontSize: 12,
        marginTop: 8,
        marginLeft: 16,
        marginRight: 16,
        lineHeight: 16
    },

    // Toggles
    toggleRow: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingVertical: 12,
        paddingHorizontal: 16
    },
    toggleLabel: {
        fontSize: 16,
        fontWeight: '400'
    },

    // User Selection
    searchBar: {
        flexDirection: 'row',
        alignItems: 'center',
        height: 44,
        borderRadius: 12,
        paddingHorizontal: 12,
    },
    userRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 12,
        borderBottomWidth: 0.5,
        borderBottomColor: 'rgba(150,150,150,0.1)'
    },
    avatar: {
        width: 40,
        height: 40,
        borderRadius: 20,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 12,
        overflow: 'hidden'
    },
    userName: {
        fontSize: 16,
        flex: 1
    },
    checkbox: {
        width: 24,
        height: 24,
        borderRadius: 12,
        borderWidth: 2,
        alignItems: 'center',
        justifyContent: 'center'
    },

    // Footer
    footer: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        paddingHorizontal: 20,
        paddingTop: 16,
        paddingBottom: 40, // Safe area approximation
        borderTopWidth: 0.5,
    },
    postButton: {
        height: 50,
        borderRadius: 25,
        alignItems: 'center',
        justifyContent: 'center',
        shadowColor: "#000",
        shadowOffset: {
            width: 0,
            height: 4,
        },
        shadowOpacity: 0.2,
        shadowRadius: 4.65,
        elevation: 8,
    },
    postButtonText: {
        color: '#fff',
        fontSize: 17,
        fontWeight: '600'
    }
})
