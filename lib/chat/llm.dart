// This file is part of ChatBot.
//
// ChatBot is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// ChatBot is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with ChatBot. If not, see <https://www.gnu.org/licenses/>.

import "../config.dart";
import "../chat/chat.dart";
import "../chat/current.dart";
import "../chat/message.dart";
import "../markdown/util.dart";

import "dart:io";
import "dart:convert";
import "package:http/http.dart";
import "package:langchain/langchain.dart";
import "package:audioplayers/audioplayers.dart";
import "package:langchain_openai/langchain_openai.dart";
import "package:langchain_google/langchain_google.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

final llmProvider =
    AutoDisposeNotifierProvider<LlmNotifier, void>(LlmNotifier.new);

class LlmNotifier extends AutoDisposeNotifier<void> {
  Client? _ttsClient;
  Client? _chatClient;
  AudioPlayer? _player;

  @override
  void build() {}
  void notify() => ref.notifyListeners();

  void updateMessage(Message message) =>
      ref.read(messageProvider(message).notifier).notify();

  Future<dynamic> tts(Message message) async {
    dynamic error;

    final tts = Config.tts;
    final model = tts.model!;
    final voice = tts.voice!;
    final api = Config.apis[tts.api]!;

    final apiUrl = api.url;
    final apiKey = api.key;
    final endPoint = "$apiUrl/audio/speech";

    Current.ttsStatus = TtsStatus.loading;
    updateMessage(message);

    try {
      _ttsClient ??= Client();
      _player ??= AudioPlayer();
      final response = await _ttsClient!.post(
        Uri.parse(endPoint),
        headers: {
          "Authorization": "Bearer $apiKey",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "model": model,
          "voice": voice,
          "stream": false,
          "input": markdownToText(message.item.text),
        }),
      );

      if (response.statusCode != 200) {
        throw "${response.statusCode} ${response.body}";
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final path = Config.audioFilePath("$timestamp.mp3");

      final file = File(path);
      await file.writeAsBytes(response.bodyBytes);

      Current.ttsStatus = TtsStatus.playing;
      updateMessage(message);

      await _player!.play(DeviceFileSource(path));
      await _player!.onPlayerStateChanged.first;
    } catch (e) {
      if (!Current.ttsStatus.isNothing) error = e;
    }

    Current.ttsStatus = TtsStatus.nothing;
    updateMessage(message);
    return error;
  }

  void stopTts() {
    Current.ttsStatus = TtsStatus.nothing;
    _ttsClient?.close();
    _ttsClient = null;
    _player?.stop();
  }

  Future<dynamic> chat(Message message) async {
    dynamic error;

    final model = Current.model!;
    final apiUrl = Current.apiUrl!;
    final apiKey = Current.apiKey!;
    final apiType = Current.apiType;
    final messages = Current.messages;

    final item = message.item;
    final chatContext = _buildContext(messages);

    Current.chatStatus = ChatStatus.responding;
    updateMessage(message);
    notify();

    try {
      _chatClient = switch (apiType) {
        "google" => _GoogleClient(baseUrl: apiUrl),
        _ => Client(),
      };

      BaseChatModel llm = switch (apiType) {
        "google" => ChatGoogleGenerativeAI(
            apiKey: apiKey,
            baseUrl: apiUrl,
            client: _chatClient,
            defaultOptions: ChatGoogleGenerativeAIOptions(
              model: model,
              temperature: Current.temperature,
              maxOutputTokens: Current.maxTokens,
            ),
          ),
        _ => ChatOpenAI(
            apiKey: apiKey,
            baseUrl: apiUrl,
            client: _chatClient,
            defaultOptions: ChatOpenAIOptions(
              model: model,
              maxTokens: Current.maxTokens,
              temperature: Current.temperature,
            ),
          ),
      };

      if (Current.stream ?? true) {
        final stream = llm.stream(PromptValue.chat(chatContext));
        await for (final chunk in stream) {
          item.text += chunk.output.content;
          updateMessage(message);
        }
      } else {
        final result = await llm.invoke(PromptValue.chat(chatContext));
        item.text += result.output.content;
        updateMessage(message);
      }
    } catch (e) {
      if (!Current.chatStatus.isNothing) error = e;
      if (item.text.isEmpty) {
        if (message.list.length == 1) {
          messages.length -= 2;
          ref.read(messagesProvider.notifier).notify();
        } else {
          message.list.removeAt(message.index--);
          updateMessage(message);
        }
      }
    }

    Current.chatStatus = ChatStatus.nothing;
    updateMessage(message);
    notify();

    return error;
  }

