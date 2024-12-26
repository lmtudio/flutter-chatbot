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

import "../util.dart";
import "../gen/l10n.dart";
import "../chat/chat.dart";

import "dart:io";
import "package:chatbot/config.dart";
import "package:flutter/material.dart";
import "package:image_picker/image_picker.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

class ModelTab extends ConsumerWidget {
  const ModelTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatProvider);

    final modelSet = <String>{};
    for (final api in Config.apis.values) {
      modelSet.addAll(api.models);
    }
    final modelList = modelSet.toList();

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: modelList.length,
      itemBuilder: (context, index) {
        final id = modelList[index];

        return Card.filled(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: ModelAvatar(id: id, key: ValueKey(id)),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            title: Text(
              Config.models[id]?.name ?? id,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            subtitle: Text(
              id,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onTap: () => showModalBottomSheet(
              context: context,
              useSafeArea: true,
              isScrollControlled: true,
              builder: (context) => Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                ),
                child: _ModelEditor(id: id),
              ),
            ),
          ),
        );
      },
      separatorBuilder: (context, index) => const SizedBox(height: 12),
    );
  }
}

class _ModelEditor extends ConsumerStatefulWidget {
  final String id;

  const _ModelEditor({required this.id});

  @override
  ConsumerState<_ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends ConsumerState<_ModelEditor> {
  XFile? _avatar;
  late String _id;
  late bool? _chat;
  late final ModelConfig? _model;
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _id = widget.id;
    _model = Config.models[_id];
    _chat = _model?.chat;
    _ctrl = TextEditingController(
      text: _model?.name ?? _id,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding:
              const EdgeInsets.only(top: 16, left: 24, right: 12, bottom: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                S.of(context).model,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: Navigator.of(context).pop,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 24, right: 24),
          child: TextField(
            controller: _ctrl,
            decoration: InputDecoration(
              hintText: widget.id,
              labelText: S.of(context).model_name,
              border: const UnderlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _chat ?? true,
          title: Text(S.of(context).chat_model),
          subtitle: Text(S.of(context).chat_model_hint),
          onChanged: (value) => setState(() => _chat = value),
          contentPadding: const EdgeInsets.only(left: 24, right: 16),
        ),
        ListTile(
          title: Text(S.of(context).model_avatar),
          subtitle: Text(S.of(context).model_avatar_hint),
          trailing: _buildAvatar(),
          onTap: _pickAvatar,
          contentPadding: const EdgeInsets.only(left: 24, right: 16),
        ),
        const Divider(height: 1),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: Navigator.of(context).pop,
              child: Text(S.of(context).cancel),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _save,
              child: Text(S.of(context).ok),
            ),
            const SizedBox(width: 24),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildAvatar() {
    String? path = _avatar?.path;
    if (_avatar == null) {
      path = _model?.avatar;
      if (path != null) {
        path = Config.avatarFilePath(path);
      }
    }

    if (path == null) {
      return const CircleAvatar(
        child: Icon(Icons.smart_toy),
      );
    }

    return ClipOval(
      child: Image.file(
        File(path),
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        frameBuilder: (context, child, frame, loaded) {
          if (loaded) return child;
          return AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: frame == null ? 0 : 1,
            curve: Curves.easeOut,
            child: child,
          );
        },
      ),
    );
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    XFile? result;

    try {
      result = await picker.pickImage(
        source: ImageSource.gallery,
      );
      if (result == null) return;
    } catch (e) {
      return;
    }

    setState(() => _avatar = result);
  }

  Future<void> _save() async {
    final name = _ctrl.text;
    if (name.isEmpty) return;

    var avatar = _model?.avatar;
    if (_avatar != null) {
      final name = _avatar!.name;
      final pos = name.lastIndexOf('.');
      final suffix = pos > 0 ? name.substring(pos) : "";
      final time = DateTime.now().millisecondsSinceEpoch;
      if (avatar != null) await File(Config.avatarFilePath(avatar)).delete();

      avatar = "$time$suffix";
      await _avatar!.saveTo(Config.avatarFilePath(avatar));
    }

    final chat = _chat ?? true;
    Config.models[_id] = ModelConfig(
      avatar: avatar,
      name: name,
      chat: chat,
    );
    Config.save();

    ref.read(messagesProvider.notifier).notify();
    ref.read(chatProvider.notifier).notify();
    if (mounted) Navigator.of(context).pop();
  }
}
