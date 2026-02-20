/**
 * StoryBar - Horizontal scrollable story avatars
 * Features:
 * - Own story at first position with add button
 * - Stories from contacts/friends
 * - Unseen stories first, then seen
 * - Pull to refresh
 */

import React, { useEffect } from 'react'
import {
    View,
    StyleSheet,
    ScrollView,
} from 'react-native'

import { useThemeStore } from '../../lib/stores/theme-store'
import { useAuthStore } from '../../lib/stores/auth-store'
import { useStoryStore } from '../../lib/stores/story-store'
import StoryAvatar from './StoryAvatar'

interface StoryBarProps {
    onStoryPress?: (userId: string) => void
    onAddStoryPress?: () => void
    onViewerOpen?: (userId: string, index: number) => void
    compact?: boolean
    size?: 'small' | 'medium' | 'large'
    scrollY?: any
    isMoving?: boolean
    isCompact?: any
}

function StoryBarItem({
    index,
    compact,
    overlapLimit = 4,
    overlapOffset = 18,
    children
}: {
    index: number
    compact: boolean
    overlapLimit?: number
    overlapOffset?: number
    children: React.ReactNode
}) {
    const baseMargin = 4
    const compactMargin = 2
    const shouldOverlap = compact && index > 0 && index < overlapLimit

    const style = {
        marginLeft: index === 0
            ? (compact ? 0 : baseMargin)
            : (shouldOverlap ? -overlapOffset : (compact ? compactMargin : baseMargin)),
        marginRight: compact ? compactMargin : baseMargin
    } as const

    return <View style={[styles.storyItem, style]}>{children}</View>
}

export default function StoryBar({
    onStoryPress,
    onAddStoryPress,
    onViewerOpen,
    compact = false,
    size = 'medium',
    scrollY,
    isMoving = false,
    isCompact,
}: StoryBarProps) {
    const { colors } = useThemeStore()
    const { user } = useAuthStore()
    const { feed, myStories, loadFeed, loadMyStories } = useStoryStore()

    // Load stories on mount
    useEffect(() => {
        if (user?.userId) {

            loadFeed(user.userId)
            loadMyStories(user.userId)
        }
    }, [user?.userId])

    // Handle story press
    const handleStoryPress = (userId: string) => {
        if (onViewerOpen) {
            onViewerOpen(userId, 0)
        }
        if (onStoryPress) {
            onStoryPress(userId)
        }
    }

    // Handle add story
    const handleAddPress = () => {
        if (onAddStoryPress) {
            onAddStoryPress()
        }
    }

    // Sort feed: unseen first
    const sortedFeed = [...feed].sort((a, b) => {
        if (a.has_unseen && !b.has_unseen) return -1
        if (!a.has_unseen && b.has_unseen) return 1
        return 0
    })

    const hasOwnStories = myStories.length > 0



    return (
        <ScrollView
            horizontal
            showsHorizontalScrollIndicator={false}
            style={{ height: 100 }}
            contentContainerStyle={[styles.scrollContent, { height: 100 }]}
            scrollEnabled={!isMoving}
        >
            {/* Own Story Avatar */}
            <StoryBarItem compact={compact} index={0}>
                <StoryAvatar
                    userId={user?.userId || ''}
                    username="Your Story"
                    profileImage={user?.profileImage}
                    hasStory={hasOwnStories}
                    hasUnseenStory={hasOwnStories}
                    storyCount={myStories.length}
                    size={size}
                    showName={!compact}
                    showAddButton={!hasOwnStories && !compact}
                    isOwnAvatar
                    onPress={() => handleStoryPress(user?.userId || '')}
                    onAddPress={handleAddPress}
                />
            </StoryBarItem>

            {/* Separator Removed */}

            {/* Other users' stories */}
            {sortedFeed.map((group, index) => (
                <StoryBarItem key={group.user_id} compact={compact} index={index + 1}>
                    <StoryAvatar
                        userId={group.user_id}
                        username={group.username}
                        profileImage={group.profile_image}
                        hasStory
                        hasUnseenStory={group.has_unseen}
                        storyCount={group.stories.length}
                        size={size}
                        showName={!compact}
                        onPress={() => handleStoryPress(group.user_id)}
                    />
                </StoryBarItem>
            ))}

            {/* Empty state */}
            {sortedFeed.length === 0 && !hasOwnStories && (
                <View style={styles.emptyState}>

                </View>
            )}
        </ScrollView>
    )
}

const styles = StyleSheet.create({
    container: {
        // Naked container
    },
    scrollContent: {
        paddingHorizontal: 0,
        alignItems: 'flex-start',
    },
    storyItem: {
        marginHorizontal: 4,
    },
    separator: {
        width: 1,
        height: 0,
        marginHorizontal: 8,
        alignSelf: 'center',
        opacity: 0.3,
    },
    emptyState: {
        paddingHorizontal: 20,
        justifyContent: 'center',
    },
    emptyText: {
        fontSize: 13,
    },
})
