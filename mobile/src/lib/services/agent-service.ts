import { getAuthHeaders, getAuthHeadersAsync, API_BASE } from '../config'
// Use the built-in global fetch if Expo's is not available or if using a polyfill.
// React Native has fetch available globally.

export interface AgentRecord {
    id: string
    type: 'event' | 'social' | 'voice' | 'task' | 'finance' | 'content'
    title: string
    description: string
    time?: string
    date?: string
    status?: string
    icon?: string
    metadata?: any
}

export interface InitialRecordsResponse {
    greeting: string
    userName: string
    records: AgentRecord[]
    suggestions?: string[]
}

export interface StreamChunk {
    text: string
    done: boolean
    conversationId?: string
    suggestions?: string[]
    voice_chunk?: boolean
}

export interface ActionEvent {
    type: 'tool_execution' | 'thinking' | 'tool_result' | 'tool_complete' | 'media_generated'
    tool?: string
    tool_name?: string
    status?: 'running' | 'completed' | 'failed' | 'retrying' | 'fallback'
    stage?: string
    content?: string
    message?: string
    result?: any
    defer_render?: boolean
    data?: {
        description: string
        result?: any
        error?: string
        url?: string
        type?: 'image' | 'video'
        prompt?: string
        originalPrompt?: string
        id?: string
    }
    attempt?: number
    startedAt?: string
    finishedAt?: string
}

export interface AgentCapability {
    id: string
    name: string
    description: string
    icon: string
    available: boolean
}

export interface Tool {
    id: string
    name: string
    description: string
    icon: string
    requiresModel?: string[]
    category: 'media' | 'document' | 'data' | 'communication'
    model?: string
    type?: 'image' | 'video' | 'text'
}

export interface ModelCapabilities {
    supportsThinking: boolean
    supportsImages: boolean
    supportsVideo: boolean
    supportsAudio: boolean
    availableTools: string[]
}

class AgentService {
    private baseUrl: string
    private currentAbortController: AbortController | null = null

    constructor() {
        this.baseUrl = API_BASE
    }

    /**
     * Fetch initial records when app launches
     * Returns personalized greeting + latest records from all agents
     */
    async fetchInitialRecords(userId?: string): Promise<InitialRecordsResponse> {
        try {
            const response = await fetch(`${this.baseUrl}/api/orchestrator/initial-records`, {
                method: 'GET',
                headers: await getAuthHeadersAsync(),
            })

            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`)
            }

            const data = await response.json() as InitialRecordsResponse

            return {
                greeting: data.greeting || '',
                userName: data.userName || '',
                records: data.records || [],
                suggestions: data.suggestions || [],
            }
        } catch (error) {
            console.error('Failed to fetch initial records:', error)

            // Return fallback data - no mock data
            return {
                greeting: '',
                userName: '',
                records: [],
                suggestions: [],
            }
        }
    }

    /**
     * Send message to agent and receive streaming response with action events
     * Uses Expo's native fetch with ReadableStream for reliable SSE streaming
     */
    async streamChatResponse(
        message: string,
        onChunk: (chunk: StreamChunk) => void,
        onError?: (error: Error) => void,
        onAction?: (action: ActionEvent) => void,
        onInline?: (type: 'task' | 'event' | 'automation' | 'button' | 'flight', data: any) => void,
        onCategory?: (category: string) => void,
        onStatus?: (status: string, message: string) => void,
        onProgress?: (data: any) => void,
        conversationId?: string,
        compact: boolean = true,
        attachments?: Array<{ type: string; url: string; filename: string }>,
        intent?: string,
        context?: any,
        onSources?: (sources: any[]) => void,
        onMedia?: (media: any[]) => void,      // ⚡ Research/Web agent media (images + videos)
        onProducts?: (products: any[]) => void, // ⚡ Shopping agent products
        onCard?: (cardType: 'flight' | 'hotel' | 'booking' | 'product_carousel' | 'product_detail', data: any) => void, // ⚡ Travel agent cards
        userMessageTimestamp?: string  // ⚡ For correct message ordering
    ): Promise<void> {
        const controller = new AbortController()
        this.currentAbortController = controller

        try {
            // NOTE: Using native fetch for streaming might require specific react-native polyfills or Expo's fetch
            // For now we assume fetch supports ReadableStream or text processing as in original file

            const response = await fetch(`${this.baseUrl}/api/orchestrator/chat/stream`, {
                method: 'POST',
                headers: {
                    ...(await getAuthHeadersAsync()),
                    'Content-Type': 'application/json',
                    'Accept': 'text/event-stream',
                },
                body: JSON.stringify({
                    message,
                    platform: 'mobile',
                    conversationId,
                    attachments: attachments || [],
                    intent,
                    context,
                    userMessageTimestamp  // ⚡ For correct message ordering
                }),
                signal: controller.signal
            })

            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`)
            }

            // Handle response body reading... simplified for cross-compatibility
            // If environment supports reader:
            // @ts-ignore
            const reader = response.body?.getReader ? response.body.getReader() : null

