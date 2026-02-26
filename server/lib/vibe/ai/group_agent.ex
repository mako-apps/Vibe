defmodule Vibe.AI.GroupAgent do
  @moduledoc """
  AI Agent for group/channel chats.
  Handles @vibe mentions, generates responses with per-group custom prompts,
  and manages conversation memory with auto-compaction.
  """

  require Logger

  alias Vibe.Chat.{GroupAgent, GroupAgentMemory}
  alias Vibe.Repo

  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-haiku-4-5-20251001"

  # Well-known UUID for the Vibe AI agent virtual user
  @agent_user_id "00000000-0000-0000-0000-000000000001"
  @agent_username "vibe_ai_agent_0001"

  # Memory thresholds
  @compaction_threshold 50
  @keep_recent_count 10
  @context_message_limit 30

  @default_system_prompt """
  You are Vibe AI, a helpful assistant in this group chat.
  Be concise, practical, and context-aware.
  """

  # Tools available to group agents
  @tools [
    %{
      name: "search_google",
      description: "Search the web using Google. Returns relevant web results.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query"}
        },
        required: ["query"]
      }
    },
    %{
      name: "analyze_image",
      description: "Analyze an image URL. Can describe contents, read text (OCR), identify objects.",
      input_schema: %{
        type: "object",
        properties: %{
          image_url: %{type: "string", description: "URL of the image to analyze"},
          task: %{type: "string", description: "What to do: describe, ocr, identify, or custom question"}
        },
        required: ["image_url"]
      }
    },
    %{
      name: "analyze_document",
      description: "Analyze a document (PDF, text). Extract information, summarize, or answer questions.",
      input_schema: %{
        type: "object",
        properties: %{
          document_url: %{type: "string", description: "URL of the document"},
          task: %{type: "string", description: "What to do: summarize, extract_key_points, answer_question"},
          question: %{type: "string", description: "Optional specific question about the document"}
        },
        required: ["document_url", "task"]
      }
    },
    %{
      name: "create_document",
      description:
        "Create a formatted document draft from user instructions. Supports markdown, plain_text, html, and json.",
      input_schema: %{
        type: "object",
        properties: %{
          title: %{type: "string", description: "Document title"},
          body: %{type: "string", description: "Document main content"},
          format: %{
            type: "string",
            enum: ["markdown", "plain_text", "html", "json"],
            description: "Output document format"
          },
          sections: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional section headings to structure the document"
          }
        },
        required: ["title", "body"]
      }
    }
  ]

  @doc """
  Returns the well-known agent user ID constant.
  """
  def agent_user_id, do: @agent_user_id

  @doc """
  Returns default system prompt text for group agents.
  """
  def default_system_prompt, do: @default_system_prompt

  @doc """
  Returns all available tool definitions for the group agent.
  """
  def available_tools, do: @tools

  @doc """
  Returns all available tool names.
  """
  def available_tool_names, do: Enum.map(@tools, & &1.name)

  @doc """
  Normalize enabled tools list coming from API input/database.
  Falls back to all available tools if list is empty or invalid.
  """
  def normalize_enabled_tools(raw_tools) do
    allowed = MapSet.new(available_tool_names())

    normalized =
      raw_tools
      |> normalize_tools_input()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(allowed, &1))

    if normalized == [], do: available_tool_names(), else: normalized
  end

  @doc """
  Generate an enhanced system prompt from short admin input.
  Uses LLM when available and falls back to deterministic prompt text.
  """
  def generate_system_prompt(user_input, enabled_tools \\ nil) do
    trimmed_input =
      user_input
      |> to_string()
      |> String.trim()

    if trimmed_input == "" do
      {:error, :empty_input}
    else
      normalized_tools = normalize_enabled_tools(enabled_tools)
      prompt = build_prompt_generation_instruction(trimmed_input, normalized_tools)

      case Vibe.AI.Agent.quick_completion(prompt) do
        {:ok, generated} ->
          final_prompt = normalize_generated_prompt(generated, trimmed_input)
          {:ok, final_prompt}

        {:error, _reason} ->
          {:ok, fallback_generated_prompt(trimmed_input)}
      end
    end
  end

  @doc """
  Handle an @vibe mention in a group chat.
  Loads agent config, builds context with memory, calls Claude, and broadcasts the response.
  """
  def handle_mention(chat_id, user_message, user_id, metadata \\ %{}) do
    Logger.info("[GroupAgent] handle_mention called chat_id=#{chat_id} user_id=#{user_id} msg_len=#{String.length(user_message)}")

    case GroupAgent.get_enabled_by_chat(chat_id) do
      nil ->
        Logger.info("[GroupAgent] No enabled agent for chat #{chat_id}")
        {:error, :no_agent}

      agent_config ->
        process_mention(chat_id, agent_config, user_message, user_id, metadata)
    end
  end

  defp process_mention(chat_id, agent_config, user_message, user_id, metadata) do
    enabled_tools = normalize_enabled_tools(Map.get(agent_config, :enabled_tools))

    # 1. Load memory
    {:ok, memory} = GroupAgentMemory.get_or_create(chat_id)
    Logger.info("[GroupAgent] Memory loaded for #{chat_id}: #{length(memory.messages)} messages, summary=#{if memory.summary, do: "yes", else: "no"}")

    # 2. Build system prompt with memory context
    system_prompt = build_system_prompt(agent_config, memory, enabled_tools)

    # 3. Build message history from memory + current message
    messages = build_messages(memory, user_message, metadata)
    Logger.info("[GroupAgent] Calling Claude for #{chat_id}: #{length(messages)} messages, system_prompt_len=#{String.length(system_prompt)}")

    # 4. Call Claude
    case call_claude(messages, system_prompt, user_id, enabled_tools) do
      {:ok, response} ->
        # 5. Store in memory
        attachment_summary = summarize_attachments_for_memory(metadata)
        stored_user_content =
          user_message
          |> String.trim()
          |> append_attachment_summary_for_storage(attachment_summary)

        GroupAgentMemory.append_message(chat_id, %{
          "role" => "user",
          "content" => stored_user_content,
          "user_id" => user_id
        })

        GroupAgentMemory.append_message(chat_id, %{
          "role" => "assistant",
          "content" => response
        })

        # 6. Check if compaction needed
        maybe_compact(chat_id)

        # 7. Broadcast agent response as a chat message
        broadcast_agent_message(chat_id, agent_config, response, metadata)

        {:ok, response}

      {:error, reason} ->
        Logger.error("[GroupAgent] Claude error for chat #{chat_id}: #{inspect(reason)}")
        # Broadcast an error message so users know something went wrong
        broadcast_agent_message(chat_id, agent_config, "Sorry, I encountered an error processing your request. Please try again.", metadata)
        {:error, reason}
    end
  end

  defp build_system_prompt(agent_config, memory, enabled_tools) do
    base_system_prompt =
      (agent_config.system_prompt || @default_system_prompt)
      |> to_string()
      |> String.trim()

    tool_descriptions =
      @tools
      |> Enum.filter(&(&1.name in enabled_tools))
      |> Enum.map(fn tool -> "- #{tool.name}: #{tool.description}" end)
      |> Enum.join("\n")

    base_prompt = """
    #{base_system_prompt}

    IMPORTANT RULES:
    - You are #{agent_config.name}, an AI assistant in this group chat.
    - Keep responses concise and relevant — this is mobile chat.
    - When using tools, call them IMMEDIATELY without intro text.
    - You can reference previous conversations from your memory.
    - Address users naturally, referring to the group context.
    - Only use tools that are enabled for this group.
    - If attachments are provided in the current message context, use them.

    ENABLED TOOLS:
    #{if tool_descriptions == "", do: "- none", else: tool_descriptions}
    """

    case memory.summary do
      nil -> base_prompt
      "" -> base_prompt
      summary ->
        base_prompt <> "\n\nConversation Memory (summary of earlier interactions):\n#{summary}\n"
    end
  end

  defp build_messages(memory, current_message, metadata) do
    # Take last N messages from memory as context
    recent_messages =
      memory.messages
      |> Enum.take(-@context_message_limit)
      |> Enum.map(fn msg ->
        %{
          role: msg["role"] || "user",
          content: msg["content"] || ""
        }
      end)
      |> Enum.filter(fn msg -> msg.content != "" end)

    image_urls = normalize_url_list(Map.get(metadata, "image_urls", []))
    document_urls = normalize_url_list(Map.get(metadata, "document_urls", []))

    attachment_context = build_attachment_context(image_urls, document_urls)
    merged_message_text = append_attachment_context(current_message, attachment_context)

    # Build current message with optional images
    current_content = if Enum.empty?(image_urls) do
      merged_message_text
    else
      image_blocks = Enum.map(image_urls, fn url ->
        %{type: "image", source: %{type: "url", url: url}}
      end)
      image_blocks ++ [%{type: "text", text: merged_message_text}]
    end

    recent_messages ++ [%{role: "user", content: current_content}]
  end

  defp call_claude(messages, system_prompt, user_id, enabled_tools) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")
    Logger.info("[GroupAgent] API key configured: #{if api_key, do: "yes (#{String.length(api_key)} chars)", else: "NO - MISSING"}")

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      enabled_tool_definitions =
        @tools
        |> Enum.filter(&(&1.name in enabled_tools))

      call_claude_with_tools(messages, system_prompt, api_key, 0, user_id, enabled_tools, enabled_tool_definitions)
    end
  end

  defp call_claude_with_tools(
         messages,
         system_prompt,
         api_key,
         depth,
         user_id,
         enabled_tools,
         enabled_tool_definitions
       ) do
    if depth > 3 do
      {:error, "Max tool depth reached"}
    else
      body = Jason.encode!(%{
        model: @claude_model,
        max_tokens: 4096,
        system: system_prompt,
        tools: enabled_tool_definitions,
        messages: messages
      })

      headers = [
        {"Content-Type", "application/json"},
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]

      request = Finch.build(:post, @claude_api, headers, body)

      case Finch.request(request, Vibe.Finch, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: resp_body}} ->
          case Jason.decode(resp_body) do
            {:ok, %{"content" => content, "stop_reason" => stop_reason} = parsed} ->
              Logger.info("[GroupAgent] Claude response received, stop_reason=#{inspect(stop_reason)}")

              if stop_reason == "tool_use" do
                # Handle tool calls
                handle_tool_response(
                  content,
                  messages,
                  system_prompt,
                  api_key,
                  depth,
                  user_id,
                  enabled_tools,
                  enabled_tool_definitions
                )
              else
                # Extract text from response
                text = extract_text(content)
                {:ok, text}
              end

            {:ok, %{"content" => content} = parsed} ->
              Logger.info("[GroupAgent] Claude response received, stop_reason=#{inspect(Map.get(parsed, "stop_reason"))}")
              # Extract text from response
              text = extract_text(content)
              {:ok, text}

            other ->
              Logger.error("[GroupAgent] Failed to parse Claude response: #{inspect(other)}")
              {:error, "Failed to parse Claude response"}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.error("[GroupAgent] Claude API error: status=#{status} body=#{String.slice(body, 0..500)}")
          {:error, "API error: #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_tool_response(
         content,
         messages,
         system_prompt,
         api_key,
         depth,
         user_id,
         enabled_tools,
         enabled_tool_definitions
       ) do
    # Extract tool calls from content
    tool_calls = Enum.filter(content, fn
      %{"type" => "tool_use"} -> true
      _ -> false
    end)

    # Execute tools
    tool_results = Enum.map(tool_calls, fn tool ->
      result = execute_tool(tool["name"], tool["input"], user_id, enabled_tools)
      %{
        "type" => "tool_result",
        "tool_use_id" => tool["id"],
        "content" => Jason.encode!(result)
      }
    end)

    # Build content blocks for assistant message (text + tool_use blocks)
    assistant_content = Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{type: "text", text: text}
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        %{type: "tool_use", id: id, name: name, input: input}
      other -> other
    end)

    new_messages = messages ++ [
      %{role: "assistant", content: assistant_content},
      %{role: "user", content: tool_results}
    ]

    call_claude_with_tools(
      new_messages,
      system_prompt,
      api_key,
      depth + 1,
      user_id,
      enabled_tools,
      enabled_tool_definitions
    )
  end

  defp execute_tool(name, input, _user_id, enabled_tools) do
    if name in enabled_tools do
      start_time = System.monotonic_time(:millisecond)

      result =
        case name do
          "search_google" -> Vibe.AI.Tools.Search.google(input)
          "analyze_image" -> Vibe.AI.Tools.Vision.analyze(input)
          "analyze_document" -> Vibe.AI.Tools.Document.analyze(input)
          "create_document" -> create_document_tool(input)
          _ -> %{error: "Unknown tool: #{name}"}
        end

      duration_ms = System.monotonic_time(:millisecond) - start_time
      Logger.info("[GroupAgent] Tool #{name} completed in #{duration_ms}ms")
      result
    else
      Logger.warning("[GroupAgent] Blocked disabled tool call #{name}")
      %{error: "Tool '#{name}' is disabled for this group."}
    end
  end

  defp create_document_tool(input) do
    title =
      input
      |> tool_input_value("title")
      |> default_if_blank("Document")

    body =
      input
      |> tool_input_value("body")
      |> default_if_blank("Draft content")

    format =
      input
      |> tool_input_value("format")
      |> String.downcase()
      |> case do
        "plain_text" -> "plain_text"
        "html" -> "html"
        "json" -> "json"
        _ -> "markdown"
      end

    sections =
      case input do
        %{"sections" => raw_sections} -> normalize_section_headings(raw_sections)
        %{sections: raw_sections} -> normalize_section_headings(raw_sections)
        _ -> []
      end

    structured_body =
      if sections == [] do
        body
      else
        headings =
          sections
          |> Enum.map_join("\n", fn heading -> "## #{heading}\n\n- Add details here." end)

        body <> "\n\n" <> headings
      end

    content =
      case format do
        "plain_text" ->
          "#{title}\n\n#{structured_body}"

        "html" ->
          "<h1>#{escape_html(title)}</h1>\n<p>#{escape_html(structured_body)}</p>"

        "json" ->
          Jason.encode!(%{
            title: title,
            content: structured_body,
            sections: sections
          })

        _ ->
          "# #{title}\n\n#{structured_body}"
      end

    %{
      ok: true,
      title: title,
      format: format,
      content: content,
      note: "Document draft generated. You can send or refine it in chat."
    }
  end

  defp tool_input_value(input, key) do
    case input do
      %{^key => value} -> to_string(value || "")
      %{} ->
        atom_value =
          try do
            Map.get(input, String.to_existing_atom(key), "")
          rescue
            _ -> ""
          end

        to_string(atom_value || "")
      _ -> ""
    end
    |> String.trim()
  end

  defp normalize_section_headings(raw_sections) when is_list(raw_sections) do
    raw_sections
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_section_headings(_), do: []

  defp escape_html(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp default_if_blank(text, fallback) do
    trimmed = text |> to_string() |> String.trim()
    if trimmed == "", do: fallback, else: trimmed
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn
      %{"type" => "text"} -> true
      _ -> false
    end)
    |> Enum.map(fn %{"text" => text} -> text end)
    |> Enum.join("")
  end
  defp extract_text(content) when is_binary(content), do: content
  defp extract_text(_), do: ""

  defp normalize_tools_input(raw_tools) do
    cond do
      is_list(raw_tools) ->
        Enum.map(raw_tools, &to_string/1)

      is_binary(raw_tools) ->
        raw_tools
        |> String.split(",")
        |> Enum.map(&String.trim/1)

      true ->
        []
    end
  end

  defp build_prompt_generation_instruction(user_input, enabled_tools) do
    tool_list =
      enabled_tools
      |> Enum.map_join(", ", &"`#{&1}`")

    """
    Create a high-quality system prompt for a group chat AI assistant.
    The prompt must be practical, concise, and optimized for short mobile-chat answers.
    It should include tone, boundaries, response style, and how to use tools safely.
    Enabled tools for this assistant: #{tool_list}.

    Admin's high-level intent:
    #{user_input}

    Return only the final system prompt text. No markdown fences. No explanations.
    """
  end

  defp normalize_generated_prompt(raw_prompt, fallback_input) do
    generated =
      raw_prompt
      |> to_string()
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")

    if String.length(generated) < 40 do
      fallback_generated_prompt(fallback_input)
    else
      generated
    end
  end

  defp fallback_generated_prompt(user_input) do
    """
    #{@default_system_prompt}

    Group-specific objective:
    #{user_input}

    Behavior:
    - Prioritize direct answers in 1-3 short paragraphs.
    - Ask clarifying questions when user intent is ambiguous.
    - Use enabled tools when they improve factual accuracy or attachment analysis.
    - If a requested action requires a disabled tool, state that clearly and suggest an alternative.
    """
    |> String.trim()
  end

  defp normalize_url_list(raw_urls) when is_list(raw_urls) do
    raw_urls
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_url_list(raw_urls) when is_binary(raw_urls) do
    normalize_url_list([raw_urls])
  end

  defp normalize_url_list(_), do: []

  defp build_attachment_context(image_urls, document_urls) do
    image_lines = Enum.map(image_urls, &"- image: #{&1}")
    document_lines = Enum.map(document_urls, &"- document: #{&1}")
    lines = image_lines ++ document_lines
    if lines == [], do: "", else: "Attached context:\n" <> Enum.join(lines, "\n")
  end

  defp append_attachment_context(current_message, attachment_context) do
    base = current_message |> to_string() |> String.trim()

    if attachment_context == "" do
      base
    else
      [base, attachment_context]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
    end
  end

  defp summarize_attachments_for_memory(metadata) do
    images = normalize_url_list(Map.get(metadata, "image_urls", []))
    documents = normalize_url_list(Map.get(metadata, "document_urls", []))
    %{images: images, documents: documents}
  end

  defp append_attachment_summary_for_storage(content, %{images: images, documents: documents}) do
    summary_lines =
      (Enum.map(images, &"[image] #{&1}") ++ Enum.map(documents, &"[document] #{&1}"))
      |> Enum.uniq()

    if summary_lines == [] do
      content
    else
      [content, Enum.join(summary_lines, "\n")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp broadcast_agent_message(chat_id, agent_config, text, metadata) do
    Logger.info("[GroupAgent] Broadcasting agent message in #{chat_id}: #{String.slice(text, 0..80)}...")

    message_id = Ecto.UUID.generate()
    timestamp = :os.system_time(:millisecond)
    reply_to_id = Map.get(metadata, "reply_to_id")

    payload = %{
      "id" => message_id,
      "fromId" => @agent_user_id,
      "chatId" => chat_id,
      "encryptedContent" => "",
      "plainContent" => text,
      "type" => "text",
      "timestamp" => timestamp,
      "status" => "sent",
      "isAgentMessage" => true,
      "agentName" => agent_config.name,
      "replyToId" => reply_to_id
    }

    # Broadcast to the chat channel
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

    # Persist the agent message to the database
    Task.start(fn ->
      case ensure_agent_user_record() do
        :ok ->
          message_attrs = %{
            id: message_id,
            chat_id: chat_id,
            from_id: @agent_user_id,
            encrypted_content: text,
            type: "text",
            timestamp: timestamp,
            reply_to_id: reply_to_id
          }

          case Vibe.Chat.add_message(message_attrs) do
            {:ok, _msg} ->
              Logger.info(
                "[GroupAgent] Agent message persisted chat_id=#{chat_id} message_id=#{message_id}"
              )

              # Notify all participants about the new message
              participants = Vibe.Chat.get_all_participant_settings(chat_id)

              Enum.each(participants, fn p ->
                VibeWeb.Endpoint.broadcast!("user:#{p.user_id}", "new_message", %{
                  chat_id: chat_id,
                  from_id: @agent_user_id,
                  message_id: message_id,
                  timestamp: timestamp,
                  muted: p.muted || false
                })
              end)

            {:error, reason} ->
              Logger.error("[GroupAgent] Failed to persist agent message: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.error("[GroupAgent] Failed to ensure agent user row: #{inspect(reason)}")
      end
    end)
  end

  defp ensure_agent_user_record do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all(
      "users",
      [
        %{
          id: @agent_user_id,
          username: @agent_username,
          password_hash: "agent",
          public_key: "agent",
          device_id: "agent",
          inserted_at: now,
          updated_at: now
        }
      ],
      conflict_target: [:id],
      on_conflict: [set: [updated_at: now]]
    )

    :ok
  rescue
    error -> {:error, error}
  end

  # ── Memory Compaction ──

  defp maybe_compact(chat_id) do
    Task.start(fn ->
      case GroupAgentMemory.get_or_create(chat_id) do
        {:ok, memory} when length(memory.messages) > @compaction_threshold ->
          compact_memory(memory)
        _ ->
          :ok
      end
    end)
  end

  defp compact_memory(memory) do
    messages = memory.messages
    to_compact = Enum.take(messages, length(messages) - @keep_recent_count)
    to_keep = Enum.take(messages, -@keep_recent_count)

    # Format messages for summarization
    conversation_text =
      to_compact
      |> Enum.map(fn msg ->
        role = if msg["role"] == "assistant", do: "Agent", else: "User"
        "#{role}: #{msg["content"]}"
      end)
      |> Enum.join("\n")

    existing_summary = memory.summary || ""
    prompt = """
    Summarize this group chat conversation concisely, preserving key facts, decisions, data, and context that would be needed to continue the conversation. Include specific numbers, names, and commitments.

    #{if existing_summary != "", do: "Previous summary:\n#{existing_summary}\n\nNew messages to incorporate:", else: "Conversation:"}

    #{conversation_text}

    Provide a concise summary (max 500 words):
    """

    case Vibe.AI.Agent.quick_completion(prompt) do
      {:ok, summary} ->
        GroupAgentMemory.update_after_compaction(memory, String.trim(summary), to_keep)
        Logger.info("[GroupAgent] Memory compacted for chat #{memory.chat_id}: #{length(to_compact)} messages summarized")

      {:error, reason} ->
        Logger.error("[GroupAgent] Memory compaction failed for chat #{memory.chat_id}: #{inspect(reason)}")
    end
  end
end