  void stopChat() {
    Current.chatStatus = ChatStatus.nothing;
    _chatClient?.close();
    _chatClient = null;
  }
}

Future<String> generateTitle(String text) async {
  if (!(Config.title.enable ?? false)) return text;

  final model = Config.title.model;
  final api = Config.apis[Config.title.api];
  if (api == null || model == null) return text;

  final prompt = Config.title.prompt ??
      """
Based on the user input below, generate a concise and relevant title.
Note: Only return the title text, without any additional content!

Output examples:
1. C Language Discussion
2. 数学问题解答
3. 電影推薦

User input:
{text}
      """
          .trim();

  final apiUrl = api.url;
  final apiKey = api.key;
  final apiType = api.type;

  final client = switch (apiType) {
    "google" => _GoogleClient(
        baseUrl: apiUrl,
        enableSearch: false,
      ),
    _ => Client(),
  };

  BaseChatModel llm = switch (apiType) {
    "google" => ChatGoogleGenerativeAI(
        apiKey: apiKey,
        client: client,
        baseUrl: apiUrl,
        defaultOptions: ChatGoogleGenerativeAIOptions(
          model: model,
        ),
      ),
    _ => ChatOpenAI(
        apiKey: apiKey,
        client: client,
        baseUrl: apiUrl,
        defaultOptions: ChatOpenAIOptions(
          model: model,
        ),
      ),
  };

  final chain = ChatPromptTemplate.fromTemplate(prompt).pipe(llm);
  final res = await chain.invoke({"text": text});
  return res.output.content.trim();
}

List<ChatMessage> _buildContext(List<Message> list) {
  final context = <ChatMessage>[];
  final items = [
    for (final message in list) message.item,
  ];
  if (items.last.role.isAssistant) items.removeLast();

  if (Current.systemPrompts != null) {
    context.add(ChatMessage.system(Current.systemPrompts!));
  }

  for (final item in items) {
    switch (item.role) {
      case MessageRole.assistant:
        context.add(ChatMessage.ai(item.text));
        break;

      case MessageRole.user:
        if (item.images.isEmpty) {
          context.add(ChatMessage.humanText(item.text));
        } else {
          context.add(ChatMessage.human(ChatMessageContent.multiModal([
            ChatMessageContent.text(item.text),
            for (final image in item.images)
              ChatMessageContent.image(
                mimeType: "image/jpeg",
                data: image.base64,
              ),
          ])));
        }
        break;
    }
  }

  return context;
}

class _GoogleClient extends BaseClient {
  final String baseUrl;
  final bool enableSearch;

  final Client _client = Client();

  _GoogleClient({
    required this.baseUrl,
    this.enableSearch = true,
  });

  BaseRequest _hook(BaseRequest origin) {
    if (origin is! Request) {
      return origin;
    }

    final request = Request(
      origin.method,
      Uri.parse("${origin.url}".replaceFirst(
        "https://generativelanguage.googleapis.com/v1beta",
        baseUrl,
      )),
    );
    request.headers.addAll(origin.headers);

    final bodyJson = jsonDecode(origin.body);

    if (enableSearch && Preferences.search) {
      bodyJson["tools"] = const [
        {"google_search": {}},
      ];
    }

    request.body = jsonEncode(bodyJson);
    return request;
  }

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    request = _hook(request);
    return _client.send(request);
  }

  @override
  void close() {
    super.close();
    _client.close();
  }
}