            if (reader) {
                const decoder = new TextDecoder()
                let buffer = ''

                while (true) {
                    const { done, value } = await reader.read()
                    if (done) break
                    buffer += decoder.decode(value, { stream: true })
                    const { events, remaining } = this.parseSSEBuffer(buffer)

                    for (const event of events) {
                        this.processSSEEvent(event.type, event.data, onChunk, onAction, onInline, onCategory, onStatus, onProgress, onSources, onMedia, onProducts, onCard)
                    }
                    buffer = remaining
                }
                if (buffer.trim()) {
                    const { events } = this.parseSSEBuffer(buffer + '\n\n')
                    for (const event of events) {
                        this.processSSEEvent(event.type, event.data, onChunk, onAction, onInline, onCategory, onStatus, onProgress, onSources, onMedia, onProducts, onCard)
                    }
                }
            } else {
                // Fallback for environments without stream reader support (Node/some RN debuggers)
                // But user requested "no mock", so we assume streaming infrastructure exists or this code
                // is running in an environment that bridges fetch correctly.
                const text = await response.text()
                const { events } = this.parseSSEBuffer(text)
                for (const event of events) {
                    this.processSSEEvent(event.type, event.data, onChunk, onAction, onInline, onCategory, onStatus, onProgress, onSources, onMedia, onProducts, onCard)
                }
            }

        } catch (error) {
            if (error instanceof Error) {
                const isAborted = error.name === 'AbortError' ||
                    error.message?.includes('cancelled') ||
                    error.message?.includes('canceled') ||
                    error.message?.includes('FetchRequestCanceledException') ||
                    error.message?.includes('aborted')
                if (isAborted) {
                    console.log('[AgentService] Stream cancelled by user')
                    return
                }
            }

            console.error('Streaming error:', error)
            if (onError) {
                onError(error as Error)
            }
        } finally {
            this.currentAbortController = null
        }
    }

    private parseSSEBuffer(buffer: string): { events: Array<{ type: string; data: any }>, remaining: string } {
        const events: Array<{ type: string; data: any }> = []
        const lastNewlineIndex = buffer.lastIndexOf('\n')
        if (lastNewlineIndex === -1) return { events, remaining: buffer }

        const completePart = buffer.slice(0, lastNewlineIndex)
        const remainingPart = buffer.slice(lastNewlineIndex + 1)

        const lines = completePart.split('\n')
        let currentEvent: { type?: string; data?: string } = {}

        for (const line of lines) {
            if (line.trim() === '') {
                if (currentEvent.type && currentEvent.data) {
                    try {
                        events.push({ type: currentEvent.type, data: JSON.parse(currentEvent.data) })
                        currentEvent = {}
                    } catch (e) {
                        currentEvent = {}
                    }
                }
                continue
            }

            if (line.startsWith('event:')) {
                currentEvent.type = line.slice(6).trim()
            } else if (line.startsWith('data:')) {
                const dataLine = line.slice(5).trim()
                currentEvent.data = currentEvent.data ? currentEvent.data + dataLine : dataLine
            }
        }

        let reconstructed = ''
        if (currentEvent.type || currentEvent.data) {
            if (currentEvent.type) reconstructed += `event:${currentEvent.type}\n`
            if (currentEvent.data) reconstructed += `data:${currentEvent.data}\n`
        }

        return { events, remaining: reconstructed + remainingPart }
    }

    abortStream() {
        if (this.currentAbortController) {
            this.currentAbortController.abort()
            this.currentAbortController = null
        }
    }

    async sendMessage(message: string, conversationId?: string, context?: any): Promise<any> {
        try {
            const response = await fetch(`${this.baseUrl}/api/orchestrator/chat`, {
                method: 'POST',
                headers: {
                    ...(await getAuthHeadersAsync()),
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    message,
                    platform: 'mobile',
                    conversationId,
                    context: context || {},
                }),
            })

            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`)
            }

            return await response.json()
        } catch (error) {
            console.error('Failed to send message:', error)
            throw error
        }
    }

    private processSSEEvent(
        eventType: string,
        data: any,
        onChunk: (chunk: StreamChunk) => void,
        onAction?: (action: ActionEvent) => void,
        onInline?: (type: 'task' | 'event' | 'automation' | 'button' | 'flight', data: any) => void,
        onCategory?: (category: string) => void,
        onStatus?: (status: string, message: string) => void,
        onProgress?: (data: any) => void,
        onSources?: (sources: any[]) => void,
        onMedia?: (media: any[]) => void,
        onProducts?: (products: any[]) => void,
        onCard?: (cardType: 'flight' | 'hotel' | 'booking' | 'product_carousel' | 'product_detail', data: any) => void
    ): void {
        if (eventType === 'text') {
            onChunk({
                text: data.chunk || data.content || '',
                done: data.done || false,
                conversationId: data.conversationId,
                suggestions: data.suggestions,
                voice_chunk: data.voice_chunk || false
            })
        } else if (eventType === 'tool_result' && onAction) {
            onAction({
                type: 'tool_result',
                tool_name: data.tool_name,
                result: data.result,
                defer_render: data.defer_render
            } as ActionEvent)

            if (onInline && data.result) {
                if (data.result.task) onInline('task', data.result.task)
                else if (data.result.event) onInline('event', data.result.event)
                else if (data.result.flight) onInline('flight', data.result.flight)
            }
        } else if (eventType === 'tool_complete' && onAction) {
            onAction({ type: 'tool_complete', message: data.message } as ActionEvent)
        } else if (eventType === 'action' && onAction) {
            onAction(data as ActionEvent)
        } else if (eventType === 'inline' && onInline) {
            onInline(data.inlineType || data.type, data.data || data)
        } else if (eventType === 'status' && onStatus) {
            onStatus(data.status, data.message)
        } else if (eventType === 'progress' && onProgress) {
            onProgress({ ...data, eventType: 'progress' })
        } else if (eventType === 'result' && onProgress) {
            onProgress({ ...data, eventType: 'result' })
        } else if (eventType === 'sources' && onSources) {
            onSources(data.sources || [])
        } else if (eventType === 'media' && onMedia) {
            onMedia(data.media || [])
        } else if (eventType === 'products' && onProducts) {
            onProducts(data.products || [])
        } else if (eventType === 'card' && onCard) {
            onCard(data.cardType, data.data)
        }
    }
}

export default new AgentService()
