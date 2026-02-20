import React, { useEffect, useState, useRef, useCallback } from 'react'
import {
    View,
    Text,
    StyleSheet,
    Modal,
    Image,
    TouchableOpacity,
    Dimensions,
    Pressable,
    StatusBar
} from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    Easing,
    FadeIn,
    FadeOut
} from 'react-native-reanimated'
import { LinearGradient } from 'expo-linear-gradient'
import * as Haptics from 'expo-haptics'
import {
    X,
    ChevronLeft,
    ChevronRight,
    Eye,
    Play,
    MoreVertical,
    Trash2
} from 'lucide-react-native'

import { theme } from '../../lib/theme'
import { useAuthStore } from '../../lib/stores/auth-store'
import { useStoryStore, Story, StoryGroup } from '../../lib/stores/story-store'
import SafeLiquidGlass from '../native/SafeLiquidGlass'

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window')
const STORY_DURATION = 5000 // 5 seconds per story

const colors = theme.dark;

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

interface StoryViewerProps {
    visible: boolean
    initialUserId?: string
    initialStoryIndex?: number
    onClose: () => void
}

export default function StoryViewer({
    visible,
    initialUserId,
    initialStoryIndex = 0,
    onClose
}: StoryViewerProps) {
    const { user } = useAuthStore()
    const {
        feed,
        myStories,
        markStoryViewed,
        deleteStory,
        currentViewingUserId,
        currentStoryIndex,
        setCurrentViewing,
        clearViewing
    } = useStoryStore()

    // Timer state
    const [isPaused, setIsPaused] = useState(false)
    const [showMenu, setShowMenu] = useState(false)
    const progress = useSharedValue(0)
    const timerRef = useRef<NodeJS.Timeout | null>(null)

    // Get current story group and story
    const isViewingOwnStories = currentViewingUserId === user?.userId
    const currentGroup = isViewingOwnStories
        ? { user_id: user?.userId, username: user?.username, profile_image: user?.profileImage, stories: myStories }
        : feed.find(g => g.user_id === currentViewingUserId)

    const currentStory = currentGroup?.stories[currentStoryIndex]

    // Initialize viewing state
    useEffect(() => {
        if (visible && initialUserId) {
            setCurrentViewing(initialUserId, initialStoryIndex)
        }
    }, [visible, initialUserId, initialStoryIndex])

    // Progress timer
    useEffect(() => {
        if (!visible || !currentStory || isPaused) return

        progress.value = 0

        // Animate progress bar
        progress.value = withTiming(1, {
            duration: currentStory.duration * 1000 || STORY_DURATION,
            easing: Easing.linear
        })

        // Auto-advance timer
        timerRef.current = setTimeout(() => {
            handleNextStory()
        }, currentStory.duration * 1000 || STORY_DURATION)

        return () => {
            if (timerRef.current) {
                clearTimeout(timerRef.current)
            }
        }
    }, [visible, currentStory?.id, isPaused])

    // Mark story as viewed
    useEffect(() => {
        if (visible && currentStory && user?.userId && !isViewingOwnStories) {
            markStoryViewed(currentStory.id, user.userId)
        }
    }, [currentStory?.id])

    const handleNextStory = useCallback(() => {
        Haptics.selectionAsync()

        if (currentGroup && currentStoryIndex < currentGroup.stories.length - 1) {
            // Next story in current user's stories
            setCurrentViewing(currentViewingUserId!, currentStoryIndex + 1)
        } else if (!isViewingOwnStories) {
            // Move to next user's stories
            const currentIdx = feed.findIndex(g => g.user_id === currentViewingUserId)
            if (currentIdx < feed.length - 1) {
                setCurrentViewing(feed[currentIdx + 1].user_id, 0)
            } else {
                handleClose()
            }
        } else {
            handleClose()
        }
    }, [currentGroup, currentStoryIndex, currentViewingUserId, feed, isViewingOwnStories])

    const handlePrevStory = useCallback(() => {
        Haptics.selectionAsync()

        if (currentStoryIndex > 0) {
            setCurrentViewing(currentViewingUserId!, currentStoryIndex - 1)
        } else if (!isViewingOwnStories) {
            // Move to previous user's stories
            const currentIdx = feed.findIndex(g => g.user_id === currentViewingUserId)
            if (currentIdx > 0) {
                const prevGroup = feed[currentIdx - 1]
                setCurrentViewing(prevGroup.user_id, prevGroup.stories.length - 1)
            }
        }
    }, [currentStoryIndex, currentViewingUserId, feed, isViewingOwnStories])

    const handleClose = useCallback(() => {
        clearViewing()
        onClose()
    }, [clearViewing, onClose])

    const handleDelete = async () => {
        if (!currentStory || !user?.userId) return

        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy)
        const success = await deleteStory(currentStory.id, user.userId)

        if (success) {
            if (myStories.length <= 1) {
                handleClose()
            } else {
                handleNextStory()
            }
        }
        setShowMenu(false)
    }

    const togglePause = () => {
        Haptics.selectionAsync()
        setIsPaused(!isPaused)
    }

    // Tap zones for navigation
    const handleTap = (event: any) => {
        const { locationX } = event.nativeEvent
        if (locationX < SCREEN_WIDTH / 3) {
            handlePrevStory()
        } else if (locationX > (SCREEN_WIDTH * 2) / 3) {
            handleNextStory()
        } else {
            togglePause()
        }
    }

    // Progress bar style
    const progressStyle = useAnimatedStyle(() => ({
        width: `${progress.value * 100}%`
    }))

    // Time ago helper
    const timeAgo = (dateStr: string) => {
        const diff = Date.now() - new Date(dateStr).getTime()
        const hours = Math.floor(diff / (1000 * 60 * 60))
        if (hours < 1) return 'Just now'
        if (hours < 24) return `${hours}h ago`
        return 'Yesterday'
    }

    if (!currentStory || !visible) return null

    return (
        <Modal
            visible={visible}
            animationType="fade"
            presentationStyle="fullScreen"
            onRequestClose={handleClose}
        >
            <StatusBar hidden />
            <View style={styles.container}>
                {/* Story Image */}
                <Image
                    source={{ uri: currentStory.media_url }}
                    style={styles.storyImage}
                    resizeMode="cover"
                />

                {/* Gradient overlays */}
                <LinearGradient
                    colors={['rgba(0,0,0,0.6)', 'transparent'] as const}
                    style={styles.topGradient}
                />
                <LinearGradient
                    colors={['transparent', 'rgba(0,0,0,0.4)'] as const}
                    style={styles.bottomGradient}
                />

                {/* Tap zones */}
                <Pressable
                    style={StyleSheet.absoluteFill}
                    onPress={handleTap}
                />

                {/* Progress bars */}
                <View style={styles.progressContainer}>
                    {currentGroup?.stories.map((story, index) => (
                        <View key={story.id} style={styles.progressBarBg}>
                            {index < currentStoryIndex ? (
                                <View style={[styles.progressBarFill, { width: '100%' }]} />
                            ) : index === currentStoryIndex ? (
                                <Animated.View style={[styles.progressBarFill, progressStyle]} />
                            ) : null}
                        </View>
                    ))}
                </View>

                {/* Header */}
                <View style={styles.header}>
                    <View style={styles.userInfo}>
                        <View style={styles.avatarContainer}>
                            {currentGroup?.profile_image ? (
                                <Image
                                    source={{ uri: currentGroup.profile_image }}
                                    style={styles.avatar}
                                />
                            ) : (
                                <View style={[styles.avatar, styles.avatarPlaceholder]}>
                                    <Text style={styles.avatarText}>
                                        {(currentGroup?.username || 'U')[0].toUpperCase()}
                                    </Text>
                                </View>
                            )}
                        </View>
                        <View>
                            <Text style={styles.username}>
                                {isViewingOwnStories ? 'Your Story' : currentGroup?.username || 'Unknown'}
                            </Text>
                            <Text style={styles.timestamp}>
                                {timeAgo(currentStory.created_at)}
                            </Text>
                        </View>
                    </View>

                    <View style={styles.headerActions}>
                        {isPaused && (
                            <Animated.View entering={FadeIn} exiting={FadeOut}>
                                <Play size={20} color="#fff" style={{ marginRight: 12 }} />
                            </Animated.View>
                        )}

                        {isViewingOwnStories && (
                            <TouchableOpacity
                                onPress={() => setShowMenu(!showMenu)}
                                style={styles.iconButton}
                            >
                                <MoreVertical size={22} color="#fff" />
                            </TouchableOpacity>
                        )}

                        <TouchableOpacity
                            onPress={handleClose}
                            style={styles.iconButton}
                        >
                            <X size={24} color="#fff" />
                        </TouchableOpacity>
                    </View>
                </View>

                {/* View count for own stories */}
                {isViewingOwnStories && (
                    <View style={styles.viewCountContainer}>
                        <SafeLiquidGlass
                            style={styles.glassBaseRound}
                            blurIntensity={20}
                            tint="dark"
                        >
                            <View style={styles.viewCountContent}>
                                <Eye size={16} color="#fff" />
                                <Text style={styles.viewCountText}>
                                    {currentStory.view_count || 0} views
                                </Text>
                            </View>
                        </SafeLiquidGlass>
                    </View>
                )}

                {/* Caption */}
                {currentStory.caption && (
                    <View style={styles.captionContainer}>
                        <Text style={styles.captionText}>
                            {currentStory.caption}
                        </Text>
                    </View>
                )}

                {/* Navigation hints */}
                <View style={styles.navHints} pointerEvents="none">
                    {currentStoryIndex > 0 && (
                        <View style={styles.navHintLeft}>
                            <ChevronLeft size={32} color="rgba(255,255,255,0.3)" />
                        </View>
                    )}
                    {currentGroup && currentStoryIndex < currentGroup.stories.length - 1 && (
                        <View style={styles.navHintRight}>
                            <ChevronRight size={32} color="rgba(255,255,255,0.3)" />
                        </View>
                    )}
                </View>

                {/* Menu for own stories */}
                {showMenu && isViewingOwnStories && (
                    <Animated.View
                        entering={FadeIn}
                        exiting={FadeOut}
                        style={styles.menuOverlay}
                    >
                        <Pressable
                            style={StyleSheet.absoluteFill}
                            onPress={() => setShowMenu(false)}
                        />
                        <SafeLiquidGlass
                            style={styles.glassBaseMenu}
                            blurIntensity={40}
                            tint="dark"
                        >
                            <View style={styles.menuContainer}>
                                <TouchableOpacity
                                    onPress={handleDelete}
                                    style={styles.menuItem}
                                >
                                    <View style={[styles.menuIconContainer, { backgroundColor: withAlpha(colors.status.error, 0.1) }]}>
                                        <Trash2 size={18} color={colors.status.error} strokeWidth={2.5} />
                                    </View>
                                    <Text style={[styles.menuItemText, { color: colors.status.error }]}>
                                        Delete Story
                                    </Text>
                                </TouchableOpacity>
                            </View>
                        </SafeLiquidGlass>
                    </Animated.View>
                )}
            </View>
        </Modal>
    )
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: '#000',
    },
    storyImage: {
        ...StyleSheet.absoluteFillObject,
        width: SCREEN_WIDTH,
        height: SCREEN_HEIGHT,
    },
    topGradient: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        height: 200,
    },
    bottomGradient: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        height: 150,
    },
    progressContainer: {
        position: 'absolute',
        top: 50,
        left: 12,
        right: 12,
        flexDirection: 'row',
        gap: 4,
    },
    progressBarBg: {
        flex: 1,
        height: 3,
        backgroundColor: 'rgba(255,255,255,0.3)',
        borderRadius: 1.5,
        overflow: 'hidden',
    },
    progressBarFill: {
        height: '100%',
        backgroundColor: '#fff',
        borderRadius: 1.5,
    },
    header: {
        position: 'absolute',
        top: 65,
        left: 12,
        right: 12,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
    },
    userInfo: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    avatarContainer: {
        marginRight: 10,
    },
    avatar: {
        width: 36,
        height: 36,
        borderRadius: 18,
        borderWidth: 2,
        borderColor: '#fff',
    },
    avatarPlaceholder: {
        backgroundColor: 'rgba(255,255,255,0.2)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    avatarText: {
        color: '#fff',
        fontSize: 14,
        fontWeight: '700',
    },
    username: {
        color: '#fff',
        fontSize: 14,
        fontWeight: '700',
    },
    timestamp: {
        color: 'rgba(255,255,255,0.7)',
        fontSize: 12,
    },
    headerActions: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    iconButton: {
        padding: 8,
    },
    viewCountContainer: {
        position: 'absolute',
        bottom: 100,
        alignSelf: 'center',
    },
    glassBaseRound: {
        borderRadius: 20,
        overflow: 'hidden',
    },
    viewCountContent: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 16,
        paddingVertical: 10,
        gap: 8,
    },
    viewCountText: {
        color: '#fff',
        fontSize: 14,
        fontWeight: '500',
    },
    captionContainer: {
        position: 'absolute',
        bottom: 50,
        left: 20,
        right: 20,
    },
    captionText: {
        color: '#fff',
        fontSize: 16,
        textAlign: 'center',
        textShadowColor: 'rgba(0,0,0,0.5)',
        textShadowOffset: { width: 0, height: 1 },
        textShadowRadius: 3,
    },
    navHints: {
        ...StyleSheet.absoluteFillObject,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 8,
    },
    navHintLeft: {},
    navHintRight: {},
    menuOverlay: {
        ...StyleSheet.absoluteFillObject,
        justifyContent: 'center',
        alignItems: 'center',
        backgroundColor: 'rgba(0,0,0,0.5)',
    },
    glassBaseMenu: {
        borderRadius: 16,
        overflow: 'hidden',
    },
    menuContainer: {
        width: 240,
    },
    menuItem: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 14,
        paddingHorizontal: 16,
        gap: 12,
    },
    menuIconContainer: {
        width: 32,
        height: 32,
        borderRadius: 8,
        alignItems: 'center',
        justifyContent: 'center',
    },
    menuItemText: {
        fontSize: 16,
        fontWeight: '400',
    },
});
