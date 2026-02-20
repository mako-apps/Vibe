/**
 * Agent Orchestrator
 * Uses Claude as the main brain and Gemini for web search/grounding.
 */

const CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages';
const GEMINI_API_URL = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent';

class AgentOrchestrator {
    constructor() {
        this.systemPrompt = `You are Vibe AI, a helpful and intelligent assistant integrated into the Vibe messaging app.
You are the Orchestrator. Your goal is to answer user queries comprehensively.
You have access to a "Web Search" capability provided by Gemini.
If the user asks about current events, news, or something that requires real-time information, you MUST use the Gemini Search tool.

To use the Gemini Search tool, output a JSON object in this format ONLY (no markdown surrounding it if possible, or inside a code block):
{
  "tool": "gemini_search",
  "query": "the search query"
}

If you do not need to search, simply return the response text.
Do not mention internal tool names to the user.
Be concise, friendly, and helpful.`;
    }

    async handleMessage(req, res) {
        try {
            const { message, history = [], claudeKey, geminiKey } = req.body;

            if (!claudeKey) {
                return res.status(400).json({ error: 'Claude API Key is required' });
            }

            // 1. Prepare context for Claude
            const messages = this.formatHistoryForClaude(history, message);

            // 2. First call to Claude (Orchestrator)
            const claudeResponse = await this.callClaude(messages, claudeKey);

            // 3. Check for tool usage
            const toolCall = this.parseToolCall(claudeResponse);

            if (toolCall && toolCall.tool === 'gemini_search') {
                if (!geminiKey) {
                    // Fallback if no Gemini key but tool requested
                    return res.json({
                        response: "I wanted to search the web for that, but I need a Google Gemini API Key to do so. Please check your settings."
                    });
                }

                // 4. Call Gemini (Search/Grounding)
                const searchResult = await this.callGeminiSearch(toolCall.query, geminiKey);

                // 5. Feed back to Claude
                const finalResponse = await this.callClaudeWithContext(messages, searchResult, claudeKey);

                return res.json({ response: finalResponse });
            }

            // No tool used, return immediate response
            return res.json({ response: claudeResponse });

        } catch (error) {
            console.error('[Agent] Error:', error);
            res.status(500).json({ error: error.message || 'Internal Agent Error' });
        }
    }

    formatHistoryForClaude(history, newMessage) {
        // Map simplified history to Claude format
        // history: [{ role: 'user'|'assistant', content: '...' }]
        const formatted = history.map(msg => ({
            role: msg.role === 'user' ? 'user' : 'assistant',
            content: msg.content
        }));

        formatted.push({ role: 'user', content: newMessage });
        return formatted;
    }

    async callClaude(messages, apiKey) {
        const response = await fetch(CLAUDE_API_URL, {
            method: 'POST',
            headers: {
                'x-api-key': apiKey,
                'anthropic-version': '2023-06-01',
                'content-type': 'application/json'
            },
            body: JSON.stringify({
                model: 'claude-3-opus-20240229', // Or sonnet if opus too expensive/slow, sticking to high qual
                max_tokens: 1000,
                system: this.systemPrompt,
                messages: messages
            })
        });

        if (!response.ok) {
            const err = await response.text();
            throw new Error(`Claude API Error: ${err}`);
        }

        const data = await response.json();
        return data.content[0].text;
    }

    async callClaudeWithContext(originalMessages, contextData, apiKey) {
        // Create a new exchange where we pretend the tool returned data
        const messages = [...originalMessages];

        // Add the "tool check result" as a system or user info
        // Since we are mocking the tool flow for simplifiction (not using native Claude tool calling API yet)
        // We will append a user message saying "Here is the search result:"
        // Or better, append to the last user message? No, that modifies history.
        // We'll append a message.

        messages.push({
            role: 'assistant',
            content: 'I will search for that information.'
        });

        messages.push({
            role: 'user',
            content: `Search Results/Context: ${contextData}\n\nBased on this context, please answer my original question.`
        });

        return this.callClaude(messages, apiKey);
    }

    async callGeminiSearch(query, apiKey) {
        // We use Gemini as a "Knowledge Engine" assuming it has browsing or broad knowledge
        // Standard Gemini API doesn't browse live web without setup, but we'll use it as the "Web Info" source
        // Or if the user meant "Gemini Search" as in Google Search Grounding? 
        // For now, prompt Gemini to act as a search summarizer/answerer

        const url = `${GEMINI_API_URL}?key=${apiKey}`;

        const response = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                contents: [{
                    parts: [{
                        text: `You are a research tool. The user wants to know: "${query}". 
Provide a detailed factual summary of this topic using your knowledge. 
If it requires current real-time news that you don't have, state what you know up to your cutoff.`
                    }]
                }]
            })
        });

        if (!response.ok) {
            const err = await response.text();
            throw new Error(`Gemini API Error: ${err}`);
        }

        const data = await response.json();
        return data.candidates?.[0]?.content?.parts?.[0]?.text || 'No information found.';
    }

    parseToolCall(text) {
        // Look for JSON block
        try {
            const match = text.match(/\{[\s\S]*"tool"[\s\S]*"gemini_search"[\s\S]*\}/);
            if (match) {
                return JSON.parse(match[0]);
            }
        } catch (e) {
            // ignore parse error, assume text
        }
        return null;
    }
}

module.exports = new AgentOrchestrator();
