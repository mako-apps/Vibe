import React from 'react'
import { View, Text, StyleSheet, FlatList, TouchableOpacity, Image, Alert } from 'react-native'
import { router } from 'expo-router'
import { useThemeStore } from '../src/lib/stores/theme-store'
import { useStoryStore, StoryDraft } from '../src/lib/stores/story-store'
import { ChevronLeft, Trash2, ArrowRight } from 'lucide-react-native'
import Animated, { FadeInUp, FadeInRight } from 'react-native-reanimated'
import * as Haptics from 'expo-haptics'
import AnimatedGlassButton from '../src/components/native/AnimatedGlassButton'

const AnimatedFlatList = Animated.createAnimatedComponent(FlatList as any)

export default function StoryDraftsScreen() {
    const { colors, effectiveTheme } = useThemeStore()
    const { drafts, deleteDraft } = useStoryStore()
    const isLight = effectiveTheme === 'light'

    const handleSelectDraft = (draft: StoryDraft) => {
        // TODO: Pass draft data back to Story Creator
        // For now, just navigate back (assuming logic in StoryCamera handles it via params or store)
        // Since StoryCamera uses state, passing via route params might be best
        // But StoryCamera is complex.
        // Let's implement basic "Select" to just show an alert or log for now, 
        // as full restoration requires StoryPreview refactor.
        // Actually, let's navigate to story-camera with params
        router.push({
            pathname: '/story-camera',
            params: {
                draftUri: draft.mediaUri,
                draftType: draft.mediaType
            }
        })
    }

    const handleDelete = (id: string) => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)
        Alert.alert(
            "Delete Draft?",
            "This cannot be undone.",
            [
                { text: "Cancel", style: "cancel" },
                {
                    text: "Delete",
                    style: "destructive",
                    onPress: () => deleteDraft(id)
                }
            ]
        )
    }

    const renderItem = ({ item, index }: { item: StoryDraft, index: number }) => {
        return (
            <Animated.View
                entering={FadeInUp.delay(index * 50)}
                style={[styles.draftItem, { backgroundColor: colors.card }]}
            >
                <TouchableOpacity
                    style={styles.draftContent}
                    onPress={() => handleSelectDraft(item)}
                    activeOpacity={0.7}
                >
                    <View style={styles.imageContainer}>
                        {item.mediaType === 'video' ? (
                            // Placeholder for video thumb (using same URI often works if format supported, or just icon)
                            <View style={[styles.videoPlaceholder, { backgroundColor: colors.backgroundSecondary }]}>
                                <Text style={{ fontSize: 24 }}>🎥</Text>
                            </View>
                        ) : (
                            <Image source={{ uri: item.mediaUri }} style={styles.thumbnail} />
                        )}
                    </View>

                    <View style={styles.infoContainer}>
                        <Text style={[styles.dateText, { color: colors.textSecondary }]}>
                            {new Date(item.createdAt).toLocaleDateString()} • {new Date(item.createdAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                        </Text>
                        <Text style={[styles.typeText, { color: colors.text }]}>
                            {item.mediaType === 'video' ? 'Video Story' : 'Photo Story'}
                        </Text>
                    </View>

                    <View style={styles.arrowContainer}>
                        <ArrowRight size={20} color={colors.textSecondary} />
                    </View>
                </TouchableOpacity>

                <TouchableOpacity
                    style={styles.deleteButton}
                    onPress={() => handleDelete(item.id)}
                >
                    <Trash2 size={20} color={colors.danger} />
                </TouchableOpacity>
            </Animated.View>
        )
    }

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            {/* Header */}
            <View style={styles.header}>
                <AnimatedGlassButton
                    onPress={() => router.back()}
                    homeIcon={<ChevronLeft size={24} color={colors.text} />}
                    showPanelIcon={false}
                    effectiveTheme={effectiveTheme}
                    size={40}
                    homeBackgroundColor={colors.input}
                />
                <Text style={[styles.title, { color: colors.text }]}>Drafts</Text>
                <View style={{ width: 40 }} />
            </View>

            {drafts.length === 0 ? (
                <View style={[styles.emptyState, { opacity: 0.6 }]}>
                    <Text style={{ fontSize: 40, marginBottom: 16 }}>📝</Text>
                    <Text style={[styles.emptyText, { color: colors.textSecondary }]}>No drafts yet</Text>
                </View>
            ) : (
                <FlatList
                    data={drafts}
                    renderItem={renderItem}
                    keyExtractor={(item: any) => item.id}
                    contentContainerStyle={{ padding: 20, paddingTop: 10 }}
                    showsVerticalScrollIndicator={false}
                />
            )}
        </View>
    )
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        paddingTop: 60,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 20,
        marginBottom: 20,
    },
    title: {
        fontSize: 18,
        fontWeight: '600',
    },
    draftItem: {
        flexDirection: 'row',
        alignItems: 'center',
        marginBottom: 12,
        borderRadius: 16,
        overflow: 'hidden',
        paddingRight: 16, // Space for delete
    },
    draftContent: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        padding: 12,
    },
    imageContainer: {
        width: 60,
        height: 60,
        borderRadius: 12,
        overflow: 'hidden',
        marginRight: 12,
    },
    thumbnail: {
        width: '100%',
        height: '100%',
        resizeMode: 'cover',
    },
    videoPlaceholder: {
        width: '100%',
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
    },
    infoContainer: {
        flex: 1,
        justifyContent: 'center',
    },
    dateText: {
        fontSize: 12,
        marginBottom: 4,
    },
    typeText: {
        fontSize: 16,
        fontWeight: '500',
    },
    arrowContainer: {
        marginLeft: 8,
    },
    deleteButton: {
        padding: 12,
    },
    emptyState: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        paddingBottom: 100
    },
    emptyText: {
        fontSize: 16,
        fontWeight: '500'
    }
})
